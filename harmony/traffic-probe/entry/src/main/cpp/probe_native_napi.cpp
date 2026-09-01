#include "probe_native_core.h"

#include <arpa/inet.h>

#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include <napi/native_api.h>
#include <node_api.h>

namespace {

using cmfa::probe::ProbeFailure;
using cmfa::probe::ProbeKind;
using cmfa::probe::ProbeOutcome;
using cmfa::probe::ProbeRequest;
using cmfa::probe::ProbeResult;

constexpr size_t kExpectedKeyCount = 5;
constexpr size_t kMaxKeyNameLength = 9;
constexpr size_t kMaxKindLength = 11;
constexpr size_t kMaxHostIpv4Length = 15;
constexpr size_t kMaxTcpPayloadBytes = 8192;
constexpr size_t kMaxUdpPayloadBytes = 1024;
constexpr const char* kInvalidArgCode = "ERR_INVALID_ARG";
constexpr const char* kInvalidArgMessage = "probeSocket request is invalid";
constexpr const char* kBridgeFailureCode = "ERR_BRIDGE_FAILURE";
constexpr const char* kBridgeFailureMessage = "probeSocket failed";

struct DecodedRequest {
  ProbeKind kind = ProbeKind::TcpEcho;
  std::string host;
  uint16_t port = 0;
  std::vector<uint8_t> payload;
  uint32_t timeout_ms = 0;
};

struct ProbeAsyncJob {
  napi_deferred deferred = nullptr;
  napi_async_work work = nullptr;
  ProbeKind kind = ProbeKind::TcpEcho;
  std::string host;
  uint16_t port = 0;
  std::vector<uint8_t> payload;
  uint32_t timeout_ms = 0;
  bool execution_failed = false;
  ProbeResult result{};
};

napi_value make_error(napi_env env, const char* code, const char* message) {
  napi_value code_value = nullptr;
  napi_value message_value = nullptr;
  napi_value error_value = nullptr;
  if (napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &code_value) != napi_ok) {
    return nullptr;
  }
  if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &message_value) != napi_ok) {
    return nullptr;
  }
  if (napi_create_error(env, code_value, message_value, &error_value) != napi_ok) {
    return nullptr;
  }
  return error_value;
}

void throw_invalid_arg(napi_env env) {
  (void)napi_throw_error(env, kInvalidArgCode, kInvalidArgMessage);
}

napi_value make_bridge_failure(napi_env env) {
  napi_value error = make_error(env, kBridgeFailureCode, kBridgeFailureMessage);
  if (error != nullptr) {
    return error;
  }
  napi_value fallback = nullptr;
  (void)napi_get_undefined(env, &fallback);
  return fallback;
}

bool read_string(napi_env env, napi_value value, size_t max_length, std::string* out) {
  napi_valuetype type = napi_undefined;
  if (out == nullptr || napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
    return false;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }
  if (length > max_length) {
    return false;
  }
  std::string buffer(length + 1, '\0');
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
    return false;
  }
  buffer.resize(length);
  *out = std::move(buffer);
  return true;
}

bool read_exact_integer(napi_env env, napi_value value, int64_t minimum, uint64_t maximum, uint64_t* out) {
  napi_valuetype type = napi_undefined;
  if (out == nullptr || napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
    return false;
  }
  double numeric = 0;
  if (napi_get_value_double(env, value, &numeric) != napi_ok || !std::isfinite(numeric) || std::floor(numeric) != numeric) {
    return false;
  }
  if (numeric < static_cast<double>(minimum) || numeric > static_cast<double>(maximum)) {
    return false;
  }
  int64_t integer = 0;
  if (napi_get_value_int64(env, value, &integer) != napi_ok) {
    return false;
  }
  if (integer < minimum) {
    return false;
  }
  *out = static_cast<uint64_t>(integer);
  return true;
}

bool read_required_property(napi_env env, napi_value object, const char* key, napi_value* value) {
  return value != nullptr && napi_get_named_property(env, object, key, value) == napi_ok;
}

