#include "cmfa_core.h"
#include "cmfa_host.h"
#include "cmfa_types.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <future>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

enum cmfa_internal_test_hook_point {
  CMFA_TEST_HOOK_BEFORE_BACKEND_BORROW = 1,
  CMFA_TEST_HOOK_AFTER_RUNTIME_STATE_BACKEND = 2,
};

#if defined(CMFA_CONTRACT_TESTING)
extern "C" void cmfa_internal_set_test_hook(void (*hook)(void *context, int point), void *context);
#endif

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

template <typename Predicate>
void expect_eventually(Predicate predicate, std::chrono::milliseconds timeout, const std::string &message) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) {
      return;
    }
    std::this_thread::yield();
  }
  if (!predicate()) {
    throw TestFailure(message);
  }
}

std::string snapshot_path(const cmfa_runtime_snapshot &snapshot) {
  return std::string(snapshot.active_config_path);
}

bool bounded_string_length_for_test(const char *text, size_t capacity, size_t *length_out) {
  if (text == nullptr) {
    return false;
  }
  for (size_t index = 0; index < capacity; ++index) {
    if (text[index] == '\0') {
      if (length_out != nullptr) {
        *length_out = index;
      }
      return true;
    }
  }
  return false;
}

struct ErrorBox {
  std::array<char, 96> storage{};
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

struct GuardedErrorBuffer {
  std::array<unsigned char, 10> bytes{};
  cmfa_error error{};

  GuardedErrorBuffer() {
    bytes.fill(0xA5);
    error.code = CMFA_OK;
    error.message = reinterpret_cast<char *>(bytes.data() + 2);
    error.capacity = 5;
    error.length = 0;
  }
};

struct JsonBufferBox {
  std::vector<char> storage;
  cmfa_json_buffer buffer{};

  explicit JsonBufferBox(size_t capacity) : storage(capacity + 2, static_cast<char>(0xC3)) {
    buffer.data = storage.data() + 1;
    buffer.capacity = capacity;
    buffer.length = 777;
    if (capacity > 0) {
      std::memset(buffer.data, 'Q', capacity);
    }
  }

  bool guards_intact() const {
    return !storage.empty() && storage.front() == static_cast<char>(0xC3) &&
           storage.back() == static_cast<char>(0xC3);
  }

  std::string c_str() const { return buffer.data != nullptr ? std::string(buffer.data) : std::string(); }
};

constexpr char kProxyProfileHash[] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
constexpr char kProxyRevisionHash[] = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
constexpr char kProxySessionHash[] = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
constexpr char kProxyDelayJobId[] = "0123456789abcdef0123456789abcdef";
constexpr char kProxyJson[] = "{\"group\":\"auto\",\"items\":[\"a\",\"b\"]}";

void copy_fixed_text(char *destination, size_t capacity, const char *source) {
  expect(destination != nullptr, "destination must not be null");
  expect(source != nullptr, "source must not be null");
  const size_t length = std::strlen(source);
  expect(length + 1 <= capacity, "source must fit destination capacity");
  std::memcpy(destination, source, length + 1);
}

cmfa_proxy_query_context make_query_context(bool include_session = true) {
  cmfa_proxy_query_context context{};
  context.struct_size = sizeof(context);
  copy_fixed_text(context.profile_hash, sizeof(context.profile_hash), kProxyProfileHash);
  copy_fixed_text(context.revision_hash, sizeof(context.revision_hash), kProxyRevisionHash);
  if (include_session) {
    copy_fixed_text(context.session_hash, sizeof(context.session_hash), kProxySessionHash);
  } else {
    std::memset(context.session_hash, 0, sizeof(context.session_hash));
  }
  context.generation = 7;
  return context;
}

void expect_error_omits_fragments(const ErrorBox &error,
                                  std::initializer_list<std::string_view> forbidden_fragments,
                                  const std::string &message) {
  const std::string text = error.message();
  for (const std::string_view fragment : forbidden_fragments) {
    if (!fragment.empty() && text.find(std::string(fragment)) != std::string::npos) {
      throw TestFailure(message + " (found forbidden fragment \"" + std::string(fragment) + "\")");
    }
  }
}

struct HostCapture {
  enum class ReentrantAction {
    None,
    Stop,
    Shutdown,
  };

  std::mutex mutex;
  std::condition_variable callback_cv;
  std::vector<std::string> logs;
  std::vector<cmfa_runtime_state_value> states;
  bool block_callbacks = false;
  bool release_callbacks = false;
  size_t callbacks_entered = 0;
  size_t callbacks_completed = 0;
  ReentrantAction reentrant_action = ReentrantAction::None;
  cmfa_status reentrant_status = CMFA_OK;
  bool reentrant_completed = false;
};

void capture_log(void *context, const cmfa_log_message *message) {
  auto *capture = static_cast<HostCapture *>(context);
  std::unique_lock<std::mutex> lock(capture->mutex);
  capture->callbacks_entered += 1;
  capture->logs.emplace_back(message != nullptr && message->message != nullptr ? message->message : "");
  capture->callback_cv.notify_all();
  while (capture->block_callbacks && !capture->release_callbacks) {
    capture->callback_cv.wait(lock);
  }
  capture->callbacks_completed += 1;
  capture->callback_cv.notify_all();
}

void capture_event(void *context, const cmfa_runtime_event *event) {
  auto *capture = static_cast<HostCapture *>(context);
  std::unique_lock<std::mutex> lock(capture->mutex);
  capture->callbacks_entered += 1;
  capture->states.push_back(event != nullptr ? event->state : CMFA_RUNTIME_ERROR);
  const HostCapture::ReentrantAction action = capture->reentrant_action;
  capture->callback_cv.notify_all();
  while (capture->block_callbacks && !capture->release_callbacks) {
    capture->callback_cv.wait(lock);
  }
  lock.unlock();

  if (action != HostCapture::ReentrantAction::None) {
    ErrorBox error;
    cmfa_status status = CMFA_BACKEND_ERROR;
    if (action == HostCapture::ReentrantAction::Stop) {
      status = cmfa_stop(&error.error);
    } else if (action == HostCapture::ReentrantAction::Shutdown) {
      status = cmfa_shutdown(&error.error);
    }
    lock.lock();
    capture->reentrant_status = status;
    capture->reentrant_completed = true;
    capture->callback_cv.notify_all();
  } else {
    lock.lock();
  }
  capture->callbacks_completed += 1;
  capture->callback_cv.notify_all();
}

cmfa_host_callbacks make_host_callbacks(HostCapture *capture) {
  cmfa_host_callbacks callbacks{};
  callbacks.struct_size = sizeof(callbacks);
  callbacks.context = capture;
  callbacks.log_sink = capture_log;
  callbacks.event_sink = capture_event;
  return callbacks;
}

void reset_contract() {
  ErrorBox error;
  (void)cmfa_shutdown(&error.error);
  (void)cmfa_internal_register_backend(nullptr, &error.error);
}

cmfa_backend_host make_backend_host() {
  cmfa_backend_host host{};
  host.struct_size = sizeof(host);
  return host;
}

void wait_for_callback_entry(HostCapture *capture, size_t expected_count = 1) {
  std::unique_lock<std::mutex> lock(capture->mutex);
  const bool reached = capture->callback_cv.wait_for(lock, std::chrono::seconds(2), [&] {
    return capture->callbacks_entered >= expected_count;
  });
  expect(reached, "timed out waiting for callback entry");
}

void release_blocked_callbacks(HostCapture *capture) {
  std::lock_guard<std::mutex> lock(capture->mutex);
  capture->release_callbacks = true;
  capture->callback_cv.notify_all();
}

#if defined(__unix__) || defined(__APPLE__)
struct GuardPageRegion {
  char *base = nullptr;
  size_t page_size = 0;
  char *path = nullptr;

