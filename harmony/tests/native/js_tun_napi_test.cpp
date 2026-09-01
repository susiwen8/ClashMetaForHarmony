#include "cmfa_napi.h"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

class TestFailure : public std::runtime_error {
public:
  explicit TestFailure(const std::string &message) : std::runtime_error(message) {}
};

void expect(bool condition, const std::string &message) {
  if (!condition) {
    throw TestFailure(message);
  }
}

template <typename T, typename U>
void expect_equal(const T &actual, const U &expected, const std::string &message) {
  if (!(actual == expected)) {
    throw TestFailure(message);
  }
}

struct FakeValue;
struct FakeDeferred;
struct FakeRef;
struct FakeTsfn;
struct FakeCallbackInfo;
struct FakeEnv;

using HostFunction = std::function<FakeValue *(FakeEnv *, const std::vector<FakeValue *> &)>;
constexpr double kMaxSafeInteger = 9007199254740991.0;

enum class FakeType {
  Undefined,
  Null,
  Boolean,
  Number,
  String,
  Object,
  Array,
  Function,
  Promise,
  Error,
};

struct FakeValue {
  FakeType type = FakeType::Undefined;
  bool bool_value = false;
  double number_value = 0;
  std::string string_value;
  std::unordered_map<std::string, FakeValue *> object_props;
  std::vector<std::string> object_keys;
  std::vector<FakeValue *> array_items;
  napi_callback native_callback = nullptr;
  void *native_data = nullptr;
  HostFunction host_callback;
  bool promise_resolved = false;
  bool promise_rejected = false;
  FakeValue *promise_result = nullptr;
};

struct FakeDeferred {
  FakeValue *promise = nullptr;
};

struct FakeRef {
  FakeValue *value = nullptr;
  bool deleted = false;
};

struct FakeTsfn {
  FakeEnv *env = nullptr;
  void *context = nullptr;
  void *finalize_data = nullptr;
  napi_finalize finalize_cb = nullptr;
  napi_threadsafe_function_call_js call_js_cb = nullptr;
  bool finalized = false;
};

struct PendingTsfnCall {
  FakeTsfn *tsfn = nullptr;
  void *data = nullptr;
};

struct FakeCallbackInfo {
  std::vector<FakeValue *> args;
  void *data = nullptr;
};

struct FakeEnv {
  std::vector<std::unique_ptr<FakeValue>> values;
  std::vector<std::unique_ptr<FakeDeferred>> deferreds;
  std::vector<std::unique_ptr<FakeRef>> refs;
  std::vector<std::unique_ptr<FakeTsfn>> tsfns;
  FakeValue *global = nullptr;
  FakeValue *undefined_value = nullptr;
  FakeValue *null_value = nullptr;
  FakeValue *last_thrown = nullptr;
  napi_status next_tsfn_call_status = napi_ok;
  bool fail_create_promise = false;
  bool fail_create_reference = false;
  bool fail_create_tsfn = false;
  bool fail_define_properties = false;
  std::vector<PendingTsfnCall> pending_tsfn_calls;
};

FakeValue *allocate_value(FakeEnv *env, FakeType type) {
  env->values.push_back(std::make_unique<FakeValue>());
  FakeValue *value = env->values.back().get();
  value->type = type;
  return value;
}

FakeValue *make_string(FakeEnv *env, const std::string &value) {
  FakeValue *result = allocate_value(env, FakeType::String);
  result->string_value = value;
  return result;
}

FakeValue *make_number(FakeEnv *env, double value) {
  FakeValue *result = allocate_value(env, FakeType::Number);
  result->number_value = value;
  return result;
}

FakeValue *make_boolean(FakeEnv *env, bool value) {
  FakeValue *result = allocate_value(env, FakeType::Boolean);
  result->bool_value = value;
  return result;
}

FakeValue *make_object(FakeEnv *env) {
  return allocate_value(env, FakeType::Object);
}

FakeValue *make_array(FakeEnv *env, size_t length = 0) {
  FakeValue *result = allocate_value(env, FakeType::Array);
  result->array_items.resize(length, env->undefined_value);
  return result;
}

FakeValue *make_host_function(FakeEnv *env, HostFunction callback) {
  FakeValue *result = allocate_value(env, FakeType::Function);
  result->host_callback = std::move(callback);
  return result;
}

void set_named_prop(FakeValue *object, const std::string &name, FakeValue *value) {
  if (object->object_props.find(name) == object->object_props.end()) {
    object->object_keys.push_back(name);
  }
  object->object_props[name] = value;
}

FakeValue *get_named_prop(FakeValue *object, const std::string &name) {
  const auto found = object->object_props.find(name);
  if (found == object->object_props.end()) {
    return nullptr;
  }
  return found->second;
}

FakeEnv *create_env() {
  auto *env = new FakeEnv();
  env->undefined_value = allocate_value(env, FakeType::Undefined);
  env->null_value = allocate_value(env, FakeType::Null);
  env->global = make_object(env);
  return env;
}

void destroy_env(FakeEnv *env) {
  delete env;
}

[[maybe_unused]] std::string value_to_string(FakeValue *value) {
  if (value == nullptr) {
    return "<null>";
  }
  if (value->type == FakeType::String) {
    return value->string_value;
  }
  if (value->type == FakeType::Number) {
    return std::to_string(static_cast<int64_t>(value->number_value));
  }
  if (value->type == FakeType::Boolean) {
    return value->bool_value ? "true" : "false";
  }
  return "<value>";
}

FakeValue *invoke_function(FakeEnv *env, FakeValue *function, const std::vector<FakeValue *> &args, void *data = nullptr) {
  expect(function != nullptr && function->type == FakeType::Function, "invoke_function expects a function");
  if (function->host_callback) {
    return function->host_callback(env, args);
  }
  FakeCallbackInfo info;
  info.args = args;
  info.data = data != nullptr ? data : function->native_data;
  return reinterpret_cast<FakeValue *>(
      function->native_callback(reinterpret_cast<napi_env>(env), reinterpret_cast<napi_callback_info>(&info)));
}

struct LifecycleContext {
  cmfa_status shutdown_status = CMFA_OK;
  cmfa_status unregister_status = CMFA_OK;
  int shutdown_calls = 0;
  int unregister_calls = 0;
};

std::unordered_map<cmfa::nodeaddon::AddonLifecycleOwnership *, LifecycleContext *> g_lifecycle_contexts;

cmfa_status lifecycle_shutdown_for_addon(void *context, cmfa_error *) {
  auto *ownership = static_cast<cmfa::nodeaddon::AddonLifecycleOwnership *>(context);
  auto found = g_lifecycle_contexts.find(ownership);
  if (ownership == nullptr || found == g_lifecycle_contexts.end()) {
    return CMFA_OK;
  }
  if (!ownership->core_initialized.exchange(false, std::memory_order_acq_rel)) {
    return CMFA_OK;
  }
  auto *state = found->second;
  state->shutdown_calls += 1;
  return state->shutdown_status;
}

cmfa_status lifecycle_unregister_for_addon(void *context, cmfa_error *) {
  auto *ownership = static_cast<cmfa::nodeaddon::AddonLifecycleOwnership *>(context);
  auto found = g_lifecycle_contexts.find(ownership);
  if (ownership == nullptr || found == g_lifecycle_contexts.end()) {
    return CMFA_OK;
  }
  if (!ownership->backend_registered.exchange(false, std::memory_order_acq_rel)) {
    return CMFA_OK;
  }
  auto *state = found->second;
  state->unregister_calls += 1;
  return state->unregister_status;
}

