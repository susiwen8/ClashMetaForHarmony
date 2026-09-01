#include "cmfa_napi.h"
#include "cmfa_mihomo_backend.h"

#include <array>
#include <cstring>
#include <new>
#include <string_view>
#include <utility>

namespace cmfa::nodeaddon {

struct AsyncCompletionPayload {
  std::shared_ptr<AsyncPromiseJob> job;
  AsyncResult result;
};

namespace {

struct AsyncTsfnFinalizerState {
  std::shared_ptr<AsyncPromiseJob> job;
};

constexpr char kProxyBufferCanary = static_cast<char>(0x7F);
constexpr std::array<std::string_view, 14> kStopTunBackendFailurePrefixes = {
    "TUN_STOP_LISTENER_FAILED_BAD_FD",
    "TUN_STOP_LISTENER_FAILED_ALREADY_CLOSED",
    "TUN_STOP_LISTENER_FAILED_INVALID",
    "TUN_STOP_LISTENER_FAILED_IO",
    "TUN_STOP_LISTENER_FAILED_OTHER",
    "TUN_STOP_LISTENER_FAILED_PANIC",
    "TUN_STOP_HTTP_LISTENER_FAILED_ERROR",
    "TUN_STOP_HTTP_LISTENER_FAILED_PANIC",
    "TUN_STOP_SOCKS_LISTENER_FAILED_ERROR",
    "TUN_STOP_SOCKS_LISTENER_FAILED_PANIC",
    "TUN_STOP_CONNECTIONS_FAILED_ERROR",
    "TUN_STOP_CONNECTIONS_FAILED_PANIC",
    "TUN_STOP_EXECUTOR_FAILED_ERROR",
    "TUN_STOP_EXECUTOR_FAILED_PANIC",
};
constexpr std::string_view kStopTunContractBackendFailed = "TUN_STOP_CONTRACT_BACKEND_FAILED";
constexpr std::string_view kStopTunContractSnapshotFailed = "TUN_STOP_CONTRACT_SNAPSHOT_FAILED";
constexpr std::string_view kStopTunContractTracesFailed = "TUN_STOP_CONTRACT_TRACES_FAILED";
constexpr std::string_view kStopTunContractEmpty = "TUN_STOP_CONTRACT_EMPTY";
constexpr std::string_view kStopTunContractOther = "TUN_STOP_CONTRACT_OTHER";
constexpr std::string_view kStopTunProxyDelayDrainFailed = "TUN_STOP_PROXY_DELAY_DRAIN_FAILED";

cmfa::napi::ReleaseResult finish_async(AddonState *addon, AsyncThreadHandle *handle) {
  if (addon == nullptr || handle == nullptr) {
    return cmfa::napi::ReleaseResult::NOT_REGISTERED;
  }
  return addon->owner.finish_async(handle);
}

cmfa::napi::ReleaseResult release_delivery(AddonState *addon, AsyncDelivery *delivery, bool abort) {
  if (addon == nullptr || delivery == nullptr) {
    return cmfa::napi::ReleaseResult::NOT_REGISTERED;
  }
  return addon->owner.release_delivery(delivery, abort);
}

void request_cancel_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  async_handle->cancel_requested.store(true, std::memory_order_relaxed);
  if (async_handle->op != AsyncOp::PROBE_HTTPS || async_handle->probe_run_id.empty()) {
    return;
  }

  bool expected = false;
  if (!async_handle->probe_cancel_requested.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel, std::memory_order_acquire)) {
    return;
  }

  std::array<char, 128> error_message{};
  cmfa_error error{};
  error.code = CMFA_OK;
  error.message = error_message.data();
  error.capacity = error_message.size();
  error.length = 0;
  (void)cmfa::cancel_mihomo_probe(async_handle->probe_run_id.c_str(), &error);
}

void join_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  if (async_handle->worker.get_id() == std::this_thread::get_id()) {
    return;
  }
  if (async_handle->worker.joinable()) {
    async_handle->worker.join();
  }
}

void release_async(void *handle) {
  auto *async_handle = static_cast<AsyncThreadHandle *>(handle);
  if (async_handle->worker.joinable() && async_handle->worker.get_id() == std::this_thread::get_id()) {
    async_handle->worker.detach();
    delete async_handle;
    return;
  }
  if (async_handle->worker.joinable()) {
    async_handle->worker.join();
  }
  delete async_handle;
}

void abort_delivery(void *handle) {
  auto *delivery = static_cast<AsyncDelivery *>(handle);
  bool expected = false;
  if (delivery->abort_consumed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
  }
}

