#include <stdint.h>

extern char *go_cmfa_probe_version_impl(void);
extern int32_t go_cmfa_probe_add_impl(int32_t left, int32_t right);

const char *cmfa_probe_version(void) {
  return go_cmfa_probe_version_impl();
}

int32_t cmfa_probe_add(int32_t left, int32_t right) {
  return go_cmfa_probe_add_impl(left, right);
}
