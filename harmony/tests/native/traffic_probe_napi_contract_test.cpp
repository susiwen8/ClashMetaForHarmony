#include "../../traffic-probe/entry/src/main/cpp/probe_native_core.h"

#include "node_api.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

class TestFailure : public std::runtime_error {
 public:
  explicit TestFailure(const std::string& message) : std::runtime_error(message) {}
};

void expect(bool condition, const std::string& message) {
  if (!condition) {
    throw TestFailure(message);
  }
}

template <typename T, typename U>
void expect_equal(const T& actual, const U& expected, const std::string& message) {
  if (!(actual == expected)) {
    throw TestFailure(message);
  }
}

void expect_strings(const std::vector<std::string>& actual,
                    const std::vector<std::string>& expected,
                    const std::string& message) {
  if (actual != expected) {
    throw TestFailure(message);
  }
}

constexpr const char* kExpectedInvalidArgCode = "ERR_INVALID_ARG";
constexpr const char* kExpectedInvalidArgMessage = "probeSocket request is invalid";
constexpr const char* kExpectedAsyncFailureCode = "ERR_BRIDGE_FAILURE";
constexpr const char* kExpectedAsyncFailureMessage = "probeSocket failed";
constexpr double kTestMaxSafeInteger = 9007199254740991.0;
constexpr size_t kTestMaxTcpPayloadBytes = 8192;
constexpr size_t kTestMaxUdpPayloadBytes = 1024;

struct napi_module {
  int nm_version;
  unsigned int nm_flags;
  const char* nm_filename;
  napi_value (*nm_register_func)(napi_env env, napi_value exports);
  const char* nm_modname;
  void* nm_priv;
};

struct FakeValue;
struct FakeDeferred;
struct FakeCallbackInfo;
struct FakeAsyncWork;
struct FakeEnv;

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
  ArrayBuffer,
};

struct FakeValue {
  FakeType type = FakeType::Undefined;
  bool bool_value = false;
  double number_value = 0;
  std::string string_value;
  std::unordered_map<std::string, FakeValue*> object_props;
  std::vector<std::string> object_keys;
  std::vector<FakeValue*> array_items;
  std::vector<uint8_t> bytes;
  bool force_null_arraybuffer_data = false;
  bool force_throw_string_read = false;
  napi_callback native_callback = nullptr;
  void* native_data = nullptr;
  bool promise_resolved = false;
  bool promise_rejected = false;
  FakeValue* promise_result = nullptr;
};

struct FakeDeferred {
  FakeValue* promise = nullptr;
};

struct FakeCallbackInfo {
  std::vector<FakeValue*> args;
  void* data = nullptr;
};

struct PendingCompletion {
  FakeAsyncWork* work = nullptr;
  napi_status status = napi_ok;
};

struct FakeAsyncWork {
  FakeEnv* env = nullptr;
  void* data = nullptr;
  napi_async_execute_callback execute = nullptr;
  napi_async_complete_callback complete = nullptr;
  bool queued = false;
  bool deleted = false;
  std::thread worker;
};

struct FakeEnv {
  std::vector<std::unique_ptr<FakeValue>> values;
  std::vector<std::unique_ptr<FakeDeferred>> deferreds;
  std::vector<std::unique_ptr<FakeAsyncWork>> async_works;
  FakeValue* undefined_value = nullptr;
  FakeValue* null_value = nullptr;
  FakeValue* last_thrown = nullptr;
  std::thread::id env_thread_id{};
  std::mutex mutex;
  std::condition_variable cv;
  std::vector<PendingCompletion> pending_completions;
  std::atomic<int> off_thread_env_api_calls{0};
  int create_promise_calls = 0;
  int create_async_work_calls = 0;
  int queue_async_work_calls = 0;
  int delete_async_work_calls = 0;
  int execute_async_work_calls = 0;
  int complete_async_work_calls = 0;
  napi_status next_create_async_work_status = napi_ok;
  napi_status next_queue_async_work_status = napi_ok;
  napi_status next_complete_async_work_status = napi_ok;
  bool fail_probe_socket_resource_name_create = false;
  bool throw_on_create_object = false;
  size_t max_string_copy_bufsize = 0;
  std::vector<std::string> copied_strings;
};

const napi_module* g_registered_module = nullptr;
int g_module_register_calls = 0;

void note_env_call(FakeEnv* env) {
  if (env == nullptr) {
    return;
  }
  if (std::this_thread::get_id() != env->env_thread_id) {
    env->off_thread_env_api_calls.fetch_add(1, std::memory_order_relaxed);
  }
}

FakeValue* allocate_value(FakeEnv* env, FakeType type) {
  env->values.push_back(std::make_unique<FakeValue>());
  FakeValue* value = env->values.back().get();
  value->type = type;
  return value;
}

FakeValue* make_string(FakeEnv* env, const std::string& value) {
  FakeValue* result = allocate_value(env, FakeType::String);
  result->string_value = value;
  return result;
}

FakeValue* make_number(FakeEnv* env, double value) {
  FakeValue* result = allocate_value(env, FakeType::Number);
  result->number_value = value;
  return result;
}

FakeValue* make_boolean(FakeEnv* env, bool value) {
  FakeValue* result = allocate_value(env, FakeType::Boolean);
  result->bool_value = value;
  return result;
}

FakeValue* make_object(FakeEnv* env) {
  return allocate_value(env, FakeType::Object);
}

FakeValue* make_array(FakeEnv* env, size_t length = 0) {
  FakeValue* result = allocate_value(env, FakeType::Array);
  result->array_items.resize(length, env->undefined_value);
  return result;
}

FakeValue* make_arraybuffer(FakeEnv* env, const std::vector<uint8_t>& bytes) {
  FakeValue* result = allocate_value(env, FakeType::ArrayBuffer);
  result->bytes = bytes;
  return result;
}

FakeValue* make_arraybuffer_with_null_data(FakeEnv* env, const std::vector<uint8_t>& bytes) {
  FakeValue* result = make_arraybuffer(env, bytes);
  result->force_null_arraybuffer_data = true;
  return result;
}

FakeValue* make_function(FakeEnv* env, napi_callback callback, void* data) {
  FakeValue* result = allocate_value(env, FakeType::Function);
  result->native_callback = callback;
  result->native_data = data;
  return result;
}

void set_named_prop(FakeValue* object, const std::string& name, FakeValue* value) {
  if (object->object_props.find(name) == object->object_props.end()) {
    object->object_keys.push_back(name);
  }
  object->object_props[name] = value;
}

FakeValue* get_named_prop(FakeValue* object, const std::string& name) {
  const auto found = object->object_props.find(name);
  if (found == object->object_props.end()) {
    return nullptr;
  }
  return found->second;
}

FakeEnv* create_env() {
  auto* env = new FakeEnv();
  env->env_thread_id = std::this_thread::get_id();
  env->undefined_value = allocate_value(env, FakeType::Undefined);
  env->null_value = allocate_value(env, FakeType::Null);
  return env;
}