  GuardPageRegion() {
    page_size = static_cast<size_t>(::sysconf(_SC_PAGESIZE));
    expect(page_size >= CMFA_MAX_PATH_BYTES, "page size must cover CMFA_MAX_PATH_BYTES");
    void *mapping = ::mmap(nullptr, page_size * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    expect(mapping != MAP_FAILED, "mmap should succeed");
    base = static_cast<char *>(mapping);
    const int protect_status = ::mprotect(base + page_size, page_size, PROT_NONE);
    expect_eq(protect_status, 0, "mprotect should succeed");
    path = base + (page_size - CMFA_MAX_PATH_BYTES);
    std::memset(path, 'p', CMFA_MAX_PATH_BYTES);
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

struct FakeBackend {
  enum class ProxyMode {
    Success,
    BufferTooSmall,
    BackendError,
    InvalidStatus,
    MissingNul,
    InvalidUtf8,
    Overrun,
    TooLarge,
  };

  std::mutex mutex;
  std::condition_variable entered_cv;
  std::condition_variable release_cv;
  std::condition_variable stop_cv;
  std::condition_variable shutdown_cv;
  std::condition_variable attach_cv;
  std::condition_variable validate_cv;
  bool block_start = false;
  bool block_attach = false;
  bool block_shutdown = false;
  bool block_validate = false;
  bool start_entered = false;
  bool allow_start_exit = false;
  bool attach_entered = false;
  bool allow_attach_exit = false;
  bool validate_entered = false;
  bool allow_validate_exit = false;
  bool allow_shutdown_exit = true;
  bool host_attached = false;
  bool stop_called = false;
  bool shutdown_called = false;
  bool attach_called = false;
  bool fail_attach = false;
  bool omit_terminating_nul_in_version = false;
  bool emit_backend_error_without_nul = false;
  bool preserve_error_on_stop = false;
  bool fail_runtime_state_after_stop = false;
  bool invalid_runtime_state_after_stop = false;
  bool proxy_groups_called = false;
  bool proxy_group_called = false;
  bool proxy_select_called = false;
  bool proxy_delay_start_called = false;
  bool proxy_delay_snapshot_called = false;
  bool proxy_delay_cancel_called = false;
  uint32_t start_calls = 0;
  uint32_t stop_calls = 0;
  uint32_t shutdown_calls = 0;
  cmfa_backend_host host = make_backend_host();
  cmfa_runtime_snapshot snapshot{};
  cmfa_runtime_mode runtime_mode = CMFA_MODE_RULE;
  cmfa_proxy_query_context last_proxy_query{};
  uint8_t last_selectable_only = 0xFF;
  std::string last_group_name;
  std::string last_member_name;
  std::string last_delay_job_id;
  ProxyMode proxy_mode = ProxyMode::Success;
  cmfa_status proxy_error_status = CMFA_BACKEND_ERROR;
  std::string proxy_json = kProxyJson;
  std::string proxy_error_message = "backend proxy failed";
  std::string version = "fake-core-1.0.0";

  FakeBackend() {
    snapshot.struct_size = sizeof(snapshot);
    snapshot.state = CMFA_RUNTIME_STOPPED;
    snapshot.mixed_port = 0;
    set_snapshot_path_locked("");
    set_snapshot_http_locked("");
    set_snapshot_socks_locked("");
    set_snapshot_last_error_locked("");
  }

  void write_snapshot_text_locked(char *buffer, size_t capacity, const std::string &value) {
    std::memset(buffer, 0, capacity);
    const size_t copy_length = value.size() < (capacity - 1) ? value.size() : (capacity - 1);
    if (copy_length > 0) {
      std::memcpy(buffer, value.data(), copy_length);
    }
    buffer[copy_length] = '\0';
  }

  void set_snapshot_path_locked(const std::string &path) {
    write_snapshot_text_locked(snapshot.active_config_path, sizeof(snapshot.active_config_path), path);
  }

  void set_snapshot_http_locked(const std::string &address) {
    write_snapshot_text_locked(snapshot.http_address, sizeof(snapshot.http_address), address);
  }

  void set_snapshot_socks_locked(const std::string &address) {
    write_snapshot_text_locked(snapshot.socks_address, sizeof(snapshot.socks_address), address);
  }

  void set_snapshot_last_error_locked(const std::string &message) {
    write_snapshot_text_locked(snapshot.last_error, sizeof(snapshot.last_error), message);
  }

  void set_runtime_snapshot(cmfa_runtime_state_value state, const std::string &path, uint32_t mixed_port) {
    std::lock_guard<std::mutex> lock(mutex);
    snapshot.state = state;
    snapshot.mixed_port = mixed_port;
    set_snapshot_path_locked(path);
    if (state == CMFA_RUNTIME_RUNNING) {
      set_snapshot_http_locked("127.0.0.1:7890");
      set_snapshot_socks_locked("127.0.0.1:19090");
      set_snapshot_last_error_locked("");
    } else {
      set_snapshot_http_locked("");
      set_snapshot_socks_locked("");
    }
  }

  void set_runtime_last_error(const std::string &message) {
    std::lock_guard<std::mutex> lock(mutex);
    set_snapshot_last_error_locked(message);
  }

  static cmfa_status attach_host(void *context, const cmfa_backend_host *host, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::unique_lock<std::mutex> lock(self->mutex);
    self->attach_called = true;
    self->attach_entered = true;
    self->host = *host;
    self->host_attached = true;
    self->attach_cv.notify_all();
    while (self->block_attach && !self->allow_attach_exit) {
      self->attach_cv.wait(lock);
    }
    if (self->fail_attach) {
      return CMFA_BACKEND_ERROR;
    }
    return CMFA_OK;
  }

  static cmfa_status core_version(void *context, char *out, size_t capacity, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    const std::string &version = self->version;
    if (out == nullptr || capacity == 0) {
      return CMFA_INVALID_ARGUMENT;
    }
    if (self->omit_terminating_nul_in_version) {
      std::memset(out, 'x', capacity);
      return CMFA_OK;
    }
    if (version.size() + 1 > capacity) {
      out[0] = '\0';
      return CMFA_BUFFER_TOO_SMALL;
    }
    std::memcpy(out, version.c_str(), version.size() + 1);
    return CMFA_OK;
  }

  static cmfa_status validate_config(void *context, const char *, cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    {
      std::unique_lock<std::mutex> lock(self->mutex);
      self->validate_entered = true;
      self->validate_cv.notify_all();
      while (self->block_validate && !self->allow_validate_exit) {
        self->validate_cv.wait(lock);
      }
    }
    if (self->emit_backend_error_without_nul && error != nullptr && error->message != nullptr && error->capacity > 0) {
      const size_t fill = error->capacity;
      std::memset(error->message, 'E', fill);
      error->code = CMFA_BACKEND_ERROR;
      error->length = fill;
      return CMFA_BACKEND_ERROR;
    }
    return CMFA_OK;
  }

  static cmfa_status load_config(void *, const char *, cmfa_error *) { return CMFA_OK; }

  static cmfa_status start_local(void *context,
                                 const cmfa_local_options *options,
                                 cmfa_runtime_snapshot *snapshot,
                                 cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    {
      std::unique_lock<std::mutex> lock(self->mutex);
      self->start_calls += 1;
      self->start_entered = true;
      self->snapshot.state = CMFA_RUNTIME_STARTING;
      self->snapshot.mixed_port = options->mixed_port;
      self->set_snapshot_path_locked(options->config_path);
      self->set_snapshot_http_locked("");
      self->set_snapshot_socks_locked("");
      self->set_snapshot_last_error_locked("");
      self->entered_cv.notify_all();
      while (self->block_start && !self->allow_start_exit) {
        self->release_cv.wait(lock);
      }
      self->snapshot.state = CMFA_RUNTIME_RUNNING;
      self->set_snapshot_http_locked("127.0.0.1:7890");
      self->set_snapshot_socks_locked("127.0.0.1:19090");
      *snapshot = self->snapshot;
    }

    if (self->host.host_emit_event != nullptr) {
      cmfa_runtime_event event{};
      event.struct_size = sizeof(event);
      event.state = CMFA_RUNTIME_RUNNING;
      event.message = "started";
      (void)self->host.host_emit_event(self->host.context, &event, nullptr);
    }
    return CMFA_OK;
  }

  static cmfa_status stop(void *context, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->stop_calls += 1;
    self->stop_called = true;
    if (!self->preserve_error_on_stop) {
      self->snapshot.state = CMFA_RUNTIME_STOPPED;
      self->snapshot.mixed_port = 0;
      self->set_snapshot_path_locked("");
      self->set_snapshot_http_locked("");
      self->set_snapshot_socks_locked("");
      self->set_snapshot_last_error_locked("");
    }
    self->stop_cv.notify_all();
    return CMFA_OK;
  }

  static cmfa_status runtime_state(void *context, cmfa_runtime_snapshot *snapshot, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    if (self->stop_called && self->fail_runtime_state_after_stop) {
      return CMFA_BACKEND_ERROR;
    }
    if (self->stop_called && self->invalid_runtime_state_after_stop) {
      *snapshot = self->snapshot;
      snapshot->state = static_cast<cmfa_runtime_state_value>(99);
      return CMFA_OK;
    }
    *snapshot = self->snapshot;
    return CMFA_OK;
  }

  static cmfa_status runtime_mode_query(void *context, cmfa_runtime_mode *mode, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    if (mode == nullptr) {
      return CMFA_INVALID_ARGUMENT;
    }
    *mode = self->runtime_mode;
    return CMFA_OK;
  }

  static cmfa_status runtime_mode_set(void *context, cmfa_runtime_mode mode, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->runtime_mode = mode;
    return CMFA_OK;
  }

  static cmfa_status probe_https(void *,
                                 const cmfa_probe_request *request,
                                 cmfa_probe_result *result,
                                 cmfa_error *) {
    if (request == nullptr || result == nullptr) {
      return CMFA_INVALID_ARGUMENT;
    }
    std::memset(result, 0, sizeof(*result));
    result->struct_size = sizeof(cmfa_probe_result);
    result->protocol = request->protocol;
    result->tracker.struct_size = sizeof(cmfa_probe_tracker_record);
    result->error.struct_size = sizeof(cmfa_probe_error);
    std::snprintf(result->error.code, sizeof(result->error.code), "%s", "UNIMPLEMENTED");
    std::snprintf(result->error.stage, sizeof(result->error.stage), "%s", "backend");
    std::snprintf(result->error.detail, sizeof(result->error.detail), "%s", "fake backend probe not implemented");
    return CMFA_CORE_UNAVAILABLE;
  }

  void copy_proxy_query_locked(const cmfa_proxy_query_context *query) {
    expect(query != nullptr, "proxy query must not be null");
    last_proxy_query = *query;
  }

  void maybe_copy_backend_error(cmfa_error *error) {
    if (error == nullptr || error->message == nullptr || error->capacity == 0) {
      return;
    }
    const size_t writable = error->capacity - 1;
    const size_t copy_length = proxy_error_message.size() < writable ? proxy_error_message.size() : writable;
    if (copy_length > 0) {
      std::memcpy(error->message, proxy_error_message.data(), copy_length);
    }
    error->message[copy_length] = '\0';
    error->code = proxy_error_status;
    error->length = proxy_error_message.size();
  }

  cmfa_status write_proxy_response(cmfa_json_buffer *output, cmfa_error *error) {
    expect(output != nullptr, "proxy output must not be null");
    const size_t required_length =
        proxy_mode == ProxyMode::TooLarge ? static_cast<size_t>(CMFA_MAX_PROXY_JSON_BYTES + 1U) : proxy_json.size();

    switch (proxy_mode) {
      case ProxyMode::Success:
        if (output->capacity <= required_length) {
          if (output->data != nullptr && output->capacity > 0) {
            output->data[0] = '\0';
          }
          output->length = required_length;
          return CMFA_BUFFER_TOO_SMALL;
        }
        if (required_length > 0) {
          std::memcpy(output->data, proxy_json.data(), required_length);
        }
        output->data[required_length] = '\0';
        output->length = required_length;
        return CMFA_OK;
      case ProxyMode::BufferTooSmall:
        if (output->data != nullptr && output->capacity > 0) {
          std::memcpy(output->data, "partial", std::min<size_t>(7, output->capacity));
        }
        output->length = required_length;
        return CMFA_BUFFER_TOO_SMALL;
      case ProxyMode::BackendError:
        maybe_copy_backend_error(error);
        output->length = 0;
        return proxy_error_status;
      case ProxyMode::InvalidStatus:
        maybe_copy_backend_error(error);
        return static_cast<cmfa_status>(99);
      case ProxyMode::MissingNul:
        expect(output->capacity > required_length, "missing-NUL mode requires writable capacity");
        if (required_length > 0) {
          std::memcpy(output->data, proxy_json.data(), required_length);
        }
        if (output->capacity > required_length + 1) {
          output->data[required_length + 1] = '!';
        }
        output->length = required_length;
        return CMFA_OK;
      case ProxyMode::InvalidUtf8:
        expect(output->capacity >= 6, "invalid UTF-8 mode requires capacity for 5 bytes plus NUL");
        output->data[0] = '{';
        output->data[1] = '"';
        output->data[2] = static_cast<char>(0xFF);
        output->data[3] = '"';
        output->data[4] = '}';
        output->data[5] = '\0';
        output->length = 5;
        return CMFA_OK;
      case ProxyMode::Overrun:
        expect(output->capacity > required_length, "overrun mode requires writable capacity");
        if (required_length > 0) {
          std::memcpy(output->data, proxy_json.data(), required_length);
        }
        output->data[required_length] = '\0';
        output->length = required_length;
        output->data[output->capacity] = '!';
        return CMFA_OK;
      case ProxyMode::TooLarge:
        if (output->data != nullptr && output->capacity > 0) {
          output->data[0] = '{';
          if (output->capacity > 1) {
            output->data[1] = '\0';
          }
        }
        output->length = required_length;
        return CMFA_OK;
    }

    return CMFA_BACKEND_ERROR;
  }

  static cmfa_status proxy_groups(void *context,
                                  const cmfa_proxy_query_context *query,
                                  uint8_t selectable_only,
                                  cmfa_json_buffer *output,
                                  cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_groups_called = true;
    self->copy_proxy_query_locked(query);
    self->last_selectable_only = selectable_only;
    self->last_group_name.clear();
    self->last_member_name.clear();
    return self->write_proxy_response(output, error);
  }

  static cmfa_status proxy_group(void *context,
                                 const cmfa_proxy_query_context *query,
                                 const char *group_name,
                                 cmfa_json_buffer *output,
                                 cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_group_called = true;
    self->copy_proxy_query_locked(query);
    self->last_selectable_only = 0xFF;
    self->last_group_name = group_name != nullptr ? group_name : "";
    self->last_member_name.clear();
    return self->write_proxy_response(output, error);
  }

  static cmfa_status proxy_select(void *context,
                                  const cmfa_proxy_query_context *query,
                                  const char *group_name,
                                  const char *member_name,
                                  cmfa_json_buffer *output,
                                  cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_select_called = true;
    self->copy_proxy_query_locked(query);
    self->last_selectable_only = 0xFF;
    self->last_group_name = group_name != nullptr ? group_name : "";
    self->last_member_name = member_name != nullptr ? member_name : "";
    return self->write_proxy_response(output, error);
  }

  static cmfa_status proxy_delay_start(void *context,
                                       const cmfa_proxy_query_context *query,
                                       const char *group_name,
                                       cmfa_json_buffer *output,
                                       cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_delay_start_called = true;
    self->copy_proxy_query_locked(query);
    self->last_group_name = group_name != nullptr ? group_name : "";
    self->last_member_name.clear();
    self->last_delay_job_id.clear();
    return self->write_proxy_response(output, error);
  }

  static cmfa_status proxy_delay_snapshot(void *context,
                                          const char *job_id,
                                          cmfa_json_buffer *output,
                                          cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_delay_snapshot_called = true;
    self->last_group_name.clear();
    self->last_member_name.clear();
    self->last_delay_job_id = job_id != nullptr ? job_id : "";
    return self->write_proxy_response(output, error);
  }

  static cmfa_status proxy_delay_cancel(void *context,
                                        const char *job_id,
                                        cmfa_json_buffer *output,
                                        cmfa_error *error) {
    auto *self = static_cast<FakeBackend *>(context);
    std::lock_guard<std::mutex> lock(self->mutex);
    self->proxy_delay_cancel_called = true;
    self->last_group_name.clear();
    self->last_member_name.clear();
    self->last_delay_job_id = job_id != nullptr ? job_id : "";
    return self->write_proxy_response(output, error);
  }

  static cmfa_status shutdown(void *context, cmfa_error *) {
    auto *self = static_cast<FakeBackend *>(context);
    std::unique_lock<std::mutex> lock(self->mutex);
    self->shutdown_calls += 1;
    self->shutdown_called = true;
    self->snapshot.state = CMFA_RUNTIME_STOPPED;
    self->snapshot.mixed_port = 0;
    self->set_snapshot_path_locked("");
    self->set_snapshot_http_locked("");
    self->set_snapshot_socks_locked("");
    self->set_snapshot_last_error_locked("");
    self->shutdown_cv.notify_all();
    while (self->block_shutdown && !self->allow_shutdown_exit) {
      self->shutdown_cv.wait(lock);
    }
    return CMFA_OK;
  }

  cmfa_backend_api api() {
    cmfa_backend_api api{};
    api.struct_size = sizeof(api);
    api.context = this;
    api.attach_host = &FakeBackend::attach_host;
    api.core_version = &FakeBackend::core_version;
    api.validate_config = &FakeBackend::validate_config;
    api.load_config = &FakeBackend::load_config;
    api.start_local = &FakeBackend::start_local;
    api.stop = &FakeBackend::stop;
    api.runtime_state = &FakeBackend::runtime_state;
    api.runtime_mode_query = &FakeBackend::runtime_mode_query;
    api.runtime_mode_set = &FakeBackend::runtime_mode_set;
    api.proxy_groups = &FakeBackend::proxy_groups;
    api.proxy_group = &FakeBackend::proxy_group;
    api.proxy_select = &FakeBackend::proxy_select;
    api.proxy_delay_start = &FakeBackend::proxy_delay_start;
    api.proxy_delay_snapshot = &FakeBackend::proxy_delay_snapshot;
    api.proxy_delay_cancel = &FakeBackend::proxy_delay_cancel;
    api.probe_https = &FakeBackend::probe_https;
    api.shutdown = &FakeBackend::shutdown;
    return api;
  }

  void wait_for_start_entry() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool entered = entered_cv.wait_for(lock, std::chrono::seconds(2), [&] { return start_entered; });
    expect(entered, "timed out waiting for backend start entry");
  }

  void release_start() {
    std::lock_guard<std::mutex> lock(mutex);
    allow_start_exit = true;
    release_cv.notify_all();
  }

  void wait_for_stop_called() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool called = stop_cv.wait_for(lock, std::chrono::seconds(2), [&] { return stop_called; });
    expect(called, "timed out waiting for backend stop");
  }

  void wait_for_shutdown_called() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool called = shutdown_cv.wait_for(lock, std::chrono::seconds(2), [&] { return shutdown_called; });
    expect(called, "timed out waiting for backend shutdown");
  }

