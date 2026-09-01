#include "cmfa_napi.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
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
  Symbol,
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
  std::vector<std::string> non_enumerable_object_keys;
  std::vector<FakeValue *> symbol_keys;
  std::vector<FakeValue *> array_items;
  FakeValue *prototype = nullptr;
  napi_callback native_callback = nullptr;
  void *native_data = nullptr;
  HostFunction host_callback;
  bool promise_resolved = false;
  bool promise_rejected = false;
  FakeValue *promise_result = nullptr;
  bool force_string_read_failure = false;
};

struct FakeDeferred {
  FakeValue *promise = nullptr;
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
  std::vector<std::unique_ptr<FakeTsfn>> tsfns;
  FakeValue *global = nullptr;
  FakeValue *object_constructor = nullptr;
  FakeValue *object_prototype = nullptr;
  FakeValue *array_prototype = nullptr;
  FakeValue *function_prototype = nullptr;
  FakeValue *undefined_value = nullptr;
  FakeValue *null_value = nullptr;
  FakeValue *last_thrown = nullptr;
  napi_status next_tsfn_call_status = napi_ok;
  bool fail_create_object = false;
  bool fail_create_promise = false;
  bool fail_create_tsfn = false;
  bool fail_define_properties = false;
  bool fail_get_prototype = false;
  bool fail_strict_equals = false;
  bool fail_global_object_lookup = false;
  bool fail_object_prototype_lookup = false;
  std::vector<PendingTsfnCall> pending_tsfn_calls;
  std::vector<FakeTsfn *> pending_tsfn_finalizers;
  std::thread::id env_thread_id{};
  std::atomic<int> off_thread_env_api_calls{0};
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

FakeValue *make_symbol(FakeEnv *env, const std::string &description) {
  FakeValue *result = allocate_value(env, FakeType::Symbol);
  result->string_value = description;
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
  FakeValue *result = allocate_value(env, FakeType::Object);
  result->prototype = env->object_prototype;
  return result;
}

FakeValue *make_array(FakeEnv *env, size_t length = 0) {
  FakeValue *result = allocate_value(env, FakeType::Array);
  result->prototype = env->array_prototype;
  result->array_items.resize(length, env->undefined_value);
  return result;
}

FakeValue *make_host_function(FakeEnv *env, HostFunction callback) {
  FakeValue *result = allocate_value(env, FakeType::Function);
  result->prototype = env->function_prototype;
  result->host_callback = std::move(callback);
  return result;
}

void remove_named_prop(FakeValue *object, const std::string &name) {
  object->object_props.erase(name);
  object->object_keys.erase(std::remove(object->object_keys.begin(), object->object_keys.end(), name), object->object_keys.end());
  object->non_enumerable_object_keys.erase(
      std::remove(object->non_enumerable_object_keys.begin(), object->non_enumerable_object_keys.end(), name),
      object->non_enumerable_object_keys.end());
}

void set_named_prop_with_enumerable(FakeValue *object, const std::string &name, FakeValue *value, bool enumerable) {
  if (object->object_props.find(name) == object->object_props.end()) {
    if (enumerable) {
      object->object_keys.push_back(name);
    } else {
      object->non_enumerable_object_keys.push_back(name);
    }
  } else if (enumerable) {
    object->non_enumerable_object_keys.erase(
        std::remove(object->non_enumerable_object_keys.begin(), object->non_enumerable_object_keys.end(), name),
        object->non_enumerable_object_keys.end());
    if (std::find(object->object_keys.begin(), object->object_keys.end(), name) == object->object_keys.end()) {
      object->object_keys.push_back(name);
    }
  } else {
    object->object_keys.erase(std::remove(object->object_keys.begin(), object->object_keys.end(), name), object->object_keys.end());
    if (std::find(object->non_enumerable_object_keys.begin(), object->non_enumerable_object_keys.end(), name) ==
        object->non_enumerable_object_keys.end()) {
      object->non_enumerable_object_keys.push_back(name);
    }
  }
  object->object_props[name] = value;
}

void set_named_prop(FakeValue *object, const std::string &name, FakeValue *value) {
  set_named_prop_with_enumerable(object, name, value, true);
}

void set_symbol_prop(FakeValue *object, FakeValue *symbol) {
  object->symbol_keys.push_back(symbol);
}

void set_prototype_prop(FakeValue *object, const std::string &name, FakeValue *value) {
  if (object->prototype != nullptr) {
    set_named_prop(object->prototype, name, value);
  }
}

FakeValue *get_named_prop(FakeValue *object, const std::string &name) {
  for (FakeValue *cursor = object; cursor != nullptr; cursor = cursor->prototype) {
    const auto own = cursor->object_props.find(name);
    if (own != cursor->object_props.end()) {
      return own->second;
    }
  }
  return nullptr;
}

FakeEnv *create_env() {
  auto *env = new FakeEnv();
  env->env_thread_id = std::this_thread::get_id();
  env->undefined_value = allocate_value(env, FakeType::Undefined);
  env->null_value = allocate_value(env, FakeType::Null);
  env->object_prototype = allocate_value(env, FakeType::Object);
  env->object_prototype->prototype = nullptr;
  env->array_prototype = allocate_value(env, FakeType::Object);
  env->array_prototype->prototype = env->object_prototype;
  env->function_prototype = allocate_value(env, FakeType::Object);
  env->function_prototype->prototype = env->object_prototype;
  env->global = make_object(env);
  env->object_constructor = make_host_function(env, [](FakeEnv *call_env, const std::vector<FakeValue *> &) {
    return make_object(call_env);
  });
  set_named_prop(env->object_constructor, "prototype", env->object_prototype);
  set_named_prop(env->global, "Object", env->object_constructor);
  return env;
}

void destroy_env(FakeEnv *env) {
  delete env;
}

bool check_env_thread(FakeEnv *env) {
  if (std::this_thread::get_id() == env->env_thread_id) {
    return true;
  }
  env->off_thread_env_api_calls.fetch_add(1, std::memory_order_relaxed);
  return false;
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
};

std::unordered_map<cmfa::nodeaddon::AddonLifecycleOwnership *, LifecycleContext *> g_lifecycle_contexts;

cmfa_status lifecycle_shutdown_for_addon(void *context, cmfa_error *) {
  auto *ownership = static_cast<cmfa::nodeaddon::AddonLifecycleOwnership *>(context);
  auto found = g_lifecycle_contexts.find(ownership);
  if (ownership == nullptr || found == g_lifecycle_contexts.end()) {
    return CMFA_OK;
  }
  ownership->core_initialized.store(false, std::memory_order_release);
  return found->second->shutdown_status;
}

cmfa_status lifecycle_unregister_for_addon(void *context, cmfa_error *) {
  auto *ownership = static_cast<cmfa::nodeaddon::AddonLifecycleOwnership *>(context);
  auto found = g_lifecycle_contexts.find(ownership);
  if (ownership == nullptr || found == g_lifecycle_contexts.end()) {
    return CMFA_OK;
  }
  ownership->backend_registered.store(false, std::memory_order_release);
  return found->second->unregister_status;
}

cmfa::napi::LifecycleOperations make_lifecycle(LifecycleContext *context) {
  cmfa::napi::LifecycleOperations operations{};
  operations.context = context;
  operations.shutdown = lifecycle_shutdown_for_addon;
  operations.unregister_backend = lifecycle_unregister_for_addon;
  return operations;
}

enum class ProxyOutputMode {
  Valid,
  InvalidUtf8,
  MissingNul,
  TooLarge,
  Overrun,
  UnexpectedBufferTooSmall,
};

struct ProxyBackendState {
  std::mutex mutex;
  std::condition_variable cv;
  bool block = false;
  bool allow = false;
  int groups_calls = 0;
  int group_calls = 0;
  int select_calls = 0;
  int delay_start_calls = 0;
  int delay_snapshot_calls = 0;
  int delay_cancel_calls = 0;
  cmfa_status groups_status = CMFA_OK;
  cmfa_status group_status = CMFA_OK;
  cmfa_status select_status = CMFA_OK;
  cmfa_status delay_start_status = CMFA_OK;
  cmfa_status delay_snapshot_status = CMFA_OK;
  cmfa_status delay_cancel_status = CMFA_OK;
  ProxyOutputMode groups_mode = ProxyOutputMode::Valid;
  ProxyOutputMode group_mode = ProxyOutputMode::Valid;
  ProxyOutputMode select_mode = ProxyOutputMode::Valid;
  ProxyOutputMode delay_start_mode = ProxyOutputMode::Valid;
  ProxyOutputMode delay_snapshot_mode = ProxyOutputMode::Valid;
  ProxyOutputMode delay_cancel_mode = ProxyOutputMode::Valid;
  std::string groups_payload = "{\"kind\":\"groups\"}";
  std::string group_payload = "{\"kind\":\"group\"}";
  std::string select_payload = "{\"kind\":\"select\"}";
  std::string delay_start_payload = "{\"kind\":\"delay-start\"}";
  std::string delay_snapshot_payload = "{\"kind\":\"delay-snapshot\"}";
  std::string delay_cancel_payload = "{\"kind\":\"delay-cancel\"}";
  cmfa_proxy_query_context last_query{};
  bool last_selectable_only = false;
  std::string last_group_name;
  std::string last_member_name;
  std::string last_delay_job_id;
  bool saw_null_session = false;
};

ProxyBackendState g_proxy_backend;

void reset_proxy_backend() {
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.block = false;
  g_proxy_backend.allow = false;
  g_proxy_backend.groups_calls = 0;
  g_proxy_backend.group_calls = 0;
  g_proxy_backend.select_calls = 0;
  g_proxy_backend.delay_start_calls = 0;
  g_proxy_backend.delay_snapshot_calls = 0;
  g_proxy_backend.delay_cancel_calls = 0;
  g_proxy_backend.groups_status = CMFA_OK;
  g_proxy_backend.group_status = CMFA_OK;
  g_proxy_backend.select_status = CMFA_OK;
  g_proxy_backend.delay_start_status = CMFA_OK;
  g_proxy_backend.delay_snapshot_status = CMFA_OK;
  g_proxy_backend.delay_cancel_status = CMFA_OK;
  g_proxy_backend.groups_mode = ProxyOutputMode::Valid;
  g_proxy_backend.group_mode = ProxyOutputMode::Valid;
  g_proxy_backend.select_mode = ProxyOutputMode::Valid;
  g_proxy_backend.delay_start_mode = ProxyOutputMode::Valid;
  g_proxy_backend.delay_snapshot_mode = ProxyOutputMode::Valid;
  g_proxy_backend.delay_cancel_mode = ProxyOutputMode::Valid;
  g_proxy_backend.groups_payload.assign("{\"kind\":\"groups\"}");
  g_proxy_backend.group_payload.assign("{\"kind\":\"group\"}");
  g_proxy_backend.select_payload.assign("{\"kind\":\"select\"}");
  g_proxy_backend.delay_start_payload.assign("{\"kind\":\"delay-start\"}");
  g_proxy_backend.delay_snapshot_payload.assign("{\"kind\":\"delay-snapshot\"}");
  g_proxy_backend.delay_cancel_payload.assign("{\"kind\":\"delay-cancel\"}");
  g_proxy_backend.last_query = cmfa_proxy_query_context{};
  g_proxy_backend.last_query.struct_size = sizeof(g_proxy_backend.last_query);
  g_proxy_backend.last_selectable_only = false;
  g_proxy_backend.last_group_name.clear();
  g_proxy_backend.last_member_name.clear();
  g_proxy_backend.last_delay_job_id.clear();
  g_proxy_backend.saw_null_session = false;
}

void copy_query_context(const cmfa_proxy_query_context *query) {
  g_proxy_backend.last_query = *query;
  g_proxy_backend.saw_null_session = query->session_hash[0] == '\0';
}

cmfa_status fill_proxy_output(ProxyOutputMode mode,
                              const std::string &payload,
                              cmfa_json_buffer *output,
                              cmfa_error *error,
                              cmfa_status nominal_status) {
  if (output == nullptr || output->data == nullptr || output->capacity == 0) {
    return CMFA_INVALID_ARGUMENT;
  }
  output->length = 0;
  output->data[0] = '\0';
  if (error != nullptr) {
    error->code = nominal_status;
    if (error->message != nullptr && error->capacity > 0) {
      error->message[0] = '\0';
      error->length = 0;
    }
  }

  if (nominal_status != CMFA_OK) {
    return nominal_status;
  }

  const size_t required_length =
      mode == ProxyOutputMode::TooLarge ? static_cast<size_t>(CMFA_MAX_PROXY_JSON_BYTES + 1U) : payload.size();

  switch (mode) {
    case ProxyOutputMode::UnexpectedBufferTooSmall:
      output->length = required_length;
      return CMFA_BUFFER_TOO_SMALL;
    case ProxyOutputMode::TooLarge:
      output->length = required_length;
      return CMFA_OK;
    case ProxyOutputMode::Overrun:
      expect(output->capacity > required_length + 1, "overrun mode requires spare capacity");
      if (required_length > 0) {
        std::memcpy(output->data, payload.data(), required_length);
      }
      output->data[required_length] = '\0';
      output->data[required_length + 1] = '!';
      output->length = required_length;
      return CMFA_OK;
    case ProxyOutputMode::MissingNul:
      expect(output->capacity > required_length + 1, "missing NUL mode requires spare capacity");
      if (required_length > 0) {
        std::memcpy(output->data, payload.data(), required_length);
      }
      output->data[required_length] = '!';
      output->length = required_length;
      return CMFA_OK;
    case ProxyOutputMode::InvalidUtf8:
      expect(output->capacity >= 6, "invalid UTF-8 mode requires 5 bytes plus NUL");
      output->data[0] = '{';
      output->data[1] = '"';
      output->data[2] = static_cast<char>(0xC3);
      output->data[3] = static_cast<char>(0x28);
      output->data[4] = '}';
      output->data[5] = '\0';
      output->length = 5;
      return CMFA_OK;
    case ProxyOutputMode::Valid:
    default:
      expect(output->capacity > required_length, "valid payload must fit");
      if (required_length > 0) {
        std::memcpy(output->data, payload.data(), required_length);
      }
      output->data[required_length] = '\0';
      output->length = required_length;
      return CMFA_OK;
  }
}

void maybe_wait_for_backend() {
  std::unique_lock<std::mutex> lock(g_proxy_backend.mutex);
  while (g_proxy_backend.block && !g_proxy_backend.allow) {
    g_proxy_backend.cv.wait(lock);
  }
}

} // namespace