void destroy_env(FakeEnv* env) {
  if (env == nullptr) {
    return;
  }
  for (auto& work : env->async_works) {
    if (work->worker.joinable()) {
      work->worker.join();
    }
  }
  delete env;
}

std::string error_text(FakeValue* error) {
  if (error == nullptr) {
    return std::string();
  }
  std::string code;
  if (FakeValue* code_value = get_named_prop(error, "code")) {
    code = code_value->string_value;
  }
  std::string message;
  if (FakeValue* message_value = get_named_prop(error, "message")) {
    message = message_value->string_value;
  }
  return code + "|" + message;
}

void expect_sanitized(FakeValue* error, const std::vector<std::string>& forbidden, const std::string& message) {
  const std::string text = error_text(error);
  for (const std::string& item : forbidden) {
    expect(text.find(item) == std::string::npos, message + " leaked \"" + item + "\"");
  }
  expect(text.find(".invalid") == std::string::npos, message + " leaked invalid label");
  expect(text.find("EINVAL") == std::string::npos, message + " leaked errno text");
  expect(text.find("system") == std::string::npos, message + " leaked system prose");
}

void expect_not_copied(FakeEnv* env, const std::string& text, const std::string& message) {
  expect(std::find(env->copied_strings.begin(), env->copied_strings.end(), text) == env->copied_strings.end(), message);
}

void pump_env(FakeEnv* env) {
  std::vector<PendingCompletion> completions;
  {
    std::lock_guard<std::mutex> lock(env->mutex);
    completions.swap(env->pending_completions);
  }

  for (PendingCompletion& completion : completions) {
    FakeAsyncWork* work = completion.work;
    if (work->worker.joinable()) {
      work->worker.join();
    }
    env->complete_async_work_calls += 1;
    work->complete(reinterpret_cast<napi_env>(env), completion.status, work->data);
  }
}

FakeValue* await_promise(FakeEnv* env, FakeValue* promise, const std::string& message) {
  expect(promise != nullptr && promise->type == FakeType::Promise, message + ": expected promise");
  for (int attempt = 0; attempt < 200; attempt += 1) {
    pump_env(env);
    if (promise->promise_resolved || promise->promise_rejected) {
      return promise->promise_result;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  throw TestFailure(message + ": promise did not settle");
}

FakeValue* invoke_function(FakeEnv* env, FakeValue* function, const std::vector<FakeValue*>& args) {
  expect(function != nullptr && function->type == FakeType::Function, "invoke_function expects function");
  FakeCallbackInfo info;
  info.args = args;
  info.data = function->native_data;
  return reinterpret_cast<FakeValue*>(
      function->native_callback(reinterpret_cast<napi_env>(env), reinterpret_cast<napi_callback_info>(&info)));
}

struct FakeProbeState {
  std::mutex mutex;
  std::condition_variable cv;
  bool block = false;
  bool allow = false;
  int call_count = 0;
  cmfa::probe::ProbeResult next_result{};
  cmfa::probe::ProbeKind last_kind = cmfa::probe::ProbeKind::TcpEcho;
  std::string last_host;
  uint16_t last_port = 0;
  std::vector<uint8_t> last_payload;
  uint32_t last_timeout_ms = 0;
  bool throw_on_call = false;
  std::string throw_text;
};

FakeProbeState g_probe_state;

void reset_probe_state() {
  std::lock_guard<std::mutex> lock(g_probe_state.mutex);
  g_probe_state.block = false;
  g_probe_state.allow = false;
  g_probe_state.call_count = 0;
  g_probe_state.next_result = cmfa::probe::ProbeResult{};
  g_probe_state.next_result.outcome = cmfa::probe::ProbeOutcome::Pass;
  g_probe_state.next_result.failure = cmfa::probe::ProbeFailure::None;
  g_probe_state.last_kind = cmfa::probe::ProbeKind::TcpEcho;
  g_probe_state.last_host.clear();
  g_probe_state.last_port = 0;
  g_probe_state.last_payload.clear();
  g_probe_state.last_timeout_ms = 0;
  g_probe_state.throw_on_call = false;
  g_probe_state.throw_text.clear();
}

std::vector<uint8_t> bytes_from_text(const std::string& text) {
  return std::vector<uint8_t>(text.begin(), text.end());
}

FakeValue* build_valid_request(FakeEnv* env,
                               const std::string& kind = "tcpEcho",
                               const std::string& host = "198.51.100.7",
                               uint16_t port = 443,
                               const std::vector<uint8_t>& payload = bytes_from_text("PING"),
                               double timeout_ms = 0) {
  FakeValue* request = make_object(env);
  set_named_prop(request, "kind", make_string(env, kind));
  set_named_prop(request, "hostIpv4", make_string(env, host));
  set_named_prop(request, "port", make_number(env, static_cast<double>(port)));
  set_named_prop(request, "payload", make_arraybuffer(env, payload));
  set_named_prop(request, "timeoutMs", make_number(env, timeout_ms));
  return request;
}

void mutate_arraybuffer(FakeValue* value, const std::vector<uint8_t>& bytes) {
  expect(value != nullptr && value->type == FakeType::ArrayBuffer, "mutate_arraybuffer expects ArrayBuffer");
  value->bytes = bytes;
}

napi_value initialize_exports(FakeEnv* env) {
  expect_equal(g_module_register_calls, 1, "module should register exactly once");
  expect(g_registered_module != nullptr, "module registration should capture module");
  FakeValue* exports = make_object(env);
  napi_value init_result =
      g_registered_module->nm_register_func(reinterpret_cast<napi_env>(env), reinterpret_cast<napi_value>(exports));
  expect(init_result == reinterpret_cast<napi_value>(exports), "Init should return exports");
  return reinterpret_cast<napi_value>(exports);
}

FakeValue* invoke_probe_socket(FakeEnv* env, const std::vector<FakeValue*>& args) {
  FakeValue* exports = reinterpret_cast<FakeValue*>(initialize_exports(env));
  expect_strings(exports->object_keys, {"probeSocket"}, "module should export only probeSocket");
  FakeValue* probe_socket = get_named_prop(exports, "probeSocket");
  expect(probe_socket != nullptr && probe_socket->type == FakeType::Function, "probeSocket export should be a function");
  return invoke_function(env, probe_socket, args);
}

}  // namespace

namespace cmfa::probe {

ProbeResult probe_socket(const ProbeRequest& request) {
  std::unique_lock<std::mutex> lock(g_probe_state.mutex);
  if (g_probe_state.throw_on_call) {
    throw std::runtime_error(g_probe_state.throw_text);
  }
  g_probe_state.call_count += 1;
  g_probe_state.last_kind = request.kind;
  g_probe_state.last_host = request.host_ipv4 != nullptr ? request.host_ipv4 : "";
  g_probe_state.last_port = request.port;
  g_probe_state.last_payload.assign(request.payload, request.payload + request.payload_size);
  g_probe_state.last_timeout_ms = request.timeout_ms;
  while (g_probe_state.block && !g_probe_state.allow) {
    g_probe_state.cv.wait(lock);
  }
  return g_probe_state.next_result;
}

}  // namespace cmfa::probe

extern "C" {

void napi_module_register(napi_module* module) {
  g_registered_module = module;
  g_module_register_calls += 1;
}

}  // extern "C"

#define NAPI_MODULE(modname, regfunc)                                                     \
  namespace {                                                                             \
  struct modname##_module_registrar {                                                     \
    modname##_module_registrar() {                                                        \
      static napi_module module = {1, 0, nullptr, regfunc, #modname, nullptr};            \
      napi_module_register(&module);                                                      \
    }                                                                                     \
  };                                                                                      \
  static modname##_module_registrar modname##_module_registrar_instance;                  \
  }

