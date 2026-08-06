#if !defined(CMFA_INTERNAL_BACKEND_API)
#define CMFA_INTERNAL_BACKEND_API 1
#endif

#include "cmfa_mihomo_backend.h"

#include "cmfa_host.h"

#include <array>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void);
extern "C" cmfa_status cmfa_mihomo_start_local_v1(const char *config_path,
                                                  uint32_t mixed_port,
                                                  cmfa_runtime_snapshot *snapshot,
                                                  cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_stop_v1(cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_runtime_state_v1(cmfa_runtime_snapshot *snapshot, cmfa_error *error);

namespace {

constexpr size_t kMaxVersionScanBytes = 256;

struct MihomoBackendState {
  std::mutex mutex;
  bool registered = false;
  bool attached = false;
  cmfa_backend_host host{};
};

MihomoBackendState g_backend_state;

void write_error(cmfa_error *error, cmfa_status status, const char *message) {
  if (error == nullptr) {
    return;
  }

  const size_t message_length = message != nullptr ? std::strlen(message) : 0;
  error->code = status;
  error->length = message_length;
  if (error->message == nullptr || error->capacity == 0) {
    return;
  }

  const size_t writable = error->capacity - 1;
  const size_t copy_length = message_length < writable ? message_length : writable;
  if (copy_length > 0 && message != nullptr) {
    std::memcpy(error->message, message, copy_length);
  }
  error->message[copy_length] = '\0';
}

void clear_error(cmfa_error *error) { write_error(error, CMFA_OK, ""); }

cmfa_status fail(cmfa_error *error, cmfa_status status, const char *message) {
  write_error(error, status, message);
  return status;
}

void reset_runtime_snapshot(cmfa_runtime_snapshot *snapshot) {
  if (snapshot == nullptr) {
    return;
  }

  snapshot->struct_size = sizeof(cmfa_runtime_snapshot);
  snapshot->state = CMFA_RUNTIME_STOPPED;
  snapshot->active_config_path[0] = '\0';
  snapshot->http_address[0] = '\0';
  snapshot->socks_address[0] = '\0';
  snapshot->last_error[0] = '\0';
  snapshot->mixed_port = 0;
}

bool host_ready_locked() {
  return g_backend_state.attached && g_backend_state.host.host_emit_event != nullptr;
}

void emit_runtime_event_locked(cmfa_runtime_state_value state, const char *message) {
  if (!host_ready_locked()) {
    return;
  }

  cmfa_runtime_event event{};
  event.struct_size = sizeof(event);
  event.state = state;
  event.message = message;
  (void)g_backend_state.host.host_emit_event(g_backend_state.host.context, &event, nullptr);
}

std::string snapshot_message(const cmfa_runtime_snapshot &snapshot, const char *fallback) {
  if (snapshot.last_error[0] != '\0') {
    return snapshot.last_error;
  }
  if (snapshot.http_address[0] != '\0' || snapshot.socks_address[0] != '\0') {
    return std::string("http=") + snapshot.http_address + " socks=" + snapshot.socks_address;
  }
  return fallback != nullptr ? std::string(fallback) : std::string{};
}

cmfa_status attach_host(void *, const cmfa_backend_host *host, cmfa_error *error) {
  if (host == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "backend host must not be null");
  }
  if (static_cast<size_t>(host->struct_size) < sizeof(cmfa_backend_host)) {
    return fail(error, CMFA_INVALID_ARGUMENT, "backend host struct_size is too small");
  }

  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  g_backend_state.host = *host;
  g_backend_state.attached = true;
  clear_error(error);
  return CMFA_OK;
}

cmfa_status core_version(void *, char *out, size_t capacity, cmfa_error *error) {
  out[0] = '\0';
  char *const raw_version = cmfa_mihomo_core_version_cstr_v1();
  if (raw_version == nullptr) {
    return fail(error, CMFA_BACKEND_ERROR, "mihomo version is null");
  }

  const void *terminator = std::memchr(raw_version, '\0', kMaxVersionScanBytes);
  if (terminator == nullptr || raw_version[0] == '\0') {
    return fail(error, CMFA_BACKEND_ERROR, "mihomo version is malformed");
  }

  const size_t version_length = static_cast<const char *>(terminator) - raw_version;
  if (capacity < version_length + 1) {
    return fail(error, CMFA_BUFFER_TOO_SMALL, "version output buffer is too small");
  }

  std::memcpy(out, raw_version, version_length + 1);
  clear_error(error);
  return CMFA_OK;
}

cmfa_status validate_config(void *, const char *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support validate_config");
}

cmfa_status load_config(void *, const char *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support load_config");
}

cmfa_status start_local(void *,
                        const cmfa_local_options *options,
                        cmfa_runtime_snapshot *snapshot,
                        cmfa_error *error) {
  reset_runtime_snapshot(snapshot);
  if (options == nullptr || snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "options and snapshot must not be null");
  }

  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_STARTING, "starting local proxy");
  }

  const cmfa_status status =
      cmfa_mihomo_start_local_v1(options->config_path, options->mixed_port, snapshot, error);
  const std::string message = snapshot_message(*snapshot, status == CMFA_OK ? "local proxy running" : "start failed");
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(status == CMFA_OK ? snapshot->state : CMFA_RUNTIME_ERROR, message.c_str());
  }
  return status;
}

