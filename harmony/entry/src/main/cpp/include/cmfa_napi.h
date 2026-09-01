#ifndef CMFA_NAPI_H
#define CMFA_NAPI_H

#include "cmfa_core.h"
#include "napi_environment.h"

#include <napi/native_api.h>
#include <node_api.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace cmfa::nodeaddon {

constexpr size_t kMaxEventMessageBytes = 4096;
constexpr uint64_t kMaxJsSafeInteger = 9007199254740991ULL;

struct CoreErrorContextData {
  std::string operation;
  int32_t status = 0;
};

struct CoreErrorData {
  std::string code;
  std::string category;
  std::string message;
  std::string detail;
  bool retryable = false;
  std::string action;
  std::optional<CoreErrorContextData> context;
};

struct OwnedLocalOptions {
  std::string config_path;
  uint32_t mixed_port = 0;
};

struct OwnedProbeRequest {
  std::string probe_run_id;
  std::string protocol;
  std::string listener_address;
  std::string origin_url;
  std::string ca_pem;
  std::string expected_body_sha256;
};

struct OwnedProbeTrackerRecord {
  std::string connection_id;
  std::string source_address;
  std::string destination_address;
  std::string inbound_type;
  std::string opened_at;
};

struct OwnedProbeError {
  std::string code;
  std::string stage;
  std::string detail;
};

struct OwnedProbeResult {
  bool ok = false;
  std::string protocol;
  int32_t http_status = 0;
  int64_t body_bytes = 0;
  std::string probe_run_id;
  std::string request_id_echo;
  std::string origin_id;
  std::string response_sha256;
  std::string tls_peer_sha256;
  std::string started_at;
  std::string completed_at;
  std::string client_local_address;
  std::string client_remote_address;
  OwnedProbeTrackerRecord tracker;
  OwnedProbeError error;
};

struct OwnedRuntimeSnapshot {
  std::string state;
  std::string active_config_path;
  std::string http_address;
  std::string socks_address;
  std::string last_error;
  uint32_t mixed_port = 0;
};

struct OwnedProxyQueryContext {
  std::string profile_hash;
  std::string revision_hash;
  std::string session_hash;
  uint64_t generation = 0;
  bool has_session = false;
};

struct OwnedTunCounters {
  uint64_t tx_packets = 0;
  uint64_t tx_bytes = 0;
  uint64_t rx_packets = 0;
  uint64_t rx_bytes = 0;
};

struct OwnedTunFailure {
  std::string code;
  std::string detail;
};

struct OwnedTunTrace {
  uint64_t sequence = 0;
  std::string session_id;
  std::string trace_id;
  std::string ingress;
  std::string protocol;
  std::string source_address;
  std::string destination_address;
  std::string hashed_tuple;
  std::string correlation_hash;
  std::string destination_hash;
  std::string outbound_terminal_hash;
  std::string outbound_chain_hash;
  uint32_t outbound_chain_length = 0;
};

struct OwnedTunSnapshot {
  std::string session_id;
  std::string state;
  OwnedTunCounters counters;
  std::optional<OwnedTunFailure> failure;
};

struct OwnedCoreEvent {
  enum class Kind {
    RUNTIME,
    LOG,
  };

  Kind kind = Kind::RUNTIME;
  std::string state;
  std::string level;
  std::string message;
  std::string code;
  std::string session_id;
  std::string trace_id;
  std::string ingress;
  std::string protocol;
};

enum class AsyncOp {
  CORE_VERSION,
  VALIDATE_CONFIGURATION,
  LOAD_CONFIGURATION,
  PROBE_HTTPS,
  START_LOCAL,
  STOP_RUNTIME,
  PROXY_GROUPS,
  PROXY_GROUP,
  PROXY_SELECT,
  PROXY_DELAY_START,
  PROXY_DELAY_SNAPSHOT,
  PROXY_DELAY_CANCEL,
  START_TUN,
  STOP_TUN,
  CLOSE_STALE_OUTBOUND_CONNECTIONS,
  TUN_SNAPSHOT,
  READ_TUN_TRACES,
};