  void wait_for_attach_entry() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool called = attach_cv.wait_for(lock, std::chrono::seconds(2), [&] { return attach_entered; });
    expect(called, "timed out waiting for backend attach");
  }

  void release_attach() {
    std::lock_guard<std::mutex> lock(mutex);
    allow_attach_exit = true;
    attach_cv.notify_all();
  }

  void wait_for_validate_called() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool called = validate_cv.wait_for(lock, std::chrono::seconds(2), [&] { return validate_entered; });
    expect(called, "timed out waiting for backend validate");
  }

  void release_validate() {
    std::lock_guard<std::mutex> lock(mutex);
    allow_validate_exit = true;
    validate_cv.notify_all();
  }

  void release_shutdown() {
    std::lock_guard<std::mutex> lock(mutex);
    allow_shutdown_exit = true;
    shutdown_cv.notify_all();
  }

  void emit_event_direct(const char *message = "event") {
    cmfa_runtime_event event{};
    event.struct_size = sizeof(event);
    event.state = CMFA_RUNTIME_RUNNING;
    event.message = message;
    expect(host.host_emit_event != nullptr, "backend host event emitter should be attached");
    (void)host.host_emit_event(host.context, &event, nullptr);
  }

  void emit_log_direct(const char *message = "log") {
    cmfa_log_message log{};
    log.struct_size = sizeof(log);
    log.level = CMFA_LOG_INFO;
    log.message = message;
    expect(host.host_emit_log != nullptr, "backend host log emitter should be attached");
    (void)host.host_emit_log(host.context, &log, nullptr);
  }

  void emit_after_stop() {
    if (host.host_emit_event != nullptr) {
      emit_event_direct("late-event");
    }
    if (host.host_emit_log != nullptr) {
      emit_log_direct("late-log");
    }
  }
};

void test_calls_require_initialization_and_shutdown_is_idempotent() {
  reset_contract();

  ErrorBox error;
  char version[16] = {};
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;

  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_NOT_INITIALIZED,
            "core_version should reject calls before initialize");
  expect_eq(cmfa_validate_config("config.yaml", &error.error), CMFA_NOT_INITIALIZED,
            "validate_config should reject calls before initialize");
  expect_eq(cmfa_load_config("config.yaml", &error.error), CMFA_NOT_INITIALIZED,
            "load_config should reject calls before initialize");
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_NOT_INITIALIZED,
            "start_local should reject calls before initialize");
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_NOT_INITIALIZED,
            "runtime_state should reject calls before initialize");
  expect_eq(cmfa_stop(&error.error), CMFA_NOT_INITIALIZED, "stop should reject calls before initialize");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown before initialize should be OK");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown after shutdown should stay OK");
}

void test_initialize_duplicate_and_backendless_contract_behaviors() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;

  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed without backend");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_ALREADY_INITIALIZED,
            "duplicate initialize should be rejected");

  char version[16] = {};
  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_CORE_UNAVAILABLE,
            "version should report core unavailable without backend");

  std::string max_path(CMFA_MAX_PATH_BYTES - 1, 'a');
  expect_eq(cmfa_validate_config(max_path.c_str(), &error.error), CMFA_CORE_UNAVAILABLE,
            "max valid path should reach core unavailable");
  expect_eq(cmfa_load_config(max_path.c_str(), &error.error), CMFA_CORE_UNAVAILABLE,
            "load_config should also reach core unavailable");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = max_path.c_str();
  options.mixed_port = 7890;
  cmfa_runtime_snapshot start_snapshot{};
  start_snapshot.struct_size = sizeof(start_snapshot);
  expect_eq(cmfa_start_local(&options, &start_snapshot, &error.error), CMFA_CORE_UNAVAILABLE,
            "start_local should report core unavailable without backend");

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK,
            "runtime_state should report contract-owned stopped state");
  expect_eq(snapshot.state, CMFA_RUNTIME_STOPPED, "runtime_state should report stopped");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should be idempotent at stopped");
  expect_eq(cmfa_stop(&error.error), CMFA_OK, "second stop should also be OK");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown after initialize should be OK");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should remain idempotent");
}

void test_null_pointer_and_invalid_argument_validation() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  expect_eq(cmfa_initialize(nullptr, &error.error), CMFA_INVALID_ARGUMENT,
            "initialize should reject null callbacks");

  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_host_callbacks short_callbacks = callbacks;
  short_callbacks.struct_size = sizeof(short_callbacks) - 1;
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should reset after init");
  expect_eq(cmfa_initialize(&short_callbacks, &error.error), CMFA_INVALID_ARGUMENT,
            "initialize should reject short callback structs");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "reinitialize should succeed");

  char version[8] = {};
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;

  expect_eq(cmfa_core_version(nullptr, sizeof(version), &error.error), CMFA_INVALID_ARGUMENT,
            "core_version should reject null output");
  expect_eq(cmfa_runtime_state(nullptr, &error.error), CMFA_INVALID_ARGUMENT,
            "runtime_state should reject null snapshot");
  expect_eq(cmfa_validate_config(nullptr, &error.error), CMFA_INVALID_ARGUMENT,
            "validate_config should reject null path");
  expect_eq(cmfa_load_config(nullptr, &error.error), CMFA_INVALID_ARGUMENT,
            "load_config should reject null path");
  expect_eq(cmfa_start_local(nullptr, &snapshot, &error.error), CMFA_INVALID_ARGUMENT,
            "start_local should reject null options");
  expect_eq(cmfa_start_local(&options, nullptr, &error.error), CMFA_INVALID_ARGUMENT,
            "start_local should reject null snapshot");

  options.mixed_port = 70000;
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_OUT_OF_RANGE,
            "start_local should reject ports above uint16 range");
  options.mixed_port = 0;
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_INVALID_ARGUMENT,
            "start_local should reject disabled local port");
  options.mixed_port = 7890;

  expect_eq(cmfa_validate_config("", &error.error), CMFA_INVALID_ARGUMENT,
            "validate_config should reject empty paths");

  std::string too_long(CMFA_MAX_PATH_BYTES, 'b');
  expect_eq(cmfa_validate_config(too_long.c_str(), &error.error), CMFA_OUT_OF_RANGE,
            "validate_config should reject overlong paths");
}

void test_probe_https_backendless_and_invalid_request_return_owned_result() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed without backend");

  cmfa_probe_result *invalid_result = nullptr;
  expect_eq(cmfa_probe_https(nullptr, &invalid_result, &error.error), CMFA_INVALID_ARGUMENT,
            "probe should reject null request");
  expect(invalid_result != nullptr, "invalid request should still yield an owned result");
  expect_string_eq(std::string(invalid_result->error.code), "INVALID_ARGUMENT", "invalid request error code");
  expect_string_eq(std::string(invalid_result->error.stage), "request", "invalid request error stage");
  cmfa_probe_result_free(invalid_result);

  cmfa_probe_request request{};
  request.struct_size = sizeof(request);
  request.probe_run_id = "probe-run";
  request.protocol = CMFA_PROBE_PROTOCOL_HTTP_CONNECT;
  request.listener_address = "127.0.0.1:7890";
  request.origin_url = "https://127.0.0.1:9443/";
  request.ca_pem = "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n";
  request.expected_body_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

  cmfa_probe_result *backendless_result = nullptr;
  expect_eq(cmfa_probe_https(&request, &backendless_result, &error.error), CMFA_CORE_UNAVAILABLE,
            "probe should surface missing backend");
  expect(backendless_result != nullptr, "backendless probe should still return an owned result");
  expect_eq(backendless_result->protocol, CMFA_PROBE_PROTOCOL_HTTP_CONNECT, "protocol should be preserved");
  expect_string_eq(std::string(backendless_result->error.code), "CORE_UNAVAILABLE", "backendless error code");
  expect_string_eq(std::string(backendless_result->error.stage), "backend", "backendless error stage");
  cmfa_probe_result_free(backendless_result);
}

void test_invalid_utf8_and_error_truncation() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const std::vector<std::string> invalid_utf8 = {
      std::string("\x80", 1),
      std::string("\xC0\xAF", 2),
      std::string("\xED\xA0\x80", 3),
      std::string("\xF4\x90\x80\x80", 4),
  };

  for (const auto &input : invalid_utf8) {
    expect_eq(cmfa_validate_config(input.c_str(), &error.error), CMFA_INVALID_UTF8,
              "validate_config should reject invalid UTF-8");
    expect_eq(error.error.code, CMFA_INVALID_UTF8, "error code should mirror invalid UTF-8");
    expect(error.error.length > 0, "invalid UTF-8 should write a message");
  }

  GuardedErrorBuffer guarded;
  expect_eq(cmfa_validate_config(invalid_utf8[0].c_str(), &guarded.error), CMFA_INVALID_UTF8,
            "guarded error should still receive invalid UTF-8");
  expect_eq(guarded.bytes[0], static_cast<unsigned char>(0xA5), "left guard should stay intact");
  expect_eq(guarded.bytes[1], static_cast<unsigned char>(0xA5), "left guard 2 should stay intact");
  expect_eq(guarded.bytes[7], static_cast<unsigned char>(0xA5), "right guard should stay intact");
  expect_eq(guarded.bytes[8], static_cast<unsigned char>(0xA5), "right guard 2 should stay intact");
  expect(reinterpret_cast<char *>(guarded.bytes.data() + 2)[4] == '\0',
         "truncated error buffer must be NUL terminated");

  char one_byte = 'X';
  cmfa_error tiny{};
  tiny.message = &one_byte;
  tiny.capacity = 1;
  tiny.code = CMFA_OK;
  tiny.length = 99;
  expect_eq(cmfa_validate_config(invalid_utf8[1].c_str(), &tiny), CMFA_INVALID_UTF8,
            "capacity-1 error buffer should still report status");
  expect(one_byte == '\0', "capacity-1 buffer should contain only NUL");

  cmfa_error zero_capacity{};
  zero_capacity.capacity = 0;
  zero_capacity.code = CMFA_OK;
  expect_eq(cmfa_validate_config(invalid_utf8[2].c_str(), &zero_capacity), CMFA_INVALID_UTF8,
            "capacity-0 error buffer should still report status");
  expect_eq(zero_capacity.code, CMFA_INVALID_UTF8, "capacity-0 error buffer should still receive the code");

  cmfa_error null_message{};
  null_message.message = nullptr;
  null_message.capacity = 8;
  null_message.code = CMFA_OK;
  expect_eq(cmfa_validate_config(invalid_utf8[3].c_str(), &null_message), CMFA_INVALID_UTF8,
            "null message pointer should still report status");
  expect_eq(null_message.code, CMFA_INVALID_UTF8, "null message pointer should still receive the code");
}

