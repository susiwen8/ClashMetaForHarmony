#include "cmfa_napi.h"

#include <array>
#include <new>
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

bool build_async_result_value(napi_env env, const AsyncResult &result, napi_value *value) {
  CoreErrorData error;
  switch (result.op) {
    case AsyncOp::CORE_VERSION:
      if (napi_create_string_utf8(env, result.string_value.c_str(), result.string_value.size(), value) != napi_ok) {
        return false;
      }
      return true;
    case AsyncOp::VALIDATE_CONFIGURATION:
    case AsyncOp::LOAD_CONFIGURATION:
      return napi_get_undefined(env, value) == napi_ok;
#if defined(CMFA_ENABLE_PHASE2_SELFTEST)
    case AsyncOp::PROBE_HTTPS:
      return owned_probe_result_to_js(env, result.probe_result, value, &error);
#endif
    case AsyncOp::START_LOCAL:
    case AsyncOp::STOP_RUNTIME:
      return owned_snapshot_to_js(env, result.snapshot, value, &error);
    default:
      return false;
  }
}

AsyncResult run_async_operation(const AsyncInput &input, const std::atomic<bool> &cancel_requested) {
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
    if (build_async_result_value(env, payload->result, &resolution)) {
      (void)napi_resolve_deferred(env, job->deferred, resolution);
    } else {
      reject_deferred_with_napi_failure(env, job->deferred, async_operation_name(job->input.op), napi_generic_failure);
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
  AsyncResult result = run_async_operation(job->input, job->async_handle->cancel_requested);
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
    return start_async_operation(env, decoded);
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
    return start_async_operation(env, decoded);
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
    return start_async_operation(env, decoded);
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
    return start_async_operation(env, decoded);
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
    return start_async_operation(env, decoded);
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
    return start_async_operation(env, decoded);
  } catch (...) {
    throw_napi_failure(env, "stopRuntime", napi_generic_failure);
    return nullptr;
  }
}

} // namespace cmfa::nodeaddon