void release_delivery_handle(void *handle) {
  auto *delivery = static_cast<AsyncDelivery *>(handle);
  if (!delivery->abort_consumed.load(std::memory_order_acquire)) {
    (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_release);
  }
  delete delivery;
}

void tsfn_finalize_async(napi_env env, void *finalize_data, void *) {
  auto *state = static_cast<AsyncTsfnFinalizerState *>(finalize_data);
  if (state == nullptr) {
    return;
  }
  if (state->job->queue_failed.load(std::memory_order_acquire) && env != nullptr) {
    reject_deferred_with_napi_failure(
        env,
        state->job->deferred,
        async_operation_name(state->job->input.op),
        static_cast<napi_status>(state->job->queue_failure_status.load(std::memory_order_acquire)));
  }
  delete state;
}

bool next_utf8_code_point(std::string_view input, size_t *index, uint32_t *code_point) {
  if (*index >= input.size()) {
    return false;
  }

  const unsigned char lead = static_cast<unsigned char>(input[*index]);
  if (lead <= 0x7F) {
    *code_point = lead;
    *index += 1;
    return true;
  }

  const size_t remaining = input.size() - *index;
  if ((lead & 0xE0U) == 0xC0U) {
    if (remaining < 2) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    if ((b1 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x1FU) << 6U) | static_cast<uint32_t>(b1 & 0x3FU);
    if (cp < 0x80U) {
      return false;
    }
    *code_point = cp;
    *index += 2;
    return true;
  }

  if ((lead & 0xF0U) == 0xE0U) {
    if (remaining < 3) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    const unsigned char b2 = static_cast<unsigned char>(input[*index + 2]);
    if ((b1 & 0xC0U) != 0x80U || (b2 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x0FU) << 12U) |
                        (static_cast<uint32_t>(b1 & 0x3FU) << 6U) |
                        static_cast<uint32_t>(b2 & 0x3FU);
    if (cp < 0x800U || (cp >= 0xD800U && cp <= 0xDFFFU)) {
      return false;
    }
    *code_point = cp;
    *index += 3;
    return true;
  }

  if ((lead & 0xF8U) == 0xF0U) {
    if (remaining < 4) {
      return false;
    }
    const unsigned char b1 = static_cast<unsigned char>(input[*index + 1]);
    const unsigned char b2 = static_cast<unsigned char>(input[*index + 2]);
    const unsigned char b3 = static_cast<unsigned char>(input[*index + 3]);
    if ((b1 & 0xC0U) != 0x80U || (b2 & 0xC0U) != 0x80U || (b3 & 0xC0U) != 0x80U) {
      return false;
    }
    const uint32_t cp = (static_cast<uint32_t>(lead & 0x07U) << 18U) |
                        (static_cast<uint32_t>(b1 & 0x3FU) << 12U) |
                        (static_cast<uint32_t>(b2 & 0x3FU) << 6U) |
                        static_cast<uint32_t>(b3 & 0x3FU);
    if (cp < 0x10000U || cp > 0x10FFFFU) {
      return false;
    }
    *code_point = cp;
    *index += 4;
    return true;
  }

  return false;
}

bool is_valid_utf8(std::string_view input) {
  size_t index = 0;
  while (index < input.size()) {
    uint32_t code_point = 0;
    if (!next_utf8_code_point(input, &index, &code_point)) {
      return false;
    }
  }
  return true;
}

std::string_view bounded_error_message_view(const cmfa_error &error) {
  if (error.message == nullptr || error.capacity == 0) {
    return {};
  }
  if (error.length > 0 && error.length < error.capacity) {
    return std::string_view(error.message, error.length);
  }
  return std::string_view(error.message, strnlen(error.message, error.capacity));
}