struct AsyncInput {
  AsyncOp op = AsyncOp::CORE_VERSION;
  std::string path;
  OwnedLocalOptions local_options;
  OwnedProxyQueryContext proxy_query_context;
  bool proxy_selectable_only = false;
  std::string proxy_group_name;
  std::string proxy_member_name;
  std::string proxy_delay_job_id;
  OwnedProbeRequest probe_request;
  int32_t tun_fd = -1;
  std::string tun_vpn_id;
  std::string tun_session_id;
  std::string tun_config_path;
  uint32_t tun_mixed_port = 0;
  uint32_t tun_platform_api_level = 0;
  bool tun_process_protected = false;
  uint64_t tun_after_sequence = 0;
};

struct AsyncResult {
  bool ok = false;
  AsyncOp op = AsyncOp::CORE_VERSION;
  std::string string_value;
  OwnedProbeResult probe_result;
  OwnedRuntimeSnapshot snapshot;
  OwnedTunSnapshot tun_snapshot;
  std::vector<OwnedTunTrace> tun_traces;
  CoreErrorData error;
};

struct AsyncDelivery;
struct AsyncThreadHandle;
struct AsyncPromiseJob;
struct AsyncCompletionPayload;
struct SubscriptionDelivery;
struct Subscription;

struct AddonLifecycleOwnership {
  std::atomic<bool> backend_registered{false};
  std::atomic<bool> core_initialized{false};
};

struct AddonState {
  explicit AddonState(cmfa::napi::LifecycleOperations operations);

  napi_env env;
  AddonLifecycleOwnership ownership;
  cmfa::napi::NapiEnvironmentOwner owner;
  std::mutex subscriptions_mutex;
  std::unordered_map<uint32_t, std::shared_ptr<Subscription>> subscriptions;
  std::atomic<uint32_t> next_subscription_id;
  std::mutex tun_trace_mutex;
  std::string tun_trace_session_id;
  uint64_t next_tun_trace_sequence = 1;
  std::unordered_map<std::string, uint64_t> tun_trace_sequences;
};

struct AsyncDelivery {
  napi_threadsafe_function tsfn = nullptr;
  std::atomic<bool> abort_consumed{false};
};

struct AsyncThreadHandle {
  std::thread worker;
  AsyncOp op = AsyncOp::CORE_VERSION;
  std::string probe_run_id;
  std::atomic<bool> cancel_requested{false};
  std::atomic<bool> probe_cancel_requested{false};
};

struct AsyncPromiseJob {
  AddonState *addon = nullptr;
  napi_deferred deferred = nullptr;
  AsyncInput input;
  AsyncDelivery *delivery = nullptr;
  AsyncThreadHandle *async_handle = nullptr;
  AsyncCompletionPayload *completion_payload = nullptr;
  std::atomic<bool> queue_failed{false};
  std::atomic<int32_t> queue_failure_status{static_cast<int32_t>(napi_ok)};
};

struct SubscriptionDelivery {
  napi_threadsafe_function tsfn = nullptr;
  std::atomic<bool> abort_consumed{false};
  std::weak_ptr<Subscription> subscription;
};

struct Subscription {
  AddonState *addon = nullptr;
  uint32_t id = 0;
  std::mutex mutex;
  std::condition_variable in_flight_js_cv;
  bool active = true;
  bool teardown_requested = false;
  bool teardown_started = false;
  uint32_t in_flight_js = 0;
  std::thread::id callback_thread_id{};
  napi_ref callback_ref = nullptr;
  SubscriptionDelivery *delivery = nullptr;
};

const char *runtime_state_name(cmfa_runtime_state_value state);
const char *log_level_name(cmfa_log_level level);
const char *async_operation_name(AsyncOp op);

CoreErrorData make_core_error(cmfa_status status, const char *operation);
CoreErrorData make_napi_failure(const char *operation, napi_status status);
napi_status create_core_error_value(napi_env env, const CoreErrorData &error, napi_value *result);
void throw_core_error(napi_env env, const CoreErrorData &error);
void throw_napi_failure(napi_env env, const char *operation, napi_status status);
void reject_deferred_with_core_error(napi_env env, napi_deferred deferred, const CoreErrorData &error);
void reject_deferred_with_napi_failure(napi_env env, napi_deferred deferred, const char *operation, napi_status status);

