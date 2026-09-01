#define CMFA_INTERNAL_BACKEND_API 1

#include "cmfa_host.h"
#include "cmfa_core.h"
#include "cmfa_types.h"

#include <array>
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
#include <thread>
#include <utility>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <cerrno>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

#if defined(CMFA_CONTRACT_TESTING)
using cmfa_internal_dup_fd_fn = int (*)(void *context, int fd);
using cmfa_internal_close_fd_fn = int (*)(void *context, int fd);
extern "C" void cmfa_internal_set_fd_ops(cmfa_internal_dup_fd_fn dup_fn,
                                         cmfa_internal_close_fd_fn close_fn,
                                         void *context);
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

struct ErrorBox {
  std::array<char, 256> storage{};
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

struct ProtectCapture {
  std::mutex mutex;
  std::condition_variable cv;
  std::vector<int> fds;
  std::vector<uint32_t> timeouts;
  bool block = false;
  bool release = false;
  bool timeout_while_blocked = false;
  bool reentrant_stop = false;
  cmfa_status response = CMFA_OK;
  cmfa_status reentrant_status = CMFA_OK;
};

cmfa_status protect_socket(void *context, int fd, uint32_t timeout_ms) {
  auto *capture = static_cast<ProtectCapture *>(context);
  std::unique_lock<std::mutex> lock(capture->mutex);
  capture->fds.push_back(fd);
  capture->timeouts.push_back(timeout_ms);
  const bool should_stop = capture->reentrant_stop;
  if (capture->block) {
    if (capture->timeout_while_blocked) {
      const bool released = capture->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
        return capture->release;
      });
      if (!released) {
        return CMFA_SOCKET_PROTECT_FAILED;
      }
    } else {
      capture->cv.wait(lock, [&] { return capture->release; });
    }
  }
  lock.unlock();
  if (should_stop) {
    ErrorBox error;
    capture->reentrant_status = cmfa_tun_stop(&error.error);
  }
  return capture->response;
}

cmfa_host_callbacks make_host_callbacks(ProtectCapture *capture) {
  cmfa_host_callbacks callbacks{};
  callbacks.struct_size = sizeof(callbacks);
  callbacks.context = capture;
  callbacks.log_sink = nullptr;
  callbacks.event_sink = nullptr;
  callbacks.protect_socket = protect_socket;
  return callbacks;
}

cmfa_backend_host make_backend_host() {
  cmfa_backend_host host{};
  host.struct_size = sizeof(host);
  return host;
}

struct FakeFdOps {
  int dup_result = -1;
  int dup_errno = 9;
  int close_result = 0;
  int dup_calls = 0;
  int close_calls = 0;
  std::vector<int> dup_fds;
  std::vector<int> close_fds;
};

int fake_dup(void *context, int fd) {
  auto *ops = static_cast<FakeFdOps *>(context);
  ops->dup_calls += 1;
  ops->dup_fds.push_back(fd);
#if defined(__unix__) || defined(__APPLE__)
  errno = ops->dup_errno;
#endif
  return ops->dup_result;
}

int fake_close(void *context, int fd) {
  auto *ops = static_cast<FakeFdOps *>(context);
  ops->close_calls += 1;
  ops->close_fds.push_back(fd);
  return ops->close_result;
}

struct FakeTunBackend {
  std::mutex mutex;
  cmfa_backend_host host = make_backend_host();
  bool attached = false;
  bool start_called = false;
  bool stop_called = false;
  bool shutdown_called = false;
  bool runtime_state_called = false;
  bool traces_called = false;
  bool fail_start = false;
  bool protect_on_start = false;
  cmfa_status start_status = CMFA_OK;
  cmfa_status protect_status = CMFA_OK;
  int received_fd = -1;
  const char *received_config_path = reinterpret_cast<const char *>(0x1);
  uint32_t received_mixed_port = 0xffffffffU;
  uint32_t received_platform_api_level = 0xffffffffU;
  uint8_t received_process_protected = 0xffU;
  int protect_fd = -1;
  uint32_t protect_timeout_ms = 0;
  cmfa_tun_snapshot snapshot{};
  cmfa_tun_trace_collection traces{};
  std::vector<cmfa_tun_trace> trace_ring;

  FakeTunBackend() {
    snapshot.struct_size = sizeof(snapshot);
    snapshot.state = CMFA_TUN_IDLE;
    snapshot.counters.struct_size = sizeof(snapshot.counters);
    snapshot.failure.struct_size = sizeof(snapshot.failure);
    traces.struct_size = sizeof(traces);
    traces.trace_count = 0;
  }
};