void test_non_terminated_paths_fail_without_overread() {
#if defined(__unix__) || defined(__APPLE__)
  reset_contract();
  expect_child_success_without_signal([]() {
    reset_contract();
    GuardPageRegion region;
    HostCapture capture;
    auto callbacks = make_host_callbacks(&capture);
    ErrorBox error;
    if (cmfa_initialize(&callbacks, &error.error) != CMFA_OK) {
      return 10;
    }
    const cmfa_status validate_status = cmfa_validate_config(region.path, &error.error);
    if (validate_status != CMFA_OUT_OF_RANGE) {
      return 11;
    }
    cmfa_runtime_snapshot snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    cmfa_local_options options{};
    options.struct_size = sizeof(options);
    options.config_path = region.path;
    options.mixed_port = 7890;
    const cmfa_status start_status = cmfa_start_local(&options, &snapshot, &error.error);
    if (start_status != CMFA_OUT_OF_RANGE) {
      return 12;
    }
    return 0;
  }, "non-terminated path should fail without signal");
#endif
}

void test_host_callback_copy_and_event_unsubscribe() {
  reset_contract();

  HostCapture capture;
  HostCapture alternate_capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  callbacks.context = &alternate_capture;
  callbacks.log_sink = nullptr;
  callbacks.event_sink = nullptr;

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_OK, "start should succeed");

  {
    std::lock_guard<std::mutex> lock(capture.mutex);
    expect_eq(capture.states.size(), static_cast<size_t>(1), "copied callback should still receive event");
  }

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed");
  backend.emit_after_stop();
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should succeed");
  backend.emit_after_stop();

  {
    std::lock_guard<std::mutex> lock(capture.mutex);
    expect_eq(capture.states.size(), static_cast<size_t>(1), "events after stop/shutdown must be gated");
    expect_eq(capture.logs.size(), static_cast<size_t>(0), "logs after stop/shutdown must be gated");
  }

  reset_contract();
}

void test_stop_waits_for_in_flight_event_callback() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_OK, "start should succeed");

  capture.block_callbacks = true;
  std::thread emitter([&] { backend.emit_event_direct("blocked-event"); });
  wait_for_callback_entry(&capture, 2);

  auto stop_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_stop(&thread_error.error);
  });

  expect_eq(stop_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "stop must not return while callback remains blocked");

  release_blocked_callbacks(&capture);
  emitter.join();

  expect_eq(stop_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "stop should complete after callback release");
  const cmfa_status stop_status = stop_future.get();
  expect_eq(stop_status, CMFA_OK, "stop should succeed after callback release");
  reset_contract();
}

void test_shutdown_waits_for_in_flight_log_callback() {
  reset_contract();

  HostCapture capture;
  capture.block_callbacks = true;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  std::thread emitter([&] { backend.emit_log_direct("blocked-log"); });
  wait_for_callback_entry(&capture);

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });

  expect_eq(shutdown_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "shutdown must not return while callback remains blocked");

  release_blocked_callbacks(&capture);
  emitter.join();

  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after callback release");
  const cmfa_status shutdown_status = shutdown_future.get();
  expect_eq(shutdown_status, CMFA_OK, "shutdown should succeed after callback release");
  reset_contract();
}

void test_concurrent_start_rejection() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_start = true;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot first_snapshot{};
  first_snapshot.struct_size = sizeof(first_snapshot);
  cmfa_runtime_snapshot second_snapshot{};
  second_snapshot.struct_size = sizeof(second_snapshot);

  std::atomic<cmfa_status> first_status{CMFA_BACKEND_ERROR};
  std::thread first([&] {
    ErrorBox thread_error;
    first_status.store(cmfa_start_local(&options, &first_snapshot, &thread_error.error));
  });

  backend.wait_for_start_entry();
  expect_eq(cmfa_start_local(&options, &second_snapshot, &error.error), CMFA_BUSY,
            "second concurrent start must be rejected deterministically");
  backend.release_start();
  first.join();

  expect_eq(first_status.load(), CMFA_OK, "first start should succeed");
  expect_eq(first_snapshot.state, CMFA_RUNTIME_RUNNING, "first snapshot should become running");

  reset_contract();
}

void test_backend_driven_version_and_runtime_queries() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  char version[32] = {};
  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_OK,
            "version should dispatch to backend");
  expect_string_eq(version, "fake-core-1.0.0", "backend version should copy into caller buffer");

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "runtime_state should query backend");
  expect_eq(snapshot.state, CMFA_RUNTIME_STOPPED, "initial backend runtime state should be stopped");

  reset_contract();
}

void test_shutdown_serializes_with_in_flight_start() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_start = true;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  auto start_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_start_local(&options, &snapshot, &thread_error.error);
  });

  backend.wait_for_start_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });

  {
    std::lock_guard<std::mutex> lock(backend.mutex);
    expect(!backend.shutdown_called, "shutdown must not advance to backend while start is still blocked");
  }
  expect_eq(shutdown_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "shutdown must not return while start remains blocked");

  backend.release_start();

  expect_eq(start_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "start should complete after release");
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after start releases");
  const cmfa_status start_status = start_future.get();
  const cmfa_status shutdown_status = shutdown_future.get();
  expect_eq(shutdown_status, CMFA_OK, "shutdown should complete after start releases");
  expect(start_status == CMFA_OK || start_status == CMFA_INVALID_STATE || start_status == CMFA_BUSY,
         "start should resolve to a defined status");
  reset_contract();
}

void test_backend_registration_rejects_incomplete_lifecycle() {
  reset_contract();

  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  api.proxy_select = nullptr;
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_INVALID_ARGUMENT,
            "backend registration should reject missing proxy_select hook");
  api = backend.api();
  api.proxy_delay_cancel = nullptr;
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_INVALID_ARGUMENT,
            "backend registration should reject missing proxy_delay_cancel hook");
}

void test_proxy_calls_require_initialization_and_backend() {
  reset_contract();

  ErrorBox error;
  const auto context = make_query_context();
  JsonBufferBox groups_output(64);
  JsonBufferBox group_output(64);
  JsonBufferBox select_output(64);

  expect_eq(cmfa_proxy_groups(&context, 0, &groups_output.buffer, &error.error), CMFA_NOT_INITIALIZED,
            "proxy_groups should reject calls before initialize");
  expect_eq(groups_output.buffer.length, static_cast<size_t>(0), "proxy_groups failure should clear length");
  expect_string_eq(groups_output.c_str(), "", "proxy_groups failure should clear public buffer");

  expect_eq(cmfa_proxy_group(&context, "group-a", &group_output.buffer, &error.error), CMFA_NOT_INITIALIZED,
            "proxy_group should reject calls before initialize");
  expect_eq(group_output.buffer.length, static_cast<size_t>(0), "proxy_group failure should clear length");
  expect_string_eq(group_output.c_str(), "", "proxy_group failure should clear public buffer");

  expect_eq(cmfa_proxy_select(&context, "group-a", "member-b", &select_output.buffer, &error.error),
            CMFA_NOT_INITIALIZED, "proxy_select should reject calls before initialize");
  expect_eq(select_output.buffer.length, static_cast<size_t>(0), "proxy_select failure should clear length");
  expect_string_eq(select_output.c_str(), "", "proxy_select failure should clear public buffer");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed without backend");

  groups_output.buffer.length = 91;
  std::memcpy(groups_output.buffer.data, "stale", 6);
  expect_eq(cmfa_proxy_groups(&context, 1, &groups_output.buffer, &error.error), CMFA_CORE_UNAVAILABLE,
            "proxy_groups should report core unavailable without backend");
  expect_eq(groups_output.buffer.length, static_cast<size_t>(0), "missing backend should clear length");
  expect_string_eq(groups_output.c_str(), "", "missing backend should clear public buffer");
  expect(groups_output.guards_intact(), "missing backend must not overrun caller buffer");

  reset_contract();
}

void test_proxy_delay_calls_require_initialization_and_backend() {
  reset_contract();

  ErrorBox error;
  const auto context = make_query_context();
  JsonBufferBox start_output(64);
  JsonBufferBox snapshot_output(64);
  JsonBufferBox cancel_output(64);

  expect_eq(cmfa_proxy_delay_start(&context, "group-a", &start_output.buffer, &error.error), CMFA_NOT_INITIALIZED,
            "proxy_delay_start should reject calls before initialize");
  expect_eq(start_output.buffer.length, static_cast<size_t>(0), "proxy_delay_start failure should clear length");
  expect_string_eq(start_output.c_str(), "", "proxy_delay_start failure should clear public buffer");

  expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &snapshot_output.buffer, &error.error), CMFA_NOT_INITIALIZED,
            "proxy_delay_snapshot should reject calls before initialize");
  expect_eq(snapshot_output.buffer.length, static_cast<size_t>(0), "proxy_delay_snapshot failure should clear length");
  expect_string_eq(snapshot_output.c_str(), "", "proxy_delay_snapshot failure should clear public buffer");

  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &cancel_output.buffer, &error.error), CMFA_NOT_INITIALIZED,
            "proxy_delay_cancel should reject calls before initialize");
  expect_eq(cancel_output.buffer.length, static_cast<size_t>(0), "proxy_delay_cancel failure should clear length");
  expect_string_eq(cancel_output.c_str(), "", "proxy_delay_cancel failure should clear public buffer");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed without backend");

  start_output.buffer.length = 91;
  std::memcpy(start_output.buffer.data, "stale", 6);
  expect_eq(cmfa_proxy_delay_start(&context, "group-a", &start_output.buffer, &error.error), CMFA_CORE_UNAVAILABLE,
            "proxy_delay_start should report core unavailable without backend");
  expect_eq(start_output.buffer.length, static_cast<size_t>(0), "missing backend should clear length");
  expect_string_eq(start_output.c_str(), "", "missing backend should clear public buffer");
  expect(start_output.guards_intact(), "missing backend must not overrun caller buffer");

  reset_contract();
}

