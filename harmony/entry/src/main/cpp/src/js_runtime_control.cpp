#include "cmfa_napi.h"

#include <array>

namespace cmfa::nodeaddon {

namespace {

const char *runtime_mode_name(cmfa_runtime_mode mode) {
  switch (mode) {
    case CMFA_MODE_RULE:
      return "RULE";
    case CMFA_MODE_GLOBAL:
      return "GLOBAL";
    case CMFA_MODE_DIRECT:
      return "DIRECT";
  }
  return nullptr;
}

bool decode_runtime_mode(napi_env env, napi_value value, cmfa_runtime_mode *mode, CoreErrorData *error) {
  std::string raw;
  if (!decode_utf8_string(env, value, &raw, error, "setRuntimeMode", true, 16)) {
    return false;
  }
  if (raw == "RULE") {
    *mode = CMFA_MODE_RULE;
    return true;
  }
  if (raw == "GLOBAL") {
    *mode = CMFA_MODE_GLOBAL;
    return true;
  }
  if (raw == "DIRECT") {
    *mode = CMFA_MODE_DIRECT;
    return true;
  }
  *error = make_core_error(CMFA_INVALID_ARGUMENT, "setRuntimeMode");
  return false;
}

napi_value mode_to_js(napi_env env, cmfa_runtime_mode mode, const char *operation) {
  const char *name = runtime_mode_name(mode);
  if (name == nullptr) {
    throw_core_error(env, make_core_error(CMFA_BACKEND_ERROR, operation));
    return nullptr;
  }
  napi_value result = nullptr;
  const napi_status status = napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &result);
  if (status != napi_ok) {
    throw_napi_failure(env, operation, status);
    return nullptr;
  }
  return result;
}

bool require_live_addon(napi_env env, void *data, const char *operation) {
  auto *addon = static_cast<AddonState *>(data);
  if (addon == nullptr || !addon->owner.can_deliver()) {
    throw_core_error(env, make_core_error(CMFA_INVALID_STATE, operation));
    return false;
  }
  return true;
}

} // namespace

napi_value query_runtime_mode(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status callback_status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (callback_status != napi_ok) {
      throw_napi_failure(env, "queryRuntimeMode", callback_status);
      return nullptr;
    }
    if (!require_live_addon(env, data, "queryRuntimeMode")) {
      return nullptr;
    }
    cmfa_runtime_mode mode = CMFA_MODE_RULE;
    std::array<char, 128> message{};
    cmfa_error error{};
    error.message = message.data();
    error.capacity = message.size();
    const cmfa_status status = cmfa_runtime_mode_query(&mode, &error);
    if (status != CMFA_OK) {
      throw_core_error(env, make_core_error(status, "queryRuntimeMode"));
      return nullptr;
    }
    return mode_to_js(env, mode, "queryRuntimeMode");
  } catch (...) {
    throw_napi_failure(env, "queryRuntimeMode", napi_generic_failure);
    return nullptr;
  }
}

napi_value set_runtime_mode(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    void *data = nullptr;
    const napi_status callback_status = napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
    if (callback_status != napi_ok) {
      throw_napi_failure(env, "setRuntimeMode", callback_status);
      return nullptr;
    }
    if (argc != 1) {
      throw_core_error(env, make_core_error(CMFA_INVALID_ARGUMENT, "setRuntimeMode"));
      return nullptr;
    }
    if (!require_live_addon(env, data, "setRuntimeMode")) {
      return nullptr;
    }
    CoreErrorData decode_error;
    cmfa_runtime_mode mode = CMFA_MODE_RULE;
    if (!decode_runtime_mode(env, argv[0], &mode, &decode_error)) {
      throw_core_error(env, decode_error);
      return nullptr;
    }
    std::array<char, 128> message{};
    cmfa_error error{};
    error.message = message.data();
    error.capacity = message.size();
    const cmfa_status set_status = cmfa_runtime_mode_set(mode, &error);
    if (set_status != CMFA_OK) {
      throw_core_error(env, make_core_error(set_status, "setRuntimeMode"));
      return nullptr;
    }
    return mode_to_js(env, mode, "setRuntimeMode");
  } catch (...) {
    throw_napi_failure(env, "setRuntimeMode", napi_generic_failure);
    return nullptr;
  }
}

} // namespace cmfa::nodeaddon