cmfa::napi::LifecycleOperations make_lifecycle(LifecycleContext *context) {
  cmfa::napi::LifecycleOperations operations{};
  operations.context = context;
  operations.shutdown = lifecycle_shutdown_for_addon;
  operations.unregister_backend = lifecycle_unregister_for_addon;
  return operations;
}

struct TunBackendState {
  std::mutex mutex;
  std::condition_variable cv;
  bool block_start = false;
  bool allow_start = false;
  int start_calls = 0;
  int stop_calls = 0;
  int close_stale_calls = 0;
  int snapshot_calls = 0;
  int trace_calls = 0;
  cmfa_status start_status = CMFA_OK;
  cmfa_status stop_status = CMFA_OK;
  cmfa_status close_stale_status = CMFA_OK;
  cmfa_status snapshot_status = CMFA_OK;
  cmfa_status trace_status = CMFA_OK;
  std::string stop_error_message;
  cmfa_tun_options copied_options{};
  std::string copied_config_path;
  std::string closed_stale_session_id;
  cmfa_tun_snapshot snapshot{};
  cmfa_tun_trace_ring traces{};
};

TunBackendState g_tun_backend;

void reset_tun_backend() {
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.block_start = false;
  g_tun_backend.allow_start = false;
  g_tun_backend.start_calls = 0;
  g_tun_backend.stop_calls = 0;
  g_tun_backend.close_stale_calls = 0;
  g_tun_backend.snapshot_calls = 0;
  g_tun_backend.trace_calls = 0;
  g_tun_backend.start_status = CMFA_OK;
  g_tun_backend.stop_status = CMFA_OK;
  g_tun_backend.close_stale_status = CMFA_OK;
  g_tun_backend.snapshot_status = CMFA_OK;
  g_tun_backend.trace_status = CMFA_OK;
  g_tun_backend.stop_error_message.clear();
  g_tun_backend.copied_options = cmfa_tun_options{};
  g_tun_backend.copied_config_path.clear();
  g_tun_backend.closed_stale_session_id.clear();
  g_tun_backend.snapshot = cmfa_tun_snapshot{};
  g_tun_backend.traces = cmfa_tun_trace_ring{};
  g_tun_backend.snapshot.struct_size = sizeof(g_tun_backend.snapshot);
  g_tun_backend.snapshot.state = CMFA_TUN_READY;
  std::strncpy(g_tun_backend.snapshot.session_id, "session-1", sizeof(g_tun_backend.snapshot.session_id) - 1);
  g_tun_backend.snapshot.counters.struct_size = sizeof(g_tun_backend.snapshot.counters);
  g_tun_backend.snapshot.counters.rx_packets = 3;
  g_tun_backend.snapshot.counters.rx_bytes = 4;
  g_tun_backend.snapshot.counters.tx_packets = 1;
  g_tun_backend.snapshot.counters.tx_bytes = 2;
  g_tun_backend.snapshot.failure.struct_size = sizeof(g_tun_backend.snapshot.failure);
  g_tun_backend.traces.struct_size = sizeof(g_tun_backend.traces);
  g_tun_backend.traces.trace_count = 2;
  const char *destination_hashes[] = {
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2",
  };
  const char *terminal_hashes[] = {
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2",
  };
  const char *chain_hashes[] = {
      "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc1",
      "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc2",
  };
  for (uint32_t index = 0; index < g_tun_backend.traces.trace_count; index += 1) {
    auto &trace = g_tun_backend.traces.traces[index];
    trace.struct_size = sizeof(trace);
    std::strncpy(trace.session_id, "session-1", sizeof(trace.session_id) - 1);
    std::snprintf(trace.trace_id, sizeof(trace.trace_id), "trace-%u", index + 1);
    std::strncpy(trace.ingress, "tun", sizeof(trace.ingress) - 1);
    std::strncpy(trace.protocol, index == 0 ? "tcp" : "dns", sizeof(trace.protocol) - 1);
    std::strncpy(trace.source_address, "10.111.222.1:12345", sizeof(trace.source_address) - 1);
    std::strncpy(trace.destination_address, "1.1.1.1:443", sizeof(trace.destination_address) - 1);
    std::snprintf(trace.hashed_tuple, sizeof(trace.hashed_tuple), "hash-%u", index + 1);
    std::snprintf(trace.correlation_hash, sizeof(trace.correlation_hash), "corr-%u", index + 1);
    std::strncpy(trace.destination_hash, destination_hashes[index], sizeof(trace.destination_hash) - 1);
    std::strncpy(trace.outbound_terminal_hash, terminal_hashes[index], sizeof(trace.outbound_terminal_hash) - 1);
    std::strncpy(trace.outbound_chain_hash, chain_hashes[index], sizeof(trace.outbound_chain_hash) - 1);
    trace.outbound_chain_length = index + 1;
  }
}

} // namespace

extern "C" cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *) {
  std::strncpy(out, "fake-core", capacity - 1);
  out[capacity - 1] = '\0';
  return CMFA_OK;
}
extern "C" cmfa_status cmfa_validate_config(const char *, cmfa_error *) { return CMFA_OK; }
extern "C" cmfa_status cmfa_load_config(const char *, cmfa_error *) { return CMFA_OK; }
extern "C" cmfa_status cmfa_start_local(const cmfa_local_options *, cmfa_runtime_snapshot *, cmfa_error *) { return CMFA_CORE_UNAVAILABLE; }
extern "C" cmfa_status cmfa_stop(cmfa_error *) { return CMFA_OK; }
extern "C" cmfa_status cmfa_runtime_state(cmfa_runtime_snapshot *snapshot, cmfa_error *) {
  std::memset(snapshot, 0, sizeof(*snapshot));
  snapshot->struct_size = sizeof(*snapshot);
  snapshot->state = CMFA_RUNTIME_RUNNING;
  std::strncpy(snapshot->active_config_path, "config.yaml", sizeof(snapshot->active_config_path) - 1);
  std::strncpy(snapshot->http_address, "127.0.0.1:7890", sizeof(snapshot->http_address) - 1);
  std::strncpy(snapshot->socks_address, "127.0.0.1:7891", sizeof(snapshot->socks_address) - 1);
  snapshot->mixed_port = 7890;
  return CMFA_OK;
}
extern "C" cmfa_status cmfa_runtime_mode_query(cmfa_runtime_mode *mode, cmfa_error *) {
  *mode = CMFA_MODE_RULE;
  return CMFA_OK;
}
extern "C" cmfa_status cmfa_runtime_mode_set(cmfa_runtime_mode, cmfa_error *) { return CMFA_OK; }
extern "C" cmfa_status cmfa_probe_https(const cmfa_probe_request *, cmfa_probe_result **, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}
extern "C" void cmfa_probe_result_free(cmfa_probe_result *) {}

