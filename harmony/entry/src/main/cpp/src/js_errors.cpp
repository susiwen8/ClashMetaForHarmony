#include "cmfa_napi.h"

#include <array>
#include <cstring>

namespace cmfa::nodeaddon {

namespace {

constexpr std::string_view kCoreErrorCategory = "CoreError";
constexpr std::string_view kStateErrorCategory = "StateError";

napi_status set_named_string(napi_env env, napi_value object, const char *name, std::string_view value) {
  napi_value js_value = nullptr;
  napi_status status = napi_create_string_utf8(env, value.data(), value.size(), &js_value);
  if (status != napi_ok) {
    return status;
  }
  return napi_set_named_property(env, object, name, js_value);
}

napi_status set_named_bool(napi_env env, napi_value object, const char *name, bool value) {
  napi_value js_value = nullptr;
  napi_status status = napi_get_boolean(env, value, &js_value);
  if (status != napi_ok) {
    return status;
  }
  return napi_set_named_property(env, object, name, js_value);
}

napi_status set_named_int32(napi_env env, napi_value object, const char *name, int32_t value) {
  napi_value js_value = nullptr;
  napi_status status = napi_create_int32(env, value, &js_value);
  if (status != napi_ok) {
    return status;
  }
  return napi_set_named_property(env, object, name, js_value);
}

CoreErrorData make_error(std::string_view code,
                         std::string_view category,
                         std::string_view detail,
                         bool retryable,
                         std::string_view action,
                         const char *operation,
                         cmfa_status status) {
  CoreErrorData error;
  error.code.assign(code);
  error.category.assign(category);
  error.message = "Native core operation failed";
  error.detail.assign(detail);
  error.retryable = retryable;
  error.action.assign(action);
  error.context = CoreErrorContextData{operation != nullptr ? operation : "unknown", status};
  return error;
}

void fallback_throw(napi_env env) {
  (void)napi_throw_error(env, "NAPI_FAILURE", "Native bridge failure");
}

} // namespace

CoreErrorData make_core_error(cmfa_status status, const char *operation) {
  switch (status) {
    case CMFA_INVALID_ARGUMENT:
      return make_error("INVALID_ARGUMENT", kCoreErrorCategory, "Input validation failed", false, "CHECK_INPUT",
                        operation, status);
    case CMFA_INVALID_UTF8:
      return make_error("INVALID_UTF8", kCoreErrorCategory, "Input must be valid UTF-8", false, "CHECK_INPUT",
                        operation, status);
    case CMFA_OUT_OF_RANGE:
      return make_error("OUT_OF_RANGE", kCoreErrorCategory, "Input exceeded the supported range", false,
                        "CHECK_INPUT", operation, status);
    case CMFA_BUFFER_TOO_SMALL:
      return make_error("BUFFER_TOO_SMALL", kCoreErrorCategory, "Native output buffer was too small", false,
                        "CHECK_INPUT", operation, status);
    case CMFA_NOT_INITIALIZED:
      return make_error("NOT_INITIALIZED", kStateErrorCategory, "Native core is not initialized", false,
                        "RESTART_OPERATION", operation, status);
    case CMFA_ALREADY_INITIALIZED:
      return make_error("ALREADY_INITIALIZED", kStateErrorCategory, "Native core is already initialized", false,
                        "RESTART_OPERATION", operation, status);
    case CMFA_INVALID_STATE:
      return make_error("INVALID_STATE", kStateErrorCategory, "Native core is in an invalid state", false,
                        "RESTART_OPERATION", operation, status);
    case CMFA_BUSY:
      return make_error("CMFA_BUSY", kStateErrorCategory, "Native core is busy", true, "RETRY", operation, status);
    case CMFA_CORE_UNAVAILABLE:
      return make_error("CORE_UNAVAILABLE", kCoreErrorCategory, "Requested core capability is unavailable", false,
                        "UPDATE_CORE", operation, status);
    case CMFA_BACKEND_ERROR:
    default:
      return make_error("BACKEND_ERROR", kCoreErrorCategory, "Native backend reported an error", true, "RETRY",
                        operation, status);
  }
}

CoreErrorData make_napi_failure(const char *operation) {
  return make_error("NAPI_FAILURE", kCoreErrorCategory, "Native bridge failed while talking to ArkTS", false,
                    "RESTART_APP", operation, CMFA_BACKEND_ERROR);
}

napi_status create_core_error_value(napi_env env, const CoreErrorData &error, napi_value *result) {
  napi_value code = nullptr;
  napi_value message = nullptr;
  napi_value js_error = nullptr;

  napi_status status = napi_create_string_utf8(env, error.code.c_str(), error.code.size(), &code);
  if (status != napi_ok) {
    return status;
  }
  status = napi_create_string_utf8(env, error.message.c_str(), error.message.size(), &message);
  if (status != napi_ok) {
    return status;
  }
  status = napi_create_error(env, code, message, &js_error);
  if (status != napi_ok) {
    return status;
  }

  status = set_named_string(env, js_error, "name", "CoreError");
  if (status != napi_ok) {
    return status;
  }
  status = set_named_string(env, js_error, "code", error.code);
  if (status != napi_ok) {
    return status;
  }
  status = set_named_string(env, js_error, "category", error.category);
  if (status != napi_ok) {
    return status;
  }
  status = set_named_string(env, js_error, "detail", error.detail);
  if (status != napi_ok) {
    return status;
  }
  status = set_named_bool(env, js_error, "retryable", error.retryable);
  if (status != napi_ok) {
    return status;
  }
  status = set_named_string(env, js_error, "action", error.action);
  if (status != napi_ok) {
    return status;
  }

  if (error.context.has_value()) {
    napi_value context = nullptr;
    status = napi_create_object(env, &context);
    if (status != napi_ok) {
      return status;
    }
    status = set_named_string(env, context, "operation", error.context->operation);
    if (status != napi_ok) {
      return status;
    }
    status = set_named_int32(env, context, "status", static_cast<int32_t>(error.context->status));
    if (status != napi_ok) {
      return status;
    }
    status = napi_set_named_property(env, js_error, "context", context);
    if (status != napi_ok) {
      return status;
    }
  }

  *result = js_error;
  return napi_ok;
}

void throw_core_error(napi_env env, const CoreErrorData &error) {
  napi_value js_error = nullptr;
  if (create_core_error_value(env, error, &js_error) != napi_ok) {
    fallback_throw(env);
    return;
  }
  if (napi_throw(env, js_error) != napi_ok) {
    fallback_throw(env);
  }
}

void throw_napi_failure(napi_env env, const char *operation) {
  throw_core_error(env, make_napi_failure(operation));
}

void reject_deferred_with_core_error(napi_env env, napi_deferred deferred, const CoreErrorData &error) {
  napi_value js_error = nullptr;
  if (create_core_error_value(env, error, &js_error) != napi_ok) {
    fallback_throw(env);
    return;
  }
  if (napi_reject_deferred(env, deferred, js_error) != napi_ok) {
    fallback_throw(env);
  }
}

void reject_deferred_with_napi_failure(napi_env env, napi_deferred deferred, const char *operation) {
  reject_deferred_with_core_error(env, deferred, make_napi_failure(operation));
}

} // namespace cmfa::nodeaddon
