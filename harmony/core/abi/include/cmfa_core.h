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