extern "C" cmfa_status cmfa_tun_start(const cmfa_tun_options *options, cmfa_tun_snapshot *snapshot, cmfa_error *) {
  std::unique_lock<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.start_calls += 1;
  g_tun_backend.copied_options = *options;
  g_tun_backend.copied_config_path = options->config_path == nullptr ? "" : options->config_path;
  while (g_tun_backend.block_start && !g_tun_backend.allow_start) {
    g_tun_backend.cv.wait(lock);
  }
  if (g_tun_backend.start_status != CMFA_OK) {
    return g_tun_backend.start_status;
  }
  *snapshot = g_tun_backend.snapshot;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_tun_stop(cmfa_error *error) {
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.stop_calls += 1;
  if (error != nullptr && error->message != nullptr && error->capacity > 0 && !g_tun_backend.stop_error_message.empty()) {
    const size_t limit = std::min(g_tun_backend.stop_error_message.size(), error->capacity - 1);
    std::memcpy(error->message, g_tun_backend.stop_error_message.data(), limit);
    error->message[limit] = '\0';
    error->length = limit;
    error->code = g_tun_backend.stop_status;
  }
  return g_tun_backend.stop_status;
}

cmfa_status close_stale_tun_connections_stub(const char *session_id, cmfa_error *) {
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.close_stale_calls += 1;
  g_tun_backend.closed_stale_session_id = session_id == nullptr ? "" : session_id;
  return g_tun_backend.close_stale_status;
}

extern "C" cmfa_status cmfa_tun_runtime_state(cmfa_tun_snapshot *snapshot, cmfa_error *) {
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.snapshot_calls += 1;
  if (g_tun_backend.snapshot_status != CMFA_OK) {
    return g_tun_backend.snapshot_status;
  }
  *snapshot = g_tun_backend.snapshot;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_tun_copy_traces(cmfa_tun_trace_collection *, cmfa_error *) { return CMFA_OK; }

extern "C" cmfa_status cmfa_tun_copy_traces_ring(cmfa_tun_trace_ring *traces, cmfa_error *) {
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  g_tun_backend.trace_calls += 1;
  if (g_tun_backend.trace_status != CMFA_OK) {
    return g_tun_backend.trace_status;
  }
  *traces = g_tun_backend.traces;
  return CMFA_OK;
}

namespace cmfa {
cmfa_status cancel_mihomo_probe(const char *, cmfa_error *) { return CMFA_OK; }
cmfa_status close_stale_tun_connections_for_mihomo_backend(const char *session_id, cmfa_error *error) {
  return close_stale_tun_connections_stub(session_id, error);
}
}

extern "C" {

struct napi_env__ {
  char placeholder;
};
struct napi_value__ {
  char placeholder;
};
struct napi_ref__ {
  char placeholder;
};
struct napi_deferred__ {
  char placeholder;
};
struct napi_callback_info__ {
  char placeholder;
};
struct napi_threadsafe_function__ {
  char placeholder;
};

napi_status napi_get_cb_info(napi_env,
                             napi_callback_info info,
                             size_t *argc,
                             napi_value *argv,
                             napi_value *,
                             void **data) {
  auto *callback_info = reinterpret_cast<FakeCallbackInfo *>(info);
  if (argc != nullptr) {
    size_t requested = *argc;
    size_t actual = callback_info->args.size();
    size_t copy_count = requested < actual ? requested : actual;
    for (size_t index = 0; index < copy_count; index += 1) {
      argv[index] = reinterpret_cast<napi_value>(callback_info->args[index]);
    }
    *argc = actual;
  }
  if (data != nullptr) {
    *data = callback_info->data;
  }
  return napi_ok;
}

napi_status napi_typeof(napi_env, napi_value value, napi_valuetype *result) {
  auto *fake = reinterpret_cast<FakeValue *>(value);
  switch (fake->type) {
    case FakeType::Undefined:
      *result = napi_undefined;
      break;
    case FakeType::Null:
      *result = napi_null;
      break;
    case FakeType::Boolean:
      *result = napi_boolean;
      break;
    case FakeType::Number:
      *result = napi_number;
      break;
    case FakeType::String:
      *result = napi_string;
      break;
    case FakeType::Function:
      *result = napi_function;
      break;
    default:
      *result = napi_object;
      break;
  }
  return napi_ok;
}

napi_status napi_create_string_utf8(napi_env env, const char *str, size_t length, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  const std::string value = length == NAPI_AUTO_LENGTH ? std::string(str) : std::string(str, length);
  *result = reinterpret_cast<napi_value>(make_string(fake_env, value));
  return napi_ok;
}

napi_status napi_get_value_string_utf8(napi_env, napi_value value, char *buf, size_t bufsize, size_t *result) {
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::String) {
    return napi_string_expected;
  }
  if (result != nullptr) {
    *result = fake->string_value.size();
  }
  if (buf != nullptr && bufsize > 0) {
    const size_t copy_size = fake->string_value.size() < bufsize - 1 ? fake->string_value.size() : bufsize - 1;
    std::memcpy(buf, fake->string_value.data(), copy_size);
    buf[copy_size] = '\0';
  }
  return napi_ok;
}

napi_status napi_create_object(napi_env env, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_object(reinterpret_cast<FakeEnv *>(env)));
  return napi_ok;
}

napi_status napi_create_array_with_length(napi_env env, size_t length, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_array(reinterpret_cast<FakeEnv *>(env), length));
  return napi_ok;
}

napi_status napi_set_named_property(napi_env, napi_value object, const char *utf8name, napi_value value) {
  set_named_prop(reinterpret_cast<FakeValue *>(object), utf8name, reinterpret_cast<FakeValue *>(value));
  return napi_ok;
}

napi_status napi_get_named_property(napi_env, napi_value object, const char *utf8name, napi_value *result) {
  FakeValue *value = get_named_prop(reinterpret_cast<FakeValue *>(object), utf8name);
  if (value == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(value);
  return napi_ok;
}

napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value) {
  auto *array = reinterpret_cast<FakeValue *>(object);
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (array->array_items.size() <= index) {
    array->array_items.resize(index + 1, fake_env->undefined_value);
  }
  array->array_items[index] = reinterpret_cast<FakeValue *>(value);
  return napi_ok;
}

napi_status napi_get_element(napi_env, napi_value object, uint32_t index, napi_value *result) {
  auto *array = reinterpret_cast<FakeValue *>(object);
  if (index >= array->array_items.size()) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(array->array_items[index]);
  return napi_ok;
}

napi_status napi_get_array_length(napi_env, napi_value value, uint32_t *result) {
  *result = reinterpret_cast<FakeValue *>(value)->array_items.size();
  return napi_ok;
}

napi_status napi_is_array(napi_env, napi_value value, bool *result) {
  *result = reinterpret_cast<FakeValue *>(value)->type == FakeType::Array;
  return napi_ok;
}

napi_status napi_get_property_names(napi_env env, napi_value object, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  auto *target = reinterpret_cast<FakeValue *>(object);
  FakeValue *keys = make_array(fake_env, target->object_keys.size());
  for (size_t index = 0; index < target->object_keys.size(); index += 1) {
    keys->array_items[index] = make_string(fake_env, target->object_keys[index]);
  }
  *result = reinterpret_cast<napi_value>(keys);
  return napi_ok;
}

napi_status napi_create_uint32(napi_env env, uint32_t value, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_number(reinterpret_cast<FakeEnv *>(env), value));
  return napi_ok;
}

napi_status napi_create_int32(napi_env env, int32_t value, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_number(reinterpret_cast<FakeEnv *>(env), value));
  return napi_ok;
}