#if defined(__unix__) || defined(__APPLE__)
struct PipePair {
  int read_fd = -1;
  int write_fd = -1;

  PipePair() {
    int fds[2] = {-1, -1};
    expect_eq(::pipe(fds), 0, "pipe should succeed");
    read_fd = fds[0];
    write_fd = fds[1];
  }

  ~PipePair() {
    if (read_fd >= 0) {
      (void)::close(read_fd);
    }
    if (write_fd >= 0) {
      (void)::close(write_fd);
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

struct GuardPageRegion {
  char *base = nullptr;
  size_t page_size = 0;
  char *prefix = nullptr;

  explicit GuardPageRegion(size_t prefix_size) {
    page_size = static_cast<size_t>(::sysconf(_SC_PAGESIZE));
    void *mapping = ::mmap(nullptr, page_size * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    expect(mapping != MAP_FAILED, "mmap should succeed");
    base = static_cast<char *>(mapping);
    const int protect_status = ::mprotect(base + page_size, page_size, PROT_NONE);
    expect_eq(protect_status, 0, "mprotect should succeed");
    prefix = base + (page_size - prefix_size);
  }

  ~GuardPageRegion() {
    if (base != nullptr) {
      (void)::munmap(base, page_size * 2);
    }
  }
};

#endif

void fill_snapshot(FakeTunBackend &backend, const char *session_id, cmfa_tun_state_value state) {
  backend.snapshot.struct_size = sizeof(backend.snapshot);
  backend.snapshot.state = state;
  std::memset(backend.snapshot.session_id, 0, sizeof(backend.snapshot.session_id));
  std::strncpy(backend.snapshot.session_id, session_id, sizeof(backend.snapshot.session_id) - 1);
  backend.snapshot.counters.struct_size = sizeof(backend.snapshot.counters);
  backend.snapshot.failure.struct_size = sizeof(backend.snapshot.failure);
}

void fill_traces(FakeTunBackend &backend, const char *session_id) {
  backend.traces.struct_size = sizeof(backend.traces);
  backend.traces.trace_count = 1;
  backend.traces.traces[0].struct_size = sizeof(backend.traces.traces[0]);
  std::strncpy(backend.traces.traces[0].session_id, session_id, sizeof(backend.traces.traces[0].session_id) - 1);
  std::strncpy(backend.traces.traces[0].trace_id, "trace-1", sizeof(backend.traces.traces[0].trace_id) - 1);
  std::strncpy(backend.traces.traces[0].ingress, "tun", sizeof(backend.traces.traces[0].ingress) - 1);
  std::strncpy(backend.traces.traces[0].protocol, "tcp", sizeof(backend.traces.traces[0].protocol) - 1);
  std::strncpy(backend.traces.traces[0].source_address, "10.111.222.1", sizeof(backend.traces.traces[0].source_address) - 1);
  std::strncpy(backend.traces.traces[0].destination_address,
               "1.1.1.1:443",
               sizeof(backend.traces.traces[0].destination_address) - 1);
  std::strncpy(backend.traces.traces[0].hashed_tuple,
               "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               sizeof(backend.traces.traces[0].hashed_tuple) - 1);
}

void fill_trace_hashes(FakeTunBackend &backend, const char *hashed_tuple, const char *correlation_hash) {
  std::memset(backend.traces.traces[0].hashed_tuple, 0, sizeof(backend.traces.traces[0].hashed_tuple));
  std::memset(backend.traces.traces[0].correlation_hash, 0, sizeof(backend.traces.traces[0].correlation_hash));
  if (hashed_tuple != nullptr) {
    std::strncpy(backend.traces.traces[0].hashed_tuple,
                 hashed_tuple,
                 sizeof(backend.traces.traces[0].hashed_tuple) - 1);
  }
  if (correlation_hash != nullptr) {
    std::strncpy(backend.traces.traces[0].correlation_hash,
                 correlation_hash,
                 sizeof(backend.traces.traces[0].correlation_hash) - 1);
  }
}

void fill_trace_outbound_proof(FakeTunBackend &backend,
                               const char *destination_hash,
                               const char *outbound_terminal_hash,
                               const char *outbound_chain_hash,
                               uint32_t outbound_chain_length) {
  std::memset(backend.traces.traces[0].destination_hash, 0, sizeof(backend.traces.traces[0].destination_hash));
  std::memset(backend.traces.traces[0].outbound_terminal_hash, 0, sizeof(backend.traces.traces[0].outbound_terminal_hash));
  std::memset(backend.traces.traces[0].outbound_chain_hash, 0, sizeof(backend.traces.traces[0].outbound_chain_hash));
  if (destination_hash != nullptr) {
    std::strncpy(backend.traces.traces[0].destination_hash,
                 destination_hash,
                 sizeof(backend.traces.traces[0].destination_hash) - 1);
  }
  if (outbound_terminal_hash != nullptr) {
    std::strncpy(backend.traces.traces[0].outbound_terminal_hash,
                 outbound_terminal_hash,
                 sizeof(backend.traces.traces[0].outbound_terminal_hash) - 1);
  }
  if (outbound_chain_hash != nullptr) {
    std::strncpy(backend.traces.traces[0].outbound_chain_hash,
                 outbound_chain_hash,
                 sizeof(backend.traces.traces[0].outbound_chain_hash) - 1);
  }
  backend.traces.traces[0].outbound_chain_length = outbound_chain_length;
}

cmfa_status backend_attach_host(void *context, const cmfa_backend_host *host, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->host = *host;
  backend->attached = true;
  return CMFA_OK;
}

cmfa_status backend_core_version(void *, char *out, size_t capacity, cmfa_error *) {
  std::strncpy(out, "fake-core", capacity - 1);
  out[capacity - 1] = '\0';
  return CMFA_OK;
}

cmfa_status backend_validate_config(void *, const char *, cmfa_error *) { return CMFA_OK; }
cmfa_status backend_load_config(void *, const char *, cmfa_error *) { return CMFA_OK; }

cmfa_status backend_start_local(void *, const cmfa_local_options *, cmfa_runtime_snapshot *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

cmfa_status backend_stop_local(void *, cmfa_error *) { return CMFA_OK; }
cmfa_status backend_runtime_state(void *, cmfa_runtime_snapshot *, cmfa_error *) { return CMFA_OK; }
cmfa_status backend_runtime_mode_query(void *, cmfa_runtime_mode *mode, cmfa_error *) {
  *mode = CMFA_MODE_RULE;
  return CMFA_OK;
}
cmfa_status backend_runtime_mode_set(void *, cmfa_runtime_mode, cmfa_error *) { return CMFA_OK; }

cmfa_status backend_probe_https(void *, const cmfa_probe_request *, cmfa_probe_result *, cmfa_error *) {
  return CMFA_CORE_UNAVAILABLE;
}

void clear_json_error(cmfa_error *error) {
  if (error == nullptr) {
    return;
  }
  error->code = CMFA_OK;
  error->length = 0;
  if (error->message != nullptr && error->capacity > 0) {
    error->message[0] = '\0';
  }
}

cmfa_status write_synthetic_json(cmfa_json_buffer *output, cmfa_error *error) {
  static constexpr char kSyntheticJson[] = "{}";
  static constexpr size_t kSyntheticJsonLength = sizeof(kSyntheticJson) - 1;
  if (output == nullptr || output->data == nullptr || output->capacity == 0) {
    if (error != nullptr) {
      error->code = CMFA_INVALID_ARGUMENT;
      error->length = 0;
      if (error->message != nullptr && error->capacity > 0) {
        error->message[0] = '\0';
      }
    }
    return CMFA_INVALID_ARGUMENT;
  }
  output->length = 0;
  output->data[0] = '\0';
  if (output->capacity <= kSyntheticJsonLength) {
    output->length = kSyntheticJsonLength;
    clear_json_error(error);
    return CMFA_BUFFER_TOO_SMALL;
  }
  std::memcpy(output->data, kSyntheticJson, sizeof(kSyntheticJson));
  output->length = kSyntheticJsonLength;
  clear_json_error(error);
  return CMFA_OK;
}

cmfa_status backend_proxy_groups(void *,
                                 const cmfa_proxy_query_context *,
                                 uint8_t,
                                 cmfa_json_buffer *output,
                                 cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_proxy_group(void *,
                                const cmfa_proxy_query_context *,
                                const char *,
                                cmfa_json_buffer *output,
                                cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_proxy_select(void *,
                                 const cmfa_proxy_query_context *,
                                 const char *,
                                 const char *,
                                 cmfa_json_buffer *output,
                                 cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_proxy_delay_start(void *,
                                      const cmfa_proxy_query_context *,
                                      const char *,
                                      cmfa_json_buffer *output,
                                      cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_proxy_delay_snapshot(void *, const char *, cmfa_json_buffer *output, cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_proxy_delay_cancel(void *, const char *, cmfa_json_buffer *output, cmfa_error *error) {
  return write_synthetic_json(output, error);
}

cmfa_status backend_start_tun(void *context,
                              const cmfa_tun_options *options,
                              cmfa_tun_snapshot *snapshot,
                              cmfa_error *error) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->start_called = true;
  backend->received_fd = options->tun_fd;
  backend->received_config_path = options->config_path;
  backend->received_mixed_port = options->mixed_port;
  backend->received_platform_api_level = options->platform_api_level;
  backend->received_process_protected = options->process_protected;
  if (backend->protect_on_start) {
    backend->protect_status =
        backend->host.host_protect_socket(backend->host.context, backend->protect_fd, 3000U, error);
    if (backend->protect_status != CMFA_OK) {
      return backend->protect_status;
    }
  }
  if (backend->fail_start) {
    return backend->start_status;
  }
  *snapshot = backend->snapshot;
  return CMFA_OK;
}

cmfa_status backend_stop_tun(void *context, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->stop_called = true;
  backend->snapshot.state = CMFA_TUN_STOPPED;
  return CMFA_OK;
}

cmfa_status backend_tun_runtime_state(void *context, cmfa_tun_snapshot *snapshot, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->runtime_state_called = true;
  *snapshot = backend->snapshot;
  return CMFA_OK;
}

cmfa_status backend_tun_copy_traces(void *context, cmfa_tun_trace_collection *traces, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->traces_called = true;
  *traces = backend->traces;
  return CMFA_OK;
}

cmfa_status backend_tun_copy_traces_ring(void *context, cmfa_tun_trace_ring *traces, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  std::memset(traces, 0, sizeof(*traces));
  traces->struct_size = sizeof(*traces);
  const size_t count = std::min<size_t>(backend->trace_ring.size(), CMFA_TUN_TRACE_RING_CAPACITY);
  traces->trace_count = static_cast<uint32_t>(count);
  for (size_t index = 0; index < count; index += 1) {
    traces->traces[index] = backend->trace_ring[index];
  }
  return CMFA_OK;
}

cmfa_status backend_shutdown(void *context, cmfa_error *) {
  auto *backend = static_cast<FakeTunBackend *>(context);
  std::lock_guard<std::mutex> lock(backend->mutex);
  backend->shutdown_called = true;
  return CMFA_OK;
}

cmfa_backend_api make_backend_api(FakeTunBackend *backend) {
  cmfa_backend_api api{};
  api.struct_size = sizeof(api);
  api.context = backend;
  api.attach_host = backend_attach_host;
  api.core_version = backend_core_version;
  api.validate_config = backend_validate_config;
  api.load_config = backend_load_config;
  api.start_local = backend_start_local;
  api.stop = backend_stop_local;
  api.runtime_state = backend_runtime_state;
  api.runtime_mode_query = backend_runtime_mode_query;
  api.runtime_mode_set = backend_runtime_mode_set;
  api.proxy_groups = backend_proxy_groups;
  api.proxy_group = backend_proxy_group;
  api.proxy_select = backend_proxy_select;
  api.proxy_delay_start = backend_proxy_delay_start;
  api.proxy_delay_snapshot = backend_proxy_delay_snapshot;
  api.proxy_delay_cancel = backend_proxy_delay_cancel;
  api.probe_https = backend_probe_https;
  api.start_tun = backend_start_tun;
  api.stop_tun = backend_stop_tun;
  api.tun_runtime_state = backend_tun_runtime_state;
  api.tun_copy_traces = backend_tun_copy_traces;
  api.tun_copy_traces_ring = backend_tun_copy_traces_ring;
  api.shutdown = backend_shutdown;
  return api;
}

void reset_contract() {
  ErrorBox error;
  (void)cmfa_shutdown(&error.error);
  (void)cmfa_internal_register_backend(nullptr, &error.error);
#if defined(CMFA_CONTRACT_TESTING)
  cmfa_internal_set_fd_ops(nullptr, nullptr, nullptr);
#endif
}

void initialize_backend(FakeTunBackend *backend, ProtectCapture *capture, uint32_t host_struct_size = sizeof(cmfa_host_callbacks)) {
  reset_contract();
  fill_snapshot(*backend, "session-1", CMFA_TUN_READY);
  fill_traces(*backend, "session-1");
  ErrorBox error;
  const cmfa_backend_api api = make_backend_api(backend);
  expect_eq(cmfa_internal_register_backend(&api, &error.error), CMFA_OK, "register backend should succeed");
  auto callbacks = make_host_callbacks(capture);
  callbacks.struct_size = host_struct_size;
  expect_eq(cmfa_initialize(&callbacks, &error.error), CMFA_OK, "initialize should succeed");
}

cmfa_tun_options make_options(int fd, const char *session_id = "session-1") {
  cmfa_tun_options options{};
  options.struct_size = sizeof(options);
  options.tun_fd = fd;
  std::strncpy(options.session_id, session_id, sizeof(options.session_id) - 1);
  options.config_path = "configs/phase4.yaml";
  options.mixed_port = 7890U;
  options.platform_api_level = 23U;
  options.process_protected = 1;
  return options;
}

void test_legacy_host_initializes_and_tun_structs_are_owned() {
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture, offsetof(cmfa_host_callbacks, protect_socket));

  cmfa_tun_snapshot snapshot{};
  snapshot.struct_size = 1;
  cmfa_tun_trace_collection traces{};
  traces.struct_size = 1;
  ErrorBox error;

#if defined(__unix__) || defined(__APPLE__)
  int pipe_fds[2] = {-1, -1};
  expect_eq(::pipe(pipe_fds), 0, "pipe should succeed");
  cmfa_tun_options options = make_options(pipe_fds[0]);
  expect_eq(cmfa_tun_start(&options, &snapshot, &error.error), CMFA_OK, "tun start should succeed");
  expect_eq(cmfa_tun_runtime_state(&snapshot, &error.error), CMFA_OK, "tun runtime_state should succeed");
  expect_eq(cmfa_tun_copy_traces(&traces, &error.error), CMFA_OK, "tun copy traces should succeed");
  expect_eq(snapshot.struct_size, static_cast<uint32_t>(sizeof(cmfa_tun_snapshot)), "snapshot struct_size should be owned");
  expect_eq(snapshot.counters.struct_size,
            static_cast<uint32_t>(sizeof(cmfa_tun_counters)),
            "nested counters struct_size should be owned");
  expect_eq(snapshot.failure.struct_size,
            static_cast<uint32_t>(sizeof(cmfa_tun_failure)),
            "nested failure struct_size should be owned");
  expect_eq(traces.struct_size,
            static_cast<uint32_t>(sizeof(cmfa_tun_trace_collection)),
            "trace collection struct_size should be owned");
  expect_eq(traces.traces[0].struct_size,
            static_cast<uint32_t>(sizeof(cmfa_tun_trace)),
            "trace struct_size should be owned");
  expect_eq(cmfa_tun_stop(&error.error), CMFA_OK, "tun stop should succeed");
  expect_eq(::close(pipe_fds[0]), 0, "read pipe close should succeed");
  expect_eq(::close(pipe_fds[1]), 0, "write pipe close should succeed");
#endif

  reset_contract();
}

void test_invalid_tun_option_shapes_fail_safely() {
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture);
  cmfa_tun_snapshot snapshot{};
  ErrorBox error;

  expect_eq(cmfa_tun_start(nullptr, &snapshot, &error.error), CMFA_INVALID_ARGUMENT, "null tun options should fail");

  cmfa_tun_options short_options{};
  short_options.struct_size = sizeof(short_options) - 1;
  expect_eq(cmfa_tun_start(&short_options, &snapshot, &error.error),
            CMFA_INVALID_ARGUMENT,
            "short tun options struct_size should fail");

  cmfa_tun_options oversized_options{};
  oversized_options.struct_size = sizeof(oversized_options) + 64;
  oversized_options.tun_fd = -1;
  expect_eq(cmfa_tun_start(&oversized_options, &snapshot, &error.error),
            CMFA_INVALID_ARGUMENT,
            "oversized tun options with invalid fd should fail safely");

  reset_contract();
}

void test_legacy_short_tun_options_do_not_overread_appended_fields() {
#if defined(__unix__) || defined(__APPLE__)
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture, offsetof(cmfa_host_callbacks, protect_socket));
  PipePair pipe_pair;

  const size_t legacy_size = offsetof(cmfa_tun_options, config_path);
  GuardPageRegion region(legacy_size);
  std::memset(region.prefix, 0, legacy_size);
  auto *options = reinterpret_cast<cmfa_tun_options *>(region.prefix);
  options->struct_size = static_cast<uint32_t>(legacy_size);
  options->tun_fd = pipe_pair.read_fd;
  std::strncpy(options->session_id, "session-1", sizeof(options->session_id) - 1);

  cmfa_tun_snapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  ErrorBox error;
  const cmfa_status status = cmfa_tun_start(options, &snapshot, &error.error);
  expect(status == CMFA_INVALID_ARGUMENT || status == CMFA_OK, "legacy short tun options should stay type-safe");
  expect(backend.received_config_path == nullptr, "legacy short tun options must zero appended config_path");
  expect_eq(backend.received_mixed_port, 0U, "legacy short tun options must zero appended mixed_port");
  expect_eq(backend.received_platform_api_level, 0U, "legacy short tun options must zero appended platform_api_level");
  expect_eq(backend.received_process_protected, static_cast<uint8_t>(0), "legacy short tun options must zero appended process_protected");
#endif
}

void test_fd_duplication_and_rollback_rules() {
#if defined(__unix__) || defined(__APPLE__)
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture);

  int pipe_fds[2] = {-1, -1};
  expect_eq(::pipe(pipe_fds), 0, "pipe should succeed");

  FakeFdOps fd_ops;
  fd_ops.dup_result = 91;
#if defined(CMFA_CONTRACT_TESTING)
  cmfa_internal_set_fd_ops(fake_dup, fake_close, &fd_ops);
#endif

  cmfa_tun_options options = make_options(pipe_fds[0]);
  cmfa_tun_snapshot snapshot{};
  ErrorBox error;
  expect_eq(cmfa_tun_start(&options, &snapshot, &error.error), CMFA_OK, "tun start should duplicate fd");
  expect_eq(fd_ops.dup_calls, 1, "dup should be called exactly once");
  expect_eq(fd_ops.close_calls, 0, "close should not run before stop");
  expect_eq(backend.received_fd, 91, "backend should receive duplicated fd");
  expect(::fcntl(pipe_fds[0], F_GETFD) != -1, "borrowed fd must stay open");

  expect_eq(cmfa_tun_stop(&error.error), CMFA_OK, "tun stop should close duplicate");
  expect_eq(fd_ops.close_calls, 1, "duplicate should close exactly once");
  expect_eq(fd_ops.close_fds.front(), 91, "close should target duplicated fd");
  expect_eq(cmfa_tun_stop(&error.error), CMFA_OK, "repeated tun stop should be idempotent");
  expect_eq(fd_ops.close_calls, 1, "repeated tun stop must not double-close");

  reset_contract();
  expect_eq(::close(pipe_fds[0]), 0, "read pipe close should succeed");
  expect_eq(::close(pipe_fds[1]), 0, "write pipe close should succeed");
#endif
}

void test_invalid_fd_and_dup_failure_never_reach_backend() {
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture);
  cmfa_tun_snapshot snapshot{};
  ErrorBox error;

  for (int invalid_fd : {-1, 0, 999999}) {
    cmfa_tun_options options = make_options(invalid_fd);
    expect_eq(cmfa_tun_start(&options, &snapshot, &error.error),
              CMFA_INVALID_ARGUMENT,
              "invalid tun fd should fail");
  }

  FakeFdOps fd_ops;
  fd_ops.dup_result = -1;
  fd_ops.dup_errno = 24;
#if defined(CMFA_CONTRACT_TESTING)
  cmfa_internal_set_fd_ops(fake_dup, fake_close, &fd_ops);
#endif
  cmfa_tun_options options = make_options(7);
  expect_eq(cmfa_tun_start(&options, &snapshot, &error.error), CMFA_BACKEND_ERROR, "dup failure should surface");
  expect(!backend.start_called, "backend start must not run after dup failure");

  reset_contract();
}

void test_socket_protection_success_and_fail_closed() {
#if defined(__unix__) || defined(__APPLE__)
  {
    PipePair pipe_pair;
    FakeTunBackend backend;
    ProtectCapture capture;
    backend.protect_on_start = true;
    backend.protect_fd = 55;
    initialize_backend(&backend, &capture);

    cmfa_tun_snapshot snapshot{};
    ErrorBox error;
    cmfa_tun_options options = make_options(pipe_pair.read_fd);
    expect_eq(cmfa_tun_start(&options, &snapshot, &error.error), CMFA_OK, "protect success should allow tun start");
    expect_eq(static_cast<int>(capture.fds.size()), 1, "protect callback should be invoked once");
    expect_eq(capture.fds.front(), 55, "protect callback fd should be forwarded");
    expect_eq(capture.timeouts.front(), 3000U, "protect timeout must be capped at 3000ms");
    reset_contract();
  }

  {
    PipePair pipe_pair;
    FakeTunBackend backend;
    ProtectCapture capture;
    backend.protect_on_start = true;
    backend.protect_fd = 91;
    initialize_backend(&backend, &capture);

    cmfa_tun_snapshot snapshot{};
    ErrorBox error;
    cmfa_tun_options options = make_options(pipe_pair.read_fd);
    capture.response = CMFA_INVALID_STATE;
    expect_eq(cmfa_tun_start(&options, &snapshot, &error.error),
              CMFA_SOCKET_PROTECT_FAILED,
              "protect rejection must fail closed");
    reset_contract();
  }
#endif
}

void test_missing_timeout_reentrant_and_shutdown_protection_failures() {
#if defined(__unix__) || defined(__APPLE__)
  {
    PipePair pipe_pair;
    FakeTunBackend backend;
    ProtectCapture capture;
    backend.protect_on_start = true;
    backend.protect_fd = 88;
    initialize_backend(&backend, &capture, offsetof(cmfa_host_callbacks, protect_socket));

    cmfa_tun_snapshot snapshot{};
    ErrorBox error;
    cmfa_tun_options options = make_options(pipe_pair.read_fd);
    expect_eq(cmfa_tun_start(&options, &snapshot, &error.error),
              CMFA_SOCKET_PROTECT_FAILED,
              "missing protect callback must fail closed");
    reset_contract();
  }

  {
    PipePair pipe_pair;
    FakeTunBackend backend;
    ProtectCapture capture;
    backend.protect_on_start = true;
    backend.protect_fd = 77;
    initialize_backend(&backend, &capture);

    cmfa_tun_snapshot snapshot{};
    ErrorBox error;
    cmfa_tun_options options = make_options(pipe_pair.read_fd);
    capture.reentrant_stop = true;
    expect_eq(cmfa_tun_start(&options, &snapshot, &error.error), CMFA_OK, "reentrant callback still returns backend status");
    expect_eq(capture.reentrant_status,
              CMFA_INVALID_STATE,
              "reentrant tun stop during protect callback must be rejected");
    reset_contract();
  }

  {
    PipePair pipe_pair;
    FakeTunBackend backend;
    ProtectCapture capture;
    backend.protect_on_start = true;
    backend.protect_fd = 66;
    initialize_backend(&backend, &capture);
    cmfa_tun_options options = make_options(pipe_pair.read_fd);
    capture.block = true;
    capture.timeout_while_blocked = true;
    auto start_future = std::async(std::launch::async, [&] {
      ErrorBox async_error;
      cmfa_tun_snapshot async_snapshot{};
      return cmfa_tun_start(&options, &async_snapshot, &async_error.error);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    auto shutdown_future = std::async(std::launch::async, [&] {
      ErrorBox async_error;
      return cmfa_shutdown(&async_error.error);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const size_t callback_count_before_release = capture.fds.size();
    {
      std::lock_guard<std::mutex> lock(capture.mutex);
      capture.release = true;
      capture.cv.notify_all();
    }
    const cmfa_status start_status = start_future.get();
    expect(start_status == CMFA_SOCKET_PROTECT_FAILED || start_status == CMFA_INVALID_STATE,
           "blocked protect callback should fail closed or be cancelled by shutdown");
    expect_eq(shutdown_future.get(), CMFA_OK, "shutdown while protect callback waits should stay safe");
    expect_eq(static_cast<int>(capture.fds.size()),
              static_cast<int>(callback_count_before_release),
              "shutdown path must not trigger a post-shutdown callback");
    reset_contract();
  }
#endif
}

void test_invalid_trace_hashes_fail_closed() {
#if defined(__unix__) || defined(__APPLE__)
  const std::vector<std::pair<const char *, const char *>> invalid_hash_cases = {
      {"short", nullptr},
      {"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", nullptr},
      {"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", nullptr},
      {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bad-correlation"},
      {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"},
  };

  for (const auto &[hashed_tuple, correlation_hash] : invalid_hash_cases) {
    FakeTunBackend backend;
    ProtectCapture capture;
    initialize_backend(&backend, &capture);
    fill_trace_hashes(backend, hashed_tuple, correlation_hash);

    cmfa_tun_trace_collection traces{};
    ErrorBox error;
    expect_eq(cmfa_tun_copy_traces(&traces, &error.error),
              CMFA_BACKEND_ERROR,
              "invalid hashed_tuple/correlation_hash must fail closed");
    reset_contract();
  }
#endif
}

void test_empty_redacted_trace_addresses_are_allowed() {
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture);
  std::memset(backend.traces.traces[0].source_address, 0, sizeof(backend.traces.traces[0].source_address));
  std::memset(backend.traces.traces[0].destination_address, 0, sizeof(backend.traces.traces[0].destination_address));

  cmfa_tun_trace_collection traces{};
  ErrorBox error;
  expect_eq(cmfa_tun_copy_traces(&traces, &error.error), CMFA_OK, "empty redacted trace addresses should export");
  reset_contract();
}

void test_trace_paging_reads_full_ring() {
  FakeTunBackend backend;
  ProtectCapture capture;
  initialize_backend(&backend, &capture);
  backend.trace_ring.resize(CMFA_TUN_TRACE_RING_CAPACITY);
  for (size_t index = 0; index < backend.trace_ring.size(); index += 1) {
    auto &trace = backend.trace_ring[index];
    trace.struct_size = sizeof(trace);
    std::snprintf(trace.session_id, sizeof(trace.session_id), "%s", "session-1");
    std::snprintf(trace.trace_id, sizeof(trace.trace_id), "trace-%03zu", index);
    std::snprintf(trace.ingress, sizeof(trace.ingress), "%s", "tun");
    std::snprintf(trace.protocol, sizeof(trace.protocol), "%s", "tcp");
    std::snprintf(trace.source_address, sizeof(trace.source_address), "10.111.222.%zu:4%03zu", (index % 200) + 1, index);
    std::snprintf(trace.destination_address, sizeof(trace.destination_address), "1.1.1.%zu:443", (index % 200) + 1);
    std::snprintf(trace.hashed_tuple, sizeof(trace.hashed_tuple),
                  "%064zu", index);
  }

  cmfa_tun_trace_ring traces{};
  traces.struct_size = sizeof(traces);
  ErrorBox error;
  std::vector<std::string> seen_ids;
  expect_eq(cmfa_tun_copy_traces_ring(&traces, &error.error), CMFA_OK, "trace ring should succeed");
  for (uint32_t index = 0; index < traces.trace_count; index += 1) {
    seen_ids.emplace_back(traces.traces[index].trace_id);
  }

  expect_eq(seen_ids.size(), backend.trace_ring.size(), "ring API should return every stored trace");
  expect_string_eq(seen_ids.front(), "trace-000", "first paged trace should be oldest");
  expect_string_eq(seen_ids.back(), "trace-255", "last paged trace should be newest");
  reset_contract();
}

void test_partial_or_malformed_outbound_proof_fails_closed() {
  const char *hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const char *hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const char *hash_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
  struct OutboundCase {
    const char *destination_hash;
    const char *terminal_hash;
    const char *chain_hash;
    uint32_t chain_length;
  };
  const std::vector<OutboundCase> invalid_cases = {
      {"short", nullptr, nullptr, 0},
      {hash_a, hash_b, nullptr, 1},
      {hash_a, nullptr, hash_c, 1},
      {hash_a, hash_b, hash_c, 0},
      {hash_a, hash_b, hash_c, 17},
  };

  for (const auto &test_case : invalid_cases) {
    FakeTunBackend backend;
    ProtectCapture capture;
    initialize_backend(&backend, &capture);
    fill_trace_outbound_proof(
        backend, test_case.destination_hash, test_case.terminal_hash, test_case.chain_hash, test_case.chain_length);

    cmfa_tun_trace_collection traces{};
    ErrorBox error;
    expect_eq(cmfa_tun_copy_traces(&traces, &error.error),
              CMFA_BACKEND_ERROR,
              "partial or malformed outbound proof must fail closed");
    reset_contract();
  }
}

} // namespace

int main() {
  const std::vector<std::pair<const char *, std::function<void()>>> tests = {
      {"legacy_host_initializes_and_tun_structs_are_owned", test_legacy_host_initializes_and_tun_structs_are_owned},
      {"invalid_tun_option_shapes_fail_safely", test_invalid_tun_option_shapes_fail_safely},
      {"legacy_short_tun_options_do_not_overread_appended_fields",
       test_legacy_short_tun_options_do_not_overread_appended_fields},
      {"fd_duplication_and_rollback_rules", test_fd_duplication_and_rollback_rules},
      {"invalid_fd_and_dup_failure_never_reach_backend", test_invalid_fd_and_dup_failure_never_reach_backend},
      {"socket_protection_success_and_fail_closed", test_socket_protection_success_and_fail_closed},
      {"missing_timeout_reentrant_and_shutdown_protection_failures",
       test_missing_timeout_reentrant_and_shutdown_protection_failures},
      {"invalid_trace_hashes_fail_closed", test_invalid_trace_hashes_fail_closed},
      {"empty_redacted_trace_addresses_are_allowed", test_empty_redacted_trace_addresses_are_allowed},
      {"trace_paging_reads_full_ring", test_trace_paging_reads_full_ring},
      {"partial_or_malformed_outbound_proof_fails_closed", test_partial_or_malformed_outbound_proof_fails_closed},
  };

  for (const auto &entry : tests) {
    try {
      entry.second();
      std::cout << "[PASS] " << entry.first << '\n';
    } catch (const std::exception &error) {
      std::cerr << "[FAIL] " << entry.first << ": " << error.what() << '\n';
      return 1;
    }
  }

  return 0;
}
