#include "cmfa_napi.h"
#include "cmfa_mihomo_backend.h"

namespace cmfa::nodeaddon {

namespace {

cmfa_status shutdown_core(void *, cmfa_error *error) {
  return cmfa_shutdown(error);
}

cmfa_status unregister_backend(void *, cmfa_error *error) {
  return cmfa::unregister_mihomo_backend(error);
}

void cleanup_addon(void *arg) {
  auto *state = static_cast<AddonState *>(arg);
  if (state == nullptr) {
    return;
  }
  (void)state->owner.cleanup();
  delete state;
}

void delete_state_with_cleanup(AddonState *state) {
  if (state == nullptr) {
    return;
  }
  (void)state->owner.cleanup();
  delete state;
}

} // namespace

napi_value Init(napi_env env, napi_value exports) {
  auto *state =
      new AddonState(cmfa::napi::LifecycleOperations{nullptr, shutdown_core, unregister_backend});
  state->env = env;

  cmfa_error error{};
  char error_message[128] = {};
  error.message = error_message;
  error.capacity = sizeof(error_message);
  error.length = 0;
  error.code = CMFA_OK;

  const cmfa_status register_status = cmfa::register_mihomo_backend(&error);
  if (register_status != CMFA_OK) {
    throw_core_error(env, make_core_error(register_status, "Init"));
    delete state;
    return nullptr;
  }

  cmfa_host_callbacks host{};
  host.struct_size = sizeof(host);
  host.context = state;
  host.log_sink = emit_log_event;
  host.event_sink = emit_runtime_event;
  const cmfa_status initialize_status = cmfa_initialize(&host, &error);
  if (initialize_status != CMFA_OK) {
    throw_core_error(env, make_core_error(initialize_status, "Init"));
    delete_state_with_cleanup(state);
    return nullptr;
  }

  if (napi_add_env_cleanup_hook(env, cleanup_addon, state) != napi_ok) {
    throw_napi_failure(env, "Init", napi_generic_failure);
    delete_state_with_cleanup(state);
    return nullptr;
  }

  if (define_core_module(env, exports, state) != napi_ok) {
    (void)napi_remove_env_cleanup_hook(env, cleanup_addon, state);
    throw_napi_failure(env, "Init", napi_generic_failure);
    delete_state_with_cleanup(state);
    return nullptr;
  }

  if (!state->owner.activate()) {
    (void)napi_remove_env_cleanup_hook(env, cleanup_addon, state);
    throw_core_error(env, make_core_error(CMFA_INVALID_STATE, "Init"));
    delete_state_with_cleanup(state);
    return nullptr;
  }

  return exports;
}

} // namespace cmfa::nodeaddon

using cmfa::nodeaddon::Init;

NAPI_MODULE(libentry, Init)