#include "../../traffic-probe/entry/src/main/cpp/probe_native_napi.cpp"

extern "C" {

napi_status napi_get_cb_info(napi_env env,
                             napi_callback_info info,
                             size_t* argc,
                             napi_value* argv,
                             napi_value* this_arg,
                             void** data) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* callback_info = reinterpret_cast<FakeCallbackInfo*>(info);
  if (argc != nullptr) {
    const size_t requested = *argc;
    *argc = callback_info->args.size();
    if (argv != nullptr) {
      const size_t copy_count = std::min(requested, callback_info->args.size());
      for (size_t index = 0; index < copy_count; index += 1) {
        argv[index] = reinterpret_cast<napi_value>(callback_info->args[index]);
      }
    }
  }
  if (this_arg != nullptr) {
    *this_arg = nullptr;
  }
  if (data != nullptr) {
    *data = callback_info->data;
  }
  return napi_ok;
}

napi_status napi_typeof(napi_env env, napi_value value, napi_valuetype* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || result == nullptr) {
    return napi_invalid_arg;
  }
  switch (fake_value->type) {
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

napi_status napi_create_string_utf8(napi_env env, const char* str, size_t length, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr || str == nullptr) {
    return napi_invalid_arg;
  }
  const size_t actual_length = length == NAPI_AUTO_LENGTH ? std::strlen(str) : length;
  if (fake_env->fail_probe_socket_resource_name_create && std::string(str, actual_length) == "probeSocket") {
    fake_env->fail_probe_socket_resource_name_create = false;
    return napi_generic_failure;
  }
  *result = reinterpret_cast<napi_value>(make_string(fake_env, std::string(str, actual_length)));
  return napi_ok;
}

napi_status napi_get_value_string_utf8(napi_env env, napi_value value, char* buf, size_t bufsize, size_t* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::String) {
    return napi_string_expected;
  }
  if (fake_value->force_throw_string_read) {
    throw std::runtime_error(fake_value->string_value);
  }
  if (result != nullptr) {
    *result = fake_value->string_value.size();
  }
  if (buf == nullptr || bufsize == 0) {
    return napi_ok;
  }
  fake_env->max_string_copy_bufsize = std::max(fake_env->max_string_copy_bufsize, bufsize);
  fake_env->copied_strings.push_back(fake_value->string_value);
  const size_t copy_length = std::min(bufsize - 1, fake_value->string_value.size());
  std::memcpy(buf, fake_value->string_value.data(), copy_length);
  buf[copy_length] = '\0';
  return napi_ok;
}

napi_status napi_create_object(napi_env env, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  if (fake_env->throw_on_create_object) {
    throw std::runtime_error("complete system sentinel");
  }
  *result = reinterpret_cast<napi_value>(make_object(fake_env));
  return napi_ok;
}

napi_status napi_create_array_with_length(napi_env env, size_t length, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(make_array(fake_env, length));
  return napi_ok;
}

napi_status napi_set_named_property(napi_env env, napi_value object, const char* utf8name, napi_value value) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_object = reinterpret_cast<FakeValue*>(object);
  if (fake_object == nullptr || utf8name == nullptr) {
    return napi_invalid_arg;
  }
  set_named_prop(fake_object, utf8name, reinterpret_cast<FakeValue*>(value));
  return napi_ok;
}

napi_status napi_get_named_property(napi_env env, napi_value object, const char* utf8name, napi_value* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_object = reinterpret_cast<FakeValue*>(object);
  if (fake_object == nullptr || utf8name == nullptr || result == nullptr) {
    return napi_invalid_arg;
  }
  FakeValue* property = get_named_prop(fake_object, utf8name);
  if (property == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(property);
  return napi_ok;
}

napi_status napi_set_element(napi_env env, napi_value object, uint32_t index, napi_value value) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_array = reinterpret_cast<FakeValue*>(object);
  if (fake_array == nullptr || fake_array->type != FakeType::Array) {
    return napi_array_expected;
  }
  if (index >= fake_array->array_items.size()) {
    fake_array->array_items.resize(index + 1, reinterpret_cast<FakeEnv*>(env)->undefined_value);
  }
  fake_array->array_items[index] = reinterpret_cast<FakeValue*>(value);
  return napi_ok;
}

napi_status napi_get_element(napi_env env, napi_value object, uint32_t index, napi_value* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_array = reinterpret_cast<FakeValue*>(object);
  if (fake_array == nullptr || fake_array->type != FakeType::Array || result == nullptr) {
    return napi_array_expected;
  }
  if (index >= fake_array->array_items.size()) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(fake_array->array_items[index]);
  return napi_ok;
}

napi_status napi_get_array_length(napi_env env, napi_value value, uint32_t* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::Array || result == nullptr) {
    return napi_array_expected;
  }
  *result = static_cast<uint32_t>(fake_value->array_items.size());
  return napi_ok;
}

napi_status napi_is_array(napi_env env, napi_value value, bool* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || result == nullptr) {
    return napi_invalid_arg;
  }
  *result = fake_value->type == FakeType::Array;
  return napi_ok;
}

napi_status napi_get_property_names(napi_env env, napi_value object, napi_value* result) {
  return napi_get_all_property_names(
      env, object, napi_key_own_only, napi_key_enumerable, napi_key_numbers_to_strings, result);
}

napi_status napi_get_all_property_names(napi_env env,
                                        napi_value object,
                                        napi_key_collection_mode,
                                        napi_key_filter,
                                        napi_key_conversion,
                                        napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  auto* fake_object = reinterpret_cast<FakeValue*>(object);
  if (fake_object == nullptr || result == nullptr) {
    return napi_invalid_arg;
  }
  FakeValue* keys = make_array(fake_env, fake_object->object_keys.size());
  for (size_t index = 0; index < fake_object->object_keys.size(); index += 1) {
    keys->array_items[index] = make_string(fake_env, fake_object->object_keys[index]);
  }
  *result = reinterpret_cast<napi_value>(keys);
  return napi_ok;
}

napi_status napi_create_uint32(napi_env env, uint32_t value, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(make_number(fake_env, static_cast<double>(value)));
  return napi_ok;
}

napi_status napi_create_int32(napi_env env, int32_t value, napi_value* result) {
  return napi_create_int64(env, value, result);
}

napi_status napi_create_int64(napi_env env, int64_t value, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(make_number(fake_env, static_cast<double>(value)));
  return napi_ok;
}

