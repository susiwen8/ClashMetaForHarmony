#include "cmfa_core.h"
#include "cmfa_mihomo_backend.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

extern "C" cmfa_status cmfa_mihomo_backend_test_start_local_direct(const cmfa_local_options *options,
                                                                   cmfa_runtime_snapshot *snapshot,
                                                                   cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_start_direct(const cmfa_proxy_query_context *query,
                                                                         const char *group_name,
                                                                         cmfa_json_buffer *output,
                                                                         cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_snapshot_direct(const char *job_id,
                                                                            cmfa_json_buffer *output,
                                                                            cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_cancel_direct(const char *job_id,
                                                                          cmfa_json_buffer *output,
                                                                          cmfa_error *error);
extern "C" void cmfa_mihomo_backend_test_emit_runtime_logs();
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_groups_direct(const cmfa_proxy_query_context *query,
                                                                    uint8_t selectable_only,
                                                                    cmfa_json_buffer *output,
                                                                    cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_group_direct(const cmfa_proxy_query_context *query,
                                                                   const char *group_name,
                                                                   cmfa_json_buffer *output,
                                                                   cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_select_direct(const cmfa_proxy_query_context *query,
                                                                    const char *group_name,
                                                                    const char *member_name,
                                                                    cmfa_json_buffer *output,
                                                                    cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_start_direct(const cmfa_proxy_query_context *query,
                                                                         const char *group_name,
                                                                         cmfa_json_buffer *output,
                                                                         cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_snapshot_direct(const char *job_id,
                                                                            cmfa_json_buffer *output,
                                                                            cmfa_error *error);
extern "C" cmfa_status cmfa_mihomo_backend_test_proxy_delay_cancel_direct(const char *job_id,
                                                                          cmfa_json_buffer *output,
                                                                          cmfa_error *error);

char *g_raw_version = nullptr;
std::string g_last_validate_config_path;
std::string g_last_load_config_path;
cmfa_runtime_snapshot g_runtime_snapshot{};
cmfa_runtime_mode g_runtime_mode = CMFA_MODE_RULE;
bool g_preserve_error_on_stop = false;
cmfa_probe_result g_probe_result{};
cmfa_status g_probe_status = CMFA_OK;
std::string g_last_cancel_probe_run_id;
cmfa_status g_cancel_probe_status = CMFA_OK;
std::string g_last_close_stale_session_id;
cmfa_status g_close_stale_status = CMFA_OK;
constexpr const char *kProxyProfileHash =
    "1111111111111111111111111111111111111111111111111111111111111111";
constexpr const char *kProxyRevisionHash =
    "2222222222222222222222222222222222222222222222222222222222222222";
constexpr const char *kProxySessionHash =
    "3333333333333333333333333333333333333333333333333333333333333333";
constexpr const char *kProxyGroupsPayload = "{\"kind\":\"groups\"}";
constexpr const char *kProxyGroupPayload = "{\"kind\":\"group\"}";
constexpr const char *kProxySelectPayload = "{\"kind\":\"select\"}";
constexpr const char *kProxyDelayStartPayload = "{\"kind\":\"delay-start\"}";
constexpr const char *kProxyDelaySnapshotPayload = "{\"kind\":\"delay-snapshot\"}";
constexpr const char *kProxyDelayCancelPayload = "{\"kind\":\"delay-cancel\"}";
constexpr const char *kProxyDelayJobId = "0123456789abcdef0123456789abcdef";
enum class RawProxyMode {
  Success,
  BufferTooSmall,
  BackendError,
};
struct RawProxyCapture {
  bool called = false;
  std::string profile_hash;
  std::string revision_hash;
  const char *session_hash = reinterpret_cast<const char *>(static_cast<uintptr_t>(1));
  uint64_t generation = 0;
  uint8_t selectable_only = 0xFF;
  std::string group_name;
  std::string member_name;
  char *output = nullptr;
  size_t output_capacity = 0;
  size_t *output_length = nullptr;
  cmfa_error *error = nullptr;
};
RawProxyMode g_proxy_mode = RawProxyMode::Success;
RawProxyCapture g_proxy_groups_capture{};
RawProxyCapture g_proxy_group_capture{};
RawProxyCapture g_proxy_select_capture{};
RawProxyCapture g_proxy_delay_start_capture{};
RawProxyCapture g_proxy_delay_snapshot_capture{};
RawProxyCapture g_proxy_delay_cancel_capture{};
struct cmfa_mihomo_runtime_log_record_v1 {
  uint32_t struct_size;
  cmfa_log_level level;
  char message[4096];
};
struct StubRuntimeLog {
  cmfa_log_level level = CMFA_LOG_INFO;
  std::string message;
};
std::vector<StubRuntimeLog> g_runtime_logs;

void set_snapshot_text(char *buffer, const std::string &value) {
  std::memset(buffer, 0, CMFA_MAX_PATH_BYTES);
  const size_t copy_length = value.size() < (CMFA_MAX_PATH_BYTES - 1) ? value.size() : (CMFA_MAX_PATH_BYTES - 1);
  if (copy_length > 0) {
    std::memcpy(buffer, value.data(), copy_length);
  }
  buffer[copy_length] = '\0';
}

void reset_runtime_snapshot_storage() {
  g_runtime_snapshot = {};
  g_runtime_snapshot.struct_size = sizeof(g_runtime_snapshot);
  g_runtime_snapshot.state = CMFA_RUNTIME_STOPPED;
  g_runtime_mode = CMFA_MODE_RULE;
  g_runtime_logs.clear();
  g_probe_result = {};
  g_probe_result.struct_size = sizeof(g_probe_result);
  g_probe_result.tracker.struct_size = sizeof(g_probe_result.tracker);
  g_probe_result.error.struct_size = sizeof(g_probe_result.error);
  g_probe_status = CMFA_OK;
  g_last_cancel_probe_run_id.clear();
  g_cancel_probe_status = CMFA_OK;
  g_last_close_stale_session_id.clear();
  g_close_stale_status = CMFA_OK;
}

void reset_raw_proxy_capture(RawProxyCapture *capture) {
  if (capture == nullptr) {
    return;
  }
  *capture = {};
  capture->session_hash = reinterpret_cast<const char *>(static_cast<uintptr_t>(1));
  capture->selectable_only = 0xFF;
}

void reset_raw_proxy_state() {
  g_proxy_mode = RawProxyMode::Success;
  reset_raw_proxy_capture(&g_proxy_groups_capture);
  reset_raw_proxy_capture(&g_proxy_group_capture);
  reset_raw_proxy_capture(&g_proxy_select_capture);
  reset_raw_proxy_capture(&g_proxy_delay_start_capture);
  reset_raw_proxy_capture(&g_proxy_delay_snapshot_capture);
  reset_raw_proxy_capture(&g_proxy_delay_cancel_capture);
}

void set_fixed_text(char *buffer, size_t capacity, const char *value) {
  if (buffer == nullptr || capacity == 0) {
    throw std::runtime_error("fixed proxy buffer must be writable");
  }
  std::memset(buffer, 0, capacity);
  if (value == nullptr) {
    return;
  }
  const size_t value_length = std::strlen(value);
  const size_t copy_length = value_length < (capacity - 1) ? value_length : (capacity - 1);
  if (copy_length > 0) {
    std::memcpy(buffer, value, copy_length);
  }
  buffer[copy_length] = '\0';
}

cmfa_proxy_query_context make_proxy_query_context(bool include_session_hash) {
  cmfa_proxy_query_context context{};
  context.struct_size = sizeof(context);
  set_fixed_text(context.profile_hash, sizeof(context.profile_hash), kProxyProfileHash);
  set_fixed_text(context.revision_hash, sizeof(context.revision_hash), kProxyRevisionHash);
  set_fixed_text(context.session_hash,
                 sizeof(context.session_hash),
                 include_session_hash ? kProxySessionHash : nullptr);
  context.generation = 987654321ULL;
  return context;
}

struct JsonOutputBox {
  std::vector<char> storage;
  cmfa_json_buffer buffer{};

  explicit JsonOutputBox(size_t capacity) : storage(capacity + 1, '\0') {
    if (capacity == 0) {
      throw std::runtime_error("json output box capacity must be nonzero");
    }
    storage.front() = '\0';
    storage.back() = static_cast<char>(0x7F);
    buffer.data = storage.data();
    buffer.capacity = capacity;
    buffer.length = 0;
  }

  std::string str() const { return std::string(buffer.data != nullptr ? buffer.data : ""); }

  void fill(char value) {
    std::fill(storage.begin(), storage.end(), value);
    storage.back() = static_cast<char>(0x7F);
    buffer.length = 0;
  }
};

cmfa_status write_raw_proxy_response(RawProxyCapture *capture,
                                     uint8_t selectable_only,
                                     const char *payload,
                                     char *output,
                                     size_t output_capacity,
                                     size_t *output_length,
                                     cmfa_error *error) {
  if (capture == nullptr) {
    throw std::runtime_error("raw proxy capture must exist");
  }
  capture->called = true;
  capture->selectable_only = selectable_only;
  capture->output = output;
  capture->output_capacity = output_capacity;
  capture->output_length = output_length;
  capture->error = error;

  const size_t required_length = std::strlen(payload);
  if (output_length != nullptr) {
    *output_length = required_length;
  }
  switch (g_proxy_mode) {
    case RawProxyMode::Success:
      if (output == nullptr || output_capacity <= required_length) {
        throw std::runtime_error("raw proxy success requires full writable caller output");
      }
      std::memcpy(output, payload, required_length);
      output[required_length] = '\0';
      if (error != nullptr) {
        error->code = CMFA_OK;
        error->length = 0;
        if (error->message != nullptr && error->capacity > 0) {
          error->message[0] = '\0';
        }
      }
      return CMFA_OK;
    case RawProxyMode::BufferTooSmall:
      if (output == nullptr) {
        throw std::runtime_error("raw proxy buffer-too-small requires output");
      }
      if (output_capacity > 0) {
        output[0] = '\0';
      }
      if (error != nullptr) {
        error->code = CMFA_OK;
        error->length = 0;
        if (error->message != nullptr && error->capacity > 0) {
          error->message[0] = '\0';
        }
      }
      return CMFA_BUFFER_TOO_SMALL;
    case RawProxyMode::BackendError:
      if (output == nullptr) {
        throw std::runtime_error("raw proxy backend error requires output");
      }
      if (output_capacity > 0) {
        output[0] = '\0';
      }
      if (output_length != nullptr) {
        *output_length = 0;
      }
      if (error != nullptr) {
        error->code = CMFA_BACKEND_ERROR;
        const char *message = "synthetic backend failure";
        const size_t message_length = std::strlen(message);
        error->length = message_length;
        if (error->message != nullptr && error->capacity > 0) {
          const size_t writable = error->capacity - 1;
          const size_t copy_length = message_length < writable ? message_length : writable;
          if (copy_length > 0) {
            std::memcpy(error->message, message, copy_length);
          }
          error->message[copy_length] = '\0';
        }
      }
      return CMFA_BACKEND_ERROR;
  }
  return CMFA_BACKEND_ERROR;
}

void capture_raw_proxy_context(RawProxyCapture *capture,
                               const char *profile_hash,
                               const char *revision_hash,
                               const char *session_hash,
                               uint64_t generation) {
  if (capture == nullptr) {
    throw std::runtime_error("raw proxy capture must exist");
  }
  capture->profile_hash = profile_hash != nullptr ? profile_hash : "";
  capture->revision_hash = revision_hash != nullptr ? revision_hash : "";
  capture->session_hash = session_hash;
  capture->generation = generation;
}

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
void expect_eq(const T &actual, const U &expected, const std::string &message) {
  if (!(actual == expected)) {
    throw TestFailure(message + " (actual=" + std::to_string(static_cast<long long>(actual)) +
                      ", expected=" + std::to_string(static_cast<long long>(expected)) + ")");
  }
}

void expect_string_eq(const std::string &actual, const std::string &expected, const std::string &message) {
  if (actual != expected) {
    throw TestFailure(message + " (actual=\"" + actual + "\", expected=\"" + expected + "\")");
  }
}

void expect_string_vector_eq(const std::vector<std::string> &actual,
                             const std::vector<std::string> &expected,
                             const std::string &message) {
  if (actual.size() != expected.size()) {
    throw TestFailure(message + " size mismatch (actual=" + std::to_string(actual.size()) +
                      ", expected=" + std::to_string(expected.size()) + ")");
  }
  for (size_t index = 0; index < actual.size(); ++index) {
    if (actual[index] != expected[index]) {
      throw TestFailure(message + " mismatch at index " + std::to_string(index) + " (actual=\"" + actual[index] +
                        "\", expected=\"" + expected[index] + "\")");
    }
  }
}

void expect_vector_strings_do_not_contain(const std::vector<std::string> &values,
                                          const std::string &needle,
                                          const std::string &message) {
  for (const auto &value : values) {
    if (!needle.empty() && value.find(needle) != std::string::npos) {
      throw TestFailure(message + " (value=\"" + value + "\", needle=\"" + needle + "\")");
    }
  }
}

struct ErrorBox {
  std::array<char, 128> storage{};
  cmfa_error error{};

  ErrorBox() {
    storage.fill('\0');
    error.code = CMFA_OK;
    error.message = storage.data();
    error.capacity = storage.size();
    error.length = 0;
  }

  std::string message() const { return std::string(storage.data()); }
};

struct HostCapture {
  uint32_t log_count = 0;
  uint32_t event_count = 0;
  std::vector<cmfa_runtime_state_value> states;
  std::vector<std::string> event_messages;
  std::vector<std::string> event_codes;
  std::vector<std::string> event_session_ids;
  std::vector<std::string> event_trace_ids;
  std::vector<std::string> event_ingresses;
  std::vector<std::string> event_protocols;
  std::vector<cmfa_log_level> log_levels;
  std::vector<std::string> log_messages;
  std::vector<int> protected_fds;
  std::vector<uint32_t> protect_timeouts;
};

void capture_log(void *context, const cmfa_log_message *message) {
  auto *capture = static_cast<HostCapture *>(context);
  capture->log_count += 1;
  capture->log_levels.push_back(message != nullptr ? message->level : CMFA_LOG_ERROR);
  capture->log_messages.push_back(message != nullptr && message->message != nullptr ? message->message : "");
}

void capture_event(void *context, const cmfa_runtime_event *event) {
  auto *capture = static_cast<HostCapture *>(context);
  capture->event_count += 1;
  capture->states.push_back(event != nullptr ? event->state : CMFA_RUNTIME_ERROR);
  capture->event_messages.push_back(event != nullptr && event->message != nullptr ? event->message : "");
  capture->event_codes.push_back(event != nullptr && event->code != nullptr ? event->code : "");
  capture->event_session_ids.push_back(event != nullptr && event->session_id != nullptr ? event->session_id : "");
  capture->event_trace_ids.push_back(event != nullptr && event->trace_id != nullptr ? event->trace_id : "");
  capture->event_ingresses.push_back(event != nullptr && event->ingress != nullptr ? event->ingress : "");
  capture->event_protocols.push_back(event != nullptr && event->protocol != nullptr ? event->protocol : "");
}

cmfa_status capture_protect_socket(void *context, int fd, uint32_t timeout_ms) {
  auto *capture = static_cast<HostCapture *>(context);
  capture->protected_fds.push_back(fd);
  capture->protect_timeouts.push_back(timeout_ms);
  return CMFA_OK;
}

cmfa_host_callbacks make_host_callbacks(HostCapture *capture, cmfa_socket_protect_fn protect_socket = nullptr) {
  cmfa_host_callbacks callbacks{};
  callbacks.struct_size = sizeof(callbacks);
  callbacks.context = capture;
  callbacks.log_sink = capture_log;
  callbacks.event_sink = capture_event;
  callbacks.protect_socket = protect_socket;
  return callbacks;
}

void expect_status_message(cmfa_status status,
                           cmfa_status expected_status,
                           const ErrorBox &error,
                           const std::string &expected_message,
                           const std::string &message) {
  expect_eq(status, expected_status, message + " status");
  expect_eq(error.error.code, expected_status, message + " error code");
  expect_string_eq(error.message(), expected_message, message + " error message");
  expect_eq(error.error.length, expected_message.size(), message + " error length");
}

void reset_contract() {
  ErrorBox error;
  (void)cmfa_shutdown(&error.error);
  (void)cmfa::unregister_mihomo_backend(&error.error);
  g_raw_version = nullptr;
  g_last_validate_config_path.clear();
  g_last_load_config_path.clear();
  g_preserve_error_on_stop = false;
  reset_runtime_snapshot_storage();
  reset_raw_proxy_state();
}

#if defined(__unix__) || defined(__APPLE__)
struct GuardPageRegion {
  char *base = nullptr;
  size_t page_size = 0;
  char *version = nullptr;

  GuardPageRegion() {
    page_size = static_cast<size_t>(::sysconf(_SC_PAGESIZE));
    void *mapping = ::mmap(nullptr, page_size * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    expect(mapping != MAP_FAILED, "mmap should succeed");
    base = static_cast<char *>(mapping);
    const int protect_status = ::mprotect(base + page_size, page_size, PROT_NONE);
    expect_eq(protect_status, 0, "mprotect should succeed");
    version = base + (page_size - 256);
  }

  ~GuardPageRegion() {
    if (base != nullptr) {
      (void)::munmap(base, page_size * 2);
    }
  }
};

template <typename ChildFn>
void expect_child_success_without_signal(ChildFn child_fn, const std::string &message) {
  const pid_t child = ::fork();
  expect(child >= 0, "fork should succeed");
  if (child == 0) {
    const int exit_code = child_fn();
    _exit(exit_code);
  }

  int status = 0;
  const pid_t waited = ::waitpid(child, &status, 0);
  expect_eq(waited, child, "waitpid should return child pid");
  if (WIFSIGNALED(status)) {
    throw TestFailure(message + " (child signaled " + std::to_string(WTERMSIG(status)) + ")");
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    throw TestFailure(message + " (child exit " + std::to_string(WEXITSTATUS(status)) + ")");
  }
}
#endif

void initialize_backend(HostCapture *capture) {
  ErrorBox error;
  const cmfa_status register_status = cmfa::register_mihomo_backend(&error.error);
  expect_eq(register_status, CMFA_OK, "register should succeed");
  auto callbacks = make_host_callbacks(capture);
  const cmfa_status initialize_status = cmfa_initialize(&callbacks, &error.error);
  expect_eq(initialize_status, CMFA_OK, "initialize should succeed");
}

void test_register_initialize_and_core_version_success() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);

  std::array<char, 32> version{};
  ErrorBox error;
  const std::string raw = "v1.19.29";
  g_raw_version = const_cast<char *>(raw.c_str());

  const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);

  expect_eq(status, CMFA_OK, "core_version should succeed");
  expect_eq(error.error.code, CMFA_OK, "successful error code should be OK");
  expect_string_eq(std::string(version.data()), raw, "version should be caller-owned copy");

  reset_contract();
}

void test_duplicate_register_before_initialize_fails() {
  reset_contract();
  ErrorBox error;
  expect_eq(cmfa::register_mihomo_backend(&error.error), CMFA_OK, "first register should succeed");
  expect_status_message(cmfa::register_mihomo_backend(&error.error),
                        CMFA_INVALID_STATE,
                        error,
                        "mihomo backend is already registered",
                        "second register before initialize");
  reset_contract();
}

void test_register_and_unregister_fail_while_initialized() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  ErrorBox error;

  expect_status_message(cmfa::register_mihomo_backend(&error.error),
                        CMFA_INVALID_STATE,
                        error,
                        "backend mutation is only allowed before initialize or after shutdown",
                        "register while initialized");
  expect_status_message(cmfa::unregister_mihomo_backend(&error.error),
                        CMFA_INVALID_STATE,
                        error,
                        "backend mutation is only allowed before initialize or after shutdown",
                        "unregister while initialized");
  reset_contract();
}

void test_null_raw_version_reports_backend_error() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  std::array<char, 16> version{};
  version.fill('X');
  ErrorBox error;

  const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);

  expect_status_message(status, CMFA_BACKEND_ERROR, error, "mihomo version is null", "null raw version");
  expect_eq(version.front(), '\0', "null raw version should clear output");
  reset_contract();
}

void test_empty_raw_version_reports_backend_error() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  std::array<char, 16> version{};
  version.fill('X');
  ErrorBox error;
  char empty[] = "";
  g_raw_version = empty;

  const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);

  expect_status_message(status, CMFA_BACKEND_ERROR, error, "mihomo version is malformed", "empty raw version");
  expect_eq(version.front(), '\0', "empty raw version should clear output");
  reset_contract();
}

