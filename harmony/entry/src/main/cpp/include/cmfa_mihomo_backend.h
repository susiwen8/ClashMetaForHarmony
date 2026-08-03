#ifndef CMFA_MIHOMO_BACKEND_H
#define CMFA_MIHOMO_BACKEND_H

#include "cmfa_types.h"

#if defined(__GNUC__) || defined(__clang__)
#define CMFA_MIHOMO_BACKEND_HIDDEN __attribute__((visibility("hidden")))
#else
#define CMFA_MIHOMO_BACKEND_HIDDEN
#endif

namespace cmfa {

CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status register_mihomo_backend(cmfa_error *error);
CMFA_MIHOMO_BACKEND_HIDDEN cmfa_status unregister_mihomo_backend(cmfa_error *error);

} // namespace cmfa

#endif
