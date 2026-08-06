#include "cmfa_napi.h"

#include <array>

namespace cmfa::nodeaddon {

namespace {

bool load_runtime_snapshot(OwnedRuntimeSnapshot *out, CoreErrorData *error) {
  cmfa_error cmfa_error_value{};
  std::array<char, 128> message{};
  cmfa_error_value.message = message.data();
  cmfa_error_value.capacity = message.size();
  cmfa_error_value.length = 0;
  cmfa_error_value.code = CMFA_OK;

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  const cmfa_status status = cmfa_runtime_state(&snapshot, &cmfa_error_value);
  if (status != CMFA_OK) {
    *error = make_core_error(status, "runtimeSnapshot");
    return false;
  }
  return snapshot_to_owned(snapshot, out, error, "runtimeSnapshot");
}

} // namespace

napi_value hello(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "hello", status);
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "hello"));
      return nullptr;
    }

    napi_value result = nullptr;
    const napi_status create_status = napi_create_string_utf8(env, "cmfa-native-ready", NAPI_AUTO_LENGTH, &result);
    if (create_status != napi_ok) {
      throw_napi_failure(env, "hello", create_status);
      return nullptr;
    }
    return result;
  } catch (...) {
    throw_napi_failure(env, "hello", napi_generic_failure);
    return nullptr;
  }
}

napi_value runtime_snapshot(napi_env env, napi_callback_info info) {
  try {
    size_t argc = 0;
    void *data = nullptr;
    const napi_status status = napi_get_cb_info(env, info, &argc, nullptr, nullptr, &data);
    if (status != napi_ok) {
      throw_napi_failure(env, "runtimeSnapshot", status);
      return nullptr;
    }
    auto *addon = static_cast<AddonState *>(data);
    if (addon == nullptr || !addon->owner.can_deliver()) {
      throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "runtimeSnapshot"));
      return nullptr;
    }

    OwnedRuntimeSnapshot snapshot;
    CoreErrorData error;
    if (!load_runtime_snapshot(&snapshot, &error)) {
      throw_core_error(env, error);
      return nullptr;
    }

    napi_value result = nullptr;
    if (!owned_snapshot_to_js(env, snapshot, &result, &error)) {
      throw_core_error(env, error);
      return nullptr;
    }
    return result;
  } catch (...) {
    throw_napi_failure(env, "runtimeSnapshot", napi_generic_failure);
    return nullptr;
  }
}

napi_status define_core_module(napi_env env, napi_value exports, AddonState *state) {
  napi_property_descriptor descriptors[] = {
      {"hello", nullptr, hello, nullptr, nullptr, nullptr, napi_default, state},
      {"coreVersion", nullptr, core_version, nullptr, nullptr, nullptr, napi_default, state},
      {"validateConfiguration", nullptr, validate_configuration, nullptr, nullptr, nullptr, napi_default, state},
      {"loadConfiguration", nullptr, load_configuration, nullptr, nullptr, nullptr, napi_default, state},
#if defined(CMFA_ENABLE_PHASE2_SELFTEST)
      {"probeHttps", nullptr, probe_https, nullptr, nullptr, nullptr, napi_default, state},
#endif
      {"startLocal", nullptr, start_local, nullptr, nullptr, nullptr, napi_default, state},
      {"stopRuntime", nullptr, stop_runtime, nullptr, nullptr, nullptr, napi_default, state},
      {"runtimeSnapshot", nullptr, runtime_snapshot, nullptr, nullptr, nullptr, napi_default, state},
      {"subscribe", nullptr, subscribe, nullptr, nullptr, nullptr, napi_default, state},
      {"unsubscribe", nullptr, unsubscribe, nullptr, nullptr, nullptr, napi_default, state},
  };
  return napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
}

} // namespace cmfa::nodeaddon