void test_non_terminated_256_byte_raw_fails_without_overread() {
#if defined(__unix__) || defined(__APPLE__)
  reset_contract();
  expect_child_success_without_signal([]() {
    reset_contract();
    HostCapture capture;
    initialize_backend(&capture);
    GuardPageRegion region;
    std::memset(region.version, 'v', 256);
    g_raw_version = region.version;
    std::array<char, 512> version{};
    ErrorBox error;
    const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);
    if (status != CMFA_BACKEND_ERROR) {
      return 10;
    }
    if (error.error.code != CMFA_BACKEND_ERROR) {
      return 11;
    }
    if (std::string(error.error.message) != "mihomo version is malformed") {
      return 12;
    }
    return 0;
  }, "256-byte non-terminated raw version should fail without signal");
#endif
}

void test_non_terminated_256_byte_raw_in_regular_memory_is_malformed() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  std::array<char, 256> raw{};
  raw.fill('m');
  g_raw_version = raw.data();
  std::array<char, 32> version{};
  version.fill('X');
  ErrorBox error;

  const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);

  expect_status_message(status,
                        CMFA_BACKEND_ERROR,
                        error,
                        "mihomo version is malformed",
                        "regular 256-byte non-terminated raw version");
  expect_eq(version.front(), '\0', "regular malformed version should clear output");
  reset_contract();
}

