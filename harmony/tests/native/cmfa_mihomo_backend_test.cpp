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
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

char *g_raw_version = nullptr;
cmfa_runtime_snapshot g_runtime_snapshot{};

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
};

void capture_log(void *context, const cmfa_log_message *) {
  auto *capture = static_cast<HostCapture *>(context);
  capture->log_count += 1;
}

void capture_event(void *context, const cmfa_runtime_event *event) {
  auto *capture = static_cast<HostCapture *>(context);
  capture->event_count += 1;
  capture->states.push_back(event != nullptr ? event->state : CMFA_RUNTIME_ERROR);
}

cmfa_host_callbacks make_host_callbacks(HostCapture *capture) {
  cmfa_host_callbacks callbacks{};
  callbacks.struct_size = sizeof(callbacks);
  callbacks.context = capture;
  callbacks.log_sink = capture_log;
  callbacks.event_sink = capture_event;
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
  reset_runtime_snapshot_storage();
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

  ErrorBox error;
  expect_status_message(cmfa_validate_config("config.yaml", &error.error),
                        CMFA_CORE_UNAVAILABLE,
                        error,
                        "mihomo backend does not support validate_config",
                        "validate_config should stay unavailable");
  expect_status_message(cmfa_load_config("config.yaml", &error.error),
                        CMFA_CORE_UNAVAILABLE,
                        error,
                        "mihomo backend does not support load_config",
                        "load_config should stay unavailable");

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

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  const cmfa_status runtime_status = cmfa_runtime_state(&snapshot, &error.error);
  expect_eq(runtime_status, CMFA_OK, "runtime_state should succeed");
  expect_eq(snapshot.state, CMFA_RUNTIME_RUNNING, "runtime_state should report running");
  expect_string_eq(std::string(snapshot.http_address), "127.0.0.1:7890", "runtime_state HTTP address");
  expect_string_eq(std::string(snapshot.socks_address), "127.0.0.1:19090", "runtime_state SOCKS address");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed");
  expect_eq(capture.event_count, static_cast<uint32_t>(4), "stop should emit STOPPING and STOPPED");
  expect_eq(capture.states[2], CMFA_RUNTIME_STOPPING, "third event should be STOPPING");
  expect_eq(capture.states[3], CMFA_RUNTIME_STOPPED, "fourth event should be STOPPED");
  reset_contract();
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

} // namespace

extern "C" char *cmfa_mihomo_core_version_cstr_v1(void) { return g_raw_version; }

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
  *snapshot = g_runtime_snapshot;
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_stop_v1(cmfa_error *) {
  reset_runtime_snapshot_storage();
  return CMFA_OK;
}

extern "C" cmfa_status cmfa_mihomo_runtime_state_v1(cmfa_runtime_snapshot *snapshot, cmfa_error *) {
  if (snapshot == nullptr) {
    return CMFA_INVALID_ARGUMENT;
  }
  *snapshot = g_runtime_snapshot;
  return CMFA_OK;
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
      {"shutdown and repeated unregister", test_shutdown_and_repeated_unregister_are_safe},
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
