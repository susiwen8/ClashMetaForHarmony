#ifndef CMFA_NAPI_H
#define CMFA_NAPI_H

#include "cmfa_core.h"
#include "napi_environment.h"

#include <napi/native_api.h>
#include <node_api.h>

#include <atomic>
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

struct OwnedRuntimeSnapshot {
  std::string state;
  std::string active_config_path;
  uint32_t mixed_port = 0;
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
};

enum class AsyncOp {
  CORE_VERSION,
  VALIDATE_CONFIGURATION,
  LOAD_CONFIGURATION,
  START_LOCAL,
  STOP_RUNTIME,
};

struct AsyncInput {
  AsyncOp op = AsyncOp::CORE_VERSION;
  std::string path;
  OwnedLocalOptions local_options;
};

struct AsyncResult {
  bool ok = false;
  AsyncOp op = AsyncOp::CORE_VERSION;
  std::string string_value;
  OwnedRuntimeSnapshot snapshot;
  CoreErrorData error;
};

struct AsyncDelivery;
struct AsyncThreadHandle;
struct AsyncPromiseJob;
struct SubscriptionDelivery;
struct Subscription;

struct AddonState {
  explicit AddonState(cmfa::napi::LifecycleOperations operations);

  napi_env env;
  cmfa::napi::NapiEnvironmentOwner owner;
  std::mutex subscriptions_mutex;
  std::unordered_map<uint32_t, std::shared_ptr<Subscription>> subscriptions;
  std::atomic<uint32_t> next_subscription_id;
};

struct AsyncDelivery {
  napi_threadsafe_function tsfn = nullptr;
  std::atomic<bool> abort_consumed{false};
};

struct AsyncThreadHandle {
  std::thread worker;
  std::atomic<bool> cancel_requested{false};
};

struct AsyncPromiseJob {
  AddonState *addon = nullptr;
  napi_deferred deferred = nullptr;
  AsyncInput input;
  AsyncDelivery *delivery = nullptr;
  AsyncThreadHandle *async_handle = nullptr;
};

struct SubscriptionDelivery {
  napi_threadsafe_function tsfn = nullptr;
  std::atomic<bool> abort_consumed{false};
};

struct Subscription {
  AddonState *addon = nullptr;
  uint32_t id = 0;
  std::atomic<bool> active{true};
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
bool decode_subscription_id(napi_env env, napi_value value, uint32_t *out, CoreErrorData *error, const char *operation);
bool snapshot_to_owned(const cmfa_runtime_snapshot &snapshot, OwnedRuntimeSnapshot *out, CoreErrorData *error, const char *operation);
bool owned_snapshot_to_js(napi_env env, const OwnedRuntimeSnapshot &snapshot, napi_value *result, CoreErrorData *error);
bool owned_event_to_js(napi_env env, const OwnedCoreEvent &event, napi_value *result, CoreErrorData *error);
OwnedCoreEvent copy_runtime_event(const cmfa_runtime_event &event);
OwnedCoreEvent copy_log_event(const cmfa_log_message &message);

napi_value core_version(napi_env env, napi_callback_info info);
napi_value validate_configuration(napi_env env, napi_callback_info info);
napi_value load_configuration(napi_env env, napi_callback_info info);
napi_value start_local(napi_env env, napi_callback_info info);
napi_value stop_runtime(napi_env env, napi_callback_info info);
napi_value subscribe(napi_env env, napi_callback_info info);
napi_value unsubscribe(napi_env env, napi_callback_info info);

napi_value hello(napi_env env, napi_callback_info info);
napi_value runtime_snapshot(napi_env env, napi_callback_info info);
napi_status define_core_module(napi_env env, napi_value exports, AddonState *state);

void emit_log_event(void *context, const cmfa_log_message *message);
void emit_runtime_event(void *context, const cmfa_runtime_event *event);

} // namespace cmfa::nodeaddon

#endif