void test_proxy_argument_validation_and_buffer_sanitization() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto valid_context = make_query_context();
  JsonBufferBox output(48);
  auto reset_output = [&] {
    output.buffer.length = 444;
    std::memset(output.buffer.data, 'Z', output.buffer.capacity);
  };
  auto expect_cleared_output = [&](const std::string &message) {
    expect_eq(output.buffer.length, static_cast<size_t>(0), message + " should clear output length");
    expect_string_eq(output.c_str(), "", message + " should clear output text");
    expect(output.guards_intact(), message + " must preserve caller guards");
  };

  reset_output();
  expect_eq(cmfa_proxy_groups(nullptr, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject null context");
  expect_cleared_output("null context");

  auto short_context = valid_context;
  short_context.struct_size -= 1;
  reset_output();
  expect_eq(cmfa_proxy_groups(&short_context, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject short context struct_size");
  expect_cleared_output("short struct_size");

  auto invalid_profile = valid_context;
  invalid_profile.profile_hash[0] = 'A';
  reset_output();
  expect_eq(cmfa_proxy_groups(&invalid_profile, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject non-lowercase profile hash");
  expect_cleared_output("invalid profile hash");

  auto invalid_revision = valid_context;
  invalid_revision.revision_hash[63] = 'z';
  reset_output();
  expect_eq(cmfa_proxy_groups(&invalid_revision, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject invalid revision hash");
  expect_cleared_output("invalid revision hash");

  auto invalid_session = valid_context;
  invalid_session.session_hash[0] = 'x';
  reset_output();
  expect_eq(cmfa_proxy_groups(&invalid_session, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject invalid session hash");
  expect_cleared_output("invalid session hash");

  auto noncanonical_empty_session = valid_context;
  noncanonical_empty_session.session_hash[0] = '\0';
  noncanonical_empty_session.session_hash[1] = 'x';
  reset_output();
  expect_eq(cmfa_proxy_groups(&noncanonical_empty_session, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject noncanonical empty session hash");
  expect_cleared_output("noncanonical empty session hash");

  auto missing_generation = valid_context;
  missing_generation.generation = 0;
  reset_output();
  expect_eq(cmfa_proxy_groups(&missing_generation, 0, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject zero generation");
  expect_cleared_output("zero generation");

  reset_output();
  expect_eq(cmfa_proxy_groups(&valid_context, 2, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject selectable_only values above 1");
  expect_cleared_output("invalid selectable_only");

  cmfa_json_buffer null_data_output{};
  null_data_output.capacity = 16;
  null_data_output.length = 5;
  expect_eq(cmfa_proxy_groups(&valid_context, 0, &null_data_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject null output.data");
  expect_eq(null_data_output.length, static_cast<size_t>(0), "null data output should clear length");

  cmfa_json_buffer null_zero_output{};
  null_zero_output.length = 6;
  expect_eq(cmfa_proxy_groups(&valid_context, 0, &null_zero_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject null output.data with zero capacity");
  expect_eq(null_zero_output.length, static_cast<size_t>(0), "null/zero output should clear length");

  cmfa_json_buffer zero_capacity_output{};
  char zero_capacity_storage = 'Y';
  zero_capacity_output.data = &zero_capacity_storage;
  zero_capacity_output.capacity = 0;
  zero_capacity_output.length = 5;
  expect_eq(cmfa_proxy_groups(&valid_context, 0, &zero_capacity_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject zero-capacity output");
  expect_eq(zero_capacity_output.length, static_cast<size_t>(0), "zero-capacity output should clear length");
  expect_eq(zero_capacity_storage, 'Y', "zero-capacity rejection must not touch caller byte");

  cmfa_json_buffer null_positive_output{};
  null_positive_output.capacity = 3;
  null_positive_output.length = 7;
  expect_eq(cmfa_proxy_groups(&valid_context, 0, &null_positive_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject null output.data with positive capacity");
  expect_eq(null_positive_output.length, static_cast<size_t>(0), "null/positive output should clear length");

  reset_output();
  expect_eq(cmfa_proxy_group(&valid_context, nullptr, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_group should reject null group_name");
  expect_cleared_output("null group_name");

  reset_output();
  expect_eq(cmfa_proxy_group(&valid_context, "", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_group should reject empty group_name");
  expect_cleared_output("empty group_name");

  const std::string too_long_name(CMFA_MAX_PROXY_NAME_UTF8_BYTES + 1, 'n');
  reset_output();
  expect_eq(cmfa_proxy_group(&valid_context, too_long_name.c_str(), &output.buffer, &error.error), CMFA_OUT_OF_RANGE,
            "proxy_group should reject oversized group_name");
  expect_cleared_output("oversized group_name");

  const char invalid_utf8_name[] = {'g', static_cast<char>(0xC3), static_cast<char>(0x28), '\0'};
  reset_output();
  expect_eq(cmfa_proxy_group(&valid_context, invalid_utf8_name, &output.buffer, &error.error), CMFA_INVALID_UTF8,
            "proxy_group should reject invalid UTF-8 names");
  expect_cleared_output("invalid UTF-8 group_name");

  const char control_name[] = {'g', '\x1F', '\0'};
  reset_output();
  expect_eq(cmfa_proxy_group(&valid_context, control_name, &output.buffer, &error.error), CMFA_INVALID_UTF8,
            "proxy_group should reject control characters");
  expect_cleared_output("control-character group_name");
  expect_error_omits_fragments(error, {too_long_name, invalid_utf8_name, control_name}, "validation errors must not echo raw group_name");

  reset_output();
  expect_eq(cmfa_proxy_select(&valid_context, "group-a", nullptr, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_select should reject null member_name");
  expect_cleared_output("null member_name");

  reset_output();
  expect_eq(cmfa_proxy_select(&valid_context, "group-a", "", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_select should reject empty member_name");
  expect_cleared_output("empty member_name");

  reset_contract();
}

void test_proxy_delay_argument_validation_and_buffer_sanitization() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto valid_context = make_query_context();
  JsonBufferBox output(48);
  auto reset_output = [&] {
    output.buffer.length = 444;
    std::memset(output.buffer.data, 'Z', output.buffer.capacity);
  };
  auto expect_cleared_output = [&](const std::string &message) {
    expect_eq(output.buffer.length, static_cast<size_t>(0), message + " should clear output length");
    expect_string_eq(output.c_str(), "", message + " should clear output text");
    expect(output.guards_intact(), message + " must preserve caller guards");
  };

  reset_output();
  expect_eq(cmfa_proxy_delay_start(nullptr, "group-a", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_start should reject null context");
  expect_cleared_output("null context");

  reset_output();
  expect_eq(cmfa_proxy_delay_start(&valid_context, nullptr, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_start should reject null group_name");
  expect_cleared_output("null group_name");

  reset_output();
  expect_eq(cmfa_proxy_delay_start(&valid_context, "", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_start should reject empty group_name");
  expect_cleared_output("empty group_name");

  const std::string too_long_name(CMFA_MAX_PROXY_NAME_UTF8_BYTES + 1, 'n');
  reset_output();
  expect_eq(cmfa_proxy_delay_start(&valid_context, too_long_name.c_str(), &output.buffer, &error.error), CMFA_OUT_OF_RANGE,
            "proxy_delay_start should reject oversized group_name");
  expect_cleared_output("oversized group_name");

  const char invalid_utf8_name[] = {'g', static_cast<char>(0xC3), static_cast<char>(0x28), '\0'};
  reset_output();
  expect_eq(cmfa_proxy_delay_start(&valid_context, invalid_utf8_name, &output.buffer, &error.error), CMFA_INVALID_UTF8,
            "proxy_delay_start should reject invalid UTF-8 names");
  expect_cleared_output("invalid UTF-8 group_name");

  const char control_name[] = {'g', '\x1F', '\0'};
  reset_output();
  expect_eq(cmfa_proxy_delay_start(&valid_context, control_name, &output.buffer, &error.error), CMFA_INVALID_UTF8,
            "proxy_delay_start should reject control characters");
  expect_cleared_output("control-character group_name");

  reset_output();
  expect_eq(cmfa_proxy_delay_snapshot(nullptr, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_snapshot should reject null job id");
  expect_cleared_output("null job id");

  reset_output();
  expect_eq(cmfa_proxy_delay_snapshot("", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_snapshot should reject empty job id");
  expect_cleared_output("empty job id");

  reset_output();
  expect_eq(cmfa_proxy_delay_cancel("0123456789abcdef0123456789abcdeF", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_cancel should reject non-lowercase job ids");
  expect_cleared_output("uppercase job id");

  reset_output();
  expect_eq(cmfa_proxy_delay_snapshot("0123456789abcdef0123456789abcdeg", &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_snapshot should reject non-hex job ids");
  expect_cleared_output("non-hex job id");

  const char short_job_id[] = "0123456789abcdef0123456789abcde";
  reset_output();
  expect_eq(cmfa_proxy_delay_cancel(short_job_id, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_cancel should reject short job ids");
  expect_cleared_output("short job id");

  const char invalid_utf8_job_id[] = {
      '0', '1', '2', '3', '4', '5', '6', '7',
      '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
      '0', '1', '2', '3', '4', '5', '6', '7',
      '8', '9', 'a', 'b', 'c', 'd', static_cast<char>(0xC3), static_cast<char>(0x28), '\0'};
  reset_output();
  expect_eq(cmfa_proxy_delay_snapshot(invalid_utf8_job_id, &output.buffer, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_snapshot should reject malformed UTF-8 job ids");
  expect_cleared_output("malformed UTF-8 job id");

  cmfa_json_buffer null_data_output{};
  null_data_output.capacity = 16;
  null_data_output.length = 5;
  expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &null_data_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_snapshot should reject null output.data");
  expect_eq(null_data_output.length, static_cast<size_t>(0), "null data output should clear length");

  cmfa_json_buffer zero_capacity_output{};
  char zero_capacity_storage = 'Y';
  zero_capacity_output.data = &zero_capacity_storage;
  zero_capacity_output.capacity = 0;
  zero_capacity_output.length = 5;
  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &zero_capacity_output, &error.error), CMFA_INVALID_ARGUMENT,
            "proxy_delay_cancel should reject zero-capacity output");
  expect_eq(zero_capacity_output.length, static_cast<size_t>(0), "zero-capacity output should clear length");
  expect_eq(zero_capacity_storage, 'Y', "zero-capacity rejection must not touch caller byte");

  expect_error_omits_fragments(
      error,
      {too_long_name, invalid_utf8_name, control_name, std::string(short_job_id), invalid_utf8_job_id, kProxyDelayJobId},
      "validation errors must not echo raw proxy delay inputs");

  reset_contract();
}

void test_proxy_rejects_output_error_aliasing_before_backend_invocation() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto context = make_query_context();

  std::array<char, 24> groups_storage{};
  groups_storage.fill('G');
  cmfa_json_buffer groups_output{};
  groups_output.data = groups_storage.data();
  groups_output.capacity = 12;
  groups_output.length = 77;
  cmfa_error groups_error{};
  groups_error.code = CMFA_OK;
  groups_error.message = groups_storage.data();
  groups_error.capacity = 12;
  groups_error.length = 55;
  backend.proxy_mode = FakeBackend::ProxyMode::Success;
  expect_eq(cmfa_proxy_groups(&context, 0, &groups_output, &groups_error), CMFA_INVALID_ARGUMENT,
            "proxy_groups should reject exact output/error aliasing");
  expect(!backend.proxy_groups_called, "proxy_groups alias rejection must happen before backend invocation");
  expect_eq(groups_output.length, static_cast<size_t>(0), "exact alias should clear output length");
  expect_eq(groups_output.data[0], '\0', "exact alias should clear first output byte");
  expect_eq(groups_storage[1], 'G', "exact alias must not write an error message into aliased output");
  expect_eq(groups_error.code, CMFA_INVALID_ARGUMENT, "exact alias should set invalid argument error code");
  expect_eq(groups_error.length, static_cast<size_t>(0), "exact alias should canonicalize error length");

  std::array<char, 24> group_storage{};
  group_storage.fill('H');
  cmfa_json_buffer group_output{};
  group_output.data = group_storage.data();
  group_output.capacity = 12;
  group_output.length = 88;
  cmfa_error group_error{};
  group_error.code = CMFA_OK;
  group_error.message = group_storage.data() + 1;
  group_error.capacity = 8;
  group_error.length = 44;
  backend.proxy_group_called = false;
  backend.proxy_mode = FakeBackend::ProxyMode::BufferTooSmall;
  expect_eq(cmfa_proxy_group(&context, "group-a", &group_output, &group_error), CMFA_INVALID_ARGUMENT,
            "proxy_group should reject overlapping output/error aliasing");
  expect(!backend.proxy_group_called, "proxy_group alias rejection must happen before backend invocation");
  expect_eq(group_output.length, static_cast<size_t>(0), "overlap alias should clear output length");
  expect_eq(group_output.data[0], '\0', "overlap alias should clear first output byte");
  expect_eq(group_storage[1], 'H', "overlap alias must not write an error message into aliased output");
  expect_eq(group_error.code, CMFA_INVALID_ARGUMENT, "overlap alias should set invalid argument error code");
  expect_eq(group_error.length, static_cast<size_t>(0), "overlap alias should canonicalize error length");

  std::array<char, 24> select_storage{};
  select_storage.fill('I');
  cmfa_json_buffer select_output{};
  select_output.data = select_storage.data() + 2;
  select_output.capacity = 10;
  select_output.length = 99;
  cmfa_error select_error{};
  select_error.code = CMFA_OK;
  select_error.message = select_storage.data();
  select_error.capacity = 5;
  select_error.length = 33;
  backend.proxy_select_called = false;
  backend.proxy_mode = FakeBackend::ProxyMode::BackendError;
  expect_eq(cmfa_proxy_select(&context, "group-a", "member-b", &select_output, &select_error), CMFA_INVALID_ARGUMENT,
            "proxy_select should reject reverse-overlap output/error aliasing");
  expect(!backend.proxy_select_called, "proxy_select alias rejection must happen before backend invocation");
  expect_eq(select_output.length, static_cast<size_t>(0), "reverse overlap should clear output length");
  expect_eq(select_output.data[0], '\0', "reverse overlap should clear first output byte");
  expect_eq(select_storage[0], 'I', "reverse overlap must not write an error message into aliased output");
  expect_eq(select_storage[1], 'I', "reverse overlap must preserve non-output prefix bytes");
  expect_eq(select_error.code, CMFA_INVALID_ARGUMENT, "reverse overlap should set invalid argument error code");
  expect_eq(select_error.length, static_cast<size_t>(0), "reverse overlap should canonicalize error length");

  reset_contract();
}

void test_proxy_successful_copy_preserves_length_and_forwarding() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto sessionless_context = make_query_context(false);
  JsonBufferBox output(128);

  expect_eq(cmfa_proxy_groups(&sessionless_context, 1, &output.buffer, &error.error), CMFA_OK,
            "proxy_groups should succeed with canonical empty session hash");
  expect_eq(output.buffer.length, std::strlen(kProxyJson), "proxy_groups should preserve JSON byte length");
  expect_string_eq(output.c_str(), kProxyJson, "proxy_groups should copy the complete JSON payload");
  expect_eq(output.buffer.data[output.buffer.length], '\0', "proxy_groups should append exactly one NUL terminator");
  expect(output.guards_intact(), "proxy_groups success must preserve caller guards");
  expect(backend.proxy_groups_called, "proxy_groups should reach backend callback");
  expect_eq(backend.last_selectable_only, static_cast<uint8_t>(1), "selectable_only should be forwarded");
  expect_eq(backend.last_proxy_query.generation, static_cast<uint64_t>(7), "generation should be forwarded");
  expect_string_eq(std::string(backend.last_proxy_query.profile_hash), kProxyProfileHash, "profile hash should be forwarded");
  expect_string_eq(std::string(backend.last_proxy_query.revision_hash), kProxyRevisionHash, "revision hash should be forwarded");
  expect_string_eq(std::string(backend.last_proxy_query.session_hash), "", "canonical empty session hash should remain empty");

  const auto hashed_session_context = make_query_context(true);
  JsonBufferBox hashed_output(128);
  expect_eq(cmfa_proxy_groups(&hashed_session_context, 0, &hashed_output.buffer, &error.error), CMFA_OK,
            "proxy_groups should also succeed with nonempty exact session hash");
  expect_string_eq(std::string(backend.last_proxy_query.session_hash), kProxySessionHash,
                   "nonempty exact session hash should be forwarded unchanged");

  JsonBufferBox group_output(128);
  expect_eq(cmfa_proxy_group(&sessionless_context, "url-test", &group_output.buffer, &error.error), CMFA_OK,
            "proxy_group should succeed");
  expect(backend.proxy_group_called, "proxy_group should reach backend callback");
  expect_string_eq(backend.last_group_name, "url-test", "group_name should be forwarded");
  expect_string_eq(group_output.c_str(), kProxyJson, "proxy_group should copy JSON");

  JsonBufferBox select_output(128);
  expect_eq(cmfa_proxy_select(&sessionless_context, "url-test", "node-a", &select_output.buffer, &error.error), CMFA_OK,
            "proxy_select should succeed");
  expect(backend.proxy_select_called, "proxy_select should reach backend callback");
  expect_string_eq(backend.last_group_name, "url-test", "proxy_select should forward group_name");
  expect_string_eq(backend.last_member_name, "node-a", "proxy_select should forward member_name");
  expect_eq(select_output.buffer.length, std::strlen(kProxyJson), "proxy_select should preserve output length");

  reset_contract();
}

void test_proxy_delay_successful_copy_preserves_length_and_forwarding() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto sessionless_context = make_query_context(false);
  JsonBufferBox start_output(128);

  expect_eq(cmfa_proxy_delay_start(&sessionless_context, "url-test", &start_output.buffer, &error.error), CMFA_OK,
            "proxy_delay_start should succeed with canonical empty session hash");
  expect_eq(start_output.buffer.length, std::strlen(kProxyJson), "proxy_delay_start should preserve JSON byte length");
  expect_string_eq(start_output.c_str(), kProxyJson, "proxy_delay_start should copy the complete JSON payload");
  expect_eq(start_output.buffer.data[start_output.buffer.length], '\0',
            "proxy_delay_start should append exactly one NUL terminator");
  expect(start_output.guards_intact(), "proxy_delay_start success must preserve caller guards");
  expect(backend.proxy_delay_start_called, "proxy_delay_start should reach backend callback");
  expect_eq(backend.last_proxy_query.generation, static_cast<uint64_t>(7), "generation should be forwarded");
  expect_string_eq(backend.last_group_name, "url-test", "proxy_delay_start should forward group_name");
  expect_string_eq(std::string(backend.last_proxy_query.session_hash), "",
                   "canonical empty session hash should remain empty");

  const auto hashed_session_context = make_query_context(true);
  JsonBufferBox snapshot_output(128);
  expect_eq(cmfa_proxy_delay_start(&hashed_session_context, "fallback", &snapshot_output.buffer, &error.error), CMFA_OK,
            "proxy_delay_start should also succeed with nonempty exact session hash");
  expect_string_eq(std::string(backend.last_proxy_query.session_hash), kProxySessionHash,
                   "nonempty exact session hash should be forwarded unchanged");

  JsonBufferBox delay_snapshot_output(128);
  expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &delay_snapshot_output.buffer, &error.error), CMFA_OK,
            "proxy_delay_snapshot should succeed");
  expect(backend.proxy_delay_snapshot_called, "proxy_delay_snapshot should reach backend callback");
  expect_string_eq(backend.last_delay_job_id, kProxyDelayJobId, "proxy_delay_snapshot should forward job id");
  expect_eq(delay_snapshot_output.buffer.length, std::strlen(kProxyJson),
            "proxy_delay_snapshot should preserve output length");

  JsonBufferBox cancel_output(128);
  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &cancel_output.buffer, &error.error), CMFA_OK,
            "proxy_delay_cancel should succeed");
  expect(backend.proxy_delay_cancel_called, "proxy_delay_cancel should reach backend callback");
  expect_string_eq(backend.last_delay_job_id, kProxyDelayJobId, "proxy_delay_cancel should forward job id");
  expect_eq(cancel_output.buffer.length, std::strlen(kProxyJson), "proxy_delay_cancel should preserve output length");

  reset_contract();
}

void test_proxy_buffer_too_small_and_backend_failures_scrub_public_buffer() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto context = make_query_context();
  JsonBufferBox small_output(8);
  backend.proxy_mode = FakeBackend::ProxyMode::BufferTooSmall;
  expect_eq(cmfa_proxy_groups(&context, 0, &small_output.buffer, &error.error), CMFA_BUFFER_TOO_SMALL,
            "proxy_groups should surface required length without partial JSON");
  expect_eq(small_output.buffer.length, std::strlen(kProxyJson), "buffer-too-small should report required JSON bytes");
  expect_string_eq(small_output.c_str(), "", "buffer-too-small should not expose partial JSON");
  expect(small_output.guards_intact(), "buffer-too-small should preserve caller guards");

  backend.proxy_mode = FakeBackend::ProxyMode::BackendError;
  backend.proxy_error_message = "typed proxy backend failure";
  JsonBufferBox failed_output(64);
  expect_eq(cmfa_proxy_select(&context, "group-a", "member-b", &failed_output.buffer, &error.error), CMFA_BACKEND_ERROR,
            "proxy_select should preserve backend error status");
  expect_eq(failed_output.buffer.length, static_cast<size_t>(0), "backend error should clear public length");
  expect_string_eq(failed_output.c_str(), "", "backend error should clear public buffer");
  expect_error_omits_fragments(error, {"group-a", "member-b", kProxyJson}, "backend error must not echo raw proxy inputs");

  reset_contract();
}

void test_proxy_delay_buffer_too_small_and_backend_failures_scrub_public_buffer() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto context = make_query_context();
  JsonBufferBox small_output(8);
  backend.proxy_mode = FakeBackend::ProxyMode::BufferTooSmall;
  expect_eq(cmfa_proxy_delay_start(&context, "group-a", &small_output.buffer, &error.error), CMFA_BUFFER_TOO_SMALL,
            "proxy_delay_start should surface required length without partial JSON");
  expect_eq(small_output.buffer.length, std::strlen(kProxyJson),
            "buffer-too-small should report required JSON bytes");
  expect_string_eq(small_output.c_str(), "", "buffer-too-small should not expose partial JSON");
  expect(small_output.guards_intact(), "buffer-too-small should preserve caller guards");

  backend.proxy_mode = FakeBackend::ProxyMode::BackendError;
  backend.proxy_error_message = "typed proxy delay backend failure";
  JsonBufferBox failed_output(64);
  expect_eq(cmfa_proxy_delay_cancel(kProxyDelayJobId, &failed_output.buffer, &error.error), CMFA_BACKEND_ERROR,
            "proxy_delay_cancel should preserve backend error status");
  expect_eq(failed_output.buffer.length, static_cast<size_t>(0), "backend error should clear public length");
  expect_string_eq(failed_output.c_str(), "", "backend error should clear public buffer");
  expect_error_omits_fragments(error, {"group-a", kProxyDelayJobId, kProxyJson},
                               "backend error must not echo raw proxy delay inputs");

  reset_contract();
}

void test_proxy_backend_output_validation_rejects_malformed_json_and_overrun() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const auto context = make_query_context();
  const struct InvalidCase {
    FakeBackend::ProxyMode mode;
    cmfa_status expected_status;
    const char *label;
  } cases[] = {
      {FakeBackend::ProxyMode::MissingNul, CMFA_BACKEND_ERROR, "missing NUL"},
      {FakeBackend::ProxyMode::InvalidUtf8, CMFA_BACKEND_ERROR, "invalid UTF-8"},
      {FakeBackend::ProxyMode::Overrun, CMFA_BACKEND_ERROR, "canary overrun"},
      {FakeBackend::ProxyMode::TooLarge, CMFA_BACKEND_ERROR, "response cap overflow"},
      {FakeBackend::ProxyMode::InvalidStatus, CMFA_BACKEND_ERROR, "invalid backend status"},
  };

  for (const InvalidCase &entry : cases) {
    backend.proxy_mode = entry.mode;
    JsonBufferBox output(128);
    expect_eq(cmfa_proxy_group(&context, "group-a", &output.buffer, &error.error), entry.expected_status,
              std::string("proxy_group should reject backend ") + entry.label);
    expect_eq(output.buffer.length, static_cast<size_t>(0),
              std::string("backend ") + entry.label + " should clear public length");
    expect_string_eq(output.c_str(), "", std::string("backend ") + entry.label + " should clear public buffer");
    expect(output.guards_intact(), std::string("backend ") + entry.label + " must preserve caller guards");
    expect_error_omits_fragments(error, {"group-a", kProxyJson}, std::string("backend ") + entry.label + " error must stay scrubbed");
  }

  reset_contract();
}

void test_proxy_delay_backend_output_validation_rejects_malformed_json_and_overrun() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  const struct InvalidCase {
    FakeBackend::ProxyMode mode;
    cmfa_status expected_status;
    const char *label;
  } cases[] = {
      {FakeBackend::ProxyMode::MissingNul, CMFA_BACKEND_ERROR, "missing NUL"},
      {FakeBackend::ProxyMode::InvalidUtf8, CMFA_BACKEND_ERROR, "invalid UTF-8"},
      {FakeBackend::ProxyMode::Overrun, CMFA_BACKEND_ERROR, "canary overrun"},
      {FakeBackend::ProxyMode::TooLarge, CMFA_BACKEND_ERROR, "response cap overflow"},
      {FakeBackend::ProxyMode::InvalidStatus, CMFA_BACKEND_ERROR, "invalid backend status"},
  };

  for (const InvalidCase &entry : cases) {
    backend.proxy_mode = entry.mode;
    JsonBufferBox output(128);
    expect_eq(cmfa_proxy_delay_snapshot(kProxyDelayJobId, &output.buffer, &error.error), entry.expected_status,
              std::string("proxy_delay_snapshot should reject backend ") + entry.label);
    expect_eq(output.buffer.length, static_cast<size_t>(0),
              std::string("backend ") + entry.label + " should clear public length");
    expect_string_eq(output.c_str(), "", std::string("backend ") + entry.label + " should clear public buffer");
    expect(output.guards_intact(), std::string("backend ") + entry.label + " must preserve caller guards");
    expect_error_omits_fragments(error, {kProxyDelayJobId, kProxyJson},
                                 std::string("backend ") + entry.label + " error must stay scrubbed");
  }

  reset_contract();
}

struct ContractHookBarrier {
  std::mutex mutex;
  std::condition_variable cv;
  int target_point = 0;
  bool block = false;
  bool entered = false;
  bool release = false;

  static void callback(void *context, int point) {
    auto *self = static_cast<ContractHookBarrier *>(context);
    std::unique_lock<std::mutex> lock(self->mutex);
    if (point != self->target_point) {
      return;
    }
    self->entered = true;
    self->cv.notify_all();
    while (self->block && !self->release) {
      self->cv.wait(lock);
    }
  }

  void wait_for_entry() {
    std::unique_lock<std::mutex> lock(mutex);
    const bool hit = cv.wait_for(lock, std::chrono::seconds(2), [&] { return entered; });
    expect(hit, "timed out waiting for contract hook");
  }

  void unblock() {
    std::lock_guard<std::mutex> lock(mutex);
    release = true;
    cv.notify_all();
  }
};

#if defined(CMFA_CONTRACT_TESTING)
class ScopedContractHook {
public:
  ScopedContractHook(void (*hook)(void *context, int point), void *context) {
    cmfa_internal_set_test_hook(hook, context);
  }

  ~ScopedContractHook() { cmfa_internal_set_test_hook(nullptr, nullptr); }

  ScopedContractHook(const ScopedContractHook &) = delete;
  ScopedContractHook &operator=(const ScopedContractHook &) = delete;
};
#endif

void test_proxy_rechecks_shutdown_before_backend_borrow() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_shutdown = true;
  backend.allow_shutdown_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  ContractHookBarrier barrier{};
  barrier.target_point = CMFA_TEST_HOOK_BEFORE_BACKEND_BORROW;
  barrier.block = true;
#if defined(CMFA_CONTRACT_TESTING)
  ScopedContractHook hook(&ContractHookBarrier::callback, &barrier);
#endif

  const auto context = make_query_context();
  JsonBufferBox output(128);
  auto groups_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_proxy_groups(&context, 1, &output.buffer, &thread_error.error);
  });
  barrier.wait_for_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });
  backend.wait_for_shutdown_called();

  barrier.unblock();
  expect_eq(groups_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "proxy_groups should complete once borrow barrier is released");
  const cmfa_status groups_status = groups_future.get();
  expect(groups_status == CMFA_BUSY || groups_status == CMFA_NOT_INITIALIZED || groups_status == CMFA_INVALID_STATE,
         "proxy_groups must not borrow backend after shutdown begins");
  expect_eq(output.buffer.length, static_cast<size_t>(0), "shutdown race should clear output length");
  expect_string_eq(output.c_str(), "", "shutdown race should clear output text");

  backend.release_shutdown();
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after backend release");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown should succeed");
}

void test_proxy_delay_rechecks_shutdown_before_backend_borrow() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_shutdown = true;
  backend.allow_shutdown_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  ContractHookBarrier barrier{};
  barrier.target_point = CMFA_TEST_HOOK_BEFORE_BACKEND_BORROW;
  barrier.block = true;
#if defined(CMFA_CONTRACT_TESTING)
  ScopedContractHook hook(&ContractHookBarrier::callback, &barrier);
#endif

  JsonBufferBox output(128);
  auto snapshot_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_proxy_delay_snapshot(kProxyDelayJobId, &output.buffer, &thread_error.error);
  });
  barrier.wait_for_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });
  backend.wait_for_shutdown_called();

  barrier.unblock();
  expect_eq(snapshot_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "proxy_delay_snapshot should complete once borrow barrier is released");
  const cmfa_status snapshot_status = snapshot_future.get();
  expect(snapshot_status == CMFA_BUSY || snapshot_status == CMFA_NOT_INITIALIZED || snapshot_status == CMFA_INVALID_STATE,
         "proxy_delay_snapshot must not borrow backend after shutdown begins");
  expect_eq(output.buffer.length, static_cast<size_t>(0), "shutdown race should clear output length");
  expect_string_eq(output.c_str(), "", "shutdown race should clear output text");

  backend.release_shutdown();
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after backend release");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown should succeed");
}

void test_initialized_backend_replacement_is_rejected_and_preserves_previous_backend() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend original;
  original.version = "backend-a";
  auto original_api = original.api();
  expect_eq(cmfa_internal_register_backend(&original_api, &error.error), CMFA_OK,
            "initial backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  char version[32] = {};
  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_OK,
            "original backend should answer version");
  expect_string_eq(version, "backend-a", "original backend version should be visible");

  FakeBackend replacement;
  replacement.version = "backend-b";
  replacement.fail_attach = true;
  auto replacement_api = replacement.api();
  expect_eq(cmfa_internal_register_backend(&replacement_api, &error.error), CMFA_INVALID_STATE,
            "replacement while initialized should be rejected");
  expect(!replacement.attach_called, "rejected live replacement must not attach a new backend");

  std::memset(version, 0, sizeof(version));
  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_OK,
            "original backend should remain active after replacement rejection");
  expect_string_eq(version, "backend-a", "replacement rejection must preserve original backend");

  reset_contract();
}

void test_initialized_backend_mutation_is_rejected() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend original;
  auto original_api = original.api();
  expect_eq(cmfa_internal_register_backend(&original_api, &error.error), CMFA_OK,
            "initial backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  FakeBackend replacement;
  auto replacement_api = replacement.api();
  expect_eq(cmfa_internal_register_backend(&replacement_api, &error.error), CMFA_INVALID_STATE,
            "replacement while initialized should be rejected");
  expect(!replacement.attach_called, "replacement must not attach while initialized");
  expect_eq(cmfa_internal_register_backend(nullptr, &error.error), CMFA_INVALID_STATE,
            "unregister while initialized should be rejected");

  reset_contract();
}

void test_initialize_attach_blocks_shutdown_until_attach_finishes() {
  reset_contract();

  ErrorBox error;
  FakeBackend backend;
  backend.block_attach = true;
  backend.allow_attach_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  auto initialize_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_initialize(&callbacks, &thread_error.error);
  });

  backend.wait_for_attach_entry();

  std::atomic<bool> shutdown_returned{false};
  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    const cmfa_status status = cmfa_shutdown(&thread_error.error);
    shutdown_returned.store(true);
    return status;
  });

  expect_eq(shutdown_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "shutdown must not return while initialize attach is blocked");
  {
    std::lock_guard<std::mutex> lock(backend.mutex);
    expect(!backend.shutdown_called, "shutdown must not call backend.shutdown before attach completes");
  }

  backend.release_attach();
  expect_eq(initialize_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "initialize should complete after attach release");
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after attach release");
  expect_eq(initialize_future.get(), CMFA_OK, "initialize should succeed");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown should succeed");

  reset_contract();
}

void test_validate_config_rechecks_shutdown_before_backend_borrow() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_shutdown = true;
  backend.allow_shutdown_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  ContractHookBarrier barrier{};
  barrier.target_point = CMFA_TEST_HOOK_BEFORE_BACKEND_BORROW;
  barrier.block = true;
#if defined(CMFA_CONTRACT_TESTING)
  ScopedContractHook hook(&ContractHookBarrier::callback, &barrier);
#endif

  auto validate_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_validate_config("config.yaml", &thread_error.error);
  });
  barrier.wait_for_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });
  backend.wait_for_shutdown_called();

  barrier.unblock();
  expect_eq(validate_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "validate_config should complete once borrow barrier is released");
  const cmfa_status validate_status = validate_future.get();
  expect(validate_status == CMFA_BUSY || validate_status == CMFA_NOT_INITIALIZED || validate_status == CMFA_INVALID_STATE,
         "validate_config must not borrow backend once shutdown has started");

  backend.release_shutdown();
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after backend release");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown should succeed");
}

void test_runtime_state_does_not_commit_after_shutdown_begins() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.block_shutdown = true;
  backend.allow_shutdown_exit = false;
  backend.set_runtime_snapshot(CMFA_RUNTIME_RUNNING, "beta.yaml", 7891);
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  ContractHookBarrier barrier{};
  barrier.target_point = CMFA_TEST_HOOK_AFTER_RUNTIME_STATE_BACKEND;
  barrier.block = true;
#if defined(CMFA_CONTRACT_TESTING)
  ScopedContractHook hook(&ContractHookBarrier::callback, &barrier);
#endif

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  snapshot.state = CMFA_RUNTIME_ERROR;
  std::memcpy(snapshot.active_config_path, "sentinel", 9);
  snapshot.mixed_port = 9999;

  auto runtime_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_runtime_state(&snapshot, &thread_error.error);
  });
  barrier.wait_for_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });
  backend.wait_for_shutdown_called();

  barrier.unblock();
  expect_eq(runtime_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "runtime_state should complete once commit barrier is released");
  const cmfa_status runtime_status = runtime_future.get();
  expect(runtime_status == CMFA_BUSY || runtime_status == CMFA_NOT_INITIALIZED || runtime_status == CMFA_INVALID_STATE,
         "runtime_state must not return success after shutdown begins");
  expect_eq(snapshot.state, CMFA_RUNTIME_ERROR, "caller-owned snapshot should remain unchanged on shutdown race");
  expect_string_eq(snapshot_path(snapshot), "sentinel", "caller-owned snapshot path should remain unchanged on shutdown race");
  expect_eq(snapshot.mixed_port, static_cast<uint32_t>(9999), "caller-owned snapshot port should remain unchanged on shutdown race");

  backend.release_shutdown();
  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should complete after backend release");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown should succeed");
}

void test_attach_failure_allows_shutdown_without_backend_teardown() {
  reset_contract();

  ErrorBox error;
  FakeBackend backend;
  backend.fail_attach = true;
  backend.block_attach = true;
  backend.allow_attach_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  auto initialize_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_initialize(&callbacks, &thread_error.error);
  });

  backend.wait_for_attach_entry();

  auto shutdown_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_shutdown(&thread_error.error);
  });
  expect_eq(shutdown_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "shutdown should wait while attach failure is still blocked");

  backend.release_attach();
  expect_eq(initialize_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "initialize should complete after attach failure releases");
  expect_eq(initialize_future.get(), CMFA_BACKEND_ERROR, "initialize should surface attach failure");

  expect_eq(shutdown_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "shutdown should return after attach failure rollback");
  expect_eq(shutdown_future.get(), CMFA_OK, "shutdown after failed initialize should be idempotent OK");
  expect_eq(backend.shutdown_calls, static_cast<uint32_t>(0),
            "shutdown must not call backend.shutdown after attach failure rollback");

  reset_contract();
}

void test_attach_failure_makes_stop_not_initialized_without_backend_stop() {
  reset_contract();

  ErrorBox error;
  FakeBackend backend;
  backend.fail_attach = true;
  backend.block_attach = true;
  backend.allow_attach_exit = false;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  auto initialize_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_initialize(&callbacks, &thread_error.error);
  });

  backend.wait_for_attach_entry();

  auto stop_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_stop(&thread_error.error);
  });
  expect_eq(stop_future.wait_for(std::chrono::milliseconds(50)), std::future_status::timeout,
            "stop should wait while attach failure is still blocked");

  backend.release_attach();
  expect_eq(initialize_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "initialize should complete after attach failure releases");
  expect_eq(initialize_future.get(), CMFA_BACKEND_ERROR, "initialize should surface attach failure");

  expect_eq(stop_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "stop should return after attach failure rollback");
  expect_eq(stop_future.get(), CMFA_NOT_INITIALIZED,
            "stop after failed initialize should report not initialized");
  expect_eq(backend.stop_calls, static_cast<uint32_t>(0),
            "stop must not call backend.stop after attach failure rollback");

  reset_contract();
}