extern "C" cmfa_status cmfa_core_version(char *out, size_t capacity, cmfa_error *) {
  std::strncpy(out, "fake-core", capacity - 1);
  out[capacity - 1] = '\0';
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_validate_config(const char *, cmfa_error *) {
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_load_config(const char *, cmfa_error *) {
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_start_local(const cmfa_local_options *, cmfa_runtime_snapshot *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_stop(cmfa_error *) {
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_runtime_state(cmfa_runtime_snapshot *snapshot, cmfa_error *) {
  std::memset(snapshot, 0, sizeof(*snapshot));
  snapshot->struct_size = sizeof(*snapshot);
  snapshot->state = CMFA_RUNTIME_RUNNING;
  std::strncpy(snapshot->active_config_path, "config.yaml", sizeof(snapshot->active_config_path) - 1);
  std::strncpy(snapshot->http_address, "127.0.0.1:7890", sizeof(snapshot->http_address) - 1);
  std::strncpy(snapshot->socks_address, "127.0.0.1:7891", sizeof(snapshot->socks_address) - 1);
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

extern "C" cmfa_status cmfa_proxy_groups(const cmfa_proxy_query_context *query,
                                         uint8_t selectable_only,
                                         cmfa_json_buffer *output,
                                         cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.groups_calls += 1;
  copy_query_context(query);
  g_proxy_backend.last_selectable_only = selectable_only != 0;
  return fill_proxy_output(
      g_proxy_backend.groups_mode, g_proxy_backend.groups_payload, output, error, g_proxy_backend.groups_status);
}

extern "C" cmfa_status cmfa_proxy_group(const cmfa_proxy_query_context *query,
                                        const char *group_name,
                                        cmfa_json_buffer *output,
                                        cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.group_calls += 1;
  copy_query_context(query);
  g_proxy_backend.last_group_name = group_name == nullptr ? "" : group_name;
  return fill_proxy_output(
      g_proxy_backend.group_mode, g_proxy_backend.group_payload, output, error, g_proxy_backend.group_status);
}

extern "C" cmfa_status cmfa_proxy_select(const cmfa_proxy_query_context *query,
                                         const char *group_name,
                                         const char *member_name,
                                         cmfa_json_buffer *output,
                                         cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.select_calls += 1;
  copy_query_context(query);
  g_proxy_backend.last_group_name = group_name == nullptr ? "" : group_name;
  g_proxy_backend.last_member_name = member_name == nullptr ? "" : member_name;
  return fill_proxy_output(
      g_proxy_backend.select_mode, g_proxy_backend.select_payload, output, error, g_proxy_backend.select_status);
}

extern "C" cmfa_status cmfa_proxy_delay_start(const cmfa_proxy_query_context *query,
                                              const char *group_name,
                                              cmfa_json_buffer *output,
                                              cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.delay_start_calls += 1;
  copy_query_context(query);
  g_proxy_backend.last_group_name = group_name == nullptr ? "" : group_name;
  return fill_proxy_output(g_proxy_backend.delay_start_mode,
                           g_proxy_backend.delay_start_payload,
                           output,
                           error,
                           g_proxy_backend.delay_start_status);
}

extern "C" cmfa_status cmfa_proxy_delay_snapshot(const char *job_id, cmfa_json_buffer *output, cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.delay_snapshot_calls += 1;
  g_proxy_backend.last_delay_job_id = job_id == nullptr ? "" : job_id;
  return fill_proxy_output(g_proxy_backend.delay_snapshot_mode,
                           g_proxy_backend.delay_snapshot_payload,
                           output,
                           error,
                           g_proxy_backend.delay_snapshot_status);
}

extern "C" cmfa_status cmfa_proxy_delay_cancel(const char *job_id, cmfa_json_buffer *output, cmfa_error *error) {
  maybe_wait_for_backend();
  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  g_proxy_backend.delay_cancel_calls += 1;
  g_proxy_backend.last_delay_job_id = job_id == nullptr ? "" : job_id;
  return fill_proxy_output(
      g_proxy_backend.delay_cancel_mode, g_proxy_backend.delay_cancel_payload, output, error, g_proxy_backend.delay_cancel_status);
}

extern "C" cmfa_status cmfa_tun_start(const cmfa_tun_options *, cmfa_tun_snapshot *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_tun_stop(cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_tun_runtime_state(cmfa_tun_snapshot *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_tun_copy_traces(cmfa_tun_trace_collection *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

extern "C" cmfa_status cmfa_tun_copy_traces_ring(cmfa_tun_trace_ring *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

namespace cmfa {
cmfa_status cancel_mihomo_probe(const char *, cmfa_error *) {
  return CMFA_OK;
}

cmfa_status close_stale_tun_connections_for_mihomo_backend(const char *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}
} // namespace cmfa

namespace cmfa::nodeaddon {
napi_value start_tun(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "startTun", napi_generic_failure);
  return nullptr;
}

napi_value stop_tun(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "stopTun", napi_generic_failure);
  return nullptr;
}

napi_value close_stale_outbound_connections(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "closeStaleOutboundConnections", napi_generic_failure);
  return nullptr;
}

napi_value tun_snapshot(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "tunSnapshot", napi_generic_failure);
  return nullptr;
}

napi_value read_tun_traces(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "readTunTraces", napi_generic_failure);
  return nullptr;
}

napi_value subscribe(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "subscribe", napi_generic_failure);
  return nullptr;
}

napi_value unsubscribe(napi_env env, napi_callback_info) {
  throw_napi_failure(env, "unsubscribe", napi_generic_failure);
  return nullptr;
}
} // namespace cmfa::nodeaddon

extern "C" {

struct napi_env__ {
  char placeholder;
};
struct napi_value__ {
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
    const size_t requested = *argc;
    const size_t actual = callback_info->args.size();
    const size_t copy_count = requested < actual ? requested : actual;
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

napi_status napi_typeof(napi_env env, napi_value value, napi_valuetype *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
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
    case FakeType::Symbol:
      *result = napi_symbol;
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
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  const std::string value = length == NAPI_AUTO_LENGTH ? std::string(str) : std::string(str, length);
  *result = reinterpret_cast<napi_value>(make_string(fake_env, value));
  return napi_ok;
}

napi_status napi_get_value_string_utf8(napi_env env, napi_value value, char *buf, size_t bufsize, size_t *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::String) {
    return napi_string_expected;
  }
  if (fake->force_string_read_failure) {
    return napi_generic_failure;
  }
  if (result != nullptr) {
    *result = fake->string_value.size();
  }
  if (buf != nullptr && bufsize > 0) {
    const size_t copy_size = fake->string_value.size() < (bufsize - 1) ? fake->string_value.size() : (bufsize - 1);
    std::memcpy(buf, fake->string_value.data(), copy_size);
    buf[copy_size] = '\0';
  }
  return napi_ok;
}

napi_status napi_create_object(napi_env env, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  if (fake_env->fail_create_object) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_object(fake_env));
  return napi_ok;
}

napi_status napi_create_array_with_length(napi_env env, size_t length, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_array(fake_env, length));
  return napi_ok;
}

napi_status napi_set_named_property(napi_env env, napi_value object, const char *utf8name, napi_value value) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  set_named_prop(reinterpret_cast<FakeValue *>(object), utf8name, reinterpret_cast<FakeValue *>(value));
  return napi_ok;
}

napi_status napi_get_named_property(napi_env env, napi_value object, const char *utf8name, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *target = reinterpret_cast<FakeValue *>(object);
  if (fake_env->fail_global_object_lookup && target == fake_env->global && std::string(utf8name) == "Object") {
    return napi_generic_failure;
  }
  if (fake_env->fail_object_prototype_lookup && target == fake_env->object_constructor &&
      std::string(utf8name) == "prototype") {
    return napi_generic_failure;
  }
  FakeValue *value = get_named_prop(target, utf8name);
  if (value == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(value);
  return napi_ok;
}

napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *array = reinterpret_cast<FakeValue *>(object);
  if (array->array_items.size() <= index) {
    array->array_items.resize(index + 1, fake_env->undefined_value);
  }
  array->array_items[index] = reinterpret_cast<FakeValue *>(value);
  return napi_ok;
}

napi_status napi_get_element(napi_env env, napi_value object, uint32_t index, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *array = reinterpret_cast<FakeValue *>(object);
  if (index >= array->array_items.size()) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(array->array_items[index]);
  return napi_ok;
}

napi_status napi_get_array_length(napi_env env, napi_value value, uint32_t *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<FakeValue *>(value)->array_items.size();
  return napi_ok;
}

napi_status napi_is_array(napi_env env, napi_value value, bool *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<FakeValue *>(value)->type == FakeType::Array;
  return napi_ok;
}

napi_status napi_get_property_names(napi_env env, napi_value object, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *target = reinterpret_cast<FakeValue *>(object);
  FakeValue *keys = make_array(fake_env, target->object_keys.size());
  for (size_t index = 0; index < target->object_keys.size(); index += 1) {
    keys->array_items[index] = make_string(fake_env, target->object_keys[index]);
  }
  *result = reinterpret_cast<napi_value>(keys);
  return napi_ok;
}

napi_status napi_get_all_property_names(napi_env env,
                                        napi_value object,
                                        napi_key_collection_mode,
                                        napi_key_filter key_filter,
                                        napi_key_conversion,
                                        napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }

  auto *target = reinterpret_cast<FakeValue *>(object);
  const bool include_strings = (key_filter & napi_key_skip_strings) == 0;
  const bool include_symbols = (key_filter & napi_key_skip_symbols) == 0;
  const bool all_properties = key_filter == napi_key_all_properties;
  const bool enumerable_only = (key_filter & napi_key_enumerable) != 0;

  size_t total = 0;
  if (include_strings) {
    total += target->object_keys.size();
    if (all_properties) {
      total += target->non_enumerable_object_keys.size();
    }
  }
  if (include_symbols) {
    total += target->symbol_keys.size();
  }

  FakeValue *keys = make_array(fake_env, total);
  size_t index = 0;
  if (include_strings) {
    for (const std::string &key : target->object_keys) {
      keys->array_items[index] = make_string(fake_env, key);
      index += 1;
    }
    if (all_properties && !enumerable_only) {
      for (const std::string &key : target->non_enumerable_object_keys) {
        keys->array_items[index] = make_string(fake_env, key);
        index += 1;
      }
    }
  }
  if (include_symbols) {
    for (FakeValue *symbol : target->symbol_keys) {
      keys->array_items[index] = symbol;
      index += 1;
    }
  }

  *result = reinterpret_cast<napi_value>(keys);
  return napi_ok;
}

napi_status napi_create_uint32(napi_env env, uint32_t value, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_number(fake_env, value));
  return napi_ok;
}

napi_status napi_create_int32(napi_env env, int32_t value, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_number(fake_env, value));
  return napi_ok;
}

