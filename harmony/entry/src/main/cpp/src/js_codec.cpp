#include "cmfa_napi.h"

#include <array>
#include <cstring>

namespace cmfa::nodeaddon {

void emit_log_event(void *context, const cmfa_log_message *message) noexcept;
void emit_runtime_event(void *context, const cmfa_runtime_event *message) noexcept;

namespace {

constexpr std::string_view kRuntimeStopped = "STOPPED";
constexpr std::string_view kRuntimeStarting = "STARTING";
constexpr std::string_view kRuntimeRunning = "RUNNING";
constexpr std::string_view kRuntimeStopping = "STOPPING";
constexpr std::string_view kRuntimeError = "ERROR";
constexpr std::string_view kLogDebug = "DEBUG";
constexpr std::string_view kLogInfo = "INFO";
constexpr std::string_view kLogWarn = "WARN";
constexpr std::string_view kLogError = "ERROR";

napi_status set_named_string(napi_env env, napi_value object, const char *name, std::string_view value) {
  napi_value js_value = nullptr;
  napi_status status = napi_create_string_utf8(env, value.data(), value.size(), &js_value);
  if (status != napi_ok) {
    return status;
  }
  return napi_set_named_property(env, object, name, js_value);
}

napi_status set_named_uint32(napi_env env, napi_value object, const char *name, uint32_t value) {
  napi_value js_value = nullptr;
  napi_status status = napi_create_uint32(env, value, &js_value);
  if (status != napi_ok) {
    return status;
  }
  return napi_set_named_property(env, object, name, js_value);
}

bool get_named_property(napi_env env, napi_value object, const char *name, napi_value *result, CoreErrorData *error) {
  napi_status status = napi_get_named_property(env, object, name, result);
  if (status == napi_ok) {
    return true;
  }
  *error = make_napi_failure("decodeLocalOptions", status);
  return false;
}

bool decode_uint32_value(napi_env env, napi_value value, uint32_t *out, CoreErrorData *error, const char *operation) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (type != napi_number) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  int64_t raw_value = 0;
  status = napi_get_value_int64(env, value, &raw_value);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  if (raw_value < 0 || raw_value > static_cast<int64_t>(UINT32_MAX)) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }

  double numeric_value = 0;
  status = napi_get_value_double(env, value, &numeric_value);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }
  if (numeric_value != static_cast<double>(raw_value)) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  *out = static_cast<uint32_t>(raw_value);
  return true;
}

} // namespace

AddonState::AddonState(cmfa::napi::LifecycleOperations operations)
    : env(nullptr),
      ownership(),
      owner(cmfa::napi::LifecycleOperations{&ownership, operations.shutdown, operations.unregister_backend}),
      next_subscription_id(1) {}

const char *runtime_state_name(cmfa_runtime_state_value state) {
  switch (state) {
    case CMFA_RUNTIME_STOPPED:
      return kRuntimeStopped.data();
    case CMFA_RUNTIME_STARTING:
      return kRuntimeStarting.data();
    case CMFA_RUNTIME_RUNNING:
      return kRuntimeRunning.data();
    case CMFA_RUNTIME_STOPPING:
      return kRuntimeStopping.data();
    case CMFA_RUNTIME_ERROR:
      return kRuntimeError.data();
    default:
      return nullptr;
  }
}

const char *log_level_name(cmfa_log_level level) {
  switch (level) {
    case CMFA_LOG_DEBUG:
      return kLogDebug.data();
    case CMFA_LOG_INFO:
      return kLogInfo.data();
    case CMFA_LOG_WARN:
      return kLogWarn.data();
    case CMFA_LOG_ERROR:
      return kLogError.data();
    default:
      return nullptr;
  }
}

const char *async_operation_name(AsyncOp op) {
  switch (op) {
    case AsyncOp::CORE_VERSION:
      return "coreVersion";
    case AsyncOp::VALIDATE_CONFIGURATION:
      return "validateConfiguration";
    case AsyncOp::LOAD_CONFIGURATION:
      return "loadConfiguration";
    case AsyncOp::START_LOCAL:
      return "startLocal";
    case AsyncOp::STOP_RUNTIME:
      return "stopRuntime";
    default:
      return "unknown";
  }
}

bool decode_utf8_string(napi_env env,
                        napi_value value,
                        std::string *out,
                        CoreErrorData *error,
                        const char *operation,
                        bool reject_embedded_nul,
                        size_t max_bytes) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure(operation, status);
    return false;
  }
  if (type != napi_string) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  size_t measured = 0;
  status = napi_get_value_string_utf8(env, value, nullptr, 0, &measured);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_UTF8, operation);
    return false;
  }
  if (measured == 0 || measured >= max_bytes) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }

  std::string storage(measured + 1, '\0');
  size_t copied = 0;
  status = napi_get_value_string_utf8(env, value, storage.data(), storage.size(), &copied);
  if (status != napi_ok) {
    *error = make_core_error(CMFA_INVALID_UTF8, operation);
    return false;
  }
  if (copied != measured) {
    *error = make_core_error(CMFA_INVALID_UTF8, operation);
    return false;
  }
  if (reject_embedded_nul && std::memchr(storage.data(), '\0', copied) != nullptr) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, operation);
    return false;
  }

  out->assign(storage.data(), copied);
  return true;
}

bool decode_path_argument(napi_env env, napi_value value, std::string *out, CoreErrorData *error, const char *operation) {
  return decode_utf8_string(env, value, out, error, operation, true, CMFA_MAX_PATH_BYTES);
}