cmfa_status stop(void *, cmfa_error *error) {
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_STOPPING, "stopping local proxy");
  }
  const cmfa_status status = cmfa_mihomo_stop_v1(error);
  if (status != CMFA_OK) {
    cmfa_runtime_snapshot snapshot{};
    reset_runtime_snapshot(&snapshot);
    (void)cmfa_mihomo_runtime_state_v1(&snapshot, nullptr);
    const std::string message = snapshot_message(snapshot, "stop failed");
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_ERROR, message.c_str());
    return status;
  }

  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_STOPPED, "local proxy stopped");
  }
  clear_error(error);
  return CMFA_OK;
}

cmfa_status runtime_state(void *, cmfa_runtime_snapshot *snapshot, cmfa_error *error) {
  if (snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "snapshot must not be null");
  }
  reset_runtime_snapshot(snapshot);
  return cmfa_mihomo_runtime_state_v1(snapshot, error);
}

cmfa_status shutdown(void *, cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  g_backend_state.host = {};
  g_backend_state.attached = false;
  clear_error(error);
  return CMFA_OK;
}

cmfa_backend_api make_backend_api() {
  cmfa_backend_api api{};
  api.struct_size = sizeof(api);
  api.context = nullptr;
  api.attach_host = attach_host;
  api.core_version = core_version;
  api.validate_config = validate_config;
  api.load_config = load_config;
  api.start_local = start_local;
  api.stop = stop;
  api.runtime_state = runtime_state;
  api.shutdown = shutdown;
  return api;
}

} // namespace

namespace cmfa {

cmfa_status register_mihomo_backend(cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  if (g_backend_state.attached) {
    return fail(error, CMFA_INVALID_STATE, "backend mutation is only allowed before initialize or after shutdown");
  }
  if (g_backend_state.registered) {
    return fail(error, CMFA_INVALID_STATE, "mihomo backend is already registered");
  }

  const cmfa_backend_api api = make_backend_api();
  const cmfa_status status = cmfa_internal_register_backend(&api, error);
  if (status == CMFA_OK) {
    g_backend_state.registered = true;
  }
  return status;
}

cmfa_status unregister_mihomo_backend(cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  if (g_backend_state.attached) {
    return fail(error, CMFA_INVALID_STATE, "backend mutation is only allowed before initialize or after shutdown");
  }
  if (!g_backend_state.registered) {
    clear_error(error);
    return CMFA_OK;
  }

  const cmfa_status status = cmfa_internal_register_backend(nullptr, error);
  if (status != CMFA_OK) {
    return status;
  }

  g_backend_state.registered = false;
  g_backend_state.host = {};
  g_backend_state.attached = false;
  clear_error(error);
  return CMFA_OK;
}

} // namespace cmfa
