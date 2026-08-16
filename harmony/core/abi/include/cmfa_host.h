#ifndef CMFA_HOST_H
#define CMFA_HOST_H

#include "cmfa_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmfa_log_message {
  uint32_t struct_size;
  cmfa_log_level level;
  const char *message;
} cmfa_log_message;

typedef struct cmfa_runtime_event {
  uint32_t struct_size;
  cmfa_runtime_state_value state;
  const char *message;
  const char *code;
  const char *session_id;
  const char *trace_id;
  const char *ingress;
  const char *protocol;
} cmfa_runtime_event;

typedef void (*cmfa_log_sink_fn)(void *context, const cmfa_log_message *message);
typedef void (*cmfa_runtime_event_sink_fn)(void *context, const cmfa_runtime_event *event);
/* Host implementations must return synchronously within timeout_ms. */
typedef cmfa_status (*cmfa_socket_protect_fn)(void *context, int fd, uint32_t timeout_ms);

typedef struct cmfa_host_callbacks {
  uint32_t struct_size;
  void *context;
  cmfa_log_sink_fn log_sink;
  cmfa_runtime_event_sink_fn event_sink;
  cmfa_socket_protect_fn protect_socket;
} cmfa_host_callbacks;

#if defined(CMFA_INTERNAL_BACKEND_API)
#if defined(__GNUC__) || defined(__clang__)
#define CMFA_INTERNAL_VISIBILITY __attribute__((visibility("hidden")))
#else
#define CMFA_INTERNAL_VISIBILITY
#endif

typedef struct cmfa_backend_host {
  uint32_t struct_size;
  void *context;
  cmfa_status (*host_emit_log)(void *context, const cmfa_log_message *message, cmfa_error *error);
  cmfa_status (*host_emit_event)(void *context, const cmfa_runtime_event *event, cmfa_error *error);
  cmfa_status (*host_protect_socket)(void *context, int fd, uint32_t timeout_ms, cmfa_error *error);
} cmfa_backend_host;

typedef struct cmfa_backend_api {
  uint32_t struct_size;
  void *context;
  cmfa_status (*attach_host)(void *context, const cmfa_backend_host *host, cmfa_error *error);
  cmfa_status (*core_version)(void *context, char *out, size_t capacity, cmfa_error *error);
  cmfa_status (*validate_config)(void *context, const char *path, cmfa_error *error);
  cmfa_status (*load_config)(void *context, const char *path, cmfa_error *error);
  cmfa_status (*start_local)(void *context,
                             const cmfa_local_options *options,
                             cmfa_runtime_snapshot *snapshot,
                             cmfa_error *error);
  cmfa_status (*stop)(void *context, cmfa_error *error);
  cmfa_status (*runtime_state)(void *context, cmfa_runtime_snapshot *snapshot, cmfa_error *error);
  cmfa_status (*probe_https)(void *context,
                             const cmfa_probe_request *request,
                             cmfa_probe_result *result,
                             cmfa_error *error);
  cmfa_status (*start_tun)(void *context,
                           const cmfa_tun_options *options,
                           cmfa_tun_snapshot *snapshot,
                           cmfa_error *error);
  cmfa_status (*stop_tun)(void *context, cmfa_error *error);
  cmfa_status (*tun_runtime_state)(void *context, cmfa_tun_snapshot *snapshot, cmfa_error *error);
  cmfa_status (*tun_copy_traces)(void *context, cmfa_tun_trace_collection *traces, cmfa_error *error);
  cmfa_status (*tun_copy_traces_ring)(void *context, cmfa_tun_trace_ring *traces, cmfa_error *error);
  cmfa_status (*shutdown)(void *context, cmfa_error *error);
} cmfa_backend_api;

CMFA_INTERNAL_VISIBILITY cmfa_status cmfa_internal_register_backend(const cmfa_backend_api *backend,
                                                                   cmfa_error *error);
#endif

#ifdef __cplusplus
}
#endif

#endif
