#ifndef CMFA_MIHOMO_BACKEND_H
#define CMFA_MIHOMO_BACKEND_H

#include "cmfa_host.h"

#if defined(__GNUC__) || defined(__clang__)
#define CMFA_MIHOMO_BACKEND_HIDDEN __attribute__((visibility("hidden")))
#define CMFA_MIHOMO_BACKEND_VISIBLE __attribute__((visibility("default")))
#else
#define CMFA_MIHOMO_BACKEND_HIDDEN
#define CMFA_MIHOMO_BACKEND_VISIBLE
#endif

#ifdef __cplusplus
extern "C" {
#endif

CMFA_MIHOMO_BACKEND_VISIBLE cmfa_status cmfa_host_protect_socket_bridge_v1(int fd,
                                                                           uint32_t timeout_ms,
                                                                           cmfa_error *error);
CMFA_MIHOMO_BACKEND_VISIBLE cmfa_status cmfa_host_emit_runtime_event_bridge_v1(const cmfa_runtime_event *event,
                                                                                cmfa_error *error);

#ifdef __cplusplus
}
#endif

namespace cmfa {

CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status register_mihomo_backend(cmfa_error *error);
CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status unregister_mihomo_backend(cmfa_error *error);
CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status cancel_mihomo_probe(const char *probe_run_id, cmfa_error *error);
CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status close_stale_tun_connections_for_mihomo_backend(const char *session_id,
                                                                                       cmfa_error *error);
CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status protect_socket_for_mihomo_backend(int fd,
                                                                         uint32_t timeout_ms,
                                                                         cmfa_error *error);

} // namespace cmfa

#endif