bool decode_utf8_string(napi_env env,
                        napi_value value,
                        std::string *out,
                        CoreErrorData *error,
                        const char *operation,
                        bool reject_embedded_nul,
                        size_t max_bytes);
bool decode_path_argument(napi_env env, napi_value value, std::string *out, CoreErrorData *error, const char *operation);
bool decode_local_options(napi_env env, napi_value value, OwnedLocalOptions *out, CoreErrorData *error);
bool decode_probe_request(napi_env env, napi_value value, OwnedProbeRequest *out, CoreErrorData *error);
bool decode_subscription_id(napi_env env, napi_value value, uint32_t *out, CoreErrorData *error, const char *operation);
bool probe_result_to_owned(const cmfa_probe_result &result, OwnedProbeResult *out, CoreErrorData *error);
bool owned_probe_result_to_js(napi_env env, const OwnedProbeResult &result, napi_value *value, CoreErrorData *error);
bool snapshot_to_owned(const cmfa_runtime_snapshot &snapshot, OwnedRuntimeSnapshot *out, CoreErrorData *error, const char *operation);
bool owned_snapshot_to_js(napi_env env, const OwnedRuntimeSnapshot &snapshot, napi_value *result, CoreErrorData *error);
bool tun_snapshot_to_owned(const cmfa_tun_snapshot &snapshot, OwnedTunSnapshot *out, CoreErrorData *error, const char *operation);
bool owned_tun_snapshot_to_js(napi_env env, const OwnedTunSnapshot &snapshot, napi_value *result, CoreErrorData *error);
bool owned_tun_traces_to_js(napi_env env, const std::vector<OwnedTunTrace> &traces, napi_value *result, CoreErrorData *error);
bool owned_event_to_js(napi_env env, const OwnedCoreEvent &event, napi_value *result, CoreErrorData *error);
OwnedCoreEvent copy_runtime_event(const cmfa_runtime_event &event);
OwnedCoreEvent copy_log_event(const cmfa_log_message &message);

napi_value start_async_operation(napi_env env, AddonState *addon, const AsyncInput &input);
napi_value core_version(napi_env env, napi_callback_info info);
napi_value validate_configuration(napi_env env, napi_callback_info info);
napi_value load_configuration(napi_env env, napi_callback_info info);
napi_value probe_https(napi_env env, napi_callback_info info);
napi_value start_local(napi_env env, napi_callback_info info);
napi_value stop_runtime(napi_env env, napi_callback_info info);
napi_value query_proxy_groups(napi_env env, napi_callback_info info);
napi_value query_proxy_group(napi_env env, napi_callback_info info);
napi_value select_proxy(napi_env env, napi_callback_info info);
napi_value start_proxy_delay_test(napi_env env, napi_callback_info info);
napi_value read_proxy_delay_test(napi_env env, napi_callback_info info);
napi_value cancel_proxy_delay_test(napi_env env, napi_callback_info info);
napi_value start_tun(napi_env env, napi_callback_info info);
napi_value stop_tun(napi_env env, napi_callback_info info);
napi_value close_stale_outbound_connections(napi_env env, napi_callback_info info);
napi_value tun_snapshot(napi_env env, napi_callback_info info);
napi_value read_tun_traces(napi_env env, napi_callback_info info);
napi_value subscribe(napi_env env, napi_callback_info info);
napi_value unsubscribe(napi_env env, napi_callback_info info);

napi_value hello(napi_env env, napi_callback_info info);
napi_value runtime_snapshot(napi_env env, napi_callback_info info);
napi_value query_runtime_mode(napi_env env, napi_callback_info info);
napi_value set_runtime_mode(napi_env env, napi_callback_info info);
napi_status define_core_module(napi_env env, napi_value exports, AddonState *state);

void emit_log_event(void *context, const cmfa_log_message *message) noexcept;
void emit_runtime_event(void *context, const cmfa_runtime_event *event) noexcept;

} // namespace cmfa::nodeaddon

#endif