void test_backend_error_fallback_handles_alias_without_nul() {
#if defined(__unix__) || defined(__APPLE__)
  reset_contract();
  expect_child_success_without_signal([]() {
    reset_contract();
    HostCapture capture;
    auto callbacks = make_host_callbacks(&capture);
    ErrorBox error;
    FakeBackend backend;
    backend.emit_backend_error_without_nul = true;
    auto api = backend.api();
    if (cmfa_internal_register_backend(&api, &error.error) != CMFA_OK) {
      return 20;
    }
    if (cmfa_initialize(&callbacks, &error.error) != CMFA_OK) {
      return 21;
    }

    GuardPageRegion region;
    cmfa_error alias_error{};
    alias_error.code = CMFA_OK;
    alias_error.message = region.path;
    alias_error.capacity = CMFA_MAX_PATH_BYTES;
    alias_error.length = 0;
    const cmfa_status status = cmfa_validate_config("config.yaml", &alias_error);
    if (status != CMFA_BACKEND_ERROR) {
      return 22;
    }
    size_t message_length = 0;
    if (!bounded_string_length_for_test(alias_error.message, alias_error.capacity, &message_length)) {
      return 23;
    }
    return 0;
  }, "backend error alias should not overread or crash");
#endif
}

void test_backend_version_output_must_be_nul_terminated() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  backend.omit_terminating_nul_in_version = true;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  char version[8];
  std::memset(version, 'z', sizeof(version));
  expect_eq(cmfa_core_version(version, sizeof(version), &error.error), CMFA_BACKEND_ERROR,
            "contract should reject non-NUL-terminated backend version output");
  expect_eq(version[sizeof(version) - 1], '\0', "version buffer must be NUL terminated on failure");

  reset_contract();
}