napi_status napi_create_int64(napi_env env, int64_t value, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_number(fake_env, static_cast<double>(value)));
  return napi_ok;
}

napi_status napi_get_value_int64(napi_env env, napi_value value, int64_t *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Number) {
    return napi_number_expected;
  }
  *result = static_cast<int64_t>(fake->number_value);
  return napi_ok;
}

napi_status napi_get_value_double(napi_env env, napi_value value, double *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Number) {
    return napi_number_expected;
  }
  *result = fake->number_value;
  return napi_ok;
}

napi_status napi_get_value_bool(napi_env env, napi_value value, bool *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *fake = reinterpret_cast<FakeValue *>(value);
  if (fake->type != FakeType::Boolean) {
    return napi_boolean_expected;
  }
  *result = fake->bool_value;
  return napi_ok;
}

napi_status napi_get_boolean(napi_env env, bool value, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_boolean(fake_env, value));
  return napi_ok;
}

napi_status napi_get_null(napi_env env, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(fake_env->null_value);
  return napi_ok;
}

napi_status napi_get_undefined(napi_env env, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(fake_env->undefined_value);
  return napi_ok;
}

napi_status napi_get_global(napi_env env, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(fake_env->global);
  return napi_ok;
}

napi_status napi_get_prototype(napi_env env, napi_value object, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  if (fake_env->fail_get_prototype) {
    return napi_generic_failure;
  }
  auto *target = reinterpret_cast<FakeValue *>(object);
  *result = reinterpret_cast<napi_value>(target->prototype != nullptr ? target->prototype : fake_env->null_value);
  return napi_ok;
}