napi_status napi_create_int64(napi_env env, int64_t value, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_number(reinterpret_cast<FakeEnv *>(env), static_cast<double>(value)));
  return napi_ok;
}

napi_status napi_get_value_int64(napi_env, napi_value value, int64_t *result) {
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Number) {
    return napi_number_expected;
  }
  *result = static_cast<int64_t>(fake->number_value);
  return napi_ok;
}

napi_status napi_get_value_double(napi_env, napi_value value, double *result) {
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Number) {
    return napi_number_expected;
  }
  *result = fake->number_value;
  return napi_ok;
}

napi_status napi_get_value_bool(napi_env, napi_value value, bool *result) {
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Boolean) {
    return napi_boolean_expected;
  }
  *result = fake->bool_value;
  return napi_ok;
}

napi_status napi_get_boolean(napi_env env, bool value, napi_value *result) {
  *result = reinterpret_cast<napi_value>(make_boolean(reinterpret_cast<FakeEnv *>(env), value));
  return napi_ok;
}

napi_status napi_get_null(napi_env env, napi_value *result) {
  *result = reinterpret_cast<napi_value>(reinterpret_cast<FakeEnv *>(env)->null_value);
  return napi_ok;
}

napi_status napi_get_undefined(napi_env env, napi_value *result) {
  *result = reinterpret_cast<napi_value>(reinterpret_cast<FakeEnv *>(env)->undefined_value);
  return napi_ok;
}

napi_status napi_get_global(napi_env env, napi_value *result) {
  *result = reinterpret_cast<napi_value>(reinterpret_cast<FakeEnv *>(env)->global);
  return napi_ok;
}

napi_status napi_create_error(napi_env env, napi_value code, napi_value msg, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  FakeValue *error = make_object(fake_env);
  error->type = FakeType::Error;
  set_named_prop(error, "code", reinterpret_cast<FakeValue *>(code));
  set_named_prop(error, "message", reinterpret_cast<FakeValue *>(msg));
  *result = reinterpret_cast<napi_value>(error);
  return napi_ok;
}

napi_status napi_throw(napi_env env, napi_value error) {
  reinterpret_cast<FakeEnv *>(env)->last_thrown = reinterpret_cast<FakeValue *>(error);
  return napi_ok;
}

napi_status napi_throw_error(napi_env env, const char *code, const char *msg) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  FakeValue *error = make_object(fake_env);
  error->type = FakeType::Error;
  set_named_prop(error, "code", make_string(fake_env, code == nullptr ? "" : code));
  set_named_prop(error, "message", make_string(fake_env, msg == nullptr ? "" : msg));
  fake_env->last_thrown = error;
  return napi_ok;
}

napi_status napi_create_promise(napi_env env, napi_deferred *deferred, napi_value *promise) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (fake_env->fail_create_promise) {
    return napi_generic_failure;
  }
  FakeValue *promise_value = allocate_value(fake_env, FakeType::Promise);
  fake_env->deferreds.push_back(std::make_unique<FakeDeferred>());
  FakeDeferred *def = fake_env->deferreds.back().get();
  def->promise = promise_value;
  *deferred = reinterpret_cast<napi_deferred>(def);
  *promise = reinterpret_cast<napi_value>(promise_value);
  return napi_ok;
}

napi_status napi_resolve_deferred(napi_env, napi_deferred deferred, napi_value resolution) {
  auto *def = reinterpret_cast<FakeDeferred *>(deferred);
  def->promise->promise_resolved = true;
  def->promise->promise_result = reinterpret_cast<FakeValue *>(resolution);
  return napi_ok;
}

napi_status napi_reject_deferred(napi_env, napi_deferred deferred, napi_value rejection) {
  auto *def = reinterpret_cast<FakeDeferred *>(deferred);
  def->promise->promise_rejected = true;
  def->promise->promise_result = reinterpret_cast<FakeValue *>(rejection);
  return napi_ok;
}

napi_status napi_define_properties(napi_env env, napi_value object, size_t count, const napi_property_descriptor *properties) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (fake_env->fail_define_properties) {
    return napi_generic_failure;
  }
  auto *target = reinterpret_cast<FakeValue *>(object);
  for (size_t index = 0; index < count; index += 1) {
    FakeValue *function = make_host_function(fake_env, [callback = properties[index].method, data = properties[index].data](
                                                           FakeEnv *callback_env,
                                                           const std::vector<FakeValue *> &args) -> FakeValue * {
      FakeCallbackInfo info;
      info.args = args;
      info.data = data;
      return reinterpret_cast<FakeValue *>(
          callback(reinterpret_cast<napi_env>(callback_env), reinterpret_cast<napi_callback_info>(&info)));
    });
    function->native_callback = properties[index].method;
    function->native_data = properties[index].data;
    set_named_prop(target, properties[index].utf8name, function);
  }
  return napi_ok;
}

napi_status napi_create_reference(napi_env env, napi_value value, uint32_t, napi_ref *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (fake_env->fail_create_reference) {
    return napi_generic_failure;
  }
  fake_env->refs.push_back(std::make_unique<FakeRef>());
  FakeRef *ref = fake_env->refs.back().get();
  ref->value = reinterpret_cast<FakeValue *>(value);
  *result = reinterpret_cast<napi_ref>(ref);
  return napi_ok;
}

napi_status napi_get_reference_value(napi_env, napi_ref ref, napi_value *result) {
  auto *fake_ref = reinterpret_cast<FakeRef *>(ref);
  if (fake_ref->deleted) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(fake_ref->value);
  return napi_ok;
}

napi_status napi_delete_reference(napi_env, napi_ref ref) {
  reinterpret_cast<FakeRef *>(ref)->deleted = true;
  return napi_ok;
}

napi_status napi_call_function(napi_env env,
                               napi_value,
                               napi_value func,
                               size_t argc,
                               const napi_value *argv,
                               napi_value *result) {
  std::vector<FakeValue *> args;
  for (size_t index = 0; index < argc; index += 1) {
    args.push_back(reinterpret_cast<FakeValue *>(argv[index]));
  }
  FakeValue *call_result = invoke_function(reinterpret_cast<FakeEnv *>(env), reinterpret_cast<FakeValue *>(func), args);
  if (result != nullptr) {
    *result = reinterpret_cast<napi_value>(call_result);
  }
  return napi_ok;
}

napi_status napi_create_threadsafe_function(napi_env env,
                                            napi_value,
                                            napi_value,
                                            napi_value,
                                            size_t,
                                            size_t,
                                            void *thread_finalize_data,
                                            napi_finalize thread_finalize_cb,
                                            void *context,
                                            napi_threadsafe_function_call_js call_js_cb,
                                            napi_threadsafe_function *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (fake_env->fail_create_tsfn) {
    return napi_generic_failure;
  }
  fake_env->tsfns.push_back(std::make_unique<FakeTsfn>());
  FakeTsfn *tsfn = fake_env->tsfns.back().get();
  tsfn->env = fake_env;
  tsfn->context = context;
  tsfn->finalize_data = thread_finalize_data;
  tsfn->finalize_cb = thread_finalize_cb;
  tsfn->call_js_cb = call_js_cb;
  *result = reinterpret_cast<napi_threadsafe_function>(tsfn);
  return napi_ok;
}