napi_status napi_get_value_int64(napi_env env, napi_value value, int64_t* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::Number || result == nullptr) {
    return napi_number_expected;
  }
  *result = static_cast<int64_t>(fake_value->number_value);
  return napi_ok;
}

napi_status napi_get_value_double(napi_env env, napi_value value, double* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::Number || result == nullptr) {
    return napi_number_expected;
  }
  *result = fake_value->number_value;
  return napi_ok;
}

napi_status napi_get_value_bool(napi_env env, napi_value value, bool* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::Boolean || result == nullptr) {
    return napi_boolean_expected;
  }
  *result = fake_value->bool_value;
  return napi_ok;
}

napi_status napi_get_boolean(napi_env env, bool value, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(make_boolean(fake_env, value));
  return napi_ok;
}

napi_status napi_get_null(napi_env env, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(fake_env->null_value);
  return napi_ok;
}

napi_status napi_get_undefined(napi_env env, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = reinterpret_cast<napi_value>(fake_env->undefined_value);
  return napi_ok;
}

napi_status napi_get_global(napi_env env, napi_value* result) {
  return napi_get_undefined(env, result);
}

napi_status napi_get_prototype(napi_env env, napi_value, napi_value* result) {
  return napi_get_null(env, result);
}

napi_status napi_strict_equals(napi_env env, napi_value lhs, napi_value rhs, bool* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  *result = lhs == rhs;
  return napi_ok;
}

napi_status napi_create_error(napi_env env, napi_value code, napi_value msg, napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (result == nullptr) {
    return napi_invalid_arg;
  }
  FakeValue* error = allocate_value(fake_env, FakeType::Error);
  set_named_prop(error, "code", reinterpret_cast<FakeValue*>(code));
  set_named_prop(error, "message", reinterpret_cast<FakeValue*>(msg));
  *result = reinterpret_cast<napi_value>(error);
  return napi_ok;
}

napi_status napi_throw(napi_env env, napi_value error) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  fake_env->last_thrown = reinterpret_cast<FakeValue*>(error);
  return napi_ok;
}

napi_status napi_throw_error(napi_env env, const char* code, const char* msg) {
  napi_value code_value = nullptr;
  napi_value message_value = nullptr;
  napi_value error_value = nullptr;
  (void)napi_create_string_utf8(env, code == nullptr ? "" : code, NAPI_AUTO_LENGTH, &code_value);
  (void)napi_create_string_utf8(env, msg == nullptr ? "" : msg, NAPI_AUTO_LENGTH, &message_value);
  (void)napi_create_error(env, code_value, message_value, &error_value);
  return napi_throw(env, error_value);
}

napi_status napi_create_promise(napi_env env, napi_deferred* deferred, napi_value* promise) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  if (deferred == nullptr || promise == nullptr) {
    return napi_invalid_arg;
  }
  fake_env->create_promise_calls += 1;
  fake_env->deferreds.push_back(std::make_unique<FakeDeferred>());
  FakeDeferred* handle = fake_env->deferreds.back().get();
  handle->promise = allocate_value(fake_env, FakeType::Promise);
  *deferred = reinterpret_cast<napi_deferred>(handle);
  *promise = reinterpret_cast<napi_value>(handle->promise);
  return napi_ok;
}

napi_status napi_resolve_deferred(napi_env env, napi_deferred deferred, napi_value resolution) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_deferred = reinterpret_cast<FakeDeferred*>(deferred);
  if (fake_deferred == nullptr || fake_deferred->promise == nullptr) {
    return napi_invalid_arg;
  }
  fake_deferred->promise->promise_resolved = true;
  fake_deferred->promise->promise_result = reinterpret_cast<FakeValue*>(resolution);
  return napi_ok;
}

napi_status napi_reject_deferred(napi_env env, napi_deferred deferred, napi_value rejection) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_deferred = reinterpret_cast<FakeDeferred*>(deferred);
  if (fake_deferred == nullptr || fake_deferred->promise == nullptr) {
    return napi_invalid_arg;
  }
  fake_deferred->promise->promise_rejected = true;
  fake_deferred->promise->promise_result = reinterpret_cast<FakeValue*>(rejection);
  return napi_ok;
}

napi_status napi_define_properties(napi_env env,
                                   napi_value object,
                                   size_t count,
                                   const napi_property_descriptor* properties) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  auto* fake_object = reinterpret_cast<FakeValue*>(object);
  if (fake_object == nullptr || properties == nullptr) {
    return napi_invalid_arg;
  }
  for (size_t index = 0; index < count; index += 1) {
    const napi_property_descriptor& property = properties[index];
    FakeValue* value = property.method != nullptr
                           ? make_function(fake_env, property.method, property.data)
                           : reinterpret_cast<FakeValue*>(property.value);
    set_named_prop(fake_object, property.utf8name, value);
  }
  return napi_ok;
}

napi_status napi_create_reference(napi_env, napi_value, uint32_t, napi_ref*) {
  return napi_invalid_arg;
}

napi_status napi_get_reference_value(napi_env, napi_ref, napi_value*) {
  return napi_invalid_arg;
}

napi_status napi_delete_reference(napi_env, napi_ref) {
  return napi_invalid_arg;
}

napi_status napi_call_function(napi_env env,
                               napi_value,
                               napi_value func,
                               size_t argc,
                               const napi_value* argv,
                               napi_value* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  std::vector<FakeValue*> args;
  for (size_t index = 0; index < argc; index += 1) {
    args.push_back(reinterpret_cast<FakeValue*>(argv[index]));
  }
  FakeValue* call_result = invoke_function(fake_env, reinterpret_cast<FakeValue*>(func), args);
  if (result != nullptr) {
    *result = reinterpret_cast<napi_value>(call_result);
  }
  return napi_ok;
}

napi_status napi_create_threadsafe_function(napi_env,
                                            napi_value,
                                            napi_value,
                                            napi_value,
                                            size_t,
                                            size_t,
                                            void*,
                                            napi_finalize,
                                            void*,
                                            napi_threadsafe_function_call_js,
                                            napi_threadsafe_function*) {
  return napi_invalid_arg;
}

napi_status napi_call_threadsafe_function(napi_threadsafe_function, void*, napi_threadsafe_function_call_mode) {
  return napi_invalid_arg;
}

napi_status napi_release_threadsafe_function(napi_threadsafe_function, napi_threadsafe_function_release_mode) {
  return napi_invalid_arg;
}

napi_status napi_is_arraybuffer(napi_env env, napi_value value, bool* result) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || result == nullptr) {
    return napi_invalid_arg;
  }
  *result = fake_value->type == FakeType::ArrayBuffer;
  return napi_ok;
}

napi_status napi_get_arraybuffer_info(napi_env env, napi_value value, void** data, size_t* byte_length) {
  note_env_call(reinterpret_cast<FakeEnv*>(env));
  auto* fake_value = reinterpret_cast<FakeValue*>(value);
  if (fake_value == nullptr || fake_value->type != FakeType::ArrayBuffer) {
    return napi_arraybuffer_expected;
  }
  if (data != nullptr) {
    *data = fake_value->force_null_arraybuffer_data ? nullptr : (fake_value->bytes.empty() ? nullptr : fake_value->bytes.data());
  }
  if (byte_length != nullptr) {
    *byte_length = fake_value->bytes.size();
  }
  return napi_ok;
}