bool decode_local_options(napi_env env, napi_value value, OwnedLocalOptions *out, CoreErrorData *error) {
  napi_valuetype type = napi_undefined;
  napi_status status = napi_typeof(env, value, &type);
  if (status != napi_ok) {
    *error = make_napi_failure("decodeLocalOptions", status);
    return false;
  }
  if (type != napi_object) {
    *error = make_core_error(CMFA_INVALID_ARGUMENT, "startLocal");
    return false;
  }

  napi_value config_path = nullptr;
  napi_value mixed_port = nullptr;
  if (!get_named_property(env, value, "configPath", &config_path, error) ||
      !get_named_property(env, value, "mixedPort", &mixed_port, error)) {
    return false;
  }
  if (!decode_path_argument(env, config_path, &out->config_path, error, "startLocal")) {
    return false;
  }
  if (!decode_uint32_value(env, mixed_port, &out->mixed_port, error, "startLocal")) {
    return false;
  }
  if (out->mixed_port == 0 || out->mixed_port > 65535) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, "startLocal");
    return false;
  }
  return true;
}

bool decode_subscription_id(napi_env env, napi_value value, uint32_t *out, CoreErrorData *error, const char *operation) {
  if (!decode_uint32_value(env, value, out, error, operation)) {
    return false;
  }
  if (*out == 0) {
    *error = make_core_error(CMFA_OUT_OF_RANGE, operation);
    return false;
  }
  return true;
}

bool snapshot_to_owned(const cmfa_runtime_snapshot &snapshot,
                       OwnedRuntimeSnapshot *out,
                       CoreErrorData *error,
                       const char *operation) {
  const char *state_name = runtime_state_name(snapshot.state);
  if (state_name == nullptr) {
    *error = make_core_error(CMFA_BACKEND_ERROR, operation);
    return false;
  }

  const size_t path_length = strnlen(snapshot.active_config_path, CMFA_MAX_PATH_BYTES);
  if (path_length >= CMFA_MAX_PATH_BYTES) {
    *error = make_core_error(CMFA_BACKEND_ERROR, operation);
    return false;
  }
  const size_t http_length = strnlen(snapshot.http_address, CMFA_MAX_PATH_BYTES);
  if (http_length >= CMFA_MAX_PATH_BYTES) {
    *error = make_core_error(CMFA_BACKEND_ERROR, operation);
    return false;
  }
  const size_t socks_length = strnlen(snapshot.socks_address, CMFA_MAX_PATH_BYTES);
  if (socks_length >= CMFA_MAX_PATH_BYTES) {
    *error = make_core_error(CMFA_BACKEND_ERROR, operation);
    return false;
  }
  const size_t last_error_length = strnlen(snapshot.last_error, CMFA_MAX_PATH_BYTES);
  if (last_error_length >= CMFA_MAX_PATH_BYTES) {
    *error = make_core_error(CMFA_BACKEND_ERROR, operation);
    return false;
  }

  out->state = state_name;
  out->active_config_path.assign(snapshot.active_config_path, path_length);
  out->http_address.assign(snapshot.http_address, http_length);
  out->socks_address.assign(snapshot.socks_address, socks_length);
  out->last_error.assign(snapshot.last_error, last_error_length);
  out->mixed_port = snapshot.mixed_port;
  return true;
}

bool owned_snapshot_to_js(napi_env env, const OwnedRuntimeSnapshot &snapshot, napi_value *result, CoreErrorData *error) {
  napi_value object = nullptr;
  napi_status status = napi_create_object(env, &object);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_string(env, object, "state", snapshot.state);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_string(env, object, "activeConfigPath", snapshot.active_config_path);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_string(env, object, "httpAddress", snapshot.http_address);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_string(env, object, "socksAddress", snapshot.socks_address);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_string(env, object, "lastError", snapshot.last_error);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  status = set_named_uint32(env, object, "mixedPort", snapshot.mixed_port);
  if (status != napi_ok) {
    *error = make_napi_failure("runtimeSnapshot", status);
    return false;
  }
  *result = object;
  return true;
}

bool owned_event_to_js(napi_env env, const OwnedCoreEvent &event, napi_value *result, CoreErrorData *error) {
  napi_value object = nullptr;
  napi_status status = napi_create_object(env, &object);
  if (status != napi_ok) {
    *error = make_napi_failure("eventDelivery", status);
    return false;
  }

  if (event.kind == OwnedCoreEvent::Kind::RUNTIME) {
    status = set_named_string(env, object, "type", "runtime");
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
    status = set_named_string(env, object, "state", event.state);
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
    status = set_named_string(env, object, "message", event.message);
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
  } else {
    status = set_named_string(env, object, "type", "log");
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
    status = set_named_string(env, object, "level", event.level);
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
    status = set_named_string(env, object, "message", event.message);
    if (status != napi_ok) {
      *error = make_napi_failure("eventDelivery", status);
      return false;
    }
  }

  *result = object;
  return true;
}

OwnedCoreEvent copy_runtime_event(const cmfa_runtime_event &event) {
  OwnedCoreEvent copy;
  copy.kind = OwnedCoreEvent::Kind::RUNTIME;
  const char *state_name = runtime_state_name(event.state);
  if (state_name != nullptr) {
    copy.state = state_name;
  }
  if (event.message != nullptr) {
    copy.message.assign(event.message, strnlen(event.message, kMaxEventMessageBytes));
  }
  return copy;
}

OwnedCoreEvent copy_log_event(const cmfa_log_message &message) {
  OwnedCoreEvent copy;
  copy.kind = OwnedCoreEvent::Kind::LOG;
  const char *level_name = log_level_name(message.level);
  if (level_name != nullptr) {
    copy.level = level_name;
  }
  if (message.message != nullptr) {
    copy.message.assign(message.message, strnlen(message.message, kMaxEventMessageBytes));
  }
  return copy;
}

} // namespace cmfa::nodeaddon