bool has_exact_request_keys(napi_env env, napi_value request) {
  napi_value keys = nullptr;
  if (napi_get_all_property_names(
          env, request, napi_key_own_only, napi_key_enumerable, napi_key_numbers_to_strings, &keys) != napi_ok) {
    return false;
  }
  uint32_t length = 0;
  if (napi_get_array_length(env, keys, &length) != napi_ok || length != kExpectedKeyCount) {
    return false;
  }

  bool saw_kind = false;
  bool saw_host = false;
  bool saw_port = false;
  bool saw_payload = false;
  bool saw_timeout = false;
  for (uint32_t index = 0; index < length; index += 1) {
    napi_value key_value = nullptr;
    if (napi_get_element(env, keys, index, &key_value) != napi_ok) {
      return false;
    }
    std::string key;
    if (!read_string(env, key_value, kMaxKeyNameLength, &key)) {
      return false;
    }
    if (key == "kind") {
      saw_kind = true;
    } else if (key == "hostIpv4") {
      saw_host = true;
    } else if (key == "port") {
      saw_port = true;
    } else if (key == "payload") {
      saw_payload = true;
    } else if (key == "timeoutMs") {
      saw_timeout = true;
    } else {
      return false;
    }
  }
  return saw_kind && saw_host && saw_port && saw_payload && saw_timeout;
}

bool decode_kind(const std::string& text, ProbeKind* out) {
  if (out == nullptr) {
    return false;
  }
  if (text == "tcpEcho") {
    *out = ProbeKind::TcpEcho;
    return true;
  }
  if (text == "tcpHttp") {
    *out = ProbeKind::TcpHttp;
    return true;
  }
  if (text == "tcpSend") {
    *out = ProbeKind::TcpSend;
    return true;
  }
  if (text == "tcpExchange") {
    *out = ProbeKind::TcpExchange;
    return true;
  }
  if (text == "udpEcho") {
    *out = ProbeKind::UdpEcho;
    return true;
  }
  if (text == "dnsUdpEcho") {
    *out = ProbeKind::DnsUdpEcho;
    return true;
  }
  return false;
}

bool is_valid_ipv4_literal(const std::string& host) {
  in_addr address {};
  return ::inet_pton(AF_INET, host.c_str(), &address) == 1;
}

size_t max_payload_bytes_for_kind(ProbeKind kind) {
  return (kind == ProbeKind::TcpEcho || kind == ProbeKind::TcpHttp || kind == ProbeKind::TcpSend ||
          kind == ProbeKind::TcpExchange)
    ? kMaxTcpPayloadBytes
    : kMaxUdpPayloadBytes;
}

bool decode_request(napi_env env, napi_value value, DecodedRequest* out) {
  napi_valuetype type = napi_undefined;
  if (out == nullptr || napi_typeof(env, value, &type) != napi_ok || type != napi_object) {
    return false;
  }
  if (!has_exact_request_keys(env, value)) {
    return false;
  }

  napi_value kind_value = nullptr;
  napi_value host_value = nullptr;
  napi_value port_value = nullptr;
  napi_value payload_value = nullptr;
  napi_value timeout_value = nullptr;
  if (!read_required_property(env, value, "kind", &kind_value) ||
      !read_required_property(env, value, "hostIpv4", &host_value) ||
      !read_required_property(env, value, "port", &port_value) ||
      !read_required_property(env, value, "payload", &payload_value) ||
      !read_required_property(env, value, "timeoutMs", &timeout_value)) {
    return false;
  }

  std::string kind_text;
  if (!read_string(env, kind_value, kMaxKindLength, &kind_text) || !decode_kind(kind_text, &out->kind)) {
    return false;
  }
  if (!read_string(env, host_value, kMaxHostIpv4Length, &out->host) || !is_valid_ipv4_literal(out->host)) {
    return false;
  }

  uint64_t port = 0;
  if (!read_exact_integer(env, port_value, 1, 65535, &port)) {
    return false;
  }
  out->port = static_cast<uint16_t>(port);

  bool is_arraybuffer = false;
  if (napi_is_arraybuffer(env, payload_value, &is_arraybuffer) != napi_ok || !is_arraybuffer) {
    return false;
  }
  void* payload_bytes = nullptr;
  size_t payload_size = 0;
  if (napi_get_arraybuffer_info(env, payload_value, &payload_bytes, &payload_size) != napi_ok || payload_size == 0 ||
      payload_bytes == nullptr || payload_size > max_payload_bytes_for_kind(out->kind)) {
    return false;
  }
  const auto* raw_bytes = static_cast<const uint8_t*>(payload_bytes);
  out->payload.assign(raw_bytes, raw_bytes + payload_size);

  uint64_t timeout_ms = 0;
  if (!read_exact_integer(env, timeout_value, 0, std::numeric_limits<uint32_t>::max(), &timeout_ms)) {
    return false;
  }
  out->timeout_ms = static_cast<uint32_t>(timeout_ms);
  return true;
}