napi_status napi_strict_equals(napi_env env, napi_value lhs, napi_value rhs, bool *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  if (fake_env->fail_strict_equals) {
    return napi_generic_failure;
  }
  *result = lhs == rhs;
  return napi_ok;
}

napi_status napi_create_error(napi_env env, napi_value code, napi_value msg, napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  FakeValue *error = make_object(fake_env);
  error->type = FakeType::Error;
  set_named_prop(error, "code", reinterpret_cast<FakeValue *>(code));
  set_named_prop(error, "message", reinterpret_cast<FakeValue *>(msg));
  *result = reinterpret_cast<napi_value>(error);
  return napi_ok;
}

napi_status napi_throw(napi_env env, napi_value error) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  fake_env->last_thrown = reinterpret_cast<FakeValue *>(error);
  return napi_ok;
}

napi_status napi_throw_error(napi_env env, const char *code, const char *msg) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  FakeValue *error = make_object(fake_env);
  error->type = FakeType::Error;
  set_named_prop(error, "code", make_string(fake_env, code == nullptr ? "" : code));
  set_named_prop(error, "message", make_string(fake_env, msg == nullptr ? "" : msg));
  fake_env->last_thrown = error;
  return napi_ok;
}

napi_status napi_create_promise(napi_env env, napi_deferred *deferred, napi_value *promise) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
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

napi_status napi_resolve_deferred(napi_env env, napi_deferred deferred, napi_value resolution) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *def = reinterpret_cast<FakeDeferred *>(deferred);
  def->promise->promise_resolved = true;
  def->promise->promise_result = reinterpret_cast<FakeValue *>(resolution);
  return napi_ok;
}

napi_status napi_reject_deferred(napi_env env, napi_deferred deferred, napi_value rejection) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  auto *def = reinterpret_cast<FakeDeferred *>(deferred);
  def->promise->promise_rejected = true;
  def->promise->promise_result = reinterpret_cast<FakeValue *>(rejection);
  return napi_ok;
}

napi_status napi_define_properties(napi_env env, napi_value object, size_t count, const napi_property_descriptor *properties) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
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

napi_status napi_create_reference(napi_env, napi_value, uint32_t, napi_ref *) {
  return napi_generic_failure;
}

napi_status napi_get_reference_value(napi_env, napi_ref, napi_value *) {
  return napi_generic_failure;
}

napi_status napi_delete_reference(napi_env, napi_ref) {
  return napi_generic_failure;
}

napi_status napi_call_function(napi_env env,
                               napi_value,
                               napi_value func,
                               size_t argc,
                               const napi_value *argv,
                               napi_value *result) {
  auto *fake_env = reinterpret_cast<FakeEnv *>(env);
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
  std::vector<FakeValue *> args;
  for (size_t index = 0; index < argc; index += 1) {
    args.push_back(reinterpret_cast<FakeValue *>(argv[index]));
  }
  FakeValue *call_result = invoke_function(fake_env, reinterpret_cast<FakeValue *>(func), args);
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
  if (!check_env_thread(fake_env)) {
    return napi_generic_failure;
  }
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
    const napi_status status = tsfn->env->next_tsfn_call_status;
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
    tsfn->env->pending_tsfn_finalizers.push_back(tsfn);
  }
  return napi_ok;
}

} // extern "C"

namespace {

void pump_env(FakeEnv *env) {
  while (!env->pending_tsfn_finalizers.empty()) {
    FakeTsfn *tsfn = env->pending_tsfn_finalizers.front();
    env->pending_tsfn_finalizers.erase(env->pending_tsfn_finalizers.begin());
    tsfn->finalize_cb(reinterpret_cast<napi_env>(env), tsfn->finalize_data, nullptr);
  }
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
  for (int attempt = 0; attempt < 400; attempt += 1) {
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

FakeValue *make_hash(FakeEnv *env, char ch) {
  return make_string(env, std::string(64, ch));
}

FakeValue *build_valid_context(FakeEnv *env) {
  FakeValue *context = make_object(env);
  set_named_prop(context, "profileHash", make_hash(env, 'a'));
  set_named_prop(context, "revisionHash", make_hash(env, 'b'));
  set_named_prop(context, "sessionHash", make_hash(env, 'c'));
  set_named_prop(context, "generation", make_number(env, 7));
  return context;
}

FakeValue *build_valid_context_with_custom_prototype(FakeEnv *env) {
  FakeValue *context = build_valid_context(env);
  FakeValue *custom_prototype = make_object(env);
  set_named_prop(custom_prototype, "poison", make_string(env, "boom"));
  context->prototype = custom_prototype;
  return context;
}

FakeValue *build_valid_context_with_data_class_prototype(FakeEnv *env) {
  FakeValue *context = build_valid_context(env);
  FakeValue *class_prototype = make_object(env);
  FakeValue *constructor = make_host_function(env, [](FakeEnv *call_env, const std::vector<FakeValue *> &) {
    return make_object(call_env);
  });
  set_named_prop_with_enumerable(class_prototype, "constructor", constructor, false);
  context->prototype = class_prototype;
  return context;
}

FakeValue *build_valid_context_with_null_prototype(FakeEnv *env) {
  FakeValue *context = build_valid_context(env);
  context->prototype = nullptr;
  return context;
}

FakeValue *build_valid_context_with_non_enumerable_extra(FakeEnv *env) {
  FakeValue *context = build_valid_context(env);
  set_named_prop_with_enumerable(context, "hidden", make_string(env, "secret"), false);
  return context;
}

FakeValue *build_valid_context_with_symbol_extra(FakeEnv *env) {
  FakeValue *context = build_valid_context(env);
  set_symbol_prop(context, make_symbol(env, "extra"));
  return context;
}

void expect_error_sanitized(FakeValue *error, const std::vector<std::string> &fragments, const std::string &message);

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

template <typename Operation>
void expect_sync_throw_without_side_effects(FakeEnv *env,
                                            Operation operation,
                                            cmfa::nodeaddon::AddonState *addon,
                                            const std::string &expected_code,
                                            const std::vector<std::string> &fragments,
                                            int expected_groups_calls,
                                            int expected_group_calls,
                                            int expected_select_calls,
                                            const std::string &message) {
  expect_sync_throw_code(env, operation, addon, expected_code, message);
  expect_error_sanitized(env->last_thrown, fragments, message);
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), message + " should not queue async work");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), message + " should not register delivery");
  expect_equal(g_proxy_backend.groups_calls, expected_groups_calls, message + " should not call groups backend");
  expect_equal(g_proxy_backend.group_calls, expected_group_calls, message + " should not call group backend");
  expect_equal(g_proxy_backend.select_calls, expected_select_calls, message + " should not call select backend");
}

FakeValue *invoke_query_proxy_groups(FakeEnv *env,
                                     cmfa::nodeaddon::AddonState *addon,
                                     FakeValue *context,
                                     FakeValue *selectable_only) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::query_proxy_groups(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context, selectable_only}, addon})));
}

FakeValue *invoke_query_proxy_group(FakeEnv *env,
                                    cmfa::nodeaddon::AddonState *addon,
                                    FakeValue *context,
                                    FakeValue *group_name) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::query_proxy_group(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context, group_name}, addon})));
}

FakeValue *invoke_select_proxy(FakeEnv *env,
                               cmfa::nodeaddon::AddonState *addon,
                               FakeValue *context,
                               FakeValue *group_name,
                               FakeValue *member_name) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::select_proxy(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context, group_name, member_name}, addon})));
}

FakeValue *invoke_start_proxy_delay_test(FakeEnv *env,
                                         cmfa::nodeaddon::AddonState *addon,
                                         FakeValue *context,
                                         FakeValue *group_name) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_proxy_delay_test(
      reinterpret_cast<napi_env>(env),
      reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context, group_name}, addon})));
}

FakeValue *invoke_read_proxy_delay_test(FakeEnv *env, cmfa::nodeaddon::AddonState *addon, FakeValue *job_id) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::read_proxy_delay_test(
      reinterpret_cast<napi_env>(env), reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{job_id}, addon})));
}

FakeValue *invoke_cancel_proxy_delay_test(FakeEnv *env, cmfa::nodeaddon::AddonState *addon, FakeValue *job_id) {
  return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::cancel_proxy_delay_test(
      reinterpret_cast<napi_env>(env), reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{job_id}, addon})));
}