napi_status napi_create_async_work(napi_env env,
                                   napi_value,
                                   napi_value,
                                   napi_async_execute_callback execute,
                                   napi_async_complete_callback complete,
                                   void* data,
                                   napi_async_work* result) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  fake_env->create_async_work_calls += 1;
  if (fake_env->next_create_async_work_status != napi_ok) {
    const napi_status status = fake_env->next_create_async_work_status;
    fake_env->next_create_async_work_status = napi_ok;
    return status;
  }
  fake_env->async_works.push_back(std::make_unique<FakeAsyncWork>());
  FakeAsyncWork* work = fake_env->async_works.back().get();
  work->env = fake_env;
  work->data = data;
  work->execute = execute;
  work->complete = complete;
  *result = reinterpret_cast<napi_async_work>(work);
  return napi_ok;
}

napi_status napi_queue_async_work(napi_env env, napi_async_work work) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  fake_env->queue_async_work_calls += 1;
  if (fake_env->next_queue_async_work_status != napi_ok) {
    const napi_status status = fake_env->next_queue_async_work_status;
    fake_env->next_queue_async_work_status = napi_ok;
    return status;
  }
  auto* fake_work = reinterpret_cast<FakeAsyncWork*>(work);
  fake_work->queued = true;
  const napi_status completion_status = fake_env->next_complete_async_work_status;
  fake_env->next_complete_async_work_status = napi_ok;
  fake_work->worker = std::thread([fake_work, completion_status]() {
    fake_work->env->execute_async_work_calls += 1;
    fake_work->execute(reinterpret_cast<napi_env>(fake_work->env), fake_work->data);
    std::lock_guard<std::mutex> lock(fake_work->env->mutex);
    fake_work->env->pending_completions.push_back({fake_work, completion_status});
    fake_work->env->cv.notify_all();
  });
  return napi_ok;
}

napi_status napi_delete_async_work(napi_env env, napi_async_work work) {
  auto* fake_env = reinterpret_cast<FakeEnv*>(env);
  note_env_call(fake_env);
  auto* fake_work = reinterpret_cast<FakeAsyncWork*>(work);
  if (fake_work == nullptr) {
    return napi_invalid_arg;
  }
  fake_env->delete_async_work_calls += 1;
  fake_work->deleted = true;
  return napi_ok;
}

}  // extern "C"

namespace {

void test_module_registers_exact_single_export() {
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  expect_equal(g_module_register_calls, 1, "module should register once");
  expect(g_registered_module != nullptr, "module should register");
  expect_equal(std::string(g_registered_module->nm_modname), std::string("libprobeentry"), "module name should match");

  FakeValue* exports = reinterpret_cast<FakeValue*>(initialize_exports(env.get()));
  expect_strings(exports->object_keys, {"probeSocket"}, "exports should contain exactly one key");
  FakeValue* probe_socket = get_named_prop(exports, "probeSocket");
  expect(probe_socket != nullptr && probe_socket->type == FakeType::Function, "probeSocket should be function");
}

void test_probe_socket_rejects_invalid_shape_and_sanitizes_sync_errors() {
  const std::vector<std::vector<FakeValue*>> direct_cases = {
      {},
      {nullptr, nullptr},
  };

  for (const auto& args : direct_cases) {
    std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
    FakeValue* result = invoke_probe_socket(env.get(), args);
    expect(result == nullptr, "invalid direct args should return null");
    expect(env->last_thrown != nullptr, "invalid direct args should throw");
    expect_equal(get_named_prop(env->last_thrown, "code")->string_value, std::string(kExpectedInvalidArgCode),
                 "invalid direct args should use fixed code");
    expect_equal(get_named_prop(env->last_thrown, "message")->string_value, std::string(kExpectedInvalidArgMessage),
                 "invalid direct args should use fixed message");
    expect_equal(env->create_promise_calls, 0, "invalid direct args must not create promise");
    expect_equal(env->create_async_work_calls, 0, "invalid direct args must not create async work");
  }

  const std::vector<std::function<FakeValue*(FakeEnv*)>> cases = {
      [](FakeEnv* env) { return make_string(env, "not-an-object"); },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "extra", make_boolean(env, true));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        request->object_props.erase("payload");
        request->object_keys.erase(std::remove(request->object_keys.begin(), request->object_keys.end(), "payload"),
                                   request->object_keys.end());
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "kind", make_number(env, 1));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env, "icmpEcho");
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env, "tcpHttpX");
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "hostIpv4", make_string(env, "probe.invalid"));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "port", make_number(env, 0));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "port", make_number(env, 1.5));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "payload", make_object(env));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        FakeValue* typed_array_like = make_object(env);
        set_named_prop(typed_array_like, "byteLength", make_number(env, 4));
        set_named_prop(request, "payload", typed_array_like);
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "payload", make_arraybuffer(env, {}));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "payload", make_arraybuffer_with_null_data(env, bytes_from_text("PING")));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request =
            build_valid_request(env, "tcpEcho", "198.51.100.7", 443, std::vector<uint8_t>(kTestMaxTcpPayloadBytes + 1, 'x'));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request =
            build_valid_request(env, "udpEcho", "198.51.100.7", 53, std::vector<uint8_t>(kTestMaxUdpPayloadBytes + 1, 'x'));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request =
            build_valid_request(env, "tcpHttp", "198.51.100.7", 80, std::vector<uint8_t>(kTestMaxTcpPayloadBytes + 1, 'x'));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "timeoutMs", make_number(env, -1));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "timeoutMs", make_number(env, 12.5));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "timeoutMs", make_number(env, std::numeric_limits<double>::infinity()));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "timeoutMs", make_number(env, static_cast<double>(UINT32_MAX) + 1.0));
        return request;
      },
      [](FakeEnv* env) {
        FakeValue* request = build_valid_request(env);
        set_named_prop(request, "timeoutMs", make_number(env, kTestMaxSafeInteger + 1.0));
        return request;
      },
  };

  for (const auto& make_case : cases) {
    std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
    FakeValue* request = make_case(env.get());
    const std::vector<std::string> forbidden = {"probe.invalid", "PING", "198.51.100.7"};
    FakeValue* result = invoke_probe_socket(env.get(), {request});
    expect(result == nullptr, "invalid request should return null");
    expect(env->last_thrown != nullptr, "invalid request should throw");
    expect_equal(get_named_prop(env->last_thrown, "code")->string_value, std::string(kExpectedInvalidArgCode),
                 "invalid request should use fixed code");
    expect_equal(get_named_prop(env->last_thrown, "message")->string_value, std::string(kExpectedInvalidArgMessage),
                 "invalid request should use fixed message");
    expect_sanitized(env->last_thrown, forbidden, "invalid request");
    expect_equal(env->create_promise_calls, 0, "invalid request must not create promise");
    expect_equal(env->create_async_work_calls, 0, "invalid request must not create async work");
  }
}

