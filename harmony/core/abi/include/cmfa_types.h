#ifndef CMFA_TYPES_H
#define CMFA_TYPES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMFA_MAX_PATH_BYTES ((size_t)4096)
#define CMFA_MAX_PROBE_ID_BYTES ((size_t)128)
#define CMFA_MAX_PROBE_DIGEST_BYTES ((size_t)65)
#define CMFA_MAX_PROBE_TIMESTAMP_BYTES ((size_t)64)
#define CMFA_MAX_PROBE_ENDPOINT_BYTES ((size_t)256)
#define CMFA_MAX_PROBE_KIND_BYTES ((size_t)64)
#define CMFA_MAX_PROBE_ERROR_BYTES ((size_t)1024)
#define CMFA_MAX_PROBE_PEM_BYTES ((size_t)16384)
#define CMFA_MAX_TUN_SESSION_ID_BYTES ((size_t)128)
#define CMFA_MAX_TUN_TRACE_ID_BYTES ((size_t)128)
#define CMFA_MAX_TUN_ADDRESS_BYTES ((size_t)256)
#define CMFA_MAX_TUN_PROTOCOL_BYTES ((size_t)32)
#define CMFA_MAX_TUN_INGRESS_BYTES ((size_t)32)
#define CMFA_MAX_TUN_HASH_BYTES ((size_t)65)
#define CMFA_MAX_TUN_FAILURE_CODE_BYTES ((size_t)64)
#define CMFA_MAX_TUN_FAILURE_DETAIL_BYTES ((size_t)1024)
#define CMFA_MAX_TUN_TRACE_COUNT ((size_t)16)

typedef enum cmfa_probe_protocol {
  CMFA_PROBE_PROTOCOL_UNSPECIFIED = 0,
  CMFA_PROBE_PROTOCOL_HTTP_CONNECT = 1,
  CMFA_PROBE_PROTOCOL_SOCKS5 = 2
} cmfa_probe_protocol;

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
  CMFA_BACKEND_ERROR = 10,
  CMFA_SOCKET_PROTECT_FAILED = 11
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

typedef enum cmfa_tun_state_value {
  CMFA_TUN_IDLE = 0,
  CMFA_TUN_STARTING = 1,
  CMFA_TUN_READY = 2,
  CMFA_TUN_STOPPED = 3,
  CMFA_TUN_ERROR = 4
} cmfa_tun_state_value;

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

typedef struct cmfa_probe_request {
  uint32_t struct_size;
  const char *probe_run_id;
  cmfa_probe_protocol protocol;
  const char *listener_address;
  const char *origin_url;
  const char *ca_pem;
  const char *expected_body_sha256;
} cmfa_probe_request;

typedef struct cmfa_probe_error {
  uint32_t struct_size;
  char code[CMFA_MAX_PROBE_KIND_BYTES];
  char stage[CMFA_MAX_PROBE_KIND_BYTES];
  char detail[CMFA_MAX_PROBE_ERROR_BYTES];
} cmfa_probe_error;

typedef struct cmfa_probe_tracker_record {
  uint32_t struct_size;
  char connection_id[CMFA_MAX_PROBE_ID_BYTES];
  char source_address[CMFA_MAX_PROBE_ENDPOINT_BYTES];
  char destination_address[CMFA_MAX_PROBE_ENDPOINT_BYTES];
  char inbound_type[CMFA_MAX_PROBE_KIND_BYTES];
  char opened_at[CMFA_MAX_PROBE_TIMESTAMP_BYTES];
} cmfa_probe_tracker_record;

typedef struct cmfa_probe_result {
  uint32_t struct_size;
  uint8_t ok;
  cmfa_probe_protocol protocol;
  int32_t http_status;
  uint64_t body_bytes;
  char probe_run_id[CMFA_MAX_PROBE_ID_BYTES];
  char request_id_echo[CMFA_MAX_PROBE_ID_BYTES];
  char origin_id[CMFA_MAX_PROBE_ID_BYTES];
  char response_sha256[CMFA_MAX_PROBE_DIGEST_BYTES];
  char tls_peer_sha256[CMFA_MAX_PROBE_DIGEST_BYTES];
  char started_at[CMFA_MAX_PROBE_TIMESTAMP_BYTES];
  char completed_at[CMFA_MAX_PROBE_TIMESTAMP_BYTES];
  char client_local_address[CMFA_MAX_PROBE_ENDPOINT_BYTES];
  char client_remote_address[CMFA_MAX_PROBE_ENDPOINT_BYTES];
  cmfa_probe_tracker_record tracker;
  cmfa_probe_error error;
} cmfa_probe_result;

typedef struct cmfa_tun_options {
  uint32_t struct_size;
  int32_t tun_fd;
  char session_id[CMFA_MAX_TUN_SESSION_ID_BYTES];
} cmfa_tun_options;

typedef struct cmfa_tun_counters {
  uint32_t struct_size;
  uint64_t tx_packets;
  uint64_t tx_bytes;
  uint64_t rx_packets;
  uint64_t rx_bytes;
} cmfa_tun_counters;

typedef struct cmfa_tun_failure {
  uint32_t struct_size;
  char code[CMFA_MAX_TUN_FAILURE_CODE_BYTES];
  char detail[CMFA_MAX_TUN_FAILURE_DETAIL_BYTES];
} cmfa_tun_failure;

typedef struct cmfa_tun_trace {
  uint32_t struct_size;
  char session_id[CMFA_MAX_TUN_SESSION_ID_BYTES];
  char trace_id[CMFA_MAX_TUN_TRACE_ID_BYTES];
  char ingress[CMFA_MAX_TUN_INGRESS_BYTES];
  char protocol[CMFA_MAX_TUN_PROTOCOL_BYTES];
  char source_address[CMFA_MAX_TUN_ADDRESS_BYTES];
  char destination_address[CMFA_MAX_TUN_ADDRESS_BYTES];
  char hashed_tuple[CMFA_MAX_TUN_HASH_BYTES];
  char correlation_hash[CMFA_MAX_TUN_HASH_BYTES];
} cmfa_tun_trace;

typedef struct cmfa_tun_trace_collection {
  uint32_t struct_size;
  uint32_t trace_count;
  cmfa_tun_trace traces[CMFA_MAX_TUN_TRACE_COUNT];
} cmfa_tun_trace_collection;

typedef struct cmfa_tun_snapshot {
  uint32_t struct_size;
  cmfa_tun_state_value state;
  char session_id[CMFA_MAX_TUN_SESSION_ID_BYTES];
  cmfa_tun_counters counters;
  cmfa_tun_failure failure;
} cmfa_tun_snapshot;

#ifdef __cplusplus
}
#endif

#endif
