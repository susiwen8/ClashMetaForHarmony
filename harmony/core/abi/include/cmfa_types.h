#ifndef CMFA_TYPES_H
#define CMFA_TYPES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMFA_MAX_PATH_BYTES ((size_t)4096)

typedef enum cmfa_status {
  CMFA_OK = 0,
  CMFA_INVALID_ARGUMENT = 1,
  CMFA_INVALID_UTF8 = 2,
  CMFA_OUT_OF_RANGE = 3,
  CMFA_BUFFER_TOO_SMALL = 4,
  CMFA_NOT_INITIALIZED = 5,
  CMFA_ALREADY_INITIALIZED = 6,
  CMFA_INVALID_STATE = 7,
  CMFA_BUSY = 8,
  CMFA_CORE_UNAVAILABLE = 9,
  CMFA_BACKEND_ERROR = 10
} cmfa_status;

typedef enum cmfa_runtime_state_value {
  CMFA_RUNTIME_STOPPED = 0,
  CMFA_RUNTIME_STARTING = 1,
  CMFA_RUNTIME_RUNNING = 2,
  CMFA_RUNTIME_STOPPING = 3,
  CMFA_RUNTIME_ERROR = 4
} cmfa_runtime_state_value;

typedef enum cmfa_log_level {
  CMFA_LOG_DEBUG = 0,
  CMFA_LOG_INFO = 1,
  CMFA_LOG_WARN = 2,
  CMFA_LOG_ERROR = 3
} cmfa_log_level;

typedef struct cmfa_error {
  cmfa_status code;
  char *message;
  size_t capacity;
  size_t length;
} cmfa_error;

typedef struct cmfa_local_options {
  uint32_t struct_size;
  const char *config_path;
  uint32_t mixed_port;
} cmfa_local_options;

typedef struct cmfa_runtime_snapshot {
  uint32_t struct_size;
  cmfa_runtime_state_value state;
  char active_config_path[CMFA_MAX_PATH_BYTES];
  char http_address[CMFA_MAX_PATH_BYTES];
  char socks_address[CMFA_MAX_PATH_BYTES];
  char last_error[CMFA_MAX_PATH_BYTES];
  uint32_t mixed_port;
} cmfa_runtime_snapshot;

#ifdef __cplusplus
}
#endif

#endif