const char* encode_outcome(ProbeOutcome outcome) {
  switch (outcome) {
    case ProbeOutcome::Pass:
      return "pass";
    case ProbeOutcome::Timeout:
      return "timeout";
    case ProbeOutcome::Fail:
    default:
      return "fail";
  }
}

const char* encode_failure(ProbeFailure failure) {
  switch (failure) {
    case ProbeFailure::InvalidArgument:
      return "INVALID_ARGUMENT";
    case ProbeFailure::ConnectFailed:
      return "CONNECT_FAILED";
    case ProbeFailure::SendFailed:
      return "SEND_FAILED";
    case ProbeFailure::RecvFailed:
      return "RECV_FAILED";
    case ProbeFailure::Timeout:
      return "TIMEOUT";
    case ProbeFailure::PayloadMismatch:
      return "PAYLOAD_MISMATCH";
    case ProbeFailure::None:
    default:
      return nullptr;
  }
}

napi_value encode_result(napi_env env, const ProbeResult& result) {
  napi_value object = nullptr;
  napi_value outcome = nullptr;
  napi_value bytes_sent = nullptr;
  napi_value bytes_received = nullptr;
  napi_value duration_ms = nullptr;
  if (napi_create_object(env, &object) != napi_ok ||
      napi_create_string_utf8(env, encode_outcome(result.outcome), NAPI_AUTO_LENGTH, &outcome) != napi_ok ||
      napi_create_uint32(env, result.bytes_sent, &bytes_sent) != napi_ok ||
      napi_create_uint32(env, result.bytes_received, &bytes_received) != napi_ok ||
      napi_create_uint32(env, result.duration_ms, &duration_ms) != napi_ok ||
      napi_set_named_property(env, object, "outcome", outcome) != napi_ok ||
      napi_set_named_property(env, object, "bytesSent", bytes_sent) != napi_ok ||
      napi_set_named_property(env, object, "bytesReceived", bytes_received) != napi_ok ||
      napi_set_named_property(env, object, "durationMs", duration_ms) != napi_ok) {
    return nullptr;
  }

  const char* failure = encode_failure(result.failure);
  if (failure != nullptr) {
    napi_value failure_value = nullptr;
    if (napi_create_string_utf8(env, failure, NAPI_AUTO_LENGTH, &failure_value) != napi_ok ||
        napi_set_named_property(env, object, "failureCode", failure_value) != napi_ok) {
      return nullptr;
    }
  }

  return object;
}

void delete_job(napi_env env, ProbeAsyncJob* job) {
  if (job == nullptr) {
    return;
  }
  if (job->work != nullptr) {
    (void)napi_delete_async_work(env, job->work);
    job->work = nullptr;
  }
  delete job;
}