napi_status napi_call_threadsafe_function(napi_threadsafe_function func,
                                          void *data,
                                          napi_threadsafe_function_call_mode) {
  auto *tsfn = reinterpret_cast<FakeTsfn *>(func);
  if (tsfn->env->next_tsfn_call_status != napi_ok) {
    napi_status status = tsfn->env->next_tsfn_call_status;
    tsfn->env->next_tsfn_call_status = napi_ok;
    return status;
  }
  tsfn->env->pending_tsfn_calls.push_back(PendingTsfnCall{tsfn, data});
  return napi_ok;
}

napi_status napi_release_threadsafe_function(napi_threadsafe_function func, napi_threadsafe_function_release_mode) {
  auto *tsfn = reinterpret_cast<FakeTsfn *>(func);
  auto &pending = tsfn->env->pending_tsfn_calls;
  pending.erase(
      std::remove_if(pending.begin(), pending.end(), [tsfn](const PendingTsfnCall &entry) { return entry.tsfn == tsfn; }),
      pending.end());
  if (!tsfn->finalized) {
    tsfn->finalized = true;
    tsfn->finalize_cb(reinterpret_cast<napi_env>(tsfn->env), tsfn->finalize_data, nullptr);
  }
  return napi_ok;
}

} // extern "C"

namespace {

void pump_env(FakeEnv *env) {
  while (!env->pending_tsfn_calls.empty()) {
    PendingTsfnCall call = env->pending_tsfn_calls.front();
    env->pending_tsfn_calls.erase(env->pending_tsfn_calls.begin());
    if (call.tsfn->finalized) {
      continue;
    }
    call.tsfn->call_js_cb(reinterpret_cast<napi_env>(env), nullptr, call.tsfn->context, call.data);
  }
}

FakeValue *await_promise(FakeEnv *env, FakeValue *promise, const std::string &message) {
  for (int attempt = 0; attempt < 200; attempt += 1) {
    pump_env(env);
    if (promise->promise_resolved || promise->promise_rejected) {
      return promise->promise_result;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  throw TestFailure(message);
}

std::unique_ptr<cmfa::nodeaddon::AddonState> make_addon(FakeEnv *env, LifecycleContext *lifecycle) {
  auto addon = std::make_unique<cmfa::nodeaddon::AddonState>(make_lifecycle(lifecycle));
  addon->env = reinterpret_cast<napi_env>(env);
  g_lifecycle_contexts[&addon->ownership] = lifecycle;
  addon->ownership.core_initialized.store(true, std::memory_order_relaxed);
  addon->ownership.backend_registered.store(true, std::memory_order_relaxed);
  expect(addon->owner.activate(), "addon activate should succeed");
  return addon;
}

FakeValue *build_valid_capture_config(FakeEnv *env) {
  FakeValue *config = make_object(env);
  FakeValue *addresses = make_array(env, 2);
  addresses->array_items[0] = make_string(env, "10.111.222.1/30");
  addresses->array_items[1] = make_string(env, "fd00:111:222::1/126");
  FakeValue *routes = make_array(env, 2);
  routes->array_items[0] = make_string(env, "0.0.0.0/0");
  routes->array_items[1] = make_string(env, "::/0");
  FakeValue *dns = make_array(env, 2);
  dns->array_items[0] = make_string(env, "10.111.222.2");
  dns->array_items[1] = make_string(env, "fd00:111:222::2");
  FakeValue *blocked = make_array(env, 1);
  blocked->array_items[0] = make_string(env, "com.github.kr328.clash.harmony");
  FakeValue *trusted = make_array(env, 0);
  set_named_prop(config, "addresses", addresses);
  set_named_prop(config, "routes", routes);
  set_named_prop(config, "dnsServers", dns);
  set_named_prop(config, "mtu", make_number(env, 1500));
  set_named_prop(config, "ipv4", make_boolean(env, true));
  set_named_prop(config, "ipv6", make_boolean(env, true));
  set_named_prop(config, "isBlocking", make_boolean(env, false));
  set_named_prop(config, "blockedApplications", blocked);
  set_named_prop(config, "trustedApplications", trusted);
  return config;
}

FakeValue *build_valid_start_options(FakeEnv *env) {
  FakeValue *options = make_object(env);
  set_named_prop(options, "fd", make_number(env, 42));
  set_named_prop(options, "vpnId", make_string(env, "vpn-1"));
  set_named_prop(options, "sessionId", make_string(env, "session-1"));
  set_named_prop(options, "configPath", make_string(env, "/tmp/config.yaml"));
  set_named_prop(options, "mixedPort", make_number(env, 7890));
  set_named_prop(options, "platformApiLevel", make_number(env, 12));
  set_named_prop(options, "processProtected", make_boolean(env, true));
  set_named_prop(options, "captureConfig", build_valid_capture_config(env));
  FakeValue *dns = make_array(env, 2);
  dns->array_items[0] = make_string(env, "10.111.222.2");
  dns->array_items[1] = make_string(env, "fd00:111:222::2");
  set_named_prop(options, "dnsServers", dns);
  return options;
}

std::string thrown_code(FakeEnv *env) {
  FakeValue *code = get_named_prop(env->last_thrown, "code");
  return code == nullptr ? "" : code->string_value;
}

void clear_thrown(FakeEnv *env) {
  env->last_thrown = nullptr;
}

template <typename Operation>
void expect_sync_throw_code(FakeEnv *env,
                            Operation operation,
                            cmfa::nodeaddon::AddonState *addon,
                            const std::string &expected_code,
                            const std::string &message) {
  clear_thrown(env);
  FakeValue *result = operation(env, addon);
  expect(result == nullptr, message + " should throw synchronously");
  expect_equal(thrown_code(env), expected_code, message + " should throw expected code");
}

FakeValue *invoke_start_tun_with_options(FakeEnv *env, cmfa::nodeaddon::AddonState *addon, FakeValue *options) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_tun(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{options}, addon})));
}

FakeValue *invoke_read_tun_traces_with_value(FakeEnv *env, cmfa::nodeaddon::AddonState *addon, FakeValue *value) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::read_tun_traces(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{value}, addon})));
}

void test_define_core_module_registers_tun_exports() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  FakeValue *exports = make_object(env.get());
  expect_equal(cmfa::nodeaddon::define_core_module(reinterpret_cast<napi_env>(env.get()),
                                                   reinterpret_cast<napi_value>(exports),
                                                   addon.get()),
               napi_ok,
               "define_core_module should succeed");
  for (const char *name : {"startTun", "stopTun", "tunSnapshot", "readTunTraces"}) {
    FakeValue *value = get_named_prop(exports, name);
    expect(value != nullptr && value->type == FakeType::Function, std::string("missing tun export: ") + name);
  }
}

void test_start_tun_rejects_extra_fields_strictly() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  FakeValue *top_level = build_valid_start_options(env.get());
  set_named_prop(top_level, "unexpected", make_string(env.get(), "boom"));
  FakeValue *top_level_result =
      reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_tun(reinterpret_cast<napi_env>(env.get()),
                                                               reinterpret_cast<napi_callback_info>(
                                                                   new FakeCallbackInfo{{top_level}, addon.get()})));
  expect(top_level_result == nullptr, "extra top-level field should reject synchronously");
  expect_equal(thrown_code(env.get()), std::string("CMFA_INVALID_ARGUMENT"), "extra top-level field should throw");

  clear_thrown(env.get());
  FakeValue *capture_extra = build_valid_start_options(env.get());
  set_named_prop(get_named_prop(capture_extra, "captureConfig"), "unexpected", make_string(env.get(), "boom"));
  FakeValue *capture_result =
      reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_tun(reinterpret_cast<napi_env>(env.get()),
                                                               reinterpret_cast<napi_callback_info>(
                                                                   new FakeCallbackInfo{{capture_extra}, addon.get()})));
  expect(capture_result == nullptr, "extra capture field should reject synchronously");
  expect_equal(thrown_code(env.get()), std::string("CMFA_INVALID_ARGUMENT"), "extra capture field should throw");
}