void test_probe_socket_rejects_overlong_strings_without_large_buffer_copy() {
  struct Case {
    std::function<FakeValue*(FakeEnv*)> make_request;
    std::string blocked_text;
  };

  const std::vector<Case> cases = {
      {[](FakeEnv* env) {
         return build_valid_request(env, "tcpExchangeX");
       },
       "tcpExchangeX"},
      {[](FakeEnv* env) {
         return build_valid_request(env, "tcpEcho", "255.255.255.2551");
       },
       "255.255.255.2551"},
      {[](FakeEnv* env) {
         FakeValue* request = build_valid_request(env);
         set_named_prop(request, "payloadX10", make_boolean(env, true));
         return request;
       },
       "payloadX10"},
  };

  for (const Case& entry : cases) {
    std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
    FakeValue* request = entry.make_request(env.get());
    FakeValue* result = invoke_probe_socket(env.get(), {request});
    expect(result == nullptr, "overlong string case should return null");
    expect(env->last_thrown != nullptr, "overlong string case should throw");
    expect_equal(get_named_prop(env->last_thrown, "code")->string_value, std::string(kExpectedInvalidArgCode),
                 "overlong string case should use invalid arg code");
    expect_equal(get_named_prop(env->last_thrown, "message")->string_value, std::string(kExpectedInvalidArgMessage),
                 "overlong string case should use invalid arg message");
    expect_equal(env->create_promise_calls, 0, "overlong string case must not create promise");
    expect_equal(env->create_async_work_calls, 0, "overlong string case must not create async work");
    expect(env->max_string_copy_bufsize <= 11, "bridge should not request oversized string copy buffer");
    expect_not_copied(env.get(), entry.blocked_text, "bridge should reject overlong string before copying it");
  }
}

void test_probe_socket_catches_decode_exception_before_promise() {
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  FakeValue* request = build_valid_request(env.get());
  FakeValue* host = get_named_prop(request, "hostIpv4");
  host->force_throw_string_read = true;
  host->string_value = "host decode sentinel 203.0.113.41";

  FakeValue* result = invoke_probe_socket(env.get(), {request});
  expect(result == nullptr, "decode exception should return null");
  expect(env->last_thrown != nullptr, "decode exception should be contained");
  expect_equal(get_named_prop(env->last_thrown, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "decode exception should use bridge failure code");
  expect_equal(get_named_prop(env->last_thrown, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "decode exception should use bridge failure message");
  expect_sanitized(env->last_thrown, {"host decode sentinel", "203.0.113.41"}, "decode exception");
  expect_equal(env->create_promise_calls, 0, "decode exception must not create promise");
  expect_equal(env->create_async_work_calls, 0, "decode exception must not create async work");
}

void test_probe_socket_copies_input_and_resolves_pass_result() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.block = true;
    g_probe_state.next_result.outcome = cmfa::probe::ProbeOutcome::Pass;
    g_probe_state.next_result.failure = cmfa::probe::ProbeFailure::None;
    g_probe_state.next_result.bytes_sent = 4;
    g_probe_state.next_result.bytes_received = 4;
    g_probe_state.next_result.duration_ms = 87;
  }

  FakeValue* request = build_valid_request(env.get(), "dnsUdpEcho", "203.0.113.5", 5353, bytes_from_text("PING"), 0);
  FakeValue* payload = get_named_prop(request, "payload");
  FakeValue* promise = invoke_probe_socket(env.get(), {request});
  expect(promise != nullptr && promise->type == FakeType::Promise, "valid request should return promise");
  set_named_prop(request, "hostIpv4", make_string(env.get(), "198.51.100.77"));
  mutate_arraybuffer(payload, bytes_from_text("MUTATE"));
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.allow = true;
  }
  g_probe_state.cv.notify_all();

  FakeValue* result = await_promise(env.get(), promise, "pass promise should settle");
  expect(promise->promise_resolved, "pass promise should resolve");
  expect_equal(get_named_prop(result, "outcome")->string_value, std::string("pass"), "result should map pass outcome");
  expect_equal(get_named_prop(result, "bytesSent")->number_value, 4.0, "bytesSent should map");
  expect_equal(get_named_prop(result, "bytesReceived")->number_value, 4.0, "bytesReceived should map");
  expect_equal(get_named_prop(result, "durationMs")->number_value, 87.0, "durationMs should map");
  expect(get_named_prop(result, "failureCode") == nullptr, "pass result should omit failureCode");
  expect_equal(env->create_promise_calls, 1, "valid request should create promise exactly once");
  expect_equal(env->create_async_work_calls, 1, "valid request should create async work once");
  expect_equal(env->queue_async_work_calls, 1, "valid request should queue async work once");
  expect_equal(env->execute_async_work_calls, 1, "valid request should execute once");
  expect_equal(env->complete_async_work_calls, 1, "valid request should complete once");
  expect_equal(env->delete_async_work_calls, 1, "valid request should delete async work once");
  expect_equal(env->off_thread_env_api_calls.load(std::memory_order_relaxed), 0, "worker must not call N-API");

  std::lock_guard<std::mutex> lock(g_probe_state.mutex);
  expect_equal(g_probe_state.call_count, 1, "core should run once");
  expect_equal(g_probe_state.last_host, std::string("203.0.113.5"), "worker should copy original host");
  expect_equal(g_probe_state.last_port, static_cast<uint16_t>(5353), "worker should copy port");
  expect_equal(g_probe_state.last_timeout_ms, static_cast<uint32_t>(0), "worker should preserve unclamped timeout");
  expect_equal(g_probe_state.last_payload, bytes_from_text("PING"), "worker should copy original payload");
  expect(g_probe_state.last_kind == cmfa::probe::ProbeKind::DnsUdpEcho, "worker should map kind");
}

void test_probe_socket_copies_input_and_resolves_tcp_http_pass_result() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.next_result.outcome = cmfa::probe::ProbeOutcome::Pass;
    g_probe_state.next_result.failure = cmfa::probe::ProbeFailure::None;
    g_probe_state.next_result.bytes_sent = 4;
    g_probe_state.next_result.bytes_received = 17;
    g_probe_state.next_result.duration_ms = 12;
  }

  FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpHttp", "203.0.113.9", 80, bytes_from_text("PING"), 0)});
  FakeValue* result = await_promise(env.get(), promise, "tcpHttp promise should settle");
  expect(promise->promise_resolved, "tcpHttp promise should resolve");
  expect_equal(get_named_prop(result, "outcome")->string_value, std::string("pass"), "tcpHttp should map pass outcome");
  expect(get_named_prop(result, "failureCode") == nullptr, "tcpHttp pass should omit failureCode");

  std::lock_guard<std::mutex> lock(g_probe_state.mutex);
  expect(g_probe_state.last_kind == cmfa::probe::ProbeKind::TcpHttp, "worker should map tcpHttp kind");
  expect_equal(g_probe_state.last_port, static_cast<uint16_t>(80), "worker should preserve tcpHttp port");
  expect_equal(g_probe_state.last_payload, bytes_from_text("PING"), "worker should preserve tcpHttp payload");
}