void expect_error_sanitized(FakeValue *error, const std::vector<std::string> &fragments, const std::string &message) {
  expect(error != nullptr && error->type == FakeType::Error, message + " should be an error");
  FakeValue *detail = get_named_prop(error, "detail");
  const std::string detail_text = detail == nullptr ? "" : detail->string_value;
  FakeValue *message_value = get_named_prop(error, "message");
  const std::string message_text = message_value == nullptr ? "" : message_value->string_value;
  for (const std::string &fragment : fragments) {
    expect(message_text.find(fragment) == std::string::npos, message + " message must not echo raw fragments");
    expect(detail_text.find(fragment) == std::string::npos, message + " detail must not echo raw fragments");
  }
}

void test_define_core_module_registers_proxy_exports() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  FakeValue *exports = make_object(env.get());
  expect_equal(cmfa::nodeaddon::define_core_module(reinterpret_cast<napi_env>(env.get()),
                                                   reinterpret_cast<napi_value>(exports),
                                                   addon.get()),
               napi_ok,
               "define_core_module should succeed");
  for (const char *name :
       {"queryProxyGroups", "queryProxyGroup", "selectProxy", "startProxyDelayTest", "readProxyDelayTest", "cancelProxyDelayTest"}) {
    FakeValue *value = get_named_prop(exports, name);
    expect(value != nullptr && value->type == FakeType::Function, std::string("missing proxy export: ") + name);
  }
}

void test_proxy_delay_rejects_argc_context_shape_and_missing_addon() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *) {
        return invoke_start_proxy_delay_test(call_env,
                                             nullptr,
                                             build_valid_context(call_env),
                                             make_string(call_env, "group-a"));
      },
      addon.get(),
      "CMFA_INVALID_STATE",
      {"group-a", std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
      0,
      0,
      0,
      "startProxyDelayTest missing addon");
  expect_equal(g_proxy_backend.delay_start_calls, 0, "missing addon should not call delay start backend");

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *) {
        return invoke_read_proxy_delay_test(call_env, nullptr, make_string(call_env, "0123456789abcdef0123456789abcdef"));
      },
      addon.get(),
      "CMFA_INVALID_STATE",
      {"0123456789abcdef0123456789abcdef"},
      0,
      0,
      0,
      "readProxyDelayTest missing addon");
  expect_equal(g_proxy_backend.delay_snapshot_calls, 0, "missing addon should not call delay snapshot backend");

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *) {
        return invoke_cancel_proxy_delay_test(call_env, nullptr, make_string(call_env, "0123456789abcdef0123456789abcdef"));
      },
      addon.get(),
      "CMFA_INVALID_STATE",
      {"0123456789abcdef0123456789abcdef"},
      0,
      0,
      0,
      "cancelProxyDelayTest missing addon");
  expect_equal(g_proxy_backend.delay_cancel_calls, 0, "missing addon should not call delay cancel backend");

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_proxy_delay_test(
              reinterpret_cast<napi_env>(call_env), reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context}, state})));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
        0,
        0,
        0,
        "startProxyDelayTest too few args");
    expect_equal(g_proxy_backend.delay_start_calls, 0, "too few args should not call delay start backend");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::start_proxy_delay_test(
              reinterpret_cast<napi_env>(call_env),
              reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{
                  {context, make_string(call_env, "group-a"), make_string(call_env, "extra")},
                  state,
              })));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a", "extra"},
        0,
        0,
        0,
        "startProxyDelayTest too many args");
    expect_equal(g_proxy_backend.delay_start_calls, 0, "too many args should not call delay start backend");
  }

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return invoke_start_proxy_delay_test(call_env, state, make_number(call_env, 1), make_string(call_env, "group-a"));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      {"group-a"},
      0,
      0,
      0,
      "startProxyDelayTest non-object context");
  expect_equal(g_proxy_backend.delay_start_calls, 0, "non-object context should not call delay start backend");

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "extra", make_string(env.get(), "boom"));
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, "group-a"));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a", "boom"},
        0,
        0,
        0,
        "startProxyDelayTest context extra key");
    expect_equal(g_proxy_backend.delay_start_calls, 0, "extra key should not call delay start backend");
  }

  {
    FakeValue *context = build_valid_context_with_custom_prototype(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, "group-a"));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a"},
        0,
        0,
        0,
        "startProxyDelayTest custom prototype context");
    expect_equal(g_proxy_backend.delay_start_calls, 0, "custom prototype should not call delay start backend");
  }

  {
    FakeValue *context = build_valid_context_with_null_prototype(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, "group-a"));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a"},
        0,
        0,
        0,
        "startProxyDelayTest null prototype context");
    expect_equal(g_proxy_backend.delay_start_calls, 0, "null prototype should not call delay start backend");
  }

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::read_proxy_delay_test(
            reinterpret_cast<napi_env>(call_env), reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, state})));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      {},
      0,
      0,
      0,
      "readProxyDelayTest too few args");
  expect_equal(g_proxy_backend.delay_snapshot_calls, 0, "too few args should not call delay snapshot backend");

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::cancel_proxy_delay_test(
            reinterpret_cast<napi_env>(call_env),
            reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{
                {make_string(call_env, "0123456789abcdef0123456789abcdef"), make_string(call_env, "extra")},
                state,
            })));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      {"0123456789abcdef0123456789abcdef", "extra"},
      0,
      0,
      0,
      "cancelProxyDelayTest too many args");
  expect_equal(g_proxy_backend.delay_cancel_calls, 0, "too many args should not call delay cancel backend");
}

void test_proxy_delay_rejects_context_group_and_job_inputs() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "generation", make_number(env.get(), 0));
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, "group-a"));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a"},
        0,
        0,
        0,
        "startProxyDelayTest zero generation");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "sessionHash", reinterpret_cast<FakeValue *>(env.get()->null_value));
    FakeValue *promise = invoke_start_proxy_delay_test(env.get(), addon.get(), context, make_string(env.get(), "group-a"));
    FakeValue *result = await_promise(env.get(), promise, "null session startProxyDelayTest should settle");
    expect(promise->promise_resolved, "null session startProxyDelayTest should resolve");
    expect_equal(result->string_value, std::string("{\"kind\":\"delay-start\"}"),
                 "null session startProxyDelayTest should resolve backend payload");
    expect_equal(g_proxy_backend.delay_start_calls, 1, "null session should reach delay start backend");
    expect(g_proxy_backend.saw_null_session, "null session should clear session hash before backend");
  }

  reset_proxy_backend();
  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, ""));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
        0,
        0,
        0,
        "startProxyDelayTest empty group");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(
              call_env, state, context, make_string(call_env, std::string(CMFA_MAX_PROXY_NAME_UTF8_BYTES + 1U, 'x')));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        {std::string(CMFA_MAX_PROXY_NAME_UTF8_BYTES + 1U, 'x')},
        0,
        0,
        0,
        "startProxyDelayTest oversized group");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_start_proxy_delay_test(call_env, state, context, make_string(call_env, "bad\x01"));
        },
        addon.get(),
        "CMFA_INVALID_UTF8",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "bad\x01"},
        0,
        0,
        0,
        "startProxyDelayTest control group");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcdeF");
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {"0123456789abcdef0123456789abcdeF"},
        0,
        0,
        0,
        "readProxyDelayTest uppercase job");
    expect_equal(g_proxy_backend.delay_snapshot_calls, 0, "uppercase job should not call delay snapshot backend");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcde");
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_cancel_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {"0123456789abcdef0123456789abcde"},
        0,
        0,
        0,
        "cancelProxyDelayTest short job");
    expect_equal(g_proxy_backend.delay_cancel_calls, 0, "short job should not call delay cancel backend");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcdef0");
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {"0123456789abcdef0123456789abcdef0"},
        0,
        0,
        0,
        "readProxyDelayTest long job");
    expect_equal(g_proxy_backend.delay_snapshot_calls, 0, "long job should not call delay snapshot backend");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcdeg");
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_cancel_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {"0123456789abcdef0123456789abcdeg"},
        0,
        0,
        0,
        "cancelProxyDelayTest non-hex job");
    expect_equal(g_proxy_backend.delay_cancel_calls, 0, "non-hex job should not call delay cancel backend");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcde\x01");
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_read_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {"0123456789abcdef0123456789abcde\x01"},
        0,
        0,
        0,
        "readProxyDelayTest control job");
    expect_equal(g_proxy_backend.delay_snapshot_calls, 0, "control job should not call delay snapshot backend");
  }

  {
    FakeValue *job = make_string(env.get(), "0123456789abcdef0123456789abcdef");
    job->force_string_read_failure = true;
    expect_sync_throw_without_side_effects(
        env.get(),
        [job](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_cancel_proxy_delay_test(call_env, state, job);
        },
        addon.get(),
        "CMFA_INVALID_UTF8",
        {"0123456789abcdef0123456789abcdef"},
        0,
        0,
        0,
        "cancelProxyDelayTest string read failure");
    expect_equal(g_proxy_backend.delay_cancel_calls, 0, "string read failure should not call delay cancel backend");
  }
}