void test_255_byte_raw_rejects_too_small_output_buffer() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  std::array<char, 256> raw{};
  raw.fill('r');
  raw.back() = '\0';
  g_raw_version = raw.data();
  std::array<char, 255> version{};
  version.fill('X');
  ErrorBox error;

  const cmfa_status status = cmfa_core_version(version.data(), version.size(), &error.error);

  expect_status_message(status,
                        CMFA_BUFFER_TOO_SMALL,
                        error,
                        "version output buffer is too small",
                        "255-byte raw version with short caller buffer");
  expect_eq(version.front(), '\0', "too-small buffer should clear output");
  reset_contract();
}

void test_start_stop_and_runtime_snapshot() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  const std::string endpoint_fragment_a = "127.0.0.1:7890";
  const std::string endpoint_fragment_b = "127.0.0.1:19090";

  ErrorBox error;
  expect_status_message(cmfa_validate_config("config.yaml", &error.error),
                        CMFA_OK,
                        error,
                        "",
                        "validate_config should forward to the Go backend");
  expect_string_eq(g_last_validate_config_path, "config.yaml", "validate_config path");
  expect_status_message(cmfa_load_config("config.yaml", &error.error),
                        CMFA_OK,
                        error,
                        "",
                        "load_config should forward to the Go backend");
  expect_string_eq(g_last_load_config_path, "config.yaml", "load_config path");

  cmfa_runtime_snapshot start_snapshot{};
  start_snapshot.struct_size = sizeof(start_snapshot);
  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  const cmfa_status start_status = cmfa_start_local(&options, &start_snapshot, &error.error);
  expect_eq(start_status, CMFA_OK, "start_local should succeed");
  expect_eq(start_snapshot.state, CMFA_RUNTIME_RUNNING, "start snapshot should be running");
  expect_string_eq(std::string(start_snapshot.active_config_path), "config.yaml", "start snapshot path");
  expect_string_eq(std::string(start_snapshot.http_address), "127.0.0.1:7890", "start snapshot HTTP address");
  expect_string_eq(std::string(start_snapshot.socks_address), "127.0.0.1:19090", "start snapshot SOCKS address");
  expect_eq(capture.event_count, static_cast<uint32_t>(2), "start_local should emit STARTING and RUNNING");
  expect_eq(capture.states[0], CMFA_RUNTIME_STARTING, "first event should be STARTING");
  expect_eq(capture.states[1], CMFA_RUNTIME_RUNNING, "second event should be RUNNING");
  expect_string_vector_eq(capture.event_messages,
                          {"starting local proxy", "local proxy running"},
                          "start_local event messages should stay on the fixed safe allowlist");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       endpoint_fragment_a,
                                       "start_local events must not include HTTP endpoint");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       endpoint_fragment_b,
                                       "start_local events must not include SOCKS endpoint");
  expect_eq(capture.log_count, static_cast<uint32_t>(2), "start should emit runtime logs through host");
  expect_string_eq(capture.log_messages[0], "{\"category\":\"runtime.starting\",\"message\":\"starting local proxy\"}",
                   "first log should be structured starting log");
  expect_string_eq(capture.log_messages[1],
                   "{\"category\":\"runtime.running\",\"message\":\"local proxy running\",\"context\":{\"httpAddress\":\"127.0.0.1:7890\",\"socksAddress\":\"127.0.0.1:19090\"}}",
                   "second log should carry structured running context");

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  const cmfa_status runtime_status = cmfa_runtime_state(&snapshot, &error.error);
  expect_eq(runtime_status, CMFA_OK, "runtime_state should succeed");
  expect_eq(snapshot.state, CMFA_RUNTIME_RUNNING, "runtime_state should report running");
  expect_string_eq(std::string(snapshot.http_address), "127.0.0.1:7890", "runtime_state HTTP address");
  expect_string_eq(std::string(snapshot.socks_address), "127.0.0.1:19090", "runtime_state SOCKS address");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed");
  expect_eq(capture.event_count, static_cast<uint32_t>(4), "stop should emit STOPPING and STOPPED");
  expect_eq(capture.log_count, static_cast<uint32_t>(4), "stop should append runtime logs through host");
  expect_eq(capture.states[2], CMFA_RUNTIME_STOPPING, "third event should be STOPPING");
  expect_eq(capture.states[3], CMFA_RUNTIME_STOPPED, "fourth event should be STOPPED");
  expect_string_vector_eq(capture.event_messages,
                          {"starting local proxy", "local proxy running", "stopping local proxy", "local proxy stopped"},
                          "start/stop event messages should stay on the fixed safe allowlist");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       endpoint_fragment_a,
                                       "start/stop events must not include HTTP endpoint");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       endpoint_fragment_b,
                                       "start/stop events must not include SOCKS endpoint");
  expect_string_eq(capture.log_messages[2], "{\"category\":\"runtime.stopping\",\"message\":\"stopping local proxy\"}",
                   "third log should be structured stopping log");
  expect_string_eq(capture.log_messages[3], "{\"category\":\"runtime.stopped\",\"message\":\"local proxy stopped\"}",
                   "fourth log should be structured stopped log");
  reset_contract();
}