bool matches_stop_tun_backend_prefix(std::string_view message, std::string_view prefix) {
  if (message.size() < prefix.size() || message.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  return message.size() == prefix.size() || message[prefix.size()] == ':';
}

bool message_equals(std::string_view message, std::string_view expected) {
  return message.size() == expected.size() && message.compare(0, expected.size(), expected) == 0;
}

bool message_has_prefix(std::string_view message, std::string_view prefix) {
  return message.size() >= prefix.size() && message.compare(0, prefix.size(), prefix) == 0;
}

std::string_view classify_stop_tun_contract_backend_detail(std::string_view message) {
  if (message.empty()) {
    return kStopTunContractEmpty;
  }
  if (message_equals(message, "PROXY_DELAY_BRIDGE_INVALID")) {
    return kStopTunProxyDelayDrainFailed;
  }
  if (message_equals(message, "backend stop_tun failed")) {
    return kStopTunContractBackendFailed;
  }
  if (message_equals(message, "backend tun_runtime_state after stop failed") ||
      message_equals(message, "backend returned an invalid tun state") ||
      message_has_prefix(message, "backend tun session_id ") ||
      message_has_prefix(message, "backend tun counters ") ||
      message_has_prefix(message, "backend tun failure ") ||
      message_has_prefix(message, "backend tun snapshot ")) {
    return kStopTunContractSnapshotFailed;
  }
  if (message_equals(message, "backend tun_copy_traces after stop failed") ||
      message_has_prefix(message, "backend tun trace") ||
      message_has_prefix(message, "backend tun traces ")) {
    return kStopTunContractTracesFailed;
  }
  return kStopTunContractOther;
}

void maybe_set_stop_tun_backend_detail(CoreErrorData *core_error,
                                       AsyncOp op,
                                       cmfa_status status,
                                       const cmfa_error &backend_error) {
  if (core_error == nullptr || op != AsyncOp::STOP_TUN || status != CMFA_BACKEND_ERROR) {
    return;
  }

  const std::string_view message = bounded_error_message_view(backend_error);
  for (const std::string_view prefix : kStopTunBackendFailurePrefixes) {
    if (matches_stop_tun_backend_prefix(message, prefix)) {
      core_error->detail.assign(prefix);
      return;
    }
  }
  core_error->detail.assign(classify_stop_tun_contract_backend_detail(message));
}

bool proxy_result_to_js(napi_env env, const AsyncResult &result, napi_value *value, CoreErrorData *error) {
  if (!is_valid_utf8(result.string_value)) {
    *error = make_core_error(CMFA_BACKEND_ERROR, async_operation_name(result.op));
    return false;
  }
  const napi_status status =
      napi_create_string_utf8(env, result.string_value.c_str(), result.string_value.size(), value);
  if (status != napi_ok) {
    *error = make_napi_failure(async_operation_name(result.op), status);
    return false;
  }
  return true;
}

bool build_async_result_value(napi_env env, const AsyncResult &result, napi_value *value, CoreErrorData *error) {
  switch (result.op) {
    case AsyncOp::CORE_VERSION:
      if (napi_create_string_utf8(env, result.string_value.c_str(), result.string_value.size(), value) != napi_ok) {
        *error = make_napi_failure(async_operation_name(result.op), napi_generic_failure);
        return false;
      }
      return true;
    case AsyncOp::VALIDATE_CONFIGURATION:
    case AsyncOp::LOAD_CONFIGURATION:
      if (napi_get_undefined(env, value) != napi_ok) {
        *error = make_napi_failure(async_operation_name(result.op), napi_generic_failure);
        return false;
      }
      return true;
#if defined(CMFA_ENABLE_PHASE2_SELFTEST)
    case AsyncOp::PROBE_HTTPS:
      return owned_probe_result_to_js(env, result.probe_result, value, error);
#endif
    case AsyncOp::START_LOCAL:
    case AsyncOp::STOP_RUNTIME:
      return owned_snapshot_to_js(env, result.snapshot, value, error);
    case AsyncOp::PROXY_GROUPS:
    case AsyncOp::PROXY_GROUP:
    case AsyncOp::PROXY_SELECT:
    case AsyncOp::PROXY_DELAY_START:
    case AsyncOp::PROXY_DELAY_SNAPSHOT:
    case AsyncOp::PROXY_DELAY_CANCEL:
      return proxy_result_to_js(env, result, value, error);
    case AsyncOp::START_TUN:
    case AsyncOp::STOP_TUN:
    case AsyncOp::TUN_SNAPSHOT:
      return owned_tun_snapshot_to_js(env, result.tun_snapshot, value, error);
    case AsyncOp::CLOSE_STALE_OUTBOUND_CONNECTIONS:
      if (napi_get_undefined(env, value) != napi_ok) {
        *error = make_napi_failure(async_operation_name(result.op), napi_generic_failure);
        return false;
      }
      return true;
    case AsyncOp::READ_TUN_TRACES:
      return owned_tun_traces_to_js(env, result.tun_traces, value, error);
    default:
      *error = make_napi_failure(async_operation_name(result.op), napi_generic_failure);
      return false;
  }
}

std::string copy_fixed_text(const char *buffer, size_t capacity) {
  return std::string(buffer, strnlen(buffer, capacity));
}

void reset_tun_trace_tracking(AddonState *addon, const std::string &session_id) {
  if (addon == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(addon->tun_trace_mutex);
  addon->tun_trace_session_id = session_id;
  addon->next_tun_trace_sequence = 1;
  addon->tun_trace_sequences.clear();
}

uint64_t assign_tun_trace_sequence(AddonState *addon, const OwnedTunTrace &trace) {
  if (addon == nullptr) {
    return trace.sequence;
  }

  std::lock_guard<std::mutex> lock(addon->tun_trace_mutex);
  if (!trace.session_id.empty() && addon->tun_trace_session_id != trace.session_id) {
    addon->tun_trace_session_id = trace.session_id;
    addon->next_tun_trace_sequence = 1;
    addon->tun_trace_sequences.clear();
  }

  const std::string key = trace.trace_id.empty() ? std::to_string(addon->next_tun_trace_sequence) : trace.trace_id;
  const auto found = addon->tun_trace_sequences.find(key);
  if (found != addon->tun_trace_sequences.end()) {
    return found->second;
  }

  const uint64_t assigned = addon->next_tun_trace_sequence;
  addon->next_tun_trace_sequence += 1;
  addon->tun_trace_sequences.emplace(key, assigned);
  return assigned;
}

bool validate_js_safe_trace_sequence(uint64_t sequence, AsyncResult *result, AsyncOp op) {
  if (sequence > kMaxJsSafeInteger) {
    result->error = make_core_error(CMFA_OUT_OF_RANGE, async_operation_name(op));
    return false;
  }
  return true;
}

void populate_proxy_query_context(const OwnedProxyQueryContext &input, cmfa_proxy_query_context *query) {
  std::memset(query, 0, sizeof(*query));
  query->struct_size = sizeof(*query);
  std::memcpy(query->profile_hash, input.profile_hash.data(), input.profile_hash.size());
  std::memcpy(query->revision_hash, input.revision_hash.data(), input.revision_hash.size());
  if (input.has_session) {
    std::memcpy(query->session_hash, input.session_hash.data(), input.session_hash.size());
  }
  query->generation = input.generation;
}

bool validate_proxy_output_buffer(const std::vector<char> &buffer, size_t length) {
  if (length > CMFA_MAX_PROXY_JSON_BYTES || length >= buffer.size()) {
    return false;
  }
  if (buffer[length] != '\0') {
    return false;
  }
  for (size_t index = length + 1; index < buffer.size(); index += 1) {
    if (buffer[index] != kProxyBufferCanary) {
      return false;
    }
  }
  return true;
}

AsyncResult run_async_operation(AddonState *addon, const AsyncInput &input, const std::atomic<bool> &cancel_requested) {
  AsyncResult result;
  result.op = input.op;

  if (cancel_requested.load(std::memory_order_relaxed)) {
    result.error = make_napi_failure(async_operation_name(input.op), napi_cancelled);
    return result;
  }

  cmfa_error error{};
  std::array<char, 256> error_message{};
  error.message = error_message.data();
  error.capacity = error_message.size();
  error.length = 0;
  error.code = CMFA_OK;

  switch (input.op) {
    case AsyncOp::CORE_VERSION: {
      std::array<char, 256> version{};
      const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      if (version[0] == '\0') {
        result.error = make_core_error(CMFA_BACKEND_ERROR, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      result.string_value = version.data();
      return result;
    }
    case AsyncOp::VALIDATE_CONFIGURATION: {
      const cmfa_status status = cmfa_validate_config(input.path.c_str(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::LOAD_CONFIGURATION: {
      const cmfa_status status = cmfa_load_config(input.path.c_str(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      return result;
    }
#if defined(CMFA_ENABLE_PHASE2_SELFTEST)
    case AsyncOp::PROBE_HTTPS: {
      cmfa_probe_request request{};
      request.struct_size = sizeof(request);
      request.probe_run_id = input.probe_request.probe_run_id.c_str();
      request.protocol = input.probe_request.protocol == "SOCKS5" ? CMFA_PROBE_PROTOCOL_SOCKS5
                                                                  : CMFA_PROBE_PROTOCOL_HTTP_CONNECT;
      request.listener_address = input.probe_request.listener_address.c_str();
      request.origin_url = input.probe_request.origin_url.c_str();
      request.ca_pem = input.probe_request.ca_pem.c_str();
      request.expected_body_sha256 = input.probe_request.expected_body_sha256.c_str();

      cmfa_probe_result *probe_result = nullptr;
      const cmfa_status status = cmfa_probe_https(&request, &probe_result, &error);
      if (probe_result == nullptr) {
        result.error = make_core_error(status == CMFA_OK ? CMFA_BACKEND_ERROR : status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData probe_copy_error;
      const bool converted =
          probe_result_to_owned(*probe_result, &result.probe_result, &probe_copy_error);
      cmfa_probe_result_free(probe_result);
      if (!converted) {
        result.error = probe_copy_error;
        return result;
      }
      result.ok = true;
      return result;
    }
#else
    case AsyncOp::PROBE_HTTPS:
      result.error = make_core_error(CMFA_CORE_UNAVAILABLE, async_operation_name(input.op));
      return result;
#endif
    case AsyncOp::START_LOCAL: {
      cmfa_local_options options{};
      options.struct_size = sizeof(options);
      options.config_path = input.local_options.config_path.c_str();
      options.mixed_port = input.local_options.mixed_port;

      cmfa_runtime_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status status = cmfa_start_local(&options, &snapshot, &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!snapshot_to_owned(snapshot, &result.snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::PROXY_GROUPS:
    case AsyncOp::PROXY_GROUP:
    case AsyncOp::PROXY_SELECT:
    case AsyncOp::PROXY_DELAY_START:
    case AsyncOp::PROXY_DELAY_SNAPSHOT:
    case AsyncOp::PROXY_DELAY_CANCEL: {
      cmfa_proxy_query_context query{};
      if (input.op == AsyncOp::PROXY_GROUPS || input.op == AsyncOp::PROXY_GROUP || input.op == AsyncOp::PROXY_SELECT ||
          input.op == AsyncOp::PROXY_DELAY_START) {
        populate_proxy_query_context(input.proxy_query_context, &query);
      }

      std::vector<char> proxy_json(CMFA_MAX_PROXY_JSON_BYTES + 1U, kProxyBufferCanary);
      cmfa_json_buffer output{};
      output.data = proxy_json.data();
      output.capacity = proxy_json.size();
      output.length = 0;

      cmfa_status status = CMFA_BACKEND_ERROR;
      switch (input.op) {
        case AsyncOp::PROXY_GROUPS:
          status = cmfa_proxy_groups(&query, input.proxy_selectable_only ? 1U : 0U, &output, &error);
          break;
        case AsyncOp::PROXY_GROUP:
          status = cmfa_proxy_group(&query, input.proxy_group_name.c_str(), &output, &error);
          break;
        case AsyncOp::PROXY_SELECT:
          status =
              cmfa_proxy_select(&query, input.proxy_group_name.c_str(), input.proxy_member_name.c_str(), &output, &error);
          break;
        case AsyncOp::PROXY_DELAY_START:
          status = cmfa_proxy_delay_start(&query, input.proxy_group_name.c_str(), &output, &error);
          break;
        case AsyncOp::PROXY_DELAY_SNAPSHOT:
          status = cmfa_proxy_delay_snapshot(input.proxy_delay_job_id.c_str(), &output, &error);
          break;
        case AsyncOp::PROXY_DELAY_CANCEL:
          status = cmfa_proxy_delay_cancel(input.proxy_delay_job_id.c_str(), &output, &error);
          break;
        default:
          status = CMFA_BACKEND_ERROR;
          break;
      }

      if (status == CMFA_OK) {
        if (!validate_proxy_output_buffer(proxy_json, output.length)) {
          result.error = make_core_error(CMFA_BACKEND_ERROR, async_operation_name(input.op));
          return result;
        }
        result.ok = true;
        result.string_value.assign(proxy_json.data(), output.length);
        return result;
      }

      if (status == CMFA_BUFFER_TOO_SMALL) {
        result.error = make_core_error(CMFA_BACKEND_ERROR, async_operation_name(input.op));
        return result;
      }

      result.error = make_core_error(status, async_operation_name(input.op));
      return result;
    }
    case AsyncOp::STOP_RUNTIME: {
      const cmfa_status stop_status = cmfa_stop(&error);
      if (stop_status != CMFA_OK) {
        result.error = make_core_error(stop_status, async_operation_name(input.op));
        return result;
      }
      cmfa_runtime_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status snapshot_status = cmfa_runtime_state(&snapshot, &error);
      if (snapshot_status != CMFA_OK) {
        result.error = make_core_error(snapshot_status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!snapshot_to_owned(snapshot, &result.snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::START_TUN: {
      cmfa_tun_options options{};
      options.struct_size = sizeof(options);
      options.tun_fd = input.tun_fd;
      std::strncpy(options.session_id, input.tun_session_id.c_str(), sizeof(options.session_id) - 1);
      options.config_path = input.tun_config_path.c_str();
      options.mixed_port = input.tun_mixed_port;
      options.platform_api_level = input.tun_platform_api_level;
      options.process_protected = input.tun_process_protected ? 1U : 0U;

      cmfa_tun_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status status = cmfa_tun_start(&options, &snapshot, &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!tun_snapshot_to_owned(snapshot, &result.tun_snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::STOP_TUN: {
      const cmfa_status stop_status = cmfa_tun_stop(&error);
      if (stop_status != CMFA_OK) {
        result.error = make_core_error(stop_status, async_operation_name(input.op));
        maybe_set_stop_tun_backend_detail(&result.error, input.op, stop_status, error);
        return result;
      }

      cmfa_tun_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status snapshot_status = cmfa_tun_runtime_state(&snapshot, &error);
      if (snapshot_status != CMFA_OK) {
        result.error = make_core_error(snapshot_status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!tun_snapshot_to_owned(snapshot, &result.tun_snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      reset_tun_trace_tracking(addon, result.tun_snapshot.session_id);
      result.ok = true;
      return result;
    }
    case AsyncOp::CLOSE_STALE_OUTBOUND_CONNECTIONS: {
      const cmfa_status status =
          cmfa::close_stale_tun_connections_for_mihomo_backend(input.tun_session_id.c_str(), &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::TUN_SNAPSHOT: {
      cmfa_tun_snapshot snapshot{};
      snapshot.struct_size = sizeof(snapshot);
      const cmfa_status status = cmfa_tun_runtime_state(&snapshot, &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }
      CoreErrorData snapshot_error;
      if (!tun_snapshot_to_owned(snapshot, &result.tun_snapshot, &snapshot_error, async_operation_name(input.op))) {
        result.error = snapshot_error;
        return result;
      }
      result.ok = true;
      return result;
    }
    case AsyncOp::READ_TUN_TRACES: {
      cmfa_tun_trace_ring traces{};
      traces.struct_size = sizeof(traces);
      const cmfa_status status = cmfa_tun_copy_traces_ring(&traces, &error);
      if (status != CMFA_OK) {
        result.error = make_core_error(status, async_operation_name(input.op));
        return result;
      }

      result.tun_traces.clear();
      result.tun_traces.reserve(traces.trace_count);
      for (uint32_t index = 0; index < traces.trace_count; index += 1) {
        const cmfa_tun_trace &trace = traces.traces[index];
        OwnedTunTrace owned_trace;
        owned_trace.session_id = copy_fixed_text(trace.session_id, sizeof(trace.session_id));
        owned_trace.trace_id = copy_fixed_text(trace.trace_id, sizeof(trace.trace_id));
        owned_trace.ingress = copy_fixed_text(trace.ingress, sizeof(trace.ingress));
        owned_trace.protocol = copy_fixed_text(trace.protocol, sizeof(trace.protocol));
        owned_trace.source_address = copy_fixed_text(trace.source_address, sizeof(trace.source_address));
        owned_trace.destination_address = copy_fixed_text(trace.destination_address, sizeof(trace.destination_address));
        owned_trace.hashed_tuple = copy_fixed_text(trace.hashed_tuple, sizeof(trace.hashed_tuple));
        owned_trace.correlation_hash = copy_fixed_text(trace.correlation_hash, sizeof(trace.correlation_hash));
        owned_trace.destination_hash = copy_fixed_text(trace.destination_hash, sizeof(trace.destination_hash));
        owned_trace.outbound_terminal_hash =
            copy_fixed_text(trace.outbound_terminal_hash, sizeof(trace.outbound_terminal_hash));
        owned_trace.outbound_chain_hash = copy_fixed_text(trace.outbound_chain_hash, sizeof(trace.outbound_chain_hash));
        owned_trace.outbound_chain_length = trace.outbound_chain_length;
        owned_trace.sequence = assign_tun_trace_sequence(addon, owned_trace);
        if (!validate_js_safe_trace_sequence(owned_trace.sequence, &result, input.op)) {
          return result;
        }
        if (owned_trace.sequence > input.tun_after_sequence) {
          result.tun_traces.push_back(std::move(owned_trace));
        }
      }
      result.ok = true;
      return result;
    }
    default:
      result.error = make_napi_failure("asyncOperation", napi_generic_failure);
      return result;
  }
}

void complete_promise(napi_env env, napi_value, void *, void *data) {
  auto *payload = static_cast<AsyncCompletionPayload *>(data);
  if (env == nullptr) {
    delete payload;
    return;
  }

  std::shared_ptr<AsyncPromiseJob> job = payload->job;
  AddonState *addon = job->addon;
  job->completion_payload = nullptr;

  if (payload->result.ok) {
    napi_value resolution = nullptr;
    CoreErrorData completion_error;
    if (build_async_result_value(env, payload->result, &resolution, &completion_error)) {
      (void)napi_resolve_deferred(env, job->deferred, resolution);
    } else {
      reject_deferred_with_core_error(env, job->deferred, completion_error);
    }
  } else {
    reject_deferred_with_core_error(env, job->deferred, payload->result.error);
  }

  (void)finish_async(addon, job->async_handle);
  (void)release_delivery(addon, job->delivery, false);
  delete payload;
}

struct DecodedAsyncCall {
  AddonState *addon = nullptr;
  AsyncInput input;
};

void run_async_worker(AsyncPromiseJob *job) {
  AsyncResult result = run_async_operation(job->addon, job->input, job->async_handle->cancel_requested);
  AsyncCompletionPayload *payload = job->completion_payload;
  if (payload == nullptr) {
    return;
  }
  payload->result = std::move(result);

  const napi_status status =
      napi_call_threadsafe_function(job->delivery->tsfn, payload, napi_tsfn_nonblocking);
  if (status != napi_ok && status != napi_closing) {
    job->queue_failure_status.store(static_cast<int32_t>(status), std::memory_order_release);
    job->queue_failed.store(true, std::memory_order_release);
    job->completion_payload = nullptr;
    delete payload;
    (void)finish_async(job->addon, job->async_handle);
    (void)release_delivery(job->addon, job->delivery, true);
  } else if (status == napi_closing) {
    job->completion_payload = nullptr;
    delete payload;
  }
}

napi_value start_async_operation(napi_env env, const DecodedAsyncCall &decoded) {
  AddonState *addon = decoded.addon;
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  AsyncDelivery *delivery = nullptr;
  AsyncThreadHandle *async_handle = nullptr;
  AsyncCompletionPayload *prepared_payload = nullptr;
  AsyncTsfnFinalizerState *finalizer_state = nullptr;
  bool delivery_registered = false;
  bool async_registered = false;
  bool tsfn_created = false;
  try {
    const AsyncOp op = decoded.input.op;
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, async_operation_name(op)));
      return nullptr;
    }

    const napi_status promise_status = napi_create_promise(env, &deferred, &promise);
    if (promise_status != napi_ok) {
      throw_napi_failure(env, async_operation_name(op), promise_status);
      return nullptr;
    }

    std::shared_ptr<AsyncPromiseJob> job = std::make_shared<AsyncPromiseJob>();
    job->addon = addon;
    job->deferred = deferred;
    job->input = decoded.input;

    auto *payload = new (std::nothrow) AsyncCompletionPayload{};
    if (payload == nullptr) {
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    prepared_payload = payload;
    payload->job = job;
    job->completion_payload = payload;

    finalizer_state = new (std::nothrow) AsyncTsfnFinalizerState{};
    if (finalizer_state == nullptr) {
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    finalizer_state->job = job;

    napi_value async_name = nullptr;
    const napi_status async_name_status =
        napi_create_string_utf8(env, async_operation_name(op), NAPI_AUTO_LENGTH, &async_name);
    if (async_name_status != napi_ok) {
      delete finalizer_state;
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), async_name_status);
      return promise;
    }

    delivery = new (std::nothrow) AsyncDelivery{};
    if (delivery == nullptr) {
      delete finalizer_state;
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    const napi_status tsfn_status = napi_create_threadsafe_function(env,
                                                                    nullptr,
                                                                    nullptr,
                                                                    async_name,
                                                                    1,
                                                                    1,
                                                                    finalizer_state,
                                                                    tsfn_finalize_async,
                                                                    nullptr,
                                                                    complete_promise,
                                                                    &delivery->tsfn);
    if (tsfn_status != napi_ok) {
      delete delivery;
      delete finalizer_state;
      finalizer_state = nullptr;
      job->completion_payload = nullptr;
      delete payload;
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), tsfn_status);
      return promise;
    }
    tsfn_created = true;
    job->delivery = delivery;

    if (!addon->owner.try_add_delivery({delivery, abort_delivery, release_delivery_handle})) {
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
      delete delivery;
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    delivery_registered = true;

    async_handle = new (std::nothrow) AsyncThreadHandle{};
    if (async_handle == nullptr) {
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      (void)release_delivery(addon, delivery, true);
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    async_handle->op = op;
    if (op == AsyncOp::PROBE_HTTPS) {
      async_handle->probe_run_id = decoded.input.probe_request.probe_run_id;
    }
    if (!addon->owner.try_add_async({async_handle, request_cancel_async, join_async, release_async})) {
      delete async_handle;
      job->completion_payload = nullptr;
      delete payload;
      prepared_payload = nullptr;
      (void)release_delivery(addon, delivery, true);
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(op), napi_generic_failure);
      return promise;
    }
    job->async_handle = async_handle;
    async_registered = true;

    async_handle->worker = std::thread([job] { run_async_worker(job.get()); });
    return promise;
  } catch (...) {
    if (deferred != nullptr) {
      reject_deferred_with_napi_failure(env, deferred, async_operation_name(decoded.input.op), napi_generic_failure);
    }
    if (async_registered) {
      (void)finish_async(addon, async_handle);
    } else if (async_handle != nullptr) {
      delete async_handle;
    }
    if (delivery_registered) {
      (void)release_delivery(addon, delivery, true);
    } else if (tsfn_created && delivery != nullptr) {
      (void)napi_release_threadsafe_function(delivery->tsfn, napi_tsfn_abort);
      delete delivery;
    } else if (delivery != nullptr) {
      delete delivery;
    }
    if (!tsfn_created && finalizer_state != nullptr) {
      delete finalizer_state;
    }
    if (prepared_payload != nullptr) {
      delete prepared_payload;
    }
    if (promise != nullptr) {
      return promise;
    }
    throw_napi_failure(env, async_operation_name(decoded.input.op), napi_generic_failure);
    return nullptr;
  }
}

} // namespace

napi_value core_version(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "coreVersion", status);
      return nullptr;
    }
    if (argc != 0) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "coreVersion"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::CORE_VERSION;
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "coreVersion", napi_generic_failure);
    return nullptr;
  }
}

napi_value validate_configuration(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "validateConfiguration", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "validateConfiguration"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::VALIDATE_CONFIGURATION;
    CoreErrorData error;
    if (!decode_path_argument(env, argv[0], &decoded.input.path, &error, "validateConfiguration")) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "validateConfiguration", napi_generic_failure);
    return nullptr;
  }
}

napi_value load_configuration(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "loadConfiguration", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "loadConfiguration"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::LOAD_CONFIGURATION;
    CoreErrorData error;
    if (!decode_path_argument(env, argv[0], &decoded.input.path, &error, "loadConfiguration")) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "loadConfiguration", napi_generic_failure);
    return nullptr;
  }
}

napi_value start_local(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "startLocal", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "startLocal"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::START_LOCAL;
    CoreErrorData error;
    if (!decode_local_options(env, argv[0], &decoded.input.local_options, &error)) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "startLocal", napi_generic_failure);
    return nullptr;
  }
}

napi_value probe_https(napi_env env, napi_callback_info info) {
#if !defined(CMFA_ENABLE_PHASE2_SELFTEST)
  (void)info;
  throw_core_error(env, make_core_error(CMFA_CORE_UNAVAILABLE, "selfTestProbe"));
  return nullptr;
#else
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "probeHttps", status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "probeHttps"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::PROBE_HTTPS;
    CoreErrorData error;
    if (!decode_probe_request(env, argv[0], &decoded.input.probe_request, &error)) {
      throw_core_error(env, error);
      return nullptr;
    }
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "probeHttps", napi_generic_failure);
    return nullptr;
  }
#endif
}

napi_value stop_runtime(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "stopRuntime", status);
      return nullptr;
    }
    if (argc != 0) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "stopRuntime"));
      return nullptr;
    }
    DecodedAsyncCall decoded;
    decoded.addon = static_cast<AddonState *>(data);
    decoded.input.op = AsyncOp::STOP_RUNTIME;
    return start_async_operation(env, decoded.addon, decoded.input);
  } catch (...) {
    throw_napi_failure(env, "stopRuntime", napi_generic_failure);
    return nullptr;
  }
}

napi_value start_async_operation(napi_env env, AddonState *addon, const AsyncInput &input) {
  DecodedAsyncCall decoded;
  decoded.addon = addon;
  decoded.input = input;
  return start_async_operation(env, decoded);
}

} // namespace cmfa::nodeaddon
