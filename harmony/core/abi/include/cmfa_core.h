#ifndef CMFA_CORE_H
#define CMFA_CORE_H

#include "cmfa_host.h"

#ifdef __cplusplus
extern "C" {
#endif

cmfa_status cmfa_initialize(const cmfa_host_callbacks *host, cmfa_error *error);
cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *error);
cmfa_status cmfa_validate_config(const char *path, cmfa_error *error);
cmfa_status cmfa_load_config(const char *path, cmfa_error *error);
cmfa_status cmfa_start_local(const cmfa_local_options *options,
                             cmfa_runtime_snapshot *snapshot,
                             cmfa_error *error);
cmfa_status cmfa_stop(cmfa_error *error);
cmfa_status cmfa_runtime_state(cmfa_runtime_snapshot *snapshot, cmfa_error *error);
cmfa_status cmfa_runtime_mode_query(cmfa_runtime_mode *mode, cmfa_error *error);
cmfa_status cmfa_runtime_mode_set(cmfa_runtime_mode mode, cmfa_error *error);
cmfa_status cmfa_proxy_groups(const cmfa_proxy_query_context *context,
                              uint8_t selectable_only,
                              cmfa_json_buffer *output,
                              cmfa_error *error);
cmfa_status cmfa_proxy_group(const cmfa_proxy_query_context *context,
                             const char *group_name,
                             cmfa_json_buffer *output,
                             cmfa_error *error);
cmfa_status cmfa_proxy_select(const cmfa_proxy_query_context *context,
                              const char *group_name,
                              const char *member_name,
                              cmfa_json_buffer *output,
                              cmfa_error *error);
cmfa_status cmfa_proxy_delay_start(const cmfa_proxy_query_context *context,
                                   const char *group_name,
                                   cmfa_json_buffer *output,
                                   cmfa_error *error);
cmfa_status cmfa_proxy_delay_snapshot(const char *job_id,
                                      cmfa_json_buffer *output,
                                      cmfa_error *error);
cmfa_status cmfa_proxy_delay_cancel(const char *job_id,
                                    cmfa_json_buffer *output,
                                    cmfa_error *error);
cmfa_status cmfa_tun_start(const cmfa_tun_options *options, cmfa_tun_snapshot *snapshot, cmfa_error *error);
cmfa_status cmfa_tun_stop(cmfa_error *error);
cmfa_status cmfa_tun_runtime_state(cmfa_tun_snapshot *snapshot, cmfa_error *error);
cmfa_status cmfa_tun_copy_traces(cmfa_tun_trace_collection *traces, cmfa_error *error);
cmfa_status cmfa_tun_copy_traces_ring(cmfa_tun_trace_ring *traces, cmfa_error *error);
#if defined(CMFA_TEST_BUILD_ABI)
cmfa_status cmfa_probe_https(const cmfa_probe_request *request,
                             cmfa_probe_result **result,
                             cmfa_error *error);
void cmfa_probe_result_free(cmfa_probe_result *result);
#endif
cmfa_status cmfa_shutdown(cmfa_error *error);

#ifdef __cplusplus
}
#endif

#endif