void test_stop_preserves_error_snapshot_event_and_redacted_failure_log() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);
  const std::string forbidden_fragment_a = "127.0.0.1:7890";
  const std::string forbidden_fragment_b = "https://alice:secret@example.invalid/config.yaml?token=abc123&password=hunter2";
  const std::string forbidden_fragment_c = "abc123";
  const std::string forbidden_fragment_d = "hunter2";
  const std::string forbidden_fragment_e = "secret";

  ErrorBox error;
  cmfa_runtime_snapshot start_snapshot{};
  start_snapshot.struct_size = sizeof(start_snapshot);
  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "/tmp/profiles/password=letmein.yaml";
  options.mixed_port = 7890;
  expect_eq(cmfa_start_local(&options, &start_snapshot, &error.error), CMFA_OK, "start_local should succeed");

  g_preserve_error_on_stop = true;
  g_runtime_snapshot.state = CMFA_RUNTIME_ERROR;
  set_snapshot_text(g_runtime_snapshot.active_config_path, "/tmp/profiles/password=letmein.yaml");
  set_snapshot_text(g_runtime_snapshot.last_error,
                    "fetch https://alice:secret@example.invalid/config.yaml?token=abc123&password=hunter2 failed");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed while preserving error");

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "runtime_state should succeed");
  expect_eq(snapshot.state, CMFA_RUNTIME_ERROR, "runtime_state should preserve error after stop");
  expect_string_eq(std::string(snapshot.last_error),
                   "fetch https://alice:secret@example.invalid/config.yaml?token=abc123&password=hunter2 failed",
                   "runtime_state should preserve diagnostic after stop");
  expect_eq(capture.states.back(), CMFA_RUNTIME_ERROR, "final event should remain ERROR");
  expect_string_vector_eq(capture.event_messages,
                          {"starting local proxy", "local proxy running", "stopping local proxy", "runtime error"},
                          "runtime error events should stay on the fixed safe allowlist");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       forbidden_fragment_a,
                                       "runtime error events must not include HTTP endpoint");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       forbidden_fragment_b,
                                       "runtime error events must not include sensitive URL");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       forbidden_fragment_c,
                                       "runtime error events must not include token");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       forbidden_fragment_d,
                                       "runtime error events must not include password");
  expect_vector_strings_do_not_contain(capture.event_messages,
                                       forbidden_fragment_e,
                                       "runtime error events must not include secret fragments");
  expect(capture.log_messages.back().find("secret") == std::string::npos, "failure log should redact userinfo/password");
  expect(capture.log_messages.back().find("abc123") == std::string::npos, "failure log should redact token");
  expect(capture.log_messages.back().find("hunter2") == std::string::npos, "failure log should redact password");
  reset_contract();
}

void test_backend_start_local_direct_null_options_preserves_snapshot() {
  reset_contract();

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  snapshot.state = CMFA_RUNTIME_ERROR;
  std::memcpy(snapshot.active_config_path, "sentinel", 9);
  snapshot.mixed_port = 9999;
  ErrorBox error;

  expect_eq(cmfa_mihomo_backend_test_start_local_direct(nullptr, &snapshot, &error.error),
            CMFA_INVALID_ARGUMENT,
            "direct backend start_local should reject null options");
  expect_eq(snapshot.state, CMFA_RUNTIME_ERROR, "backend direct start_local must not clobber caller snapshot");
  expect_string_eq(std::string(snapshot.active_config_path), "sentinel",
                   "backend direct start_local must preserve caller snapshot path");
}

