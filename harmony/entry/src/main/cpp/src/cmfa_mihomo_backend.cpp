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

#if defined(__OHOS__)
#include <hilog/log.h>
#endif

#if defined(__APPLE__)
#define CMFA_OPTIONAL_SYMBOL __attribute__((weak_import))
#elif defined(__GNUC__) || defined(__clang__)
#define CMFA_OPTIONAL_SYMBOL __attribute__((weak))
#else
#define CMFA_OPTIONAL_SYMBOL
#endif

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void);
struct cmfa_mihomo_runtime_log_record_v1 {
  uint32_t struct_size;
  cmfa_log_level level;
  char message[4096];
};
extern "C" int cmfa_mihomo_take_runtime_log_v1(cmfa_mihomo_runtime_log_record_v1 *record);
extern "C" cmfa_status cmfa_mihomo_validate_config_v1(const char *config_path, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_load_config_v1(const char *config_path, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_start_local_v1(const char *config_path,
                                                  uint32_t mixed_port,
                                                  cmfa_runtime_snapshot *snapshot,
                                                  cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_stop_v1(cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_runtime_state_v1(cmfa_runtime_snapshot *snapshot, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_runtime_mode_v1(cmfa_runtime_mode *mode, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_set_runtime_mode_v1(cmfa_runtime_mode mode, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_probe_https_v1(const cmfa_probe_request *request,
                                                  cmfa_probe_result *result,
                                                  cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_probe_cancel_v1(const char *probe_run_id, cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_groups_v1(const char *profile_hash,
                                                   const char *revision_hash,
                                                   const char *session_hash,
                                                   uint64_t generation,
                                                   uint8_t selectable_only,
                                                   char *output,
                                                   size_t output_capacity,
                                                   size_t *output_length,
                                                   cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_group_v1(const char *profile_hash,
                                                  const char *revision_hash,
                                                  const char *session_hash,
                                                  uint64_t generation,
                                                  const char *group_name,
                                                  char *output,
                                                  size_t output_capacity,
                                                  size_t *output_length,
                                                  cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_select_v1(const char *profile_hash,
                                                   const char *revision_hash,
                                                   const char *session_hash,
                                                   uint64_t generation,
                                                   const char *group_name,
                                                   const char *member_name,
                                                   char *output,
                                                   size_t output_capacity,
                                                   size_t *output_length,
                                                   cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_delay_start_v1(const char *profile_hash,
                                                        const char *revision_hash,
                                                        const char *session_hash,
                                                        uint64_t generation,
                                                        const char *group_name,
                                                        char *output,
                                                        size_t output_capacity,
                                                        size_t *output_length,
                                                        cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_delay_snapshot_v1(const char *job_id,
                                                           char *output,
                                                           size_t output_capacity,
                                                           size_t *output_length,
                                                           cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_proxy_delay_cancel_v1(const char *job_id,
                                                         char *output,
                                                         size_t output_capacity,
                                                         size_t *output_length,
                                                         cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_start_tun_v1(const cmfa_tun_options *options,
                                                cmfa_tun_snapshot *snapshot,
                                                cmfa_error *error) CMFA_OPTIONAL_SYMBOL;
extern "C" cmfa_status cmfa_mihomo_stop_tun_v1(cmfa_error *error) CMFA_OPTIONAL_SYMBOL;
extern "C" cmfa_status cmfa_mihomo_tun_runtime_state_v1(cmfa_tun_snapshot *snapshot,
                                                        cmfa_error *error) CMFA_OPTIONAL_SYMBOL;
extern "C" cmfa_status cmfa_mihomo_tun_copy_traces_v1(cmfa_tun_trace_collection *traces,
                                                      cmfa_error *error) CMFA_OPTIONAL_SYMBOL;
extern "C" cmfa_status cmfa_mihomo_tun_copy_traces_ring_v1(cmfa_tun_trace_ring *traces,
                                                           cmfa_error *error) CMFA_OPTIONAL_SYMBOL;
extern "C" cmfa_status cmfa_mihomo_close_stale_tun_connections_v1(const char *session_id,
                                                                   cmfa_error *error) CMFA_OPTIONAL_SYMBOL;

namespace {

constexpr size_t kMaxVersionScanBytes = 256;
#if defined(__OHOS__)
constexpr unsigned int kVpnStageLogDomain = 0x0D00CF4A;
constexpr const char *kVpnStageLogTag = "CMFAVpn";
#endif
constexpr std::array<const char *, 38> kTunLifecycleStages = {
    "tun.prepare.begin",
    "tun.prepare.ok",
    "tun.prepare.failed",
    "tun.http-listener.begin",
    "tun.http-listener.ok",
    "tun.http-listener.failed",
    "tun.socks-listener.begin",
    "tun.socks-listener.ok",
    "tun.socks-listener.failed",
    "tun.listener.begin",
    "tun.listener.endpoint-enter",
    "tun.listener.ok",
    "tun.listener.failure.interface",
    "tun.listener.failure.stack-create",
    "tun.listener.failure.stack-start",
    "tun.listener.failure.unknown-scope",
    "tun.listener.failure.bad-fd",
    "tun.listener.failure.permission",
    "tun.listener.failure.invalid",
    "tun.listener.failure.unsupported",
    "tun.listener.failure.io",
    "tun.listener.failure.unknown-cause",
    "tun.listener.failed",
    "tun.stop.listener.begin",
    "tun.stop.listener.ok",
    "tun.stop.listener.failed",
    "tun.stop.http-listener.begin",
    "tun.stop.http-listener.ok",
    "tun.stop.http-listener.failed",
    "tun.stop.socks-listener.begin",
    "tun.stop.socks-listener.ok",
    "tun.stop.socks-listener.failed",
    "tun.stop.connections.begin",
    "tun.stop.connections.ok",
    "tun.stop.connections.failed",
    "tun.stop.executor.begin",
    "tun.stop.executor.ok",
    "tun.stop.executor.failed",
};
constexpr std::array<const char *, 5> kTunPacketDiagnosticStages = {
    "tun.packet.read-loop-enter",
    "tun.packet.read-would-block",
    "tun.packet.read-failed",
    "tun.packet.raw-read",
    "tun.packet.gvisor-inject",
};
bool is_allowed_tun_lifecycle_stage(const char *stage) {
  if (stage == nullptr) {
    return false;
  }
  for (const char *allowed : kTunLifecycleStages) {
    if (std::strcmp(stage, allowed) == 0) {
      return true;
    }
  }
  return false;
}

bool is_allowed_tun_packet_diagnostic_stage(const char *stage) {
  if (stage == nullptr) {
    return false;
  }
  for (const char *allowed : kTunPacketDiagnosticStages) {
    if (std::strcmp(stage, allowed) == 0) {
      return true;
    }
  }
  return false;
}

#if defined(__OHOS__)
bool is_allowed_tun_packet_diagnostic_event(const cmfa_runtime_event *event) {
  return event != nullptr && event->ingress != nullptr && event->protocol != nullptr &&
         std::strcmp(event->ingress, "diagnostic") == 0 &&
         is_allowed_tun_packet_diagnostic_stage(event->protocol);
}
#endif

void emit_tun_packet_diagnostic_stage_if_allowed(const cmfa_runtime_event *event) {
#if defined(__OHOS__)
  if (!is_allowed_tun_packet_diagnostic_event(event)) {
    return;
  }
  (void)OH_LOG_Print(LOG_APP, LOG_INFO, kVpnStageLogDomain, kVpnStageLogTag, "%{public}s", event->protocol);
#else
  (void)event;
#endif
}

struct MihomoBackendState {
  std::mutex mutex;
  bool registered = false;
  bool attached = false;
  cmfa_backend_host host{};
  std::string active_tun_session_id;
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

void reset_tun_snapshot(cmfa_tun_snapshot *snapshot) {
  if (snapshot == nullptr) {
    return;
  }
  std::memset(snapshot, 0, sizeof(*snapshot));
  snapshot->struct_size = sizeof(cmfa_tun_snapshot);
  snapshot->state = CMFA_TUN_IDLE;
  snapshot->counters.struct_size = sizeof(cmfa_tun_counters);
  snapshot->failure.struct_size = sizeof(cmfa_tun_failure);
}

void reset_tun_traces(cmfa_tun_trace_collection *traces) {
  if (traces == nullptr) {
    return;
  }
  std::memset(traces, 0, sizeof(*traces));
  traces->struct_size = sizeof(cmfa_tun_trace_collection);
  for (size_t index = 0; index < CMFA_MAX_TUN_TRACE_COUNT; ++index) {
    traces->traces[index].struct_size = sizeof(cmfa_tun_trace);
  }
}

bool host_ready_locked() {
  return g_backend_state.attached && g_backend_state.host.host_emit_event != nullptr;
}

bool log_host_ready_locked() {
  return g_backend_state.attached && g_backend_state.host.host_emit_log != nullptr;
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

void emit_runtime_logs(const char *tun_session_id = nullptr) {
  cmfa_backend_host host{};
  std::string stored_tun_session_id;
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    if (!log_host_ready_locked()) {
      return;
    }
    host = g_backend_state.host;
    if ((tun_session_id == nullptr || tun_session_id[0] == '\0') &&
        !g_backend_state.active_tun_session_id.empty()) {
      stored_tun_session_id = g_backend_state.active_tun_session_id;
      tun_session_id = stored_tun_session_id.c_str();
    }
  }

  while (true) {
    cmfa_mihomo_runtime_log_record_v1 record{};
    record.struct_size = sizeof(record);
    if (cmfa_mihomo_take_runtime_log_v1(&record) == 0) {
      return;
    }
    const char *stage = record.message;
    if (is_allowed_tun_lifecycle_stage(stage)) {
#if defined(__OHOS__)
      (void)OH_LOG_Print(LOG_APP, LOG_INFO, kVpnStageLogDomain, kVpnStageLogTag, "%{public}s", stage);
#endif
      continue;
    }
    if (is_allowed_tun_packet_diagnostic_stage(stage)) {
#if defined(__OHOS__)
      (void)OH_LOG_Print(LOG_APP, LOG_INFO, kVpnStageLogDomain, kVpnStageLogTag, "%{public}s", stage);
#endif
      if (tun_session_id != nullptr && tun_session_id[0] != '\0' && host.host_emit_event != nullptr) {
        cmfa_runtime_event event{};
        event.struct_size = sizeof(event);
        event.state = CMFA_RUNTIME_RUNNING;
        event.message = stage;
        event.session_id = tun_session_id;
        event.ingress = "diagnostic";
        event.protocol = stage;
        (void)host.host_emit_event(host.context, &event, nullptr);
      }
      continue;
    }
    cmfa_log_message message{};
    message.struct_size = sizeof(message);
    message.level = record.level;
    message.message = record.message;
    (void)host.host_emit_log(host.context, &message, nullptr);
  }
}

const char *runtime_event_message(cmfa_status status,
                                  cmfa_runtime_state_value state,
                                  const char *failure_message,
                                  const char *fallback_message) {
  if (status != CMFA_OK) {
    return failure_message != nullptr ? failure_message : "runtime error";
  }
  switch (state) {
    case CMFA_RUNTIME_STARTING:
      return "starting local proxy";
    case CMFA_RUNTIME_RUNNING:
      return "local proxy running";
    case CMFA_RUNTIME_STOPPING:
      return "stopping local proxy";
    case CMFA_RUNTIME_STOPPED:
      return "local proxy stopped";
    case CMFA_RUNTIME_ERROR:
      return "runtime error";
    default:
      return fallback_message != nullptr ? fallback_message : "runtime error";
  }
}

const char *proxy_session_hash_or_null(const cmfa_proxy_query_context *query) {
  if (query == nullptr || query->session_hash[0] == '\0') {
    return nullptr;
  }
  return query->session_hash;
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

cmfa_status validate_config(void *, const char *config_path, cmfa_error *error) {
  return cmfa_mihomo_validate_config_v1(config_path, error);
}

cmfa_status load_config(void *, const char *config_path, cmfa_error *error) {
  return cmfa_mihomo_load_config_v1(config_path, error);
}

cmfa_status start_local(void *,
                        const cmfa_local_options *options,
                        cmfa_runtime_snapshot *snapshot,
                        cmfa_error *error) {
  if (options == nullptr || snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "options and snapshot must not be null");
  }
  reset_runtime_snapshot(snapshot);

  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_STARTING, "starting local proxy");
  }

  const cmfa_status status =
      cmfa_mihomo_start_local_v1(options->config_path, options->mixed_port, snapshot, error);
  emit_runtime_logs();
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(status == CMFA_OK ? snapshot->state : CMFA_RUNTIME_ERROR,
                              runtime_event_message(status, snapshot->state, "start failed", "local proxy running"));
  }
  return status;
}

cmfa_status stop(void *, cmfa_error *error) {
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(CMFA_RUNTIME_STOPPING, "stopping local proxy");
  }
  const cmfa_status status = cmfa_mihomo_stop_v1(error);
  emit_runtime_logs();
  cmfa_runtime_snapshot snapshot{};
  reset_runtime_snapshot(&snapshot);
  (void)cmfa_mihomo_runtime_state_v1(&snapshot, nullptr);
  if (status != CMFA_OK) {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(snapshot.state == CMFA_RUNTIME_STOPPED ? CMFA_RUNTIME_ERROR : snapshot.state,
                              runtime_event_message(status, snapshot.state, "stop failed", "local proxy stopped"));
    return status;
  }
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    emit_runtime_event_locked(snapshot.state,
                              runtime_event_message(status, snapshot.state, "stop failed", "local proxy stopped"));
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

cmfa_status runtime_mode_query(void *, cmfa_runtime_mode *mode, cmfa_error *error) {
  if (mode == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "runtime mode output must not be null");
  }
  return cmfa_mihomo_runtime_mode_v1(mode, error);
}

cmfa_status runtime_mode_set(void *, cmfa_runtime_mode mode, cmfa_error *error) {
  return cmfa_mihomo_set_runtime_mode_v1(mode, error);
}

cmfa_status proxy_groups(void *,
                         const cmfa_proxy_query_context *query,
                         uint8_t selectable_only,
                         cmfa_json_buffer *output,
                         cmfa_error *error) {
  if (query == nullptr || output == nullptr || output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy query and output must not be null");
  }
  return cmfa_mihomo_proxy_groups_v1(query->profile_hash,
                                     query->revision_hash,
                                     proxy_session_hash_or_null(query),
                                     query->generation,
                                     selectable_only,
                                     output->data,
                                     output->capacity,
                                     &output->length,
                                     error);
}

cmfa_status proxy_group(void *,
                        const cmfa_proxy_query_context *query,
                        const char *group_name,
                        cmfa_json_buffer *output,
                        cmfa_error *error) {
  if (query == nullptr || group_name == nullptr || output == nullptr || output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy query, group name, and output must not be null");
  }
  return cmfa_mihomo_proxy_group_v1(query->profile_hash,
                                    query->revision_hash,
                                    proxy_session_hash_or_null(query),
                                    query->generation,
                                    group_name,
                                    output->data,
                                    output->capacity,
                                    &output->length,
                                    error);
}

cmfa_status proxy_select(void *,
                         const cmfa_proxy_query_context *query,
                         const char *group_name,
                         const char *member_name,
                         cmfa_json_buffer *output,
                         cmfa_error *error) {
  if (query == nullptr || group_name == nullptr || member_name == nullptr || output == nullptr ||
      output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy query, names, and output must not be null");
  }
  return cmfa_mihomo_proxy_select_v1(query->profile_hash,
                                     query->revision_hash,
                                     proxy_session_hash_or_null(query),
                                     query->generation,
                                     group_name,
                                     member_name,
                                     output->data,
                                     output->capacity,
                                     &output->length,
                                     error);
}

cmfa_status proxy_delay_start(void *,
                              const cmfa_proxy_query_context *query,
                              const char *group_name,
                              cmfa_json_buffer *output,
                              cmfa_error *error) {
  if (query == nullptr || group_name == nullptr || output == nullptr || output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy query, group name, and output must not be null");
  }
  return cmfa_mihomo_proxy_delay_start_v1(query->profile_hash,
                                          query->revision_hash,
                                          proxy_session_hash_or_null(query),
                                          query->generation,
                                          group_name,
                                          output->data,
                                          output->capacity,
                                          &output->length,
                                          error);
}

cmfa_status proxy_delay_snapshot(void *, const char *job_id, cmfa_json_buffer *output, cmfa_error *error) {
  if (job_id == nullptr || output == nullptr || output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy delay job id and output must not be null");
  }
  return cmfa_mihomo_proxy_delay_snapshot_v1(job_id, output->data, output->capacity, &output->length, error);
}

cmfa_status proxy_delay_cancel(void *, const char *job_id, cmfa_json_buffer *output, cmfa_error *error) {
  if (job_id == nullptr || output == nullptr || output->data == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "proxy delay job id and output must not be null");
  }
  return cmfa_mihomo_proxy_delay_cancel_v1(job_id, output->data, output->capacity, &output->length, error);
}

cmfa_status probe_https(void *, const cmfa_probe_request *request, cmfa_probe_result *result, cmfa_error *error) {
  if (request == nullptr || result == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "probe request and result must not be null");
  }
  std::memset(result, 0, sizeof(*result));
  result->struct_size = sizeof(cmfa_probe_result);
  result->protocol = request->protocol;
  result->tracker.struct_size = sizeof(cmfa_probe_tracker_record);
  result->error.struct_size = sizeof(cmfa_probe_error);
  return cmfa_mihomo_probe_https_v1(request, result, error);
}

cmfa_status start_tun(void *, const cmfa_tun_options *options, cmfa_tun_snapshot *snapshot, cmfa_error *error) {
  if (options == nullptr || snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "tun options and snapshot must not be null");
  }
  reset_tun_snapshot(snapshot);
  if (cmfa_mihomo_start_tun_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support start_tun");
  }
  {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    g_backend_state.active_tun_session_id = options->session_id;
  }
  const cmfa_status status = cmfa_mihomo_start_tun_v1(options, snapshot, error);
  emit_runtime_logs(options->session_id);
  if (status != CMFA_OK) {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    if (g_backend_state.active_tun_session_id == options->session_id) {
      g_backend_state.active_tun_session_id.clear();
    }
  }
  return status;
}

cmfa_status stop_tun(void *, cmfa_error *error) {
  if (cmfa_mihomo_stop_tun_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support stop_tun");
  }
  const cmfa_status status = cmfa_mihomo_stop_tun_v1(error);
  emit_runtime_logs();
  if (status == CMFA_OK) {
    std::lock_guard<std::mutex> lock(g_backend_state.mutex);
    g_backend_state.active_tun_session_id.clear();
  }
  return status;
}

cmfa_status tun_runtime_state(void *, cmfa_tun_snapshot *snapshot, cmfa_error *error) {
  if (snapshot == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "tun snapshot must not be null");
  }
  reset_tun_snapshot(snapshot);
  if (cmfa_mihomo_tun_runtime_state_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support tun_runtime_state");
  }
  const cmfa_status status = cmfa_mihomo_tun_runtime_state_v1(snapshot, error);
  emit_runtime_logs();
  return status;
}

cmfa_status tun_copy_traces(void *, cmfa_tun_trace_collection *traces, cmfa_error *error) {
  if (traces == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "tun traces must not be null");
  }
  reset_tun_traces(traces);
  if (cmfa_mihomo_tun_copy_traces_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support tun_copy_traces");
  }
  return cmfa_mihomo_tun_copy_traces_v1(traces, error);
}

cmfa_status tun_copy_traces_ring(void *, cmfa_tun_trace_ring *traces, cmfa_error *error) {
  if (traces == nullptr) {
    return fail(error, CMFA_INVALID_ARGUMENT, "tun trace ring must not be null");
  }
  std::memset(traces, 0, sizeof(*traces));
  traces->struct_size = sizeof(*traces);
  if (cmfa_mihomo_tun_copy_traces_ring_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support tun_copy_traces_ring");
  }
  const cmfa_status status = cmfa_mihomo_tun_copy_traces_ring_v1(traces, error);
  emit_runtime_logs();
  return status;
}

cmfa_status shutdown(void *, cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  g_backend_state.host = {};
  g_backend_state.attached = false;
  g_backend_state.active_tun_session_id.clear();
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
  api.runtime_mode_query = runtime_mode_query;
  api.runtime_mode_set = runtime_mode_set;
  api.proxy_groups = proxy_groups;
  api.proxy_group = proxy_group;
  api.proxy_select = proxy_select;
  api.proxy_delay_start = proxy_delay_start;
  api.proxy_delay_snapshot = proxy_delay_snapshot;
  api.proxy_delay_cancel = proxy_delay_cancel;
  api.probe_https = probe_https;
  api.start_tun = start_tun;
  api.stop_tun = stop_tun;
  api.tun_runtime_state = tun_runtime_state;
  api.tun_copy_traces = tun_copy_traces;
  api.tun_copy_traces_ring = tun_copy_traces_ring;
  api.shutdown = shutdown;
  return api;
}

} // namespace

#if defined(CMFA_BACKEND_TESTING)
extern "C" cmfa_status cmfa_mihomo_backend_test_start_local_direct(const cmfa_local_options *options,
                                                                   cmfa_runtime_snapshot *snapshot,
                                                                   cmfa_error *error) {
  return start_local(nullptr, options, snapshot, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_groups_direct(const cmfa_proxy_query_context *query,
                                                                    uint8_t selectable_only,
                                                                    cmfa_json_buffer *output,
                                                                    cmfa_error *error) {
  return proxy_groups(nullptr, query, selectable_only, output, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_group_direct(const cmfa_proxy_query_context *query,
                                                                   const char *group_name,
                                                                   cmfa_json_buffer *output,
                                                                   cmfa_error *error) {
  return proxy_group(nullptr, query, group_name, output, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_select_direct(const cmfa_proxy_query_context *query,
                                                                    const char *group_name,
                                                                    const char *member_name,
                                                                    cmfa_json_buffer *output,
                                                                    cmfa_error *error) {
  return proxy_select(nullptr, query, group_name, member_name, output, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_start_direct(const cmfa_proxy_query_context *query,
                                                                         const char *group_name,
                                                                         cmfa_json_buffer *output,
                                                                         cmfa_error *error) {
  return proxy_delay_start(nullptr, query, group_name, output, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_snapshot_direct(const char *job_id,
                                                                            cmfa_json_buffer *output,
                                                                            cmfa_error *error) {
  return proxy_delay_snapshot(nullptr, job_id, output, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_cancel_direct(const char *job_id,
                                                                          cmfa_json_buffer *output,
                                                                          cmfa_error *error) {
  return proxy_delay_cancel(nullptr, job_id, output, error);
}

extern "C" void cmfa_mihomo_backend_test_emit_runtime_logs() { emit_runtime_logs("session-test"); }

extern "C" cmfa_status cmfa_mihomo_backend_test_close_stale_tun_connections_impl(const char *session_id,
                                                                                  cmfa_error *error);

extern "C" cmfa_status cmfa_mihomo_start_tun_v1(const cmfa_tun_options *, cmfa_tun_snapshot *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend test stub does not support start_tun");
}

extern "C" cmfa_status cmfa_mihomo_stop_tun_v1(cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend test stub does not support stop_tun");
}

extern "C" cmfa_status cmfa_mihomo_tun_runtime_state_v1(cmfa_tun_snapshot *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend test stub does not support tun_runtime_state");
}

extern "C" cmfa_status cmfa_mihomo_tun_copy_traces_v1(cmfa_tun_trace_collection *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend test stub does not support tun_copy_traces");
}

extern "C" cmfa_status cmfa_mihomo_tun_copy_traces_ring_v1(cmfa_tun_trace_ring *, cmfa_error *error) {
  return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend test stub does not support tun_copy_traces_ring");
}

extern "C" cmfa_status cmfa_mihomo_close_stale_tun_connections_v1(const char *session_id, cmfa_error *error) {
  return cmfa_mihomo_backend_test_close_stale_tun_connections_impl(session_id, error);
}
#endif

namespace cmfa {

cmfa_status protect_socket_for_mihomo_backend(int fd, uint32_t timeout_ms, cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  if (!g_backend_state.attached || g_backend_state.host.host_protect_socket == nullptr) {
    return fail(error, CMFA_SOCKET_PROTECT_FAILED, "host protect_socket callback is unavailable");
  }
  return g_backend_state.host.host_protect_socket(g_backend_state.host.context, fd, timeout_ms, error);
}

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
  g_backend_state.active_tun_session_id.clear();
  clear_error(error);
  return CMFA_OK;
}

cmfa_status cancel_mihomo_probe(const char *probe_run_id, cmfa_error *error) {
  if (probe_run_id == nullptr || probe_run_id[0] == '\0') {
    return fail(error, CMFA_INVALID_ARGUMENT, "probeRunID must not be empty");
  }
  return cmfa_mihomo_probe_cancel_v1(probe_run_id, error);
}

cmfa_status close_stale_tun_connections_for_mihomo_backend(const char *session_id, cmfa_error *error) {
  if (session_id == nullptr || session_id[0] == '\0') {
    return fail(error, CMFA_INVALID_ARGUMENT, "tun session id must not be empty");
  }
#if !defined(CMFA_BACKEND_TESTING)
  if (cmfa_mihomo_close_stale_tun_connections_v1 == nullptr) {
    return fail(error, CMFA_CORE_UNAVAILABLE, "mihomo backend does not support close_stale_tun_connections");
  }
#endif
  return cmfa_mihomo_close_stale_tun_connections_v1(session_id, error);
}

} // namespace cmfa

extern "C" cmfa_status cmfa_host_protect_socket_bridge_v1(int fd, uint32_t timeout_ms, cmfa_error *error) {
  return cmfa::protect_socket_for_mihomo_backend(fd, timeout_ms, error);
}

extern "C" cmfa_status cmfa_host_emit_runtime_event_bridge_v1(const cmfa_runtime_event *event, cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_backend_state.mutex);
  if (!g_backend_state.attached || g_backend_state.host.host_emit_event == nullptr) {
    return fail(error, CMFA_BACKEND_ERROR, "host runtime event callback is unavailable");
  }
  emit_tun_packet_diagnostic_stage_if_allowed(event);
  return g_backend_state.host.host_emit_event(g_backend_state.host.context, event, error);
}