void test_probe_socket_copies_input_and_resolves_tcp_send_pass_result() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.next_result.outcome = cmfa::probe::ProbeOutcome::Pass;
    g_probe_state.next_result.failure = cmfa::probe::ProbeFailure::None;
    g_probe_state.next_result.bytes_sent = 4;
    g_probe_state.next_result.bytes_received = 0;
    g_probe_state.next_result.duration_ms = 8;
  }

  FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpSend", "203.0.113.9", 443, bytes_from_text("PING"), 0)});
  FakeValue* result = await_promise(env.get(), promise, "tcpSend promise should settle");
  expect(promise->promise_resolved, "tcpSend promise should resolve");
  expect_equal(get_named_prop(result, "outcome")->string_value, std::string("pass"), "tcpSend should map pass outcome");
  expect(get_named_prop(result, "failureCode") == nullptr, "tcpSend pass should omit failureCode");

  std::lock_guard<std::mutex> lock(g_probe_state.mutex);
  expect(g_probe_state.last_kind == cmfa::probe::ProbeKind::TcpSend, "worker should map tcpSend kind");
  expect_equal(g_probe_state.last_port, static_cast<uint16_t>(443), "worker should preserve tcpSend port");
  expect_equal(g_probe_state.last_payload, bytes_from_text("PING"), "worker should preserve tcpSend payload");
}

void test_probe_socket_copies_input_and_resolves_tcp_exchange_pass_result() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.next_result.outcome = cmfa::probe::ProbeOutcome::Pass;
    g_probe_state.next_result.failure = cmfa::probe::ProbeFailure::None;
    g_probe_state.next_result.bytes_sent = 4;
    g_probe_state.next_result.bytes_received = 8;
    g_probe_state.next_result.duration_ms = 9;
  }

  FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpExchange", "203.0.113.9", 443, bytes_from_text("PING"), 0)});
  FakeValue* result = await_promise(env.get(), promise, "tcpExchange promise should settle");
  expect(promise->promise_resolved, "tcpExchange promise should resolve");
  expect_equal(get_named_prop(result, "outcome")->string_value, std::string("pass"), "tcpExchange should map pass outcome");
  expect(get_named_prop(result, "failureCode") == nullptr, "tcpExchange pass should omit failureCode");

  std::lock_guard<std::mutex> lock(g_probe_state.mutex);
  expect(g_probe_state.last_kind == cmfa::probe::ProbeKind::TcpExchange, "worker should map tcpExchange kind");
  expect_equal(g_probe_state.last_port, static_cast<uint16_t>(443), "worker should preserve tcpExchange port");
  expect_equal(g_probe_state.last_payload, bytes_from_text("PING"), "worker should preserve tcpExchange payload");
}

void test_probe_socket_resolves_failure_variants_with_optional_failure_code() {
  const struct Case {
    cmfa::probe::ProbeOutcome outcome;
    cmfa::probe::ProbeFailure failure;
    const char* expected_outcome;
    const char* expected_failure_code;
  } cases[] = {
      {cmfa::probe::ProbeOutcome::Timeout, cmfa::probe::ProbeFailure::Timeout, "timeout", "TIMEOUT"},
      {cmfa::probe::ProbeOutcome::Fail, cmfa::probe::ProbeFailure::PayloadMismatch, "fail", "PAYLOAD_MISMATCH"},
  };

  for (const Case& entry : cases) {
    reset_probe_state();
    std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
    {
      std::lock_guard<std::mutex> lock(g_probe_state.mutex);
      g_probe_state.next_result.outcome = entry.outcome;
      g_probe_state.next_result.failure = entry.failure;
      g_probe_state.next_result.bytes_sent = 2;
      g_probe_state.next_result.bytes_received = 1;
      g_probe_state.next_result.duration_ms = 25;
    }
    FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get())});
    FakeValue* result = await_promise(env.get(), promise, "failure variant should settle");
    expect(promise->promise_resolved, "core failure should resolve promise");
    expect_equal(get_named_prop(result, "outcome")->string_value, std::string(entry.expected_outcome),
                 "result should map outcome");
    expect_equal(get_named_prop(result, "failureCode")->string_value, std::string(entry.expected_failure_code),
                 "result should map failure code");
  }
}

void test_probe_socket_rejects_create_work_failure_without_leaking() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  env->next_create_async_work_status = napi_generic_failure;

  FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get(), "udpEcho", "203.0.113.9", 53, bytes_from_text("SEKR"))});
  FakeValue* error = await_promise(env.get(), promise, "create async work failure should settle");
  expect(promise->promise_rejected, "create async work failure should reject");
  expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "create async work failure should use fixed code");
  expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "create async work failure should use fixed message");
  expect_sanitized(error, {"203.0.113.9", "SEKR"}, "create async work failure");
  expect_equal(env->create_promise_calls, 1, "create async work failure should still create promise");
  expect_equal(env->create_async_work_calls, 1, "create async work failure should attempt create once");
  expect_equal(env->queue_async_work_calls, 0, "create async work failure should not queue");
  expect_equal(env->delete_async_work_calls, 0, "create async work failure should not delete absent work");
  expect_equal(env->execute_async_work_calls, 0, "create async work failure should not execute");
  expect_equal(env->complete_async_work_calls, 0, "create async work failure should not complete");
}

void test_probe_socket_rejects_resource_name_creation_failure_without_creating_work() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  env->fail_probe_socket_resource_name_create = true;

  FakeValue* promise = invoke_probe_socket(env.get(), {build_valid_request(env.get(), "udpEcho", "203.0.113.19", 53, bytes_from_text("SEKR"))});
  FakeValue* error = await_promise(env.get(), promise, "resource name failure should settle");
  expect(promise->promise_rejected, "resource name failure should reject");
  expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "resource name failure should use fixed code");
  expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "resource name failure should use fixed message");
  expect_sanitized(error, {"203.0.113.19", "SEKR"}, "resource name failure");
  expect_equal(env->create_promise_calls, 1, "resource name failure should create promise");
  expect_equal(env->create_async_work_calls, 0, "resource name failure must not create async work");
  expect_equal(env->queue_async_work_calls, 0, "resource name failure must not queue work");
  expect_equal(env->delete_async_work_calls, 0, "resource name failure should not delete absent work");
}

void test_probe_socket_rejects_queue_failure_and_deletes_work_once() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  env->next_queue_async_work_status = napi_generic_failure;

  FakeValue* promise =
      invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpEcho", "203.0.113.10", 80, bytes_from_text("LOCK"))});
  FakeValue* error = await_promise(env.get(), promise, "queue failure should settle");
  expect(promise->promise_rejected, "queue failure should reject");
  expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "queue failure should use fixed code");
  expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "queue failure should use fixed message");
  expect_sanitized(error, {"203.0.113.10", "LOCK"}, "queue failure");
  expect_equal(env->create_promise_calls, 1, "queue failure should create promise");
  expect_equal(env->create_async_work_calls, 1, "queue failure should create work once");
  expect_equal(env->queue_async_work_calls, 1, "queue failure should queue once");
  expect_equal(env->delete_async_work_calls, 1, "queue failure should delete work exactly once");
  expect_equal(env->execute_async_work_calls, 0, "queue failure should not execute work");
  expect_equal(env->complete_async_work_calls, 0, "queue failure should not complete work");
}