void test_probe_https_returns_structured_owned_result() {
  reset_contract();
  HostCapture capture;
  initialize_backend(&capture);

  std::memset(&g_probe_result, 0, sizeof(g_probe_result));
  g_probe_result.struct_size = sizeof(g_probe_result);
  g_probe_result.protocol = CMFA_PROBE_PROTOCOL_HTTP_CONNECT;
  g_probe_result.ok = 1;
  g_probe_result.http_status = 200;
  g_probe_result.body_bytes = 23;
  g_probe_result.tracker.struct_size = sizeof(g_probe_result.tracker);
  g_probe_result.error.struct_size = sizeof(g_probe_result.error);
  std::snprintf(g_probe_result.probe_run_id, sizeof(g_probe_result.probe_run_id), "%s", "probe-run");
  std::snprintf(g_probe_result.request_id_echo, sizeof(g_probe_result.request_id_echo), "%s", "probe-run");
  std::snprintf(g_probe_result.origin_id, sizeof(g_probe_result.origin_id), "%s", "origin-1");
  std::snprintf(g_probe_result.response_sha256, sizeof(g_probe_result.response_sha256), "%s",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  std::snprintf(g_probe_result.tls_peer_sha256, sizeof(g_probe_result.tls_peer_sha256), "%s",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
  std::snprintf(g_probe_result.started_at, sizeof(g_probe_result.started_at), "%s", "2026-08-06T06:00:00Z");
  std::snprintf(g_probe_result.completed_at, sizeof(g_probe_result.completed_at), "%s", "2026-08-06T06:00:01Z");
  std::snprintf(g_probe_result.client_local_address, sizeof(g_probe_result.client_local_address), "%s", "127.0.0.1:50001");
  std::snprintf(g_probe_result.client_remote_address, sizeof(g_probe_result.client_remote_address), "%s", "127.0.0.1:7890");
  std::snprintf(g_probe_result.tracker.connection_id, sizeof(g_probe_result.tracker.connection_id), "%s", "tracker-1");
  std::snprintf(g_probe_result.tracker.source_address, sizeof(g_probe_result.tracker.source_address), "%s", "127.0.0.1:50001");
  std::snprintf(g_probe_result.tracker.destination_address, sizeof(g_probe_result.tracker.destination_address), "%s", "127.0.0.1:9443");
  std::snprintf(g_probe_result.tracker.inbound_type, sizeof(g_probe_result.tracker.inbound_type), "%s", "HTTPS");
  std::snprintf(g_probe_result.tracker.opened_at, sizeof(g_probe_result.tracker.opened_at), "%s", "2026-08-06T06:00:00Z");
  g_probe_status = CMFA_OK;

  cmfa_probe_request request{};
  request.struct_size = sizeof(request);
  request.probe_run_id = "probe-run";
  request.protocol = CMFA_PROBE_PROTOCOL_HTTP_CONNECT;
  request.listener_address = "127.0.0.1:7890";
  request.origin_url = "https://127.0.0.1:9443/";
  request.ca_pem = "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n";
  request.expected_body_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

  cmfa_probe_result *result = nullptr;
  ErrorBox error;
  expect_eq(cmfa_probe_https(&request, &result, &error.error), CMFA_OK, "probe should succeed");
  expect(result != nullptr, "probe should return an owned result");
  expect_eq(result->protocol, CMFA_PROBE_PROTOCOL_HTTP_CONNECT, "protocol should match");
  expect_eq(result->ok, static_cast<uint8_t>(1), "probe result should be ok");
  expect_eq(result->http_status, 200, "HTTP status should match");
  expect_string_eq(std::string(result->tracker.inbound_type), "HTTPS", "tracker inbound type");
  expect_string_eq(std::string(result->origin_id), "origin-1", "origin id");
  cmfa_probe_result_free(result);
}

void test_cancel_probe_forwards_run_id_to_go_backend() {
  reset_contract();
  ErrorBox error;
  g_cancel_probe_status = CMFA_OK;

  expect_eq(cmfa::cancel_mihomo_probe("probe-run", &error.error), CMFA_OK, "cancel should succeed");
  expect_string_eq(g_last_cancel_probe_run_id, "probe-run", "cancel should forward the exact probeRunID");
}

void test_cancel_probe_rejects_empty_run_id() {
  reset_contract();
  ErrorBox error;

  expect_eq(cmfa::cancel_mihomo_probe("", &error.error),
            CMFA_INVALID_ARGUMENT,
            "cancel should reject an empty probeRunID");
  expect(error.message().find("probeRunID") != std::string::npos, "cancel failure should explain the invalid run id");
}

void test_shutdown_and_repeated_unregister_are_safe() {
  reset_contract();
  HostCapture first_capture;
  initialize_backend(&first_capture);
  ErrorBox error;
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should succeed");
  expect_eq(cmfa::unregister_mihomo_backend(&error.error), CMFA_OK, "first unregister should succeed");
  expect_eq(cmfa::unregister_mihomo_backend(&error.error), CMFA_OK, "second unregister should stay safe");

  HostCapture second_capture;
  initialize_backend(&second_capture);
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "reinitialized runtime_state should succeed");
  expect_eq(first_capture.event_count, static_cast<uint32_t>(0), "old host bridge should not retain listeners");
  expect_eq(second_capture.event_count, static_cast<uint32_t>(0), "new host should stay idle");
  reset_contract();
}

void test_close_stale_tun_connections_forwards_session_id_to_go_backend() {
  reset_contract();
  ErrorBox error;

  const cmfa_status status = cmfa::close_stale_tun_connections_for_mihomo_backend("session-1", &error.error);

  expect_eq(status, CMFA_OK, "close stale should succeed");
  expect_string_eq(g_last_close_stale_session_id, "session-1", "close stale should forward session id");
  reset_contract();
}

void test_close_stale_tun_connections_rejects_empty_session_id() {
  reset_contract();
  ErrorBox error;

  expect_status_message(cmfa::close_stale_tun_connections_for_mihomo_backend("", &error.error),
                        CMFA_INVALID_ARGUMENT,
                        error,
                        "tun session id must not be empty",
                        "empty close stale session");
  reset_contract();
}

void test_proxy_wrapper_direct_forwarding_and_success_payload() {
  reset_contract();
  ErrorBox error;
  JsonOutputBox groups_output(64);
  JsonOutputBox group_output(64);
  JsonOutputBox select_output(64);
  const auto sessionless_query = make_proxy_query_context(false);
  const auto session_query = make_proxy_query_context(true);

  expect_eq(cmfa_mihomo_backend_test_proxy_groups_direct(&sessionless_query, 1, &groups_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_groups wrapper should succeed");
  expect(g_proxy_groups_capture.called, "raw proxy_groups stub should be invoked");
  expect_string_eq(g_proxy_groups_capture.profile_hash, kProxyProfileHash, "proxy_groups should forward profile hash");
  expect_string_eq(g_proxy_groups_capture.revision_hash,
                   kProxyRevisionHash,
                   "proxy_groups should forward revision hash");
  expect(g_proxy_groups_capture.session_hash == nullptr, "proxy_groups should canonicalize empty session as null");
  expect_eq(g_proxy_groups_capture.generation, sessionless_query.generation, "proxy_groups should forward generation");
  expect_eq(g_proxy_groups_capture.selectable_only, static_cast<uint8_t>(1), "proxy_groups should forward selectable_only");
  expect(g_proxy_groups_capture.output == groups_output.buffer.data, "proxy_groups should forward caller output pointer");
  expect_eq(g_proxy_groups_capture.output_capacity,
            groups_output.buffer.capacity,
            "proxy_groups should forward caller output capacity");
  expect(g_proxy_groups_capture.output_length == &groups_output.buffer.length,
         "proxy_groups should forward caller output length pointer");
  expect(g_proxy_groups_capture.error == &error.error, "proxy_groups should forward caller error pointer");
  expect_string_eq(groups_output.str(), kProxyGroupsPayload, "proxy_groups should write the synthetic payload");
  expect_eq(groups_output.buffer.length, std::strlen(kProxyGroupsPayload), "proxy_groups should preserve payload length");

  expect_eq(cmfa_mihomo_backend_test_proxy_group_direct(&session_query, "alpha", &group_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_group wrapper should succeed");
  expect(g_proxy_group_capture.called, "raw proxy_group stub should be invoked");
  expect(g_proxy_group_capture.session_hash != nullptr, "proxy_group should forward nonempty session");
  expect_string_eq(g_proxy_group_capture.session_hash, kProxySessionHash, "proxy_group should preserve exact session hash");
  expect_eq(g_proxy_group_capture.generation, session_query.generation, "proxy_group should forward generation");
  expect_string_eq(g_proxy_group_capture.group_name, "alpha", "proxy_group should forward group name");
  expect(g_proxy_group_capture.output == group_output.buffer.data, "proxy_group should forward caller output pointer");
  expect_eq(g_proxy_group_capture.output_capacity,
            group_output.buffer.capacity,
            "proxy_group should forward caller output capacity");
  expect(g_proxy_group_capture.output_length == &group_output.buffer.length,
         "proxy_group should forward caller output length pointer");
  expect(g_proxy_group_capture.error == &error.error, "proxy_group should forward caller error pointer");
  expect_string_eq(group_output.str(), kProxyGroupPayload, "proxy_group should write the synthetic payload");

  expect_eq(cmfa_mihomo_backend_test_proxy_select_direct(&session_query, "alpha", "beta", &select_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_select wrapper should succeed");
  expect(g_proxy_select_capture.called, "raw proxy_select stub should be invoked");
  expect_string_eq(g_proxy_select_capture.group_name, "alpha", "proxy_select should forward group name");
  expect_string_eq(g_proxy_select_capture.member_name, "beta", "proxy_select should forward member name");
  expect(g_proxy_select_capture.output == select_output.buffer.data,
         "proxy_select should forward caller output pointer");
  expect_eq(g_proxy_select_capture.output_capacity,
            select_output.buffer.capacity,
            "proxy_select should forward caller output capacity");
  expect(g_proxy_select_capture.output_length == &select_output.buffer.length,
         "proxy_select should forward caller output length pointer");
  expect(g_proxy_select_capture.error == &error.error, "proxy_select should forward caller error pointer");
  expect_string_eq(select_output.str(), kProxySelectPayload, "proxy_select should write the synthetic payload");

  reset_contract();
}

void test_proxy_wrapper_direct_buffer_too_small_and_backend_error_preserve_contract() {
  reset_contract();
  const auto query = make_proxy_query_context(true);
  ErrorBox error;
  JsonOutputBox small_output(8);
  small_output.fill('Q');
  g_proxy_mode = RawProxyMode::BufferTooSmall;

  expect_eq(cmfa_mihomo_backend_test_proxy_groups_direct(&query, 0, &small_output.buffer, &error.error),
            CMFA_BUFFER_TOO_SMALL,
            "direct proxy_groups wrapper should surface buffer-too-small");
  expect(g_proxy_groups_capture.called, "buffer-too-small should still invoke raw proxy_groups");
  expect_eq(small_output.buffer.length,
            std::strlen(kProxyGroupsPayload),
            "buffer-too-small should report required payload length");
  expect_eq(small_output.buffer.data[0], '\0', "buffer-too-small should not leave partial payload");

  JsonOutputBox failed_output(64);
  failed_output.fill('R');
  error.storage.fill('\0');
  error.error.code = CMFA_OK;
  error.error.length = 0;
  g_proxy_mode = RawProxyMode::BackendError;

  expect_eq(cmfa_mihomo_backend_test_proxy_select_direct(&query, "alpha", "beta", &failed_output.buffer, &error.error),
            CMFA_BACKEND_ERROR,
            "direct proxy_select wrapper should preserve backend error status");
  expect(g_proxy_select_capture.called, "backend error should still invoke raw proxy_select");
  expect_eq(failed_output.buffer.length, static_cast<size_t>(0), "backend error should clear public length");
  expect_eq(failed_output.buffer.data[0], '\0', "backend error should clear public output");
  expect_eq(error.error.code, CMFA_BACKEND_ERROR, "backend error code should be preserved");
  expect_string_eq(error.message(), "synthetic backend failure", "backend error detail should be preserved");

  reset_contract();
}

void test_proxy_delay_wrapper_direct_forwarding_and_success_payload() {
  reset_contract();
  ErrorBox error;
  JsonOutputBox start_output(64);
  JsonOutputBox snapshot_output(64);
  JsonOutputBox cancel_output(64);
  const auto sessionless_query = make_proxy_query_context(false);
  const auto session_query = make_proxy_query_context(true);

  expect_eq(cmfa_mihomo_backend_test_proxy_delay_start_direct(&sessionless_query, "alpha", &start_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_delay_start wrapper should succeed");
  expect(g_proxy_delay_start_capture.called, "raw proxy_delay_start stub should be invoked");
  expect_string_eq(g_proxy_delay_start_capture.profile_hash, kProxyProfileHash,
                   "proxy_delay_start should forward profile hash");
  expect_string_eq(g_proxy_delay_start_capture.revision_hash, kProxyRevisionHash,
                   "proxy_delay_start should forward revision hash");
  expect(g_proxy_delay_start_capture.session_hash == nullptr,
         "proxy_delay_start should canonicalize empty session as null");
  expect_eq(g_proxy_delay_start_capture.generation, sessionless_query.generation,
            "proxy_delay_start should forward generation");
  expect_string_eq(g_proxy_delay_start_capture.group_name, "alpha", "proxy_delay_start should forward group name");
  expect(g_proxy_delay_start_capture.output == start_output.buffer.data,
         "proxy_delay_start should forward caller output pointer");
  expect_eq(g_proxy_delay_start_capture.output_capacity,
            start_output.buffer.capacity,
            "proxy_delay_start should forward caller output capacity");
  expect(g_proxy_delay_start_capture.output_length == &start_output.buffer.length,
         "proxy_delay_start should forward caller output length pointer");
  expect(g_proxy_delay_start_capture.error == &error.error, "proxy_delay_start should forward caller error pointer");
  expect_string_eq(start_output.str(), kProxyDelayStartPayload, "proxy_delay_start should write the synthetic payload");

  expect_eq(cmfa_mihomo_backend_test_proxy_delay_snapshot_direct(kProxyDelayJobId, &snapshot_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_delay_snapshot wrapper should succeed");
  expect(g_proxy_delay_snapshot_capture.called, "raw proxy_delay_snapshot stub should be invoked");
  expect_string_eq(g_proxy_delay_snapshot_capture.group_name, kProxyDelayJobId,
                   "proxy_delay_snapshot should forward job id");
  expect(g_proxy_delay_snapshot_capture.output == snapshot_output.buffer.data,
         "proxy_delay_snapshot should forward caller output pointer");
  expect_eq(g_proxy_delay_snapshot_capture.output_capacity,
            snapshot_output.buffer.capacity,
            "proxy_delay_snapshot should forward caller output capacity");
  expect(g_proxy_delay_snapshot_capture.output_length == &snapshot_output.buffer.length,
         "proxy_delay_snapshot should forward caller output length pointer");
  expect(g_proxy_delay_snapshot_capture.error == &error.error,
         "proxy_delay_snapshot should forward caller error pointer");
  expect_string_eq(snapshot_output.str(), kProxyDelaySnapshotPayload,
                   "proxy_delay_snapshot should write the synthetic payload");

  expect_eq(cmfa_mihomo_backend_test_proxy_delay_start_direct(&session_query, "beta", &cancel_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_delay_start wrapper should preserve nonempty session");
  expect(g_proxy_delay_start_capture.session_hash != nullptr, "proxy_delay_start should forward nonempty session");
  expect_string_eq(g_proxy_delay_start_capture.session_hash, kProxySessionHash,
                   "proxy_delay_start should preserve exact session hash");

  JsonOutputBox cancel_direct_output(64);
  expect_eq(cmfa_mihomo_backend_test_proxy_delay_cancel_direct(kProxyDelayJobId, &cancel_direct_output.buffer, &error.error),
            CMFA_OK,
            "direct proxy_delay_cancel wrapper should succeed");
  expect(g_proxy_delay_cancel_capture.called, "raw proxy_delay_cancel stub should be invoked");
  expect_string_eq(g_proxy_delay_cancel_capture.group_name, kProxyDelayJobId,
                   "proxy_delay_cancel should forward job id via capture");
  expect(g_proxy_delay_cancel_capture.output == cancel_direct_output.buffer.data,
         "proxy_delay_cancel should forward caller output pointer");
  expect_eq(g_proxy_delay_cancel_capture.output_capacity,
            cancel_direct_output.buffer.capacity,
            "proxy_delay_cancel should forward caller output capacity");
  expect(g_proxy_delay_cancel_capture.output_length == &cancel_direct_output.buffer.length,
         "proxy_delay_cancel should forward caller output length pointer");
  expect(g_proxy_delay_cancel_capture.error == &error.error,
         "proxy_delay_cancel should forward caller error pointer");
  expect_string_eq(cancel_direct_output.str(), kProxyDelayCancelPayload,
                   "proxy_delay_cancel should write the synthetic payload");

  reset_contract();
}

void test_proxy_delay_wrapper_direct_buffer_too_small_and_backend_error_preserve_contract() {
  reset_contract();
  ErrorBox error;
  JsonOutputBox small_output(8);
  small_output.fill('Q');
  g_proxy_mode = RawProxyMode::BufferTooSmall;

  expect_eq(cmfa_mihomo_backend_test_proxy_delay_snapshot_direct(kProxyDelayJobId, &small_output.buffer, &error.error),
            CMFA_BUFFER_TOO_SMALL,
            "direct proxy_delay_snapshot wrapper should surface buffer-too-small");
  expect(g_proxy_delay_snapshot_capture.called, "buffer-too-small should still invoke raw proxy_delay_snapshot");
  expect_eq(small_output.buffer.length,
            std::strlen(kProxyDelaySnapshotPayload),
            "buffer-too-small should report required payload length");
  expect_eq(small_output.buffer.data[0], '\0', "buffer-too-small should not leave partial payload");

  JsonOutputBox failed_output(64);
  failed_output.fill('R');
  error.storage.fill('\0');
  error.error.code = CMFA_OK;
  error.error.length = 0;
  g_proxy_mode = RawProxyMode::BackendError;

  expect_eq(cmfa_mihomo_backend_test_proxy_delay_cancel_direct(kProxyDelayJobId, &failed_output.buffer, &error.error),
            CMFA_BACKEND_ERROR,
            "direct proxy_delay_cancel wrapper should preserve backend error status");
  expect(g_proxy_delay_cancel_capture.called, "backend error should still invoke raw proxy_delay_cancel");
  expect_eq(failed_output.buffer.length, static_cast<size_t>(0), "backend error should clear public length");
  expect_eq(failed_output.buffer.data[0], '\0', "backend error should clear public output");
  expect_eq(error.error.code, CMFA_BACKEND_ERROR, "backend error code should be preserved");
  expect_string_eq(error.message(), "synthetic backend failure", "backend error detail should be preserved");

  reset_contract();
}

void test_registered_proxy_callbacks_complete_abi_smoke_and_lifecycle() {
  reset_contract();
  HostCapture capture;
  ErrorBox error;
  expect_eq(cmfa::register_mihomo_backend(&error.error), CMFA_OK, "register should succeed when proxy callbacks are complete");
  auto callbacks = make_host_callbacks(&capture);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto sessionless_query = make_proxy_query_context(false);
  JsonOutputBox groups_output(64);
  g_proxy_mode = RawProxyMode::Success;
  expect_eq(cmfa_proxy_groups(&sessionless_query, 1, &groups_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_groups should reach registered backend wrapper");
  expect(g_proxy_groups_capture.called, "public proxy_groups should invoke raw proxy_groups");
  expect(g_proxy_groups_capture.session_hash == nullptr, "public proxy_groups should canonicalize empty session as null");
  expect_eq(g_proxy_groups_capture.selectable_only, static_cast<uint8_t>(1), "public proxy_groups should forward selectable_only");
  expect_eq(g_proxy_groups_capture.output_capacity,
            groups_output.buffer.capacity,
            "public proxy_groups should pass the working output capacity");
  expect_eq(groups_output.buffer.length, std::strlen(kProxyGroupsPayload), "public proxy_groups should preserve payload length");
  expect_string_eq(groups_output.str(), kProxyGroupsPayload, "public proxy_groups should copy payload back to caller");

  const auto session_query = make_proxy_query_context(true);
  JsonOutputBox group_output(64);
  expect_eq(cmfa_proxy_group(&session_query, "alpha", &group_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_group should reach registered backend wrapper");
  expect_string_eq(g_proxy_group_capture.group_name, "alpha", "public proxy_group should forward group name");
  expect(g_proxy_group_capture.session_hash != nullptr, "public proxy_group should forward nonempty session");
  expect_string_eq(g_proxy_group_capture.session_hash, kProxySessionHash, "public proxy_group should preserve exact session hash");

  JsonOutputBox select_output(64);
  expect_eq(cmfa_proxy_select(&session_query, "alpha", "beta", &select_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_select should reach registered backend wrapper");
  expect_string_eq(g_proxy_select_capture.group_name, "alpha", "public proxy_select should forward group name");
  expect_string_eq(g_proxy_select_capture.member_name, "beta", "public proxy_select should forward member name");
  expect_eq(g_proxy_select_capture.generation, session_query.generation, "public proxy_select should forward generation");
  expect_eq(select_output.buffer.length, std::strlen(kProxySelectPayload), "public proxy_select should preserve payload length");
  expect_string_eq(select_output.str(), kProxySelectPayload, "public proxy_select should copy payload back to caller");

  JsonOutputBox delay_start_output(64);
  expect_eq(cmfa_proxy_delay_start(&sessionless_query, "alpha", &delay_start_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_delay_start should reach registered backend wrapper");
  expect(g_proxy_delay_start_capture.called, "public proxy_delay_start should invoke raw proxy_delay_start");
  expect(g_proxy_delay_start_capture.session_hash == nullptr,
         "public proxy_delay_start should canonicalize empty session as null");
  expect_string_eq(g_proxy_delay_start_capture.group_name, "alpha", "public proxy_delay_start should forward group name");
  expect_eq(delay_start_output.buffer.length,
            std::strlen(kProxyDelayStartPayload),
            "public proxy_delay_start should preserve payload length");
  expect_string_eq(delay_start_output.str(), kProxyDelayStartPayload,
                   "public proxy_delay_start should copy payload back to caller");

  JsonOutputBox delay_snapshot_output(64);
  expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &delay_snapshot_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_delay_snapshot should reach registered backend wrapper");
  expect(g_proxy_delay_snapshot_capture.called,
         "public proxy_delay_snapshot should invoke raw proxy_delay_snapshot");
  expect_string_eq(g_proxy_delay_snapshot_capture.group_name, kProxyDelayJobId,
                   "public proxy_delay_snapshot should forward job id");
  expect_eq(delay_snapshot_output.buffer.length,
            std::strlen(kProxyDelaySnapshotPayload),
            "public proxy_delay_snapshot should preserve payload length");

  JsonOutputBox delay_cancel_output(64);
  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &delay_cancel_output.buffer, &error.error),
            CMFA_OK,
            "public proxy_delay_cancel should reach registered backend wrapper");
  expect(g_proxy_delay_cancel_capture.called, "public proxy_delay_cancel should invoke raw proxy_delay_cancel");
  expect_string_eq(g_proxy_delay_cancel_capture.group_name, kProxyDelayJobId,
                   "public proxy_delay_cancel should forward job id");
  expect_eq(delay_cancel_output.buffer.length,
            std::strlen(kProxyDelayCancelPayload),
            "public proxy_delay_cancel should preserve payload length");

  JsonOutputBox small_output(8);
  g_proxy_mode = RawProxyMode::BufferTooSmall;
  expect_eq(cmfa_proxy_groups(&session_query, 0, &small_output.buffer, &error.error),
            CMFA_BUFFER_TOO_SMALL,
            "public proxy_groups should surface raw buffer-too-small");
  expect_eq(small_output.buffer.length,
            std::strlen(kProxyGroupsPayload),
            "public proxy_groups should preserve required length on buffer-too-small");
  expect_eq(small_output.buffer.data[0], '\0', "public proxy_groups should not expose partial payload");

  JsonOutputBox failed_output(64);
  g_proxy_mode = RawProxyMode::BackendError;
  expect_eq(cmfa_proxy_select(&session_query, "alpha", "beta", &failed_output.buffer, &error.error),
            CMFA_BACKEND_ERROR,
            "public proxy_select should preserve raw backend error");
  expect_eq(failed_output.buffer.length, static_cast<size_t>(0), "public proxy_select should clear output on backend error");
  expect_eq(failed_output.buffer.data[0], '\0', "public proxy_select should clear bytes on backend error");
  expect_eq(error.error.code, CMFA_BACKEND_ERROR, "public proxy_select should preserve raw error code");
  expect_string_eq(error.message(), "synthetic backend failure", "public proxy_select should preserve raw error detail");

  JsonOutputBox delay_small_output(8);
  g_proxy_mode = RawProxyMode::BufferTooSmall;
  expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &delay_small_output.buffer, &error.error),
            CMFA_BUFFER_TOO_SMALL,
            "public proxy_delay_snapshot should surface raw buffer-too-small");
  expect_eq(delay_small_output.buffer.length,
            std::strlen(kProxyDelaySnapshotPayload),
            "public proxy_delay_snapshot should preserve required length on buffer-too-small");
  expect_eq(delay_small_output.buffer.data[0], '\0',
            "public proxy_delay_snapshot should not expose partial payload");

  JsonOutputBox delay_failed_output(64);
  g_proxy_mode = RawProxyMode::BackendError;
  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &delay_failed_output.buffer, &error.error), CMFA_BACKEND_ERROR,
            "public proxy_delay_cancel should preserve raw backend error");
  expect_eq(delay_failed_output.buffer.length, static_cast<size_t>(0),
            "public proxy_delay_cancel should clear output on backend error");
  expect_eq(delay_failed_output.buffer.data[0], '\0',
            "public proxy_delay_cancel should clear bytes on backend error");
  expect_eq(error.error.code, CMFA_BACKEND_ERROR, "public proxy_delay_cancel should preserve raw error code");
  expect_string_eq(error.message(), "synthetic backend failure",
                   "public proxy_delay_cancel should preserve raw error detail");

  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should succeed after proxy operations");
  expect_eq(cmfa::unregister_mihomo_backend(&error.error), CMFA_OK, "unregister should succeed after shutdown");
  JsonOutputBox post_unregister_output(64);
  expect_eq(cmfa_proxy_groups(&session_query, 0, &post_unregister_output.buffer, &error.error),
            CMFA_NOT_INITIALIZED,
            "proxy API should reject calls after shutdown and unregister lifecycle completes");
  expect_eq(post_unregister_output.buffer.length, static_cast<size_t>(0), "post-unregister proxy call should clear output length");
  expect_eq(post_unregister_output.buffer.data[0], '\0', "post-unregister proxy call should clear output bytes");

  reset_contract();
}

void test_visible_host_protect_bridge_symbol_can_be_found_and_called() {
  reset_contract();
  HostCapture capture;
  ErrorBox error;
  expect_eq(cmfa::register_mihomo_backend(&error.error), CMFA_OK, "register should succeed");
  auto callbacks = make_host_callbacks(&capture, capture_protect_socket);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

#if defined(__unix__) || defined(__APPLE__)
  void *symbol = dlsym(RTLD_DEFAULT, "cmfa_host_protect_socket_bridge_v1");
  expect(symbol != nullptr, "visible host protect bridge symbol should be discoverable via dlsym");
  using bridge_fn = cmfa_status (*)(int, uint32_t, cmfa_error *);
  auto bridge = reinterpret_cast<bridge_fn>(symbol);
  expect_eq(bridge(77, 1234U, &error.error), CMFA_OK, "visible host protect bridge should call through successfully");
  expect_eq(capture.protected_fds.size(), static_cast<size_t>(1), "protect callback should be invoked exactly once");
  expect_eq(capture.protected_fds[0], 77, "protect callback should receive fd");
  expect_eq(capture.protect_timeouts[0], 1234U, "protect callback should receive timeout");
#endif

  reset_contract();
}

void test_runtime_log_pump_consumes_fixed_tun_stage_diagnostics() {
  reset_contract();
  HostCapture capture;
  ErrorBox error;
  expect_eq(cmfa::register_mihomo_backend(&error.error), CMFA_OK, "register should succeed");
  auto callbacks = make_host_callbacks(&capture);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");
  constexpr std::array<const char *, 15> kFixedTunStopStages = {
      "tun.stop.listener.begin",
      "tun.stop.listener.ok",
      "tun.stop.listener.failed",
      "tun.stop.http-listener.begin",
      "tun.stop.http-listener.ok",
      "tun.stop.http-listener.failed",
      "tun.stop.socks-listener.begin",
      "tun.stop.socks-listener.ok",
      "tun.stop.socks-listener.failed",
      "tun.stop.connections.begin",
      "tun.stop.connections.ok",
      "tun.stop.connections.failed",
      "tun.stop.executor.begin",
      "tun.stop.executor.ok",
      "tun.stop.executor.failed",
  };

  g_runtime_logs.push_back({CMFA_LOG_INFO, "ordinary-runtime-log"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.prepare.begin"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.listener.endpoint-enter"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.listener.failure.stack-start"});
  for (const char *stage : kFixedTunStopStages) {
    g_runtime_logs.push_back({CMFA_LOG_INFO, stage});
  }
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.packet.read-loop-enter"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.listener.failed:secret"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "tun.stop.listener.failed:secret"});
  cmfa_mihomo_backend_test_emit_runtime_logs();

  expect_eq(capture.log_count,
            static_cast<uint32_t>(3),
            "only the exact fixed stage should be consumed by native diagnostics");
  expect_string_eq(capture.log_messages[0], "ordinary-runtime-log", "ordinary log should be delivered");
  expect_string_eq(capture.log_messages[1],
                   "tun.listener.failed:secret",
                   "dynamic stage suffix should remain an ordinary log");
  expect_string_eq(capture.log_messages[2],
                   "tun.stop.listener.failed:secret",
                   "dynamic stop stage suffix should remain an ordinary log");
  expect_eq(capture.event_count,
            static_cast<uint32_t>(1),
            "fixed packet diagnostics should use the private runtime event fallback");
  expect_string_eq(capture.event_messages[0],
                   "tun.packet.read-loop-enter",
                   "packet diagnostic fallback should keep only the fixed stage");
  expect_string_eq(capture.event_session_ids[0],
                   "session-test",
                   "packet diagnostic fallback should preserve only the current session correlation");
  expect_string_eq(capture.event_ingresses[0], "diagnostic", "packet diagnostic fallback ingress should be fixed");
  expect_string_eq(capture.event_protocols[0],
                   "tun.packet.read-loop-enter",
                   "packet diagnostic fallback protocol should equal the fixed stage");
  expect_string_eq(capture.event_codes[0], "", "packet diagnostic fallback must not copy an error code");
  expect_string_eq(capture.event_trace_ids[0], "", "packet diagnostic fallback must not copy a trace payload");
  reset_contract();
}

void test_visible_host_runtime_event_bridge_preserves_packet_diagnostic_forwarding() {
  reset_contract();
  HostCapture capture;
  ErrorBox error;
  expect_eq(cmfa::register_mihomo_backend(&error.error), CMFA_OK, "register should succeed");
  auto callbacks = make_host_callbacks(&capture);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

#if defined(__unix__) || defined(__APPLE__)
  void *symbol = dlsym(RTLD_DEFAULT, "cmfa_host_emit_runtime_event_bridge_v1");
  expect(symbol != nullptr, "visible host runtime event bridge symbol should be discoverable via dlsym");
  using bridge_fn = cmfa_status (*)(const cmfa_runtime_event *, cmfa_error *);
  auto bridge = reinterpret_cast<bridge_fn>(symbol);

  cmfa_runtime_event event{};
  event.struct_size = sizeof(event);
  event.state = CMFA_RUNTIME_RUNNING;
  event.message = "tun.packet.raw-read";
  event.code = "ignored-code";
  event.session_id = "session-forward";
  event.trace_id = "trace-forward";
  event.ingress = "diagnostic";
  event.protocol = "tun.packet.raw-read";

  expect_eq(bridge(&event, &error.error), CMFA_OK, "visible host runtime event bridge should call through successfully");
  expect_eq(capture.event_count, static_cast<uint32_t>(1), "event callback should be invoked exactly once");
  expect_eq(capture.states[0], CMFA_RUNTIME_RUNNING, "event state should be forwarded");
  expect_string_eq(capture.event_messages[0], "tun.packet.raw-read", "event message should be forwarded");
  expect_string_eq(capture.event_codes[0], "ignored-code", "event code should be forwarded");
  expect_string_eq(capture.event_session_ids[0], "session-forward", "event session id should be forwarded");
  expect_string_eq(capture.event_trace_ids[0], "trace-forward", "event trace id should be forwarded");
  expect_string_eq(capture.event_ingresses[0], "diagnostic", "event ingress should be forwarded");
  expect_string_eq(capture.event_protocols[0], "tun.packet.raw-read", "event protocol should be forwarded");
#endif

  reset_contract();
}

} // namespace

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void) { return g_raw_version; }

extern "C" cmfa_status cmfa_mihomo_validate_config_v1(const char *config_path, cmfa_error *) {
  if (config_path == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  g_last_validate_config_path = config_path;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_load_config_v1(const char *config_path, cmfa_error *) {
  if (config_path == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  g_last_load_config_path = config_path;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_start_local_v1(const char *config_path,
                                                  uint32_t mixed_port,
                                                  cmfa_runtime_snapshot *snapshot,
                                                  cmfa_error *) {
  if (config_path == nullptr || snapshot == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }

  reset_runtime_snapshot_storage();
  g_runtime_snapshot.state = CMFA_RUNTIME_RUNNING;
  g_runtime_snapshot.mixed_port = mixed_port;
  set_snapshot_text(g_runtime_snapshot.active_config_path, config_path);
  set_snapshot_text(g_runtime_snapshot.http_address, "127.0.0.1:" + std::to_string(mixed_port));
  set_snapshot_text(g_runtime_snapshot.socks_address, "127.0.0.1:19090");
  g_runtime_logs.push_back({CMFA_LOG_INFO, "{\"category\":\"runtime.starting\",\"message\":\"starting local proxy\"}"});
  g_runtime_logs.push_back(
      {CMFA_LOG_INFO,
       "{\"category\":\"runtime.running\",\"message\":\"local proxy running\",\"context\":{\"httpAddress\":\"127.0.0.1:7890\",\"socksAddress\":\"127.0.0.1:19090\"}}"});
  *snapshot = g_runtime_snapshot;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_stop_v1(cmfa_error *) {
  if (g_preserve_error_on_stop) {
    g_runtime_logs.push_back({CMFA_LOG_INFO, "{\"category\":\"runtime.stopping\",\"message\":\"stopping local proxy\"}"});
    g_runtime_logs.push_back(
        {CMFA_LOG_ERROR,
         "{\"category\":\"runtime.stop.error\",\"message\":\"fetch https://<redacted>@example.invalid/config.yaml?token=<redacted>&password=<redacted> failed\",\"context\":{\"configPath\":\"<redacted-path>\"}}"});
    return CMFA_OK;
  }
  g_runtime_logs.push_back({CMFA_LOG_INFO, "{\"category\":\"runtime.stopping\",\"message\":\"stopping local proxy\"}"});
  g_runtime_logs.push_back({CMFA_LOG_INFO, "{\"category\":\"runtime.stopped\",\"message\":\"local proxy stopped\"}"});
  g_runtime_snapshot = {};
  g_runtime_snapshot.struct_size = sizeof(g_runtime_snapshot);
  g_runtime_snapshot.state = CMFA_RUNTIME_STOPPED;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_runtime_state_v1(cmfa_runtime_snapshot *snapshot, cmfa_error *) {
  if (snapshot == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  *snapshot = g_runtime_snapshot;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_runtime_mode_v1(cmfa_runtime_mode *mode, cmfa_error *) {
  if (mode == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  *mode = g_runtime_mode;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_set_runtime_mode_v1(cmfa_runtime_mode mode, cmfa_error *) {
  g_runtime_mode = mode;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_probe_https_v1(const cmfa_probe_request *request,
                                                  cmfa_probe_result *result,
                                                  cmfa_error *) {
  if (request == nullptr || result == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  *result = g_probe_result;
  result->protocol = request->protocol;
  return g_probe_status;
}

extern "C" cmfa_status cmfa_mihomo_probe_cancel_v1(const char *probe_run_id, cmfa_error *) {
  g_last_cancel_probe_run_id = probe_run_id != nullptr ? probe_run_id : "";
  return g_cancel_probe_status;
}

extern "C" cmfa_status cmfa_mihomo_proxy_groups_v1(const char *profile_hash,
                                                   const char *revision_hash,
                                                   const char *session_hash,
                                                   uint64_t generation,
                                                   uint8_t selectable_only,
                                                   char *output,
                                                   size_t output_capacity,
                                                   size_t *output_length,
                                                   cmfa_error *error) {
  capture_raw_proxy_context(&g_proxy_groups_capture, profile_hash, revision_hash, session_hash, generation);
  return write_raw_proxy_response(
      &g_proxy_groups_capture, selectable_only, kProxyGroupsPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_proxy_group_v1(const char *profile_hash,
                                                  const char *revision_hash,
                                                  const char *session_hash,
                                                  uint64_t generation,
                                                  const char *group_name,
                                                  char *output,
                                                  size_t output_capacity,
                                                  size_t *output_length,
                                                  cmfa_error *error) {
  capture_raw_proxy_context(&g_proxy_group_capture, profile_hash, revision_hash, session_hash, generation);
  g_proxy_group_capture.group_name = group_name != nullptr ? group_name : "";
  return write_raw_proxy_response(
      &g_proxy_group_capture, 0xFF, kProxyGroupPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_proxy_select_v1(const char *profile_hash,
                                                   const char *revision_hash,
                                                   const char *session_hash,
                                                   uint64_t generation,
                                                   const char *group_name,
                                                   const char *member_name,
                                                   char *output,
                                                   size_t output_capacity,
                                                   size_t *output_length,
                                                   cmfa_error *error) {
  capture_raw_proxy_context(&g_proxy_select_capture, profile_hash, revision_hash, session_hash, generation);
  g_proxy_select_capture.group_name = group_name != nullptr ? group_name : "";
  g_proxy_select_capture.member_name = member_name != nullptr ? member_name : "";
  return write_raw_proxy_response(
      &g_proxy_select_capture, 0xFF, kProxySelectPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_proxy_delay_start_v1(const char *profile_hash,
                                                        const char *revision_hash,
                                                        const char *session_hash,
                                                        uint64_t generation,
                                                        const char *group_name,
                                                        char *output,
                                                        size_t output_capacity,
                                                        size_t *output_length,
                                                        cmfa_error *error) {
  capture_raw_proxy_context(&g_proxy_delay_start_capture, profile_hash, revision_hash, session_hash, generation);
  g_proxy_delay_start_capture.group_name = group_name != nullptr ? group_name : "";
  return write_raw_proxy_response(
      &g_proxy_delay_start_capture, 0xFF, kProxyDelayStartPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_proxy_delay_snapshot_v1(const char *job_id,
                                                           char *output,
                                                           size_t output_capacity,
                                                           size_t *output_length,
                                                           cmfa_error *error) {
  reset_raw_proxy_capture(&g_proxy_delay_snapshot_capture);
  g_proxy_delay_snapshot_capture.called = true;
  g_proxy_delay_snapshot_capture.group_name = job_id != nullptr ? job_id : "";
  return write_raw_proxy_response(
      &g_proxy_delay_snapshot_capture, 0xFF, kProxyDelaySnapshotPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_proxy_delay_cancel_v1(const char *job_id,
                                                         char *output,
                                                         size_t output_capacity,
                                                         size_t *output_length,
                                                         cmfa_error *error) {
  reset_raw_proxy_capture(&g_proxy_delay_cancel_capture);
  g_proxy_delay_cancel_capture.called = true;
  g_proxy_delay_cancel_capture.group_name = job_id != nullptr ? job_id : "";
  return write_raw_proxy_response(
      &g_proxy_delay_cancel_capture, 0xFF, kProxyDelayCancelPayload, output, output_capacity, output_length, error);
}

extern "C" cmfa_status cmfa_mihomo_backend_test_close_stale_tun_connections_impl(const char *session_id, cmfa_error *) {
  g_last_close_stale_session_id = session_id != nullptr ? session_id : "";
  return g_close_stale_status;
}

extern "C" cmfa_status cmfa_mihomo_backend_test_start_local_direct(const cmfa_local_options *options,
                                                                   cmfa_runtime_snapshot *snapshot,
                                                                   cmfa_error *error);

extern "C" int cmfa_mihomo_take_runtime_log_v1(cmfa_mihomo_runtime_log_record_v1 *record) {
  if (record == nullptr || g_runtime_logs.empty()) {
    return 0;
  }
  const StubRuntimeLog next = g_runtime_logs.front();
  g_runtime_logs.erase(g_runtime_logs.begin());
  record->struct_size = sizeof(*record);
  record->level = next.level;
  std::memset(record->message, 0, sizeof(record->message));
  const size_t copy_length = next.message.size() < (sizeof(record->message) - 1) ? next.message.size()
                                                                                  : (sizeof(record->message) - 1);
  if (copy_length > 0) {
    std::memcpy(record->message, next.message.data(), copy_length);
  }
  record->message[copy_length] = '\0';
  return 1;
}

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"register initialize core_version success", test_register_initialize_and_core_version_success},
      {"duplicate register before initialize", test_duplicate_register_before_initialize_fails},
      {"register and unregister while initialized", test_register_and_unregister_fail_while_initialized},
      {"null raw version", test_null_raw_version_reports_backend_error},
      {"empty raw version", test_empty_raw_version_reports_backend_error},
      {"guard-page raw version", test_non_terminated_256_byte_raw_fails_without_overread},
      {"regular malformed 256-byte raw version", test_non_terminated_256_byte_raw_in_regular_memory_is_malformed},
      {"255-byte raw version", test_255_byte_raw_rejects_too_small_output_buffer},
      {"start stop and runtime snapshot", test_start_stop_and_runtime_snapshot},
      {"stop preserves error snapshot event and redacted failure log",
       test_stop_preserves_error_snapshot_event_and_redacted_failure_log},
      {"backend start_local direct null options preserves snapshot",
       test_backend_start_local_direct_null_options_preserves_snapshot},
      {"probe https returns structured owned result", test_probe_https_returns_structured_owned_result},
      {"cancel probe forwards run id to go backend", test_cancel_probe_forwards_run_id_to_go_backend},
      {"cancel probe rejects empty run id", test_cancel_probe_rejects_empty_run_id},
      {"close stale tun connections forwards session id to go backend",
       test_close_stale_tun_connections_forwards_session_id_to_go_backend},
      {"close stale tun connections rejects empty session id",
       test_close_stale_tun_connections_rejects_empty_session_id},
      {"proxy wrapper direct forwarding and success payload",
       test_proxy_wrapper_direct_forwarding_and_success_payload},
      {"proxy wrapper direct buffer too small and backend error preserve contract",
       test_proxy_wrapper_direct_buffer_too_small_and_backend_error_preserve_contract},
      {"proxy delay wrapper direct forwarding and success payload",
       test_proxy_delay_wrapper_direct_forwarding_and_success_payload},
      {"proxy delay wrapper direct buffer too small and backend error preserve contract",
       test_proxy_delay_wrapper_direct_buffer_too_small_and_backend_error_preserve_contract},
      {"registered proxy callbacks complete abi smoke and lifecycle",
       test_registered_proxy_callbacks_complete_abi_smoke_and_lifecycle},
      {"shutdown and repeated unregister", test_shutdown_and_repeated_unregister_are_safe},
      {"visible host protect bridge symbol can be found and called",
       test_visible_host_protect_bridge_symbol_can_be_found_and_called},
      {"runtime log pump consumes fixed tun stage diagnostics",
       test_runtime_log_pump_consumes_fixed_tun_stage_diagnostics},
      {"visible host runtime event bridge preserves packet diagnostic forwarding",
       test_visible_host_runtime_event_bridge_preserves_packet_diagnostic_forwarding},
  };

  size_t failures = 0;
  for (const auto &[name, fn] : tests) {
    try {
      fn();
      std::cout << "[PASS] " << name << '\n';
    } catch (const std::exception &error) {
      failures += 1;
      std::cerr << "[FAIL] " << name << ": " << error.what() << '\n';
    }
  }

  return failures == 0 ? 0 : 1;
}