void test_start_tun_rejects_missing_type_and_range_inputs() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    FakeValue *options = build_valid_start_options(env.get());
    options->object_props.erase("fd");
    options->object_keys.erase(std::remove(options->object_keys.begin(), options->object_keys.end(), "fd"),
                               options->object_keys.end());
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "missing fd");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    options->object_props.erase("sessionId");
    options->object_keys.erase(
        std::remove(options->object_keys.begin(), options->object_keys.end(), "sessionId"),
        options->object_keys.end());
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "missing sessionId");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    options->object_props.erase("captureConfig");
    options->object_keys.erase(
        std::remove(options->object_keys.begin(), options->object_keys.end(), "captureConfig"),
        options->object_keys.end());
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "missing captureConfig");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "fd", make_string(env.get(), "42"));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "string fd");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "fd", make_number(env.get(), 42.5));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "fractional fd");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "fd", make_number(env.get(), 0));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "zero fd");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "fd", make_number(env.get(), -1));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "negative fd");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "mixedPort", make_number(env.get(), 0));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "zero mixedPort");
  }

  {
    FakeValue *options = build_valid_start_options(env.get());
    set_named_prop(options, "mixedPort", make_number(env.get(), 65536));
    expect_sync_throw_code(
        env.get(),
        [options](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_tun_with_options(call_env, state, options);
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "mixedPort above 65535");
  }

  {
    expect_sync_throw_code(
        env.get(),
        [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_tun_traces_with_value(call_env, state, make_number(call_env, 1.5));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "fractional afterSequence");
  }

  {
    expect_sync_throw_code(
        env.get(),
        [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_tun_traces_with_value(call_env, state, make_number(call_env, -1));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "negative afterSequence");
  }

  {
    expect_sync_throw_code(
        env.get(),
        [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_tun_traces_with_value(call_env, state, make_number(call_env, kMaxSafeInteger + 1.0));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "afterSequence above MAX_SAFE_INTEGER");
  }
}

void test_start_tun_promise_worker_copies_input_before_backend_runs() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.block_start = true;
  }

  FakeValue *options = build_valid_start_options(env.get());
  FakeValue *promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::start_tun(reinterpret_cast<napi_env>(env.get()),
                                 reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{options}, addon.get()})));
  expect(promise != nullptr && promise->type == FakeType::Promise, "startTun should return a promise");

  set_named_prop(options, "sessionId", make_string(env.get(), "mutated-session"));
  set_named_prop(options, "configPath", make_string(env.get(), "/tmp/mutated.yaml"));
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.allow_start = true;
  }
  g_tun_backend.cv.notify_all();

  FakeValue *result = await_promise(env.get(), promise, "startTun promise should settle");
  expect(promise->promise_resolved, "startTun promise should resolve");
  expect_equal(get_named_prop(result, "sessionId")->string_value, std::string("session-1"),
               "resolved snapshot should keep native session");
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  expect_equal(std::string(g_tun_backend.copied_options.session_id), std::string("session-1"),
               "worker should use copied session id");
  expect_equal(g_tun_backend.copied_config_path, std::string("/tmp/config.yaml"),
               "worker should use copied config path");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "async handles should release after completion");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "deliveries should release after completion");
}

void test_queue_failure_and_native_error_release_resources() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  env->next_tsfn_call_status = napi_generic_failure;
  FakeValue *queue_failure_promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::start_tun(reinterpret_cast<napi_env>(env.get()),
                                 reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{build_valid_start_options(env.get())}, addon.get()})));
  FakeValue *queue_failure_error = await_promise(env.get(), queue_failure_promise, "queue failure promise should settle");
  expect(queue_failure_promise->promise_rejected, "queue failure should reject");
  expect_equal(get_named_prop(queue_failure_error, "code")->string_value, std::string("NAPI_FAILURE"),
               "queue failure should reject with napi failure");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "queue failure should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "queue failure should release deliveries");

  reset_tun_backend();
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.start_status = CMFA_BACKEND_ERROR;
  }
  FakeValue *native_error_promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::start_tun(reinterpret_cast<napi_env>(env.get()),
                                 reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{build_valid_start_options(env.get())}, addon.get()})));
  FakeValue *native_error = await_promise(env.get(), native_error_promise, "native error promise should settle");
  expect(native_error_promise->promise_rejected, "native error should reject");
  expect_equal(get_named_prop(native_error, "code")->string_value, std::string("CMFA_BACKEND_ERROR"),
               "native error should keep backend failure code");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "native error should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "native error should release deliveries");
}

void test_start_tun_preserves_socket_protect_failure_code() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.start_status = CMFA_SOCKET_PROTECT_FAILED;
  }

  FakeValue *promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{build_valid_start_options(env.get())}, addon.get()})));
  FakeValue *rejection = await_promise(env.get(), promise, "socket protect failure should settle");
  expect(promise->promise_rejected, "socket protect failure should reject");
  expect_equal(get_named_prop(rejection, "code")->string_value, std::string("CMFA_SOCKET_PROTECT_FAILED"),
               "socket protect failure should preserve native code");
}

void test_stop_tun_allows_only_fixed_backend_prefixes_in_detail() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.stop_status = CMFA_BACKEND_ERROR;
    g_tun_backend.stop_error_message = "TUN_STOP_EXECUTOR_FAILED_ERROR: secret-token";
  }

  FakeValue *promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::stop_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *rejection = await_promise(env.get(), promise, "stopTun fixed-prefix failure should settle");
  expect(promise->promise_rejected, "stopTun fixed-prefix failure should reject");
  expect_equal(get_named_prop(rejection, "code")->string_value, std::string("CMFA_BACKEND_ERROR"),
               "stopTun fixed-prefix failure should preserve backend code");
  expect_equal(get_named_prop(rejection, "detail")->string_value, std::string("TUN_STOP_EXECUTOR_FAILED_ERROR"),
               "stopTun should expose only the allowlisted fixed prefix");
  expect(get_named_prop(rejection, "detail")->string_value.find("secret-token") == std::string::npos,
         "stopTun fixed-prefix detail must not leak backend secret");

  reset_tun_backend();
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.stop_status = CMFA_BACKEND_ERROR;
    g_tun_backend.stop_error_message = "TUN_STOP_EXECUTOR_FAILED_ERRORISH: secret-token";
  }

  FakeValue *pseudo_promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::stop_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *pseudo_rejection = await_promise(env.get(), pseudo_promise, "stopTun pseudo-prefix failure should settle");
  expect(pseudo_promise->promise_rejected, "stopTun pseudo-prefix failure should reject");
  expect_equal(get_named_prop(pseudo_rejection, "detail")->string_value, std::string("TUN_STOP_CONTRACT_OTHER"),
               "stopTun pseudo-prefix failure should map to other contract detail");
  expect(get_named_prop(pseudo_rejection, "detail")->string_value.find("secret-token") == std::string::npos,
         "stopTun pseudo-prefix detail must not leak backend secret");
}