void test_probe_socket_rejects_non_ok_complete_status_and_cleans_up_once() {
  const napi_status statuses[] = {napi_cancelled, napi_generic_failure};
  for (const napi_status status : statuses) {
    reset_probe_state();
    std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
    env->next_complete_async_work_status = status;

    FakeValue* promise =
        invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpEcho", "203.0.113.88", 443, bytes_from_text("SEKR"))});
    FakeValue* error = await_promise(env.get(), promise, "non-ok completion status should settle");
    expect(promise->promise_rejected, "non-ok completion status should reject");
    expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
                 "non-ok completion status should use fixed code");
    expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
                 "non-ok completion status should use fixed message");
    expect_sanitized(error, {"203.0.113.88", "SEKR", "cancelled", "generic_failure", "napi_cancelled"},
                     "non-ok completion status");
    expect_equal(env->create_promise_calls, 1, "non-ok completion status should create promise");
    expect_equal(env->create_async_work_calls, 1, "non-ok completion status should create work");
    expect_equal(env->queue_async_work_calls, 1, "non-ok completion status should queue work");
    expect_equal(env->complete_async_work_calls, 1, "non-ok completion status should complete once");
    expect_equal(env->delete_async_work_calls, 1, "non-ok completion status should delete work once");
    expect(env->execute_async_work_calls == 0 || env->execute_async_work_calls == 1,
           "non-ok completion status may or may not execute before completion");
  }
}

void test_probe_socket_rejects_core_throw_without_crashing() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  {
    std::lock_guard<std::mutex> lock(g_probe_state.mutex);
    g_probe_state.throw_on_call = true;
    g_probe_state.throw_text = "worker sentinel 203.0.113.77 SEKR system";
  }

  FakeValue* promise =
      invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpEcho", "203.0.113.77", 443, bytes_from_text("SEKR"))});
  FakeValue* error = await_promise(env.get(), promise, "core throw should settle");
  expect(promise->promise_rejected, "core throw should reject");
  expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "core throw should use bridge failure code");
  expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "core throw should use bridge failure message");
  expect_sanitized(error, {"203.0.113.77", "SEKR", "worker sentinel"}, "core throw");
  expect_equal(env->create_async_work_calls, 1, "core throw should still create work");
  expect_equal(env->queue_async_work_calls, 1, "core throw should still queue work");
  expect_equal(env->execute_async_work_calls, 1, "core throw should execute once");
  expect_equal(env->complete_async_work_calls, 1, "core throw should complete once");
  expect_equal(env->delete_async_work_calls, 1, "core throw should delete work once");
  expect_equal(env->off_thread_env_api_calls.load(std::memory_order_relaxed), 0, "worker throw must not call N-API");
}

void test_probe_socket_rejects_complete_exception_and_cleans_up_once() {
  reset_probe_state();
  std::unique_ptr<FakeEnv, void (*)(FakeEnv*)> env(create_env(), destroy_env);
  env->throw_on_create_object = true;

  FakeValue* promise =
      invoke_probe_socket(env.get(), {build_valid_request(env.get(), "tcpEcho", "203.0.113.23", 443, bytes_from_text("LOCK"))});
  FakeValue* error = await_promise(env.get(), promise, "complete exception should settle");
  expect(promise->promise_rejected, "complete exception should reject");
  expect_equal(get_named_prop(error, "code")->string_value, std::string(kExpectedAsyncFailureCode),
               "complete exception should use bridge failure code");
  expect_equal(get_named_prop(error, "message")->string_value, std::string(kExpectedAsyncFailureMessage),
               "complete exception should use bridge failure message");
  expect_sanitized(error, {"203.0.113.23", "LOCK", "complete system sentinel"}, "complete exception");
  expect_equal(env->create_async_work_calls, 1, "complete exception should create work");
  expect_equal(env->queue_async_work_calls, 1, "complete exception should queue work");
  expect_equal(env->complete_async_work_calls, 1, "complete exception should complete once");
  expect_equal(env->delete_async_work_calls, 1, "complete exception should delete work once");
}

}  // namespace

int main() {
  const std::vector<std::pair<const char*, std::function<void()>>> tests = {
      {"module_registers_exact_single_export", test_module_registers_exact_single_export},
      {"probe_socket_rejects_invalid_shape_and_sanitizes_sync_errors",
       test_probe_socket_rejects_invalid_shape_and_sanitizes_sync_errors},
      {"probe_socket_rejects_overlong_strings_without_large_buffer_copy",
       test_probe_socket_rejects_overlong_strings_without_large_buffer_copy},
      {"probe_socket_catches_decode_exception_before_promise",
       test_probe_socket_catches_decode_exception_before_promise},
      {"probe_socket_copies_input_and_resolves_pass_result", test_probe_socket_copies_input_and_resolves_pass_result},
      {"probe_socket_copies_input_and_resolves_tcp_http_pass_result", test_probe_socket_copies_input_and_resolves_tcp_http_pass_result},
      {"probe_socket_copies_input_and_resolves_tcp_send_pass_result", test_probe_socket_copies_input_and_resolves_tcp_send_pass_result},
      {"probe_socket_copies_input_and_resolves_tcp_exchange_pass_result", test_probe_socket_copies_input_and_resolves_tcp_exchange_pass_result},
      {"probe_socket_resolves_failure_variants_with_optional_failure_code",
       test_probe_socket_resolves_failure_variants_with_optional_failure_code},
      {"probe_socket_rejects_create_work_failure_without_leaking",
       test_probe_socket_rejects_create_work_failure_without_leaking},
      {"probe_socket_rejects_resource_name_creation_failure_without_creating_work",
       test_probe_socket_rejects_resource_name_creation_failure_without_creating_work},
      {"probe_socket_rejects_queue_failure_and_deletes_work_once",
       test_probe_socket_rejects_queue_failure_and_deletes_work_once},
      {"probe_socket_rejects_non_ok_complete_status_and_cleans_up_once",
       test_probe_socket_rejects_non_ok_complete_status_and_cleans_up_once},
      {"probe_socket_rejects_core_throw_without_crashing",
       test_probe_socket_rejects_core_throw_without_crashing},
      {"probe_socket_rejects_complete_exception_and_cleans_up_once",
       test_probe_socket_rejects_complete_exception_and_cleans_up_once},
  };

  size_t failed = 0;
  for (const auto& entry : tests) {
    try {
      std::cout << "[RUN] " << entry.first << std::endl;
      entry.second();
      std::cout << "[PASS] " << entry.first << std::endl;
    } catch (const std::exception& error) {
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