void test_reentrant_stop_during_backend_start_is_typed_not_deadlocked() {
  reset_contract();

  HostCapture capture;
  capture.reentrant_action = HostCapture::ReentrantAction::Stop;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);

  auto start_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_start_local(&options, &snapshot, &thread_error.error);
  });

  expect_eq(start_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "reentrant stop must not deadlock start_local");
  const cmfa_status start_status = start_future.get();
  expect(start_status == CMFA_OK || start_status == CMFA_INVALID_STATE,
         "start_local should resolve to a defined status under reentrant stop");

  std::unique_lock<std::mutex> lock(capture.mutex);
  const bool reentrant_done = capture.callback_cv.wait_for(lock, std::chrono::seconds(2), [&] {
    return capture.reentrant_completed;
  });
  expect(reentrant_done, "reentrant stop should complete");
  expect(capture.reentrant_status == CMFA_INVALID_STATE || capture.reentrant_status == CMFA_BUSY,
         "reentrant stop should be typed rejected instead of deadlocking");

  reset_contract();
}

void test_reentrant_shutdown_during_backend_start_is_typed_not_deadlocked() {
  reset_contract();

  HostCapture capture;
  capture.reentrant_action = HostCapture::ReentrantAction::Shutdown;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "config.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);

  auto start_future = std::async(std::launch::async, [&] {
    ErrorBox thread_error;
    return cmfa_start_local(&options, &snapshot, &thread_error.error);
  });

  expect_eq(start_future.wait_for(std::chrono::seconds(2)), std::future_status::ready,
            "reentrant shutdown must not deadlock start_local");
  const cmfa_status start_status = start_future.get();
  expect(start_status == CMFA_OK || start_status == CMFA_INVALID_STATE,
         "start_local should resolve to a defined status under reentrant shutdown");

  std::unique_lock<std::mutex> lock(capture.mutex);
  const bool reentrant_done = capture.callback_cv.wait_for(lock, std::chrono::seconds(2), [&] {
    return capture.reentrant_completed;
  });
  expect(reentrant_done, "reentrant shutdown should complete");
  expect(capture.reentrant_status == CMFA_INVALID_STATE || capture.reentrant_status == CMFA_BUSY,
         "reentrant shutdown should be typed rejected instead of deadlocking");

  reset_contract();
}