void test_proxy_delay_resolves_rejects_and_copies_inputs() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.block = true;
    g_proxy_backend.delay_start_payload = "{\"kind\":\"delay-start\",\"ok\":true}";
  }

  FakeValue *context = build_valid_context(env.get());
  FakeValue *group_name = make_string(env.get(), "节点-東京");
  FakeValue *start_promise = invoke_start_proxy_delay_test(env.get(), addon.get(), context, group_name);
  expect(start_promise != nullptr && start_promise->type == FakeType::Promise,
         "startProxyDelayTest should return a promise");

  set_named_prop(context, "profileHash", make_hash(env.get(), 'd'));
  set_named_prop(context, "generation", make_number(env.get(), 99));
  group_name->string_value = "mutated";
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.allow = true;
  }
  g_proxy_backend.cv.notify_all();

  FakeValue *start_result = await_promise(env.get(), start_promise, "startProxyDelayTest should settle");
  expect(start_promise->promise_resolved, "startProxyDelayTest should resolve");
  expect_equal(start_result->string_value,
               std::string("{\"kind\":\"delay-start\",\"ok\":true}"),
               "startProxyDelayTest should resolve payload");

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    expect_equal(std::string(g_proxy_backend.last_query.profile_hash), std::string(64, 'a'),
                 "delay start should copy original profile hash");
    expect_equal(g_proxy_backend.last_query.generation, static_cast<uint64_t>(7),
                 "delay start should copy original generation");
    expect_equal(g_proxy_backend.last_group_name, std::string("节点-東京"),
                 "delay start should copy original group name");
  }

  reset_proxy_backend();
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.delay_snapshot_payload = "{\"kind\":\"delay-snapshot\",\"state\":\"ok\"}";
    g_proxy_backend.delay_cancel_status = CMFA_BUSY;
  }

  FakeValue *job_id = make_string(env.get(), "0123456789abcdef0123456789abcdef");
  FakeValue *snapshot_promise = invoke_read_proxy_delay_test(env.get(), addon.get(), job_id);
  job_id->string_value = "mutated-mutated-mutated-mutated";
  FakeValue *snapshot_result = await_promise(env.get(), snapshot_promise, "readProxyDelayTest should settle");
  expect(snapshot_promise->promise_resolved, "readProxyDelayTest should resolve");
  expect_equal(snapshot_result->string_value,
               std::string("{\"kind\":\"delay-snapshot\",\"state\":\"ok\"}"),
               "readProxyDelayTest should resolve payload");
  expect_equal(g_proxy_backend.last_delay_job_id,
               std::string("0123456789abcdef0123456789abcdef"),
               "readProxyDelayTest should forward original job id");

  FakeValue *busy_promise =
      invoke_cancel_proxy_delay_test(env.get(), addon.get(), make_string(env.get(), "0123456789abcdef0123456789abcdef"));
  FakeValue *busy_error = await_promise(env.get(), busy_promise, "cancelProxyDelayTest busy should settle");
  expect(busy_promise->promise_rejected, "cancelProxyDelayTest busy should reject");
  expect_equal(get_named_prop(busy_error, "code")->string_value, std::string("CMFA_BUSY"),
               "cancelProxyDelayTest should preserve busy code");
  expect_error_sanitized(
      busy_error, {"0123456789abcdef0123456789abcdef", "{\"kind\":\"delay-cancel\"}"}, "cancelProxyDelayTest busy rejection");

  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "delay operations should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "delay operations should release deliveries");
}

void test_proxy_delay_rejects_queue_failure_and_malformed_backend_output() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  env->next_tsfn_call_status = napi_generic_failure;
  FakeValue *queue_failure_promise =
      invoke_read_proxy_delay_test(env.get(), addon.get(), make_string(env.get(), "0123456789abcdef0123456789abcdef"));
  FakeValue *queue_failure_error = await_promise(env.get(), queue_failure_promise, "delay queue failure should settle");
  expect(queue_failure_promise->promise_rejected, "delay queue failure should reject");
  expect_equal(get_named_prop(queue_failure_error, "code")->string_value,
               std::string("NAPI_FAILURE"),
               "delay queue failure should sanitize");

  const struct Case {
    ProxyOutputMode mode;
    const char *label;
  } cases[] = {
      {ProxyOutputMode::UnexpectedBufferTooSmall, "unexpected buffer-too-small"},
      {ProxyOutputMode::InvalidUtf8, "invalid utf8"},
      {ProxyOutputMode::MissingNul, "missing nul"},
      {ProxyOutputMode::TooLarge, "too large"},
      {ProxyOutputMode::Overrun, "overrun"},
  };

  for (const Case &entry : cases) {
    reset_proxy_backend();
    {
      std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
      g_proxy_backend.delay_snapshot_mode = entry.mode;
      if (entry.mode == ProxyOutputMode::TooLarge) {
        g_proxy_backend.delay_snapshot_payload.assign(CMFA_MAX_PROXY_JSON_BYTES, 'x');
      }
    }
    FakeValue *promise =
        invoke_read_proxy_delay_test(env.get(), addon.get(), make_string(env.get(), "0123456789abcdef0123456789abcdef"));
    FakeValue *error = await_promise(env.get(), promise, std::string(entry.label) + " delay read should settle");
    expect(promise->promise_rejected, std::string(entry.label) + " delay read should reject");
    expect_equal(get_named_prop(error, "code")->string_value,
                 std::string("CMFA_BACKEND_ERROR"),
                 std::string(entry.label) + " delay read should reject as bridge invalid");
    expect_error_sanitized(error,
                           {"0123456789abcdef0123456789abcdef", g_proxy_backend.delay_snapshot_payload},
                           std::string(entry.label) + " delay read rejection");
  }
}

void test_proxy_delay_supports_buffer_cap_and_cleanup_with_pending_work() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.delay_snapshot_payload.assign(CMFA_MAX_PROXY_JSON_BYTES, 'z');
  }
  FakeValue *max_payload_promise =
      invoke_read_proxy_delay_test(env.get(), addon.get(), make_string(env.get(), "0123456789abcdef0123456789abcdef"));
  FakeValue *max_payload_result = await_promise(env.get(), max_payload_promise, "max sized delay snapshot should settle");
  expect(max_payload_promise->promise_resolved, "max sized delay snapshot should resolve");
  expect_equal(max_payload_result->string_value.size(),
               static_cast<size_t>(CMFA_MAX_PROXY_JSON_BYTES),
               "max sized delay snapshot should preserve exact length");
  expect_equal(env->off_thread_env_api_calls.load(std::memory_order_relaxed),
               0,
               "delay worker must not call env-thread NAPI APIs");

  reset_proxy_backend();
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.block = true;
  }

  FakeValue *pending_promise =
      invoke_start_proxy_delay_test(env.get(), addon.get(), build_valid_context(env.get()), make_string(env.get(), "group-a"));
  expect(pending_promise != nullptr && pending_promise->type == FakeType::Promise,
         "pending startProxyDelayTest should return promise");

  cmfa::napi::CleanupResult cleanup{};
  std::thread cleanup_thread([&] { cleanup = addon->owner.cleanup(); });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.allow = true;
  }
  g_proxy_backend.cv.notify_all();
  cleanup_thread.join();

  for (int attempt = 0; attempt < 30; attempt += 1) {
    pump_env(env.get());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  expect_equal(cleanup.shutdown_status, CMFA_OK, "delay cleanup should succeed");
  expect(!pending_promise->promise_resolved, "delay cleanup should not resolve a pending promise");
  expect(!pending_promise->promise_rejected, "delay cleanup should not reject a pending promise");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "delay cleanup should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "delay cleanup should release deliveries");
}