void test_stop_tun_maps_contract_backend_messages_to_safe_tokens() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  const struct {
    const char *message;
    const char *expected_detail;
    const char *label;
  } cases[] = {
      {"backend stop_tun failed", "TUN_STOP_CONTRACT_BACKEND_FAILED", "exact backend failure"},
      {"backend tun_runtime_state after stop failed", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "exact snapshot failure"},
      {"backend tun snapshot secret-token", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "snapshot prefix failure"},
      {"backend returned an invalid tun state", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "invalid tun state snapshot failure"},
      {"backend tun session_id secret-token", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "tun session id snapshot failure"},
      {"backend tun counters secret-token", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "tun counters snapshot failure"},
      {"backend tun failure secret-token", "TUN_STOP_CONTRACT_SNAPSHOT_FAILED", "tun failure snapshot failure"},
      {"backend tun_copy_traces after stop failed", "TUN_STOP_CONTRACT_TRACES_FAILED", "exact traces failure"},
      {"backend tun trace secret-token", "TUN_STOP_CONTRACT_TRACES_FAILED", "trace prefix failure"},
      {"backend tun traces secret-token", "TUN_STOP_CONTRACT_TRACES_FAILED", "traces prefix failure"},
      {"totally different secret-token", "TUN_STOP_CONTRACT_OTHER", "other failure"},
      {"", "TUN_STOP_CONTRACT_EMPTY", "empty failure"},
  };

  for (const auto &entry : cases) {
    reset_tun_backend();
    {
      std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
      g_tun_backend.stop_status = CMFA_BACKEND_ERROR;
      g_tun_backend.stop_error_message = entry.message;
    }

    FakeValue *promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::stop_tun(
        reinterpret_cast<napi_env>(env.get()),
        reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
    FakeValue *rejection = await_promise(env.get(), promise, std::string(entry.label) + " should settle");
    expect(promise->promise_rejected, std::string(entry.label) + " should reject");
    expect_equal(get_named_prop(rejection, "code")->string_value, std::string("CMFA_BACKEND_ERROR"),
                 std::string(entry.label) + " should preserve backend code");
    expect_equal(get_named_prop(rejection, "detail")->string_value, std::string(entry.expected_detail),
                 std::string(entry.label) + " should map to the safe contract token");
    expect(get_named_prop(rejection, "detail")->string_value.find("secret-token") == std::string::npos,
           std::string(entry.label) + " must not leak backend secret");
  }
}

void test_stop_tun_maps_proxy_delay_bridge_invalid_to_safe_token() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.stop_status = CMFA_BACKEND_ERROR;
    g_tun_backend.stop_error_message = "PROXY_DELAY_BRIDGE_INVALID";
  }

  FakeValue *promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::stop_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *rejection = await_promise(env.get(), promise, "proxy delay bridge invalid should settle");
  expect(promise->promise_rejected, "proxy delay bridge invalid should reject");
  expect_equal(get_named_prop(rejection, "detail")->string_value, std::string("TUN_STOP_PROXY_DELAY_DRAIN_FAILED"),
               "exact proxy delay bridge invalid should map to the fixed token");
  expect(get_named_prop(rejection, "detail")->string_value.find("secret-token") == std::string::npos,
         "proxy delay bridge invalid must not leak backend secret");

  reset_tun_backend();
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.stop_status = CMFA_BACKEND_ERROR;
    g_tun_backend.stop_error_message = "PROXY_DELAY_BRIDGE_INVALID_SUFFIX: secret-token";
  }

  FakeValue *pseudo_promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::stop_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *pseudo_rejection = await_promise(env.get(), pseudo_promise, "proxy delay bridge invalid suffix should settle");
  expect(pseudo_promise->promise_rejected, "proxy delay bridge invalid suffix should reject");
  expect_equal(get_named_prop(pseudo_rejection, "detail")->string_value, std::string("TUN_STOP_CONTRACT_OTHER"),
               "proxy delay bridge invalid suffix should fall back to other token");
  expect(get_named_prop(pseudo_rejection, "detail")->string_value.find("secret-token") == std::string::npos,
         "proxy delay bridge invalid suffix must not leak backend secret");
}

void test_tsfn_closing_requires_cleanup_but_does_not_settle_or_leak() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  env->next_tsfn_call_status = napi_closing;
  FakeValue *closing_promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_tun(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{build_valid_start_options(env.get())}, addon.get()})));
  expect(closing_promise != nullptr && closing_promise->type == FakeType::Promise, "napi_closing should still return a promise");

  for (int attempt = 0; attempt < 20; attempt += 1) {
    pump_env(env.get());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  expect(!closing_promise->promise_resolved, "napi_closing must not resolve the promise");
  expect(!closing_promise->promise_rejected, "napi_closing must not reject the promise");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(1), "napi_closing should leave async handle for cleanup");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(1), "napi_closing should leave delivery for cleanup");

  const auto cleanup = addon->owner.cleanup();
  expect_equal(cleanup.shutdown_status, CMFA_OK, "cleanup after napi_closing should succeed");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "cleanup should release async after napi_closing");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "cleanup should release delivery after napi_closing");
  expect(!closing_promise->promise_resolved, "cleanup must not retroactively resolve a napi_closing promise");
  expect(!closing_promise->promise_rejected, "cleanup must not retroactively reject a napi_closing promise");
  pump_env(env.get());
  expect(!closing_promise->promise_resolved, "draining after cleanup must keep promise unresolved");
  expect(!closing_promise->promise_rejected, "draining after cleanup must keep promise unrejected");
}

void test_tun_snapshot_stop_and_trace_exports_resolve() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  FakeValue *snapshot_promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::tun_snapshot(reinterpret_cast<napi_env>(env.get()),
                                    reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *snapshot = await_promise(env.get(), snapshot_promise, "tunSnapshot should settle");
  expect(snapshot_promise->promise_resolved, "tunSnapshot should resolve");
  expect_equal(get_named_prop(snapshot, "state")->string_value, std::string("READY"), "snapshot state should resolve");

  FakeValue *traces_promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::read_tun_traces(reinterpret_cast<napi_env>(env.get()),
                                       reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{make_number(env.get(), 1)}, addon.get()})));
  FakeValue *traces = await_promise(env.get(), traces_promise, "readTunTraces should settle");
  expect(traces_promise->promise_resolved, "readTunTraces should resolve");
  expect_equal(traces->array_items.size(), static_cast<size_t>(1), "afterSequence should filter one earlier trace");
  expect_equal(get_named_prop(traces->array_items[0], "sequence")->number_value, 2.0, "remaining trace should be sequence 2");
  expect_equal(get_named_prop(traces->array_items[0], "destinationHash")->string_value,
               std::string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2"),
               "destination hash should export");
  expect_equal(get_named_prop(traces->array_items[0], "outboundTerminalHash")->string_value,
               std::string("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2"),
               "terminal hash should export");
  expect_equal(get_named_prop(traces->array_items[0], "outboundChainHash")->string_value,
               std::string("ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc2"),
               "chain hash should export");
  expect_equal(get_named_prop(traces->array_items[0], "outboundChainLength")->number_value,
               2.0,
               "chain length should export");

  FakeValue *stop_promise = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::stop_tun(reinterpret_cast<napi_env>(env.get()),
                                reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, addon.get()})));
  FakeValue *stop_snapshot = await_promise(env.get(), stop_promise, "stopTun should settle");
  expect(stop_promise->promise_resolved, "stopTun should resolve");
  expect_equal(get_named_prop(stop_snapshot, "sessionId")->string_value, std::string("session-1"),
               "stopTun should resolve snapshot");
}