void test_snapshot_path_is_caller_owned_and_stable() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "alpha.yaml";
  options.mixed_port = 7890;

  cmfa_runtime_snapshot first_snapshot{};
  first_snapshot.struct_size = sizeof(first_snapshot);
  expect_eq(cmfa_start_local(&options, &first_snapshot, &error.error), CMFA_OK, "start should succeed");
  expect_string_eq(snapshot_path(first_snapshot), "alpha.yaml", "first snapshot should preserve started path");

  backend.set_runtime_snapshot(CMFA_RUNTIME_RUNNING, "beta.yaml", 7891);
  cmfa_runtime_snapshot second_snapshot{};
  second_snapshot.struct_size = sizeof(second_snapshot);
  expect_eq(cmfa_runtime_state(&second_snapshot, &error.error), CMFA_OK, "runtime_state should succeed");
  expect_string_eq(snapshot_path(second_snapshot), "beta.yaml", "second snapshot should receive backend runtime path");
  expect_string_eq(snapshot_path(first_snapshot), "alpha.yaml",
                   "first snapshot must not be rewritten by later runtime_state");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed");
  expect_string_eq(snapshot_path(first_snapshot), "alpha.yaml",
                   "first snapshot must survive stop without mutation");
  expect_string_eq(snapshot_path(second_snapshot), "beta.yaml",
                   "second snapshot must survive stop without mutation");

  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should succeed");
  expect_string_eq(snapshot_path(first_snapshot), "alpha.yaml",
                   "first snapshot must survive shutdown without mutation");
  expect_string_eq(snapshot_path(second_snapshot), "beta.yaml",
                   "second snapshot must survive shutdown without mutation");

  reset_contract();
}

void test_stop_preserves_backend_error_snapshot_and_diagnostic() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "alpha.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot start_snapshot{};
  start_snapshot.struct_size = sizeof(start_snapshot);
  expect_eq(cmfa_start_local(&options, &start_snapshot, &error.error), CMFA_OK, "start should succeed");

  backend.preserve_error_on_stop = true;
  backend.set_runtime_snapshot(CMFA_RUNTIME_ERROR, "alpha.yaml", 7890);
  backend.set_runtime_last_error("bind socks listener 127.0.0.1:43003 denied");

  expect_eq(cmfa_stop(&error.error), CMFA_OK, "stop should succeed while preserving backend error");

  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "runtime_state should succeed");
  expect_eq(snapshot.state, CMFA_RUNTIME_ERROR, "runtime_state should preserve error after stop");
  expect_string_eq(snapshot_path(snapshot), "alpha.yaml", "runtime_state should preserve error path");
  expect_string_eq(std::string(snapshot.last_error), "bind socks listener 127.0.0.1:43003 denied",
                   "runtime_state should preserve stop diagnostic");

  reset_contract();
}

void test_stop_post_runtime_state_failure_clears_transition() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "alpha.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_OK, "start should succeed");

  backend.fail_runtime_state_after_stop = true;
  expect_eq(cmfa_stop(&error.error), CMFA_BACKEND_ERROR, "stop should surface post-stop runtime_state failure");

  backend.fail_runtime_state_after_stop = false;
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "runtime_state should not remain blocked after stop failure");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should not remain blocked after stop failure");

  reset_contract();
}

void test_stop_post_runtime_state_validation_failure_clears_transition() {
  reset_contract();

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  ErrorBox error;
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  cmfa_local_options options{};
  options.struct_size = sizeof(options);
  options.config_path = "alpha.yaml";
  options.mixed_port = 7890;
  cmfa_runtime_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  expect_eq(cmfa_start_local(&options, &snapshot, &error.error), CMFA_OK, "start should succeed");

  backend.invalid_runtime_state_after_stop = true;
  expect_eq(cmfa_stop(&error.error), CMFA_BACKEND_ERROR, "stop should surface invalid post-stop snapshot");

  backend.invalid_runtime_state_after_stop = false;
  expect_eq(cmfa_runtime_state(&snapshot, &error.error), CMFA_OK, "runtime_state should not remain blocked after invalid stop snapshot");
  expect_eq(cmfa_shutdown(&error.error), CMFA_OK, "shutdown should not remain blocked after invalid stop snapshot");

  reset_contract();
}

void test_runtime_mode_contract_is_closed_and_backend_authoritative() {
  reset_contract();

  ErrorBox error;
  cmfa_runtime_mode mode = CMFA_MODE_DIRECT;
  expect_eq(cmfa_runtime_mode_query(&mode, &error.error), CMFA_NOT_INITIALIZED,
            "runtime mode query should require initialization");
  expect_eq(mode, CMFA_MODE_RULE, "failed mode query should reset output");
  expect_eq(cmfa_runtime_mode_set(static_cast<cmfa_runtime_mode>(99), &error.error), CMFA_INVALID_ARGUMENT,
            "runtime mode set should reject unknown enum values before initialization");

  HostCapture capture;
  auto callbacks = make_host_callbacks(&capture);
  FakeBackend backend;
  auto api = backend.api();
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "backend registration should succeed");
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");

  expect_eq(cmfa_runtime_mode_query(&mode, &error.error), CMFA_OK, "runtime mode query should succeed");
  expect_eq(mode, CMFA_MODE_RULE, "fake backend should start in rule mode");
  expect_eq(cmfa_runtime_mode_set(CMFA_MODE_GLOBAL, &error.error), CMFA_OK,
            "runtime mode set should forward a valid mode");
  expect_eq(cmfa_runtime_mode_query(&mode, &error.error), CMFA_OK, "updated mode query should succeed");
  expect_eq(mode, CMFA_MODE_GLOBAL, "updated mode should come from backend");
  expect_eq(cmfa_runtime_mode_set(static_cast<cmfa_runtime_mode>(99), &error.error), CMFA_INVALID_ARGUMENT,
            "runtime mode set should reject values outside the closed enum");
  expect_eq(cmfa_runtime_mode_query(&mode, &error.error), CMFA_OK, "mode should remain queryable after rejection");
  expect_eq(mode, CMFA_MODE_GLOBAL, "invalid mode must not mutate backend state");

  reset_contract();
}

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"calls_require_initialization_and_shutdown_is_idempotent",
       test_calls_require_initialization_and_shutdown_is_idempotent},
      {"initialize_duplicate_and_backendless_contract_behaviors",
       test_initialize_duplicate_and_backendless_contract_behaviors},
      {"null_pointer_and_invalid_argument_validation", test_null_pointer_and_invalid_argument_validation},
      {"probe_https_backendless_and_invalid_request_return_owned_result",
       test_probe_https_backendless_and_invalid_request_return_owned_result},
      {"invalid_utf8_and_error_truncation", test_invalid_utf8_and_error_truncation},
      {"non_terminated_paths_fail_without_overread", test_non_terminated_paths_fail_without_overread},
      {"host_callback_copy_and_event_unsubscribe", test_host_callback_copy_and_event_unsubscribe},
      {"stop_waits_for_in_flight_event_callback", test_stop_waits_for_in_flight_event_callback},
      {"shutdown_waits_for_in_flight_log_callback", test_shutdown_waits_for_in_flight_log_callback},
      {"concurrent_start_rejection", test_concurrent_start_rejection},
      {"backend_driven_version_and_runtime_queries", test_backend_driven_version_and_runtime_queries},
      {"runtime_mode_contract_is_closed_and_backend_authoritative",
       test_runtime_mode_contract_is_closed_and_backend_authoritative},
      {"shutdown_serializes_with_in_flight_start", test_shutdown_serializes_with_in_flight_start},
      {"backend_registration_rejects_incomplete_lifecycle", test_backend_registration_rejects_incomplete_lifecycle},
      {"proxy_calls_require_initialization_and_backend", test_proxy_calls_require_initialization_and_backend},
      {"proxy_delay_calls_require_initialization_and_backend",
       test_proxy_delay_calls_require_initialization_and_backend},
      {"proxy_argument_validation_and_buffer_sanitization", test_proxy_argument_validation_and_buffer_sanitization},
      {"proxy_delay_argument_validation_and_buffer_sanitization",
       test_proxy_delay_argument_validation_and_buffer_sanitization},
      {"proxy_rejects_output_error_aliasing_before_backend_invocation",
       test_proxy_rejects_output_error_aliasing_before_backend_invocation},
      {"proxy_successful_copy_preserves_length_and_forwarding",
       test_proxy_successful_copy_preserves_length_and_forwarding},
      {"proxy_delay_successful_copy_preserves_length_and_forwarding",
       test_proxy_delay_successful_copy_preserves_length_and_forwarding},
      {"proxy_buffer_too_small_and_backend_failures_scrub_public_buffer",
       test_proxy_buffer_too_small_and_backend_failures_scrub_public_buffer},
      {"proxy_delay_buffer_too_small_and_backend_failures_scrub_public_buffer",
       test_proxy_delay_buffer_too_small_and_backend_failures_scrub_public_buffer},
      {"proxy_backend_output_validation_rejects_malformed_json_and_overrun",
       test_proxy_backend_output_validation_rejects_malformed_json_and_overrun},
      {"proxy_delay_backend_output_validation_rejects_malformed_json_and_overrun",
       test_proxy_delay_backend_output_validation_rejects_malformed_json_and_overrun},
      {"initialized_backend_replacement_is_rejected_and_preserves_previous_backend",
       test_initialized_backend_replacement_is_rejected_and_preserves_previous_backend},
      {"initialized_backend_mutation_is_rejected", test_initialized_backend_mutation_is_rejected},
      {"initialize_attach_blocks_shutdown_until_attach_finishes",
       test_initialize_attach_blocks_shutdown_until_attach_finishes},
      {"attach_failure_allows_shutdown_without_backend_teardown",
       test_attach_failure_allows_shutdown_without_backend_teardown},
      {"attach_failure_makes_stop_not_initialized_without_backend_stop",
       test_attach_failure_makes_stop_not_initialized_without_backend_stop},
      {"proxy_rechecks_shutdown_before_backend_borrow", test_proxy_rechecks_shutdown_before_backend_borrow},
      {"proxy_delay_rechecks_shutdown_before_backend_borrow",
       test_proxy_delay_rechecks_shutdown_before_backend_borrow},
      {"validate_config_rechecks_shutdown_before_backend_borrow",
       test_validate_config_rechecks_shutdown_before_backend_borrow},
      {"runtime_state_does_not_commit_after_shutdown_begins",
       test_runtime_state_does_not_commit_after_shutdown_begins},
      {"backend_error_fallback_handles_alias_without_nul", test_backend_error_fallback_handles_alias_without_nul},
      {"backend_version_output_must_be_nul_terminated", test_backend_version_output_must_be_nul_terminated},
      {"reentrant_stop_during_backend_start_is_typed_not_deadlocked",
       test_reentrant_stop_during_backend_start_is_typed_not_deadlocked},
      {"reentrant_shutdown_during_backend_start_is_typed_not_deadlocked",
       test_reentrant_shutdown_during_backend_start_is_typed_not_deadlocked},
      {"snapshot_path_is_caller_owned_and_stable", test_snapshot_path_is_caller_owned_and_stable},
      {"stop_preserves_backend_error_snapshot_and_diagnostic",
       test_stop_preserves_backend_error_snapshot_and_diagnostic},
      {"stop_post_runtime_state_failure_clears_transition",
       test_stop_post_runtime_state_failure_clears_transition},
      {"stop_post_runtime_state_validation_failure_clears_transition",
       test_stop_post_runtime_state_validation_failure_clears_transition},
  };

  size_t failed = 0;
  for (const auto &entry : tests) {
    try {
      entry.second();
      std::cout << "[PASS] " << entry.first << '\n';
    } catch (const std::exception &error) {
      failed += 1;
      std::cerr << "[FAIL] " << entry.first << ": " << error.what() << '\n';
    }
  }

  if (failed != 0) {
    std::cerr << failed << " test(s) failed\n";
    return 1;
  }

  std::cout << tests.size() << " test(s) passed\n";
  return 0;
}