void test_query_proxy_rejects_argc_and_context_shape() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  expect_sync_throw_code(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::query_proxy_groups(
            reinterpret_cast<napi_env>(call_env), reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{}, state})));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      "queryProxyGroups argc");

  expect_sync_throw_code(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return invoke_query_proxy_group(call_env, state, make_number(call_env, 1), make_string(call_env, "a"));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      "queryProxyGroup non-object context");

  expect_sync_throw_without_side_effects(
      env.get(),
      [](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
        return invoke_select_proxy(call_env,
                                   state,
                                   make_number(call_env, 1),
                                   make_string(call_env, "group-a"),
                                   make_string(call_env, "member-b"));
      },
      addon.get(),
      "CMFA_INVALID_ARGUMENT",
      {"group-a", "member-b"},
      0,
      0,
      0,
      "selectProxy non-object context");

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "extra", make_string(env.get(), "boom"));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "context extra key");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    remove_named_prop(context, "generation");
    set_prototype_prop(context, "generation", make_number(env.get(), 7));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "inherited generation");
  }

  {
    FakeValue *context = build_valid_context_with_custom_prototype(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_group(call_env, state, context, make_string(call_env, "group-a"));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a"},
        0,
        0,
        0,
        "queryProxyGroup custom prototype context");
  }

  {
    FakeValue *context = build_valid_context_with_custom_prototype(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_select_proxy(
              call_env, state, context, make_string(call_env, "group-a"), make_string(call_env, "member-b"));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a", "member-b"},
        0,
        0,
        0,
        "selectProxy custom prototype context");
  }

  {
    FakeValue *context = build_valid_context_with_non_enumerable_extra(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "hidden", "secret"},
        0,
        0,
        0,
        "queryProxyGroups non-enumerable own key");
  }

  {
    FakeValue *context = build_valid_context_with_symbol_extra(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "extra"},
        0,
        0,
        0,
        "queryProxyGroups symbol own key");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::query_proxy_group(
              reinterpret_cast<napi_env>(call_env),
              reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{{context}, state})));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
        0,
        0,
        0,
        "queryProxyGroup too few args");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::query_proxy_group(
              reinterpret_cast<napi_env>(call_env),
              reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{
                  {context, make_string(call_env, "group-a"), make_string(call_env, "extra")},
                  state,
              })));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a", "extra"},
        0,
        0,
        0,
        "queryProxyGroup too many args");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::select_proxy(
              reinterpret_cast<napi_env>(call_env),
              reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{
                  {context, make_string(call_env, "group-a")},
                  state,
              })));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a"},
        0,
        0,
        0,
        "selectProxy too few args");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_without_side_effects(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return reinterpret_cast<FakeValue *>(cmfa::nodeaddon::select_proxy(
              reinterpret_cast<napi_env>(call_env),
              reinterpret_cast<napi_callback_info>(new FakeCallbackInfo{
                  {context,
                   make_string(call_env, "group-a"),
                   make_string(call_env, "member-b"),
                   make_string(call_env, "extra")},
                  state,
              })));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c'), "group-a", "member-b", "extra"},
        0,
        0,
        0,
        "selectProxy too many args");
  }
}

void test_query_proxy_rejects_custom_and_null_prototype_contexts() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    FakeValue *context = build_valid_context_with_custom_prototype(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "custom prototype context");
    expect_equal(g_proxy_backend.groups_calls, 0, "custom prototype should reject before backend");
    expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "custom prototype should not queue async work");
  }

  {
    FakeValue *context = build_valid_context_with_null_prototype(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "null prototype context");
    expect_equal(g_proxy_backend.groups_calls, 0, "null prototype should reject before backend");
    expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "null prototype should not queue async work");
  }
}

void test_query_proxy_accepts_ordinary_object_literal_prototype() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    FakeValue *promise =
        invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), true));
    FakeValue *result = await_promise(env.get(), promise, "ordinary object literal prototype should settle");
    expect(promise->promise_resolved, "ordinary object literal prototype should resolve");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"), "ordinary object literal prototype should pass");
    expect_equal(g_proxy_backend.groups_calls, 1, "ordinary object literal prototype should reach backend");
  }

  reset_proxy_backend();
  {
    FakeValue *promise = invoke_query_proxy_groups(
        env.get(), addon.get(), build_valid_context_with_data_class_prototype(env.get()), make_boolean(env.get(), true));
    FakeValue *result = await_promise(env.get(), promise, "data class prototype should settle");
    expect(promise->promise_resolved, "data class prototype should resolve");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"), "data class prototype should pass");
    expect_equal(g_proxy_backend.groups_calls, 1, "data class prototype should reach backend");
  }

  reset_proxy_backend();
  remove_named_prop(env.get()->global, "Object");
  {
    FakeValue *promise =
        invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), false));
    FakeValue *result = await_promise(env.get(), promise, "ordinary object should validate without global.Object");
    expect(promise->promise_resolved, "ordinary object should resolve without global.Object");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"), "ordinary object should ignore removed global.Object");
  }

  reset_proxy_backend();
  set_named_prop(env.get()->global, "Object", make_number(env.get(), 42));
  {
    FakeValue *promise =
        invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), false));
    FakeValue *result = await_promise(env.get(), promise, "ordinary object should validate with monkey-patched global.Object");
    expect(promise->promise_resolved, "ordinary object should resolve with monkey-patched global.Object");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"),
                 "ordinary object should ignore monkey-patched global.Object");
  }

  reset_proxy_backend();
  env.get()->fail_global_object_lookup = true;
  env.get()->fail_object_prototype_lookup = true;
  {
    FakeValue *promise =
        invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), false));
    FakeValue *result =
        await_promise(env.get(), promise, "ordinary object should validate even if global.Object/prototype lookup would fail");
    expect(promise->promise_resolved, "ordinary object should resolve without any global.Object/prototype dependency");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"),
                 "ordinary object should ignore failing global.Object/prototype lookups");
  }
  env.get()->fail_global_object_lookup = false;
  env.get()->fail_object_prototype_lookup = false;
}

void test_query_proxy_normalizes_prototype_napi_failures() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    env->fail_create_object = true;
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "NAPI_FAILURE",
        "create object failure");
    expect_error_sanitized(env->last_thrown,
                           {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
                           "create object failure");
    expect_equal(g_proxy_backend.groups_calls, 0, "create object failure should reject before backend");
    env->fail_create_object = false;
  }

  {
    env->fail_get_prototype = true;
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "NAPI_FAILURE",
        "get prototype failure");
    expect_error_sanitized(env->last_thrown,
                           {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
                           "get prototype failure");
    expect_equal(g_proxy_backend.groups_calls, 0, "get prototype failure should reject before backend");
    env->fail_get_prototype = false;
  }

  {
    env->fail_strict_equals = true;
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "NAPI_FAILURE",
        "strict equals failure");
    expect_error_sanitized(env->last_thrown,
                           {std::string(64, 'a'), std::string(64, 'b'), std::string(64, 'c')},
                           "strict equals failure");
    expect_equal(g_proxy_backend.groups_calls, 0, "strict equals failure should reject before backend");
    env->fail_strict_equals = false;
  }
}

void test_query_proxy_rejects_hash_session_generation_and_name_inputs() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "profileHash", make_string(env.get(), std::string(63, 'a')));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "short profile hash");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "revisionHash", make_string(env.get(), std::string(64, 'A')));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "uppercase revision hash");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "sessionHash", reinterpret_cast<FakeValue *>(env.get()->null_value));
    FakeValue *promise = invoke_query_proxy_groups(env.get(), addon.get(), context, make_boolean(env.get(), true));
    FakeValue *result = await_promise(env.get(), promise, "null session queryProxyGroups should settle");
    expect(promise->promise_resolved, "null session should resolve");
    expect_equal(result->string_value, std::string("{\"kind\":\"groups\"}"), "null session should still resolve payload");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "sessionHash", make_string(env.get(), "bad"));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "invalid session hash");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "generation", make_number(env.get(), 0));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "zero generation");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    set_named_prop(context, "generation", make_number(env.get(), kMaxSafeInteger + 1.0));
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_boolean(call_env, false));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "generation above MAX_SAFE_INTEGER");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_groups(call_env, state, context, make_number(call_env, 1));
        },
        addon.get(),
        "CMFA_INVALID_ARGUMENT",
        "non-boolean selectableOnly");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_group(call_env, state, context, make_string(call_env, ""));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "empty group name");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_group(call_env, state, context, make_string(call_env, std::string(257, 'x')));
        },
        addon.get(),
        "CMFA_OUT_OF_RANGE",
        "oversized group name");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    FakeValue *bad = make_string(env.get(), "abc");
    bad->force_string_read_failure = true;
    expect_sync_throw_code(
        env.get(),
        [context, bad](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_query_proxy_group(call_env, state, context, bad);
        },
        addon.get(),
        "CMFA_INVALID_UTF8",
        "invalid UTF-8 group name");
  }

  {
    FakeValue *context = build_valid_context(env.get());
    expect_sync_throw_code(
        env.get(),
        [context](FakeEnv *call_env, cmfa::nodeaddon::AddonState *state) {
          return invoke_select_proxy(call_env, state, context, make_string(call_env, "alpha"), make_string(call_env, "bad\x01"));
        },
        addon.get(),
        "CMFA_INVALID_UTF8",
        "control member name");
  }
}