void reject_bridge_failure(napi_env env, napi_deferred deferred) {
  if (deferred == nullptr) {
    (void)napi_throw_error(env, kBridgeFailureCode, kBridgeFailureMessage);
    return;
  }
  napi_value rejection = make_bridge_failure(env);
  (void)napi_reject_deferred(env, deferred, rejection);
}

void reject_bridge_failure_and_delete_job(napi_env env, ProbeAsyncJob* job) {
  if (job == nullptr) {
    return;
  }
  reject_bridge_failure(env, job->deferred);
  delete_job(env, job);
}

void execute_probe(napi_env, void* data) {
  auto* job = static_cast<ProbeAsyncJob*>(data);
  if (job == nullptr) {
    return;
  }
  try {
    ProbeRequest request{};
    request.kind = job->kind;
    request.host_ipv4 = job->host.c_str();
    request.port = job->port;
    request.payload = job->payload.data();
    request.payload_size = job->payload.size();
    request.timeout_ms = job->timeout_ms;
    job->result = cmfa::probe::probe_socket(request);
  } catch (...) {
    job->execution_failed = true;
    job->result = ProbeResult{};
  }
}

void complete_probe(napi_env env, napi_status status, void* data) {
  auto* job = static_cast<ProbeAsyncJob*>(data);
  if (job == nullptr) {
    return;
  }
  try {
    if (status != napi_ok || job->execution_failed) {
      reject_bridge_failure_and_delete_job(env, job);
      return;
    }

    napi_value resolution = encode_result(env, job->result);
    if (resolution != nullptr) {
      (void)napi_resolve_deferred(env, job->deferred, resolution);
    } else {
      reject_bridge_failure(env, job->deferred);
    }
    delete_job(env, job);
  } catch (...) {
    reject_bridge_failure_and_delete_job(env, job);
  }
}

napi_value probe_socket_bridge(napi_env env, napi_callback_info info) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  ProbeAsyncJob* job = nullptr;
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1) {
      throw_invalid_arg(env);
      return nullptr;
    }

    DecodedRequest request;
    if (!decode_request(env, argv[0], &request)) {
      throw_invalid_arg(env);
      return nullptr;
    }

    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
      (void)napi_throw_error(env, kBridgeFailureCode, kBridgeFailureMessage);
      return nullptr;
    }

    job = new (std::nothrow) ProbeAsyncJob();
    if (job == nullptr) {
      reject_bridge_failure(env, deferred);
      return promise;
    }

    job->deferred = deferred;
    job->kind = request.kind;
    job->host = std::move(request.host);
    job->port = request.port;
    job->payload = std::move(request.payload);
    job->timeout_ms = request.timeout_ms;

    napi_value resource_name = nullptr;
    if (napi_create_string_utf8(env, "probeSocket", NAPI_AUTO_LENGTH, &resource_name) != napi_ok) {
      reject_bridge_failure_and_delete_job(env, job);
      return promise;
    }
    const napi_status create_status =
        napi_create_async_work(env, nullptr, resource_name, execute_probe, complete_probe, job, &job->work);
    if (create_status != napi_ok) {
      reject_bridge_failure_and_delete_job(env, job);
      return promise;
    }

    const napi_status queue_status = napi_queue_async_work(env, job->work);
    if (queue_status != napi_ok) {
      reject_bridge_failure_and_delete_job(env, job);
      return promise;
    }

    return promise;
  } catch (...) {
    if (deferred == nullptr) {
      (void)napi_throw_error(env, kBridgeFailureCode, kBridgeFailureMessage);
      return nullptr;
    }
    if (job != nullptr) {
      reject_bridge_failure_and_delete_job(env, job);
    } else {
      reject_bridge_failure(env, deferred);
    }
    return promise;
  }
}

napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
      {"probeSocket", nullptr, probe_socket_bridge, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, 1, properties) != napi_ok) {
    (void)napi_throw_error(env, kBridgeFailureCode, kBridgeFailureMessage);
    return nullptr;
  }
  return exports;
}

}  // namespace

NAPI_MODULE(libprobeentry, Init)