void test_close_stale_outbound_connections_resolves_without_stopping_tun() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  FakeValue *close_promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::close_stale_outbound_connections(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{make_string(env.get(), "session-1")}, addon.get()})));
  await_promise(env.get(), close_promise, "closeStaleOutboundConnections should settle");
  expect(close_promise->promise_resolved, "close stale should resolve");
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  expect_equal(g_tun_backend.close_stale_calls, 1, "close stale should call hidden backend wrapper once");
  expect_equal(g_tun_backend.closed_stale_session_id, std::string("session-1"), "close stale should forward session id");
  expect_equal(g_tun_backend.stop_calls, 0, "close stale should not stop tun");
}

void test_close_stale_outbound_connections_preserves_busy_code() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  {
    std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
    g_tun_backend.close_stale_status = CMFA_BUSY;
  }

  FakeValue *promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::close_stale_outbound_connections(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{make_string(env.get(), "session-1")}, addon.get()})));
  FakeValue *rejection = await_promise(env.get(), promise, "close stale busy should settle");
  expect(promise->promise_rejected, "close stale busy should reject");
  expect_equal(get_named_prop(rejection, "code")->string_value, std::string("CMFA_BUSY"),
               "close stale busy should preserve busy code");
  std::lock_guard<std::mutex> lock(g_tun_backend.mutex);
  expect_equal(g_tun_backend.stop_calls, 0, "close stale busy should not stop tun");
}

void test_read_tun_traces_rejects_sequence_above_max_safe_integer() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  addon->tun_trace_session_id = "session-1";
  addon->next_tun_trace_sequence = static_cast<uint64_t>(kMaxSafeInteger);

  FakeValue *traces_promise = reinterpret_cast<FakeValue *>(cmfa::nodeaddon::read_tun_traces(
      reinterpret_cast<napi_env>(env.get()),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{make_number(env.get(), 0)}, addon.get()})));
  FakeValue *rejection = await_promise(env.get(), traces_promise, "readTunTraces overflow should settle");
  expect(traces_promise->promise_rejected, "overflowing trace sequence should reject");
  expect_equal(get_named_prop(rejection, "code")->string_value, std::string("CMFA_OUT_OF_RANGE"),
               "overflowing trace sequence should reject with out-of-range");
}

void test_subscribe_event_lifetime_and_shutdown_cleanup_release() {
  reset_tun_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  lifecycle.shutdown_status = CMFA_BACKEND_ERROR;
  auto addon = make_addon(env.get(), &lifecycle);

  int callback_count = 0;
  FakeValue *callback = make_host_function(env.get(), [&callback_count](FakeEnv *, const std::vector<FakeValue *> &args) -> FakeValue * {
    callback_count += 1;
    expect(args.size() == 1, "subscribe callback should receive one event");
    return nullptr;
  });

  FakeValue *subscription_id = reinterpret_cast<FakeValue *>(
      cmfa::nodeaddon::subscribe(reinterpret_cast<napi_env>(env.get()),
                                 reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{callback}, addon.get()})));
  expect(subscription_id != nullptr, "subscribe should return id");
  pump_env(env.get());
  expect_equal(callback_count, 1, "subscribe should enqueue an initial snapshot event");

  cmfa_runtime_event event{};
  event.struct_size = sizeof(event);
  event.state = CMFA_RUNTIME_RUNNING;
  event.message = "ready";
  event.code = "CMFA_OK";
  event.session_id = "session-1";
  event.trace_id = "trace-1";
  event.ingress = "tun";
  event.protocol = "tcp";
  cmfa::nodeaddon::emit_runtime_event(addon.get(), &event);
  pump_env(env.get());
  expect_equal(callback_count, 2, "event should be delivered while active");

  const auto cleanup = addon->owner.cleanup();
  expect_equal(cleanup.shutdown_status, CMFA_BACKEND_ERROR, "cleanup should surface shutdown error");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "cleanup should release deliveries");
  expect_equal(addon->owner.reference_count(), static_cast<size_t>(0), "cleanup should release references");

  cmfa::nodeaddon::emit_runtime_event(addon.get(), &event);
  pump_env(env.get());
  expect_equal(callback_count, 2, "late event should be ignored after cleanup");
}

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"define_core_module_registers_tun_exports", test_define_core_module_registers_tun_exports},
      {"start_tun_rejects_extra_fields_strictly", test_start_tun_rejects_extra_fields_strictly},
      {"start_tun_rejects_missing_type_and_range_inputs", test_start_tun_rejects_missing_type_and_range_inputs},
      {"start_tun_promise_worker_copies_input_before_backend_runs",
       test_start_tun_promise_worker_copies_input_before_backend_runs},
      {"queue_failure_and_native_error_release_resources", test_queue_failure_and_native_error_release_resources},
      {"start_tun_preserves_socket_protect_failure_code", test_start_tun_preserves_socket_protect_failure_code},
      {"stop_tun_allows_only_fixed_backend_prefixes_in_detail",
       test_stop_tun_allows_only_fixed_backend_prefixes_in_detail},
      {"stop_tun_maps_contract_backend_messages_to_safe_tokens",
       test_stop_tun_maps_contract_backend_messages_to_safe_tokens},
      {"stop_tun_maps_proxy_delay_bridge_invalid_to_safe_token",
       test_stop_tun_maps_proxy_delay_bridge_invalid_to_safe_token},
      {"tsfn_closing_requires_cleanup_but_does_not_settle_or_leak",
       test_tsfn_closing_requires_cleanup_but_does_not_settle_or_leak},
      {"tun_snapshot_stop_and_trace_exports_resolve", test_tun_snapshot_stop_and_trace_exports_resolve},
      {"close_stale_outbound_connections_resolves_without_stopping_tun",
       test_close_stale_outbound_connections_resolves_without_stopping_tun},
      {"close_stale_outbound_connections_preserves_busy_code",
       test_close_stale_outbound_connections_preserves_busy_code},
      {"read_tun_traces_rejects_sequence_above_max_safe_integer",
       test_read_tun_traces_rejects_sequence_above_max_safe_integer},
      {"subscribe_event_lifetime_and_shutdown_cleanup_release",
       test_subscribe_event_lifetime_and_shutdown_cleanup_release},
  };

  size_t failed = 0;
  for (const auto &entry : tests) {
    try {
      std::cout << "[RUN] " << entry.first << std::endl;
      entry.second();
      std::cout << "[PASS] " << entry.first << std::endl;
    } catch (const std::exception &error) {
      failed += 1;
      std::cerr << "[FAIL] " << entry.first << ": " << error.what() << std::endl;
    }
  }

  if (failed != 0) {
    std::cerr << failed << " test(s) failed\n";
    return 1;
  }

  std::cout << tests.size() << " test(s) passed" << std::endl;
  return 0;
}