void test_query_proxy_resolves_and_copies_env_thread_inputs() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.block = true;
    g_proxy_backend.group_payload = "{\"kind\":\"group\",\"ok\":true}";
  }

  FakeValue *context = build_valid_context(env.get());
  FakeValue *name = make_string(env.get(), "节点-東京");
  FakeValue *promise = invoke_query_proxy_group(env.get(), addon.get(), context, name);
  expect(promise != nullptr && promise->type == FakeType::Promise, "queryProxyGroup should return a promise");

  set_named_prop(context, "profileHash", make_hash(env.get(), 'd'));
  set_named_prop(context, "generation", make_number(env.get(), 99));
  name->string_value = "mutated";
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.allow = true;
  }
  g_proxy_backend.cv.notify_all();

  FakeValue *result = await_promise(env.get(), promise, "queryProxyGroup promise should settle");
  expect(promise->promise_resolved, "queryProxyGroup should resolve");
  expect_equal(result->string_value, std::string("{\"kind\":\"group\",\"ok\":true}"), "resolved payload should match");

  std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
  expect_equal(std::string(g_proxy_backend.last_query.profile_hash), std::string(64, 'a'),
               "worker should copy original profile hash");
  expect_equal(g_proxy_backend.last_query.generation, static_cast<uint64_t>(7), "worker should copy original generation");
  expect_equal(g_proxy_backend.last_group_name, std::string("节点-東京"), "worker should copy original group name");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "async handles should release after resolve");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "deliveries should release after resolve");
}

void test_query_proxy_rejects_busy_queue_failure_and_tsfn_creation_failure() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.select_status = CMFA_BUSY;
  }
  FakeValue *busy_promise = invoke_select_proxy(
      env.get(), addon.get(), build_valid_context(env.get()), make_string(env.get(), "group-a"), make_string(env.get(), "成员"));
  FakeValue *busy_error = await_promise(env.get(), busy_promise, "busy selectProxy should settle");
  expect(busy_promise->promise_rejected, "busy selectProxy should reject");
  expect_equal(get_named_prop(busy_error, "code")->string_value, std::string("CMFA_BUSY"), "busy error should preserve code");
  expect_error_sanitized(busy_error, {"group-a", "成员", "{\"kind\":\"select\"}"}, "busy rejection");

  env->next_tsfn_call_status = napi_generic_failure;
  FakeValue *queue_failure_promise =
      invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), false));
  FakeValue *queue_failure_error = await_promise(env.get(), queue_failure_promise, "queue failure should settle");
  expect(queue_failure_promise->promise_rejected, "queue failure should reject");
  expect_equal(
      get_named_prop(queue_failure_error, "code")->string_value, std::string("NAPI_FAILURE"), "queue failure should sanitize");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "queue failure should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "queue failure should release deliveries");

  env->fail_create_tsfn = true;
  FakeValue *creation_promise =
      invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), true));
  expect(creation_promise != nullptr && creation_promise->type == FakeType::Promise, "TSFN creation failure should still return promise");
  FakeValue *creation_error = await_promise(env.get(), creation_promise, "TSFN creation failure should settle");
  expect(creation_promise->promise_rejected, "TSFN creation failure should reject");
  expect_equal(get_named_prop(creation_error, "code")->string_value, std::string("NAPI_FAILURE"),
               "TSFN creation failure should reject with NAPI_FAILURE");
}

void test_query_proxy_rejects_unexpected_buffer_and_malformed_backend_output() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  const struct Case {
    ProxyOutputMode mode;
    const char *label;
  } cases[] = {
      {ProxyOutputMode::UnexpectedBufferTooSmall, "unexpected buffer-too-small"},
      {ProxyOutputMode::InvalidUtf8, "invalid utf8"},
      {ProxyOutputMode::MissingNul, "missing nul"},
      {ProxyOutputMode::TooLarge, "too large"},
      {ProxyOutputMode::Overrun, "overrun"},
  };

  for (const Case &entry : cases) {
    reset_proxy_backend();
    {
      std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
      g_proxy_backend.group_mode = entry.mode;
      if (entry.mode == ProxyOutputMode::TooLarge) {
        g_proxy_backend.group_payload.assign(CMFA_MAX_PROXY_JSON_BYTES, 'x');
      }
    }
    FakeValue *promise =
        invoke_query_proxy_group(env.get(), addon.get(), build_valid_context(env.get()), make_string(env.get(), "group-a"));
    FakeValue *error = await_promise(env.get(), promise, std::string(entry.label) + " should settle");
    expect(promise->promise_rejected, std::string(entry.label) + " should reject");
    expect_equal(get_named_prop(error, "code")->string_value, std::string("CMFA_BACKEND_ERROR"),
                 std::string(entry.label) + " should reject as bridge invalid");
    expect_error_sanitized(error, {"group-a", g_proxy_backend.group_payload}, std::string(entry.label) + " rejection");
    expect_equal(addon->owner.async_count(), static_cast<size_t>(0), std::string(entry.label) + " should release async handles");
    expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0),
                 std::string(entry.label) + " should release deliveries");
  }
}

void test_query_proxy_supports_max_sized_json_and_no_off_thread_napi() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);

  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.groups_payload.assign(CMFA_MAX_PROXY_JSON_BYTES, 'z');
  }
  FakeValue *promise =
      invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), true));
  FakeValue *result = await_promise(env.get(), promise, "max sized groups payload should settle");
  expect(promise->promise_resolved, "max sized groups payload should resolve");
  expect_equal(result->string_value.size(), static_cast<size_t>(CMFA_MAX_PROXY_JSON_BYTES),
               "max sized groups payload should preserve exact length");
  expect_equal(env->off_thread_env_api_calls.load(std::memory_order_relaxed), 0, "worker must not call env-thread NAPI APIs");
}

void test_query_proxy_cleanup_with_pending_work_does_not_settle_or_leak() {
  reset_proxy_backend();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv *)> env(create_env(), destroy_env);
  LifecycleContext lifecycle;
  auto addon = make_addon(env.get(), &lifecycle);
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.block = true;
  }

  FakeValue *promise =
      invoke_query_proxy_groups(env.get(), addon.get(), build_valid_context(env.get()), make_boolean(env.get(), false));
  expect(promise != nullptr && promise->type == FakeType::Promise, "pending queryProxyGroups should return promise");

  cmfa::napi::CleanupResult cleanup{};
  std::thread cleanup_thread([&] { cleanup = addon->owner.cleanup(); });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  {
    std::lock_guard<std::mutex> lock(g_proxy_backend.mutex);
    g_proxy_backend.allow = true;
  }
  g_proxy_backend.cv.notify_all();
  cleanup_thread.join();

  for (int attempt = 0; attempt < 30; attempt += 1) {
    pump_env(env.get());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  expect_equal(cleanup.shutdown_status, CMFA_OK, "cleanup should succeed");
  expect(!promise->promise_resolved, "cleanup should not resolve a pending proxy promise");
  expect(!promise->promise_rejected, "cleanup should not reject a pending proxy promise");
  expect_equal(addon->owner.async_count(), static_cast<size_t>(0), "cleanup should release async handles");
  expect_equal(addon->owner.delivery_count(), static_cast<size_t>(0), "cleanup should release deliveries");
}

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"define_core_module_registers_proxy_exports", test_define_core_module_registers_proxy_exports},
      {"query_proxy_rejects_argc_and_context_shape", test_query_proxy_rejects_argc_and_context_shape},
      {"query_proxy_rejects_custom_and_null_prototype_contexts",
       test_query_proxy_rejects_custom_and_null_prototype_contexts},
      {"query_proxy_accepts_ordinary_object_literal_prototype",
       test_query_proxy_accepts_ordinary_object_literal_prototype},
      {"query_proxy_normalizes_prototype_napi_failures", test_query_proxy_normalizes_prototype_napi_failures},
      {"query_proxy_rejects_hash_session_generation_and_name_inputs",
       test_query_proxy_rejects_hash_session_generation_and_name_inputs},
      {"query_proxy_resolves_and_copies_env_thread_inputs", test_query_proxy_resolves_and_copies_env_thread_inputs},
      {"query_proxy_rejects_busy_queue_failure_and_tsfn_creation_failure",
       test_query_proxy_rejects_busy_queue_failure_and_tsfn_creation_failure},
      {"query_proxy_rejects_unexpected_buffer_and_malformed_backend_output",
       test_query_proxy_rejects_unexpected_buffer_and_malformed_backend_output},
      {"query_proxy_supports_max_sized_json_and_no_off_thread_napi",
       test_query_proxy_supports_max_sized_json_and_no_off_thread_napi},
      {"query_proxy_cleanup_with_pending_work_does_not_settle_or_leak",
       test_query_proxy_cleanup_with_pending_work_does_not_settle_or_leak},
      {"proxy_delay_rejects_argc_context_shape_and_missing_addon",
       test_proxy_delay_rejects_argc_context_shape_and_missing_addon},
      {"proxy_delay_rejects_context_group_and_job_inputs", test_proxy_delay_rejects_context_group_and_job_inputs},
      {"proxy_delay_resolves_rejects_and_copies_inputs", test_proxy_delay_resolves_rejects_and_copies_inputs},
      {"proxy_delay_rejects_queue_failure_and_malformed_backend_output",
       test_proxy_delay_rejects_queue_failure_and_malformed_backend_output},
      {"proxy_delay_supports_buffer_cap_and_cleanup_with_pending_work",
       test_proxy_delay_supports_buffer_cap_and_cleanup_with_pending_work},
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
