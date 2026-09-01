#include "probe_native_core.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace cmfa::probe {
namespace {

constexpr uint32_t kMinTimeoutMs = 250;
constexpr uint32_t kMaxTimeoutMs = 10000;
constexpr size_t kMaxTcpPayloadBytes = 8192;
constexpr size_t kMaxUdpPayloadBytes = 1024;
constexpr size_t kMaxHttpStatusLineBytes = 4096;

int real_socket(void*, int domain, int type, int protocol) {
  return ::socket(domain, type, protocol);
}

int real_fcntl(void*, int fd, int command, int value) {
  if (command == F_GETFL) {
    return ::fcntl(fd, command);
  }
  return ::fcntl(fd, command, value);
}

int real_connect(void* context, int fd, const sockaddr* address, socklen_t address_length) {
  (void)context;
  return ::connect(fd, address, address_length);
}

int real_poll(void* context, pollfd* fds, nfds_t count, int timeout_ms) {
  (void)context;
  return ::poll(fds, count, timeout_ms);
}

int real_getsockopt(void* context,
                    int fd,
                    int level,
                    int option_name,
                    void* option_value,
                    socklen_t* option_length) {
  (void)context;
  return ::getsockopt(fd, level, option_name, option_value, option_length);
}

int real_setsockopt(void* context,
                    int fd,
                    int level,
                    int option_name,
                    const void* option_value,
                    socklen_t option_length) {
  (void)context;
  return ::setsockopt(fd, level, option_name, option_value, option_length);
}

ssize_t real_send(void* context, int fd, const void* buffer, size_t length, int flags) {
  (void)context;
  return ::send(fd, buffer, length, flags);
}

ssize_t real_recv(void* context, int fd, void* buffer, size_t length, int flags) {
  (void)context;
  return ::recv(fd, buffer, length, flags);
}

ssize_t real_sendto(void* context,
                    int fd,
                    const void* buffer,
                    size_t length,
                    int flags,
                    const sockaddr* address,
                    socklen_t address_length) {
  (void)context;
  return ::sendto(fd, buffer, length, flags, address, address_length);
}

ssize_t real_recvfrom(void* context,
                      int fd,
                      void* buffer,
                      size_t length,
                      int flags,
                      sockaddr* address,
                      socklen_t* address_length) {
  (void)context;
  return ::recvfrom(fd, buffer, length, flags, address, address_length);
}

int real_close(void* context, int fd) {
  (void)context;
  return ::close(fd);
}

int64_t real_monotonic_now_ms(void*) {
  timespec now {};
  if (::clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return static_cast<int64_t>(now.tv_sec) * 1000 + static_cast<int64_t>(now.tv_nsec / 1000000);
}

PosixOps make_real_ops() {
  PosixOps ops {};
  ops.context = nullptr;
  ops.socket_fn = &real_socket;
  ops.fcntl_fn = &real_fcntl;
  ops.connect_fn = &real_connect;
  ops.poll_fn = &real_poll;
  ops.getsockopt_fn = &real_getsockopt;
  ops.setsockopt_fn = &real_setsockopt;
  ops.send_fn = &real_send;
  ops.recv_fn = &real_recv;
  ops.sendto_fn = &real_sendto;
  ops.recvfrom_fn = &real_recvfrom;
  ops.close_fn = &real_close;
  ops.monotonic_now_ms_fn = &real_monotonic_now_ms;
  return ops;
}

class SocketGuard {
 public:
  explicit SocketGuard(const PosixOps& ops) : ops_(ops) {}

  ~SocketGuard() {
    if (fd_ >= 0 && ops_.close_fn != nullptr) {
      ops_.close_fn(ops_.context, fd_);
    }
  }

  SocketGuard(const SocketGuard&) = delete;
  SocketGuard& operator=(const SocketGuard&) = delete;

  int get() const { return fd_; }
  void reset(int fd) { fd_ = fd; }

 private:
  const PosixOps& ops_;
  int fd_ = -1;
};

enum class WaitResult {
  Ready,
  Timeout,
  Error,
};

uint32_t clamp_timeout_ms(uint32_t timeout_ms) {
  return std::min(std::max(timeout_ms, kMinTimeoutMs), kMaxTimeoutMs);
}

uint32_t saturating_duration_ms(int64_t started_at_ms, int64_t completed_at_ms) {
  if (completed_at_ms <= started_at_ms) {
    return 0;
  }
  const int64_t delta = completed_at_ms - started_at_ms;
  if (delta >= static_cast<int64_t>(UINT32_MAX)) {
    return UINT32_MAX;
  }
  return static_cast<uint32_t>(delta);
}

void finish_result(const PosixOps& ops, int64_t started_at_ms, ProbeResult* result) {
  if (result == nullptr || ops.monotonic_now_ms_fn == nullptr) {
    return;
  }
  result->duration_ms = saturating_duration_ms(started_at_ms, ops.monotonic_now_ms_fn(ops.context));
}

bool is_udp_kind(ProbeKind kind) {
  return kind == ProbeKind::UdpEcho || kind == ProbeKind::DnsUdpEcho;
}

bool is_tcp_kind(ProbeKind kind) {
  return kind == ProbeKind::TcpEcho || kind == ProbeKind::TcpHttp || kind == ProbeKind::TcpSend ||
    kind == ProbeKind::TcpExchange;
}

bool is_supported_kind(ProbeKind kind) {
  return is_tcp_kind(kind) || is_udp_kind(kind);
}

bool parse_ipv4_literal(const char* host_ipv4, in_addr* address) {
  if (host_ipv4 == nullptr || address == nullptr) {
    return false;
  }
  return ::inet_pton(AF_INET, host_ipv4, address) == 1;
}

bool validate_request(const ProbeRequest& request) {
  if (!is_supported_kind(request.kind)) {
    return false;
  }
  if (request.port == 0) {
    return false;
  }
  if (request.payload == nullptr || request.payload_size == 0) {
    return false;
  }
  const size_t max_payload_bytes = is_tcp_kind(request.kind) ? kMaxTcpPayloadBytes : kMaxUdpPayloadBytes;
  if (request.payload_size > max_payload_bytes) {
    return false;
  }
  in_addr address {};
  return parse_ipv4_literal(request.host_ipv4, &address);
}

sockaddr_in make_destination(const ProbeRequest& request) {
  sockaddr_in destination {};
  destination.sin_family = AF_INET;
  destination.sin_port = htons(request.port);
  (void)::inet_pton(AF_INET, request.host_ipv4, &destination.sin_addr);
  return destination;
}

bool set_nonblocking(const PosixOps& ops, int fd) {
  if (ops.fcntl_fn == nullptr) {
    return false;
  }
  int flags = 0;
  while (true) {
    flags = ops.fcntl_fn(ops.context, fd, F_GETFL, 0);
    if (flags >= 0) {
      break;
    }
    if (errno != EINTR) {
      return false;
    }
  }
  while (true) {
    const int result = ops.fcntl_fn(ops.context, fd, F_SETFL, flags | O_NONBLOCK);
    if (result == 0) {
      return true;
    }
    if (errno != EINTR) {
      return false;
    }
  }
}

bool configure_tcp_no_sigpipe(const PosixOps& ops, int fd) {
#if defined(SO_NOSIGPIPE)
  if (ops.setsockopt_fn == nullptr) {
    return false;
  }
  const int enabled = 1;
  while (true) {
    const int result =
        ops.setsockopt_fn(ops.context, fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, static_cast<socklen_t>(sizeof(enabled)));
    if (result == 0) {
      return true;
    }
    if (errno != EINTR) {
      return false;
    }
  }
#else
  (void)ops;
  (void)fd;
  return true;
#endif
}

int tcp_send_flags() {
#if defined(MSG_NOSIGNAL)
  return MSG_NOSIGNAL;
#else
  return 0;
#endif
}

WaitResult wait_for_events(const PosixOps& ops, int fd, short events, int64_t deadline_ms) {
  if (ops.poll_fn == nullptr || ops.monotonic_now_ms_fn == nullptr) {
    return WaitResult::Error;
  }
  while (true) {
    const int64_t now_ms = ops.monotonic_now_ms_fn(ops.context);
    if (now_ms >= deadline_ms) {
      return WaitResult::Timeout;
    }
    const int64_t remaining_ms = deadline_ms - now_ms;
    const int timeout_ms =
        static_cast<int>(std::min<int64_t>(remaining_ms, static_cast<int64_t>(INT_MAX)));
    pollfd descriptor {};
    descriptor.fd = fd;
    descriptor.events = events;
    descriptor.revents = 0;
    const int result = ops.poll_fn(ops.context, &descriptor, 1, timeout_ms);
    if (result > 0) {
      return WaitResult::Ready;
    }
    if (result == 0) {
      return WaitResult::Timeout;
    }
    if (errno != EINTR) {
      return WaitResult::Error;
    }
  }
}

ProbeResult make_invalid_argument_result() {
  ProbeResult result {};
  result.outcome = ProbeOutcome::Fail;
  result.failure = ProbeFailure::InvalidArgument;
  return result;
}

ProbeResult make_failure_result(ProbeOutcome outcome, ProbeFailure failure, uint32_t bytes_sent, uint32_t bytes_received) {
  ProbeResult result {};
  result.outcome = outcome;
  result.failure = failure;
  result.bytes_sent = bytes_sent;
  result.bytes_received = bytes_received;
  return result;
}

bool deadline_elapsed(const PosixOps& ops, int64_t deadline_ms) {
  return ops.monotonic_now_ms_fn != nullptr && ops.monotonic_now_ms_fn(ops.context) >= deadline_ms;
}

ProbeResult make_finished_result(const PosixOps& ops,
                                 int64_t started_at_ms,
                                 ProbeOutcome outcome,
                                 ProbeFailure failure,
                                 uint32_t bytes_sent,
                                 uint32_t bytes_received) {
  ProbeResult result = make_failure_result(outcome, failure, bytes_sent, bytes_received);
  finish_result(ops, started_at_ms, &result);
  return result;
}

ProbeResult make_timeout_result(const PosixOps& ops,
                                int64_t started_at_ms,
                                uint32_t bytes_sent,
                                uint32_t bytes_received) {
  return make_finished_result(ops, started_at_ms, ProbeOutcome::Timeout, ProbeFailure::Timeout, bytes_sent, bytes_received);
}

ProbeResult verify_tcp_exact_tail(int fd,
                                  const PosixOps& ops,
                                  int64_t started_at_ms,
                                  int64_t deadline_ms,
                                  uint32_t bytes_sent,
                                  uint32_t bytes_received) {
  uint8_t extra_byte = 0;
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, bytes_sent, bytes_received);
    }
    const ssize_t read = ops.recv_fn(ops.context, fd, &extra_byte, sizeof(extra_byte), 0);
    if (read > 0) {
      return make_finished_result(ops,
                                  started_at_ms,
                                  ProbeOutcome::Fail,
                                  ProbeFailure::PayloadMismatch,
                                  bytes_sent,
                                  bytes_received + static_cast<uint32_t>(read));
    }
    if (read == 0) {
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, bytes_sent, bytes_received);
      }
      ProbeResult result {};
      result.outcome = ProbeOutcome::Pass;
      result.failure = ProbeFailure::None;
      result.bytes_sent = bytes_sent;
      result.bytes_received = bytes_received;
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, fd, POLLIN, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        return make_timeout_result(ops, started_at_ms, bytes_sent, bytes_received);
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    return make_finished_result(ops,
                                started_at_ms,
                                ProbeOutcome::Fail,
                                ProbeFailure::RecvFailed,
                                bytes_sent,
                                bytes_received);
  }
}

ProbeResult run_tcp_probe(const ProbeRequest& request, const PosixOps& ops, int64_t started_at_ms, int64_t deadline_ms) {
  ProbeResult result {};
  result.outcome = ProbeOutcome::Pass;
  result.failure = ProbeFailure::None;

  const int socket_fd = ops.socket_fn != nullptr ? ops.socket_fn(ops.context, AF_INET, SOCK_STREAM, 0) : -1;
  if (socket_fd < 0) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  SocketGuard socket_guard(ops);
  socket_guard.reset(socket_fd);
  if (!set_nonblocking(ops, socket_guard.get())) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }
  if (!configure_tcp_no_sigpipe(ops, socket_guard.get())) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  const sockaddr_in destination = make_destination(request);
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, 0, 0);
    }
    const int connect_result = ops.connect_fn(ops.context,
                                              socket_guard.get(),
                                              reinterpret_cast<const sockaddr*>(&destination),
                                              static_cast<socklen_t>(sizeof(destination)));
    if (connect_result == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno != EINPROGRESS) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }

    const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLOUT, deadline_ms);
    if (wait_result == WaitResult::Timeout) {
      result = make_failure_result(ProbeOutcome::Timeout, ProbeFailure::Timeout, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (wait_result == WaitResult::Error) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }

    int socket_error = 0;
    socklen_t socket_error_length = static_cast<socklen_t>(sizeof(socket_error));
    while (true) {
      const int getsockopt_result = ops.getsockopt_fn(ops.context,
                                                      socket_guard.get(),
                                                      SOL_SOCKET,
                                                      SO_ERROR,
                                                      &socket_error,
                                                      &socket_error_length);
      if (getsockopt_result == 0) {
        break;
      }
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, 0, 0);
      }
      if (errno != EINTR) {
        result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
    }
    if (socket_error != 0) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    break;
  }

  size_t sent_bytes = 0;
  while (sent_bytes < request.payload_size) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), 0);
    }
    const ssize_t wrote =
        ops.send_fn(ops.context,
                    socket_guard.get(),
                    request.payload + sent_bytes,
                    request.payload_size - sent_bytes,
                    tcp_send_flags());
    if (wrote > 0) {
      sent_bytes += static_cast<size_t>(wrote);
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), 0);
      }
      continue;
    }
    if (wrote == 0) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, static_cast<uint32_t>(sent_bytes), 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLOUT, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        result = make_failure_result(ProbeOutcome::Timeout,
                                     ProbeFailure::Timeout,
                                     static_cast<uint32_t>(sent_bytes),
                                     0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, static_cast<uint32_t>(sent_bytes), 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  std::vector<uint8_t> response(request.payload_size);
  size_t received_bytes = 0;
  while (received_bytes < request.payload_size) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(
          ops, started_at_ms, static_cast<uint32_t>(sent_bytes), static_cast<uint32_t>(received_bytes));
    }
    const ssize_t read =
        ops.recv_fn(ops.context, socket_guard.get(), response.data() + received_bytes, response.size() - received_bytes, 0);
    if (read > 0) {
      received_bytes += static_cast<size_t>(read);
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(
            ops, started_at_ms, static_cast<uint32_t>(sent_bytes), static_cast<uint32_t>(received_bytes));
      }
      continue;
    }
    if (read == 0) {
      result = make_failure_result(ProbeOutcome::Fail,
                                   ProbeFailure::RecvFailed,
                                   static_cast<uint32_t>(sent_bytes),
                                   static_cast<uint32_t>(received_bytes));
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLIN, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        result = make_failure_result(ProbeOutcome::Timeout,
                                     ProbeFailure::Timeout,
                                     static_cast<uint32_t>(sent_bytes),
                                     static_cast<uint32_t>(received_bytes));
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    result = make_failure_result(ProbeOutcome::Fail,
                                 ProbeFailure::RecvFailed,
                                 static_cast<uint32_t>(sent_bytes),
                                 static_cast<uint32_t>(received_bytes));
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  result.bytes_sent = static_cast<uint32_t>(sent_bytes);
  result.bytes_received = static_cast<uint32_t>(received_bytes);
  if (std::memcmp(response.data(), request.payload, request.payload_size) != 0) {
    result.outcome = ProbeOutcome::Fail;
    result.failure = ProbeFailure::PayloadMismatch;
    finish_result(ops, started_at_ms, &result);
    return result;
  }
  return verify_tcp_exact_tail(socket_guard.get(),
                               ops,
                               started_at_ms,
                               deadline_ms,
                               result.bytes_sent,
                               result.bytes_received);
}

bool is_valid_http_status_line(const std::vector<uint8_t>& buffer, size_t* line_length) {
  if (line_length == nullptr) {
    return false;
  }
  for (size_t index = 1; index < buffer.size(); ++index) {
    if (buffer[index - 1] != '\r' || buffer[index] != '\n') {
      continue;
    }
    const size_t end = index - 1;
    *line_length = index + 1;
    if (end < 13) {
      return false;
    }
    const char* data = reinterpret_cast<const char*>(buffer.data());
    const bool http10 = std::memcmp(data, "HTTP/1.0 ", 9) == 0;
    const bool http11 = std::memcmp(data, "HTTP/1.1 ", 9) == 0;
    if (!http10 && !http11) {
      return false;
    }
    const char hundreds = data[9];
    const char tens = data[10];
    const char ones = data[11];
    if (hundreds < '1' || hundreds > '5' || tens < '0' || tens > '9' || ones < '0' || ones > '9') {
      return false;
    }
    if (data[12] != ' ') {
      return false;
    }
    return true;
  }
  return false;
}

ProbeResult run_tcp_http_probe(const ProbeRequest& request, const PosixOps& ops, int64_t started_at_ms, int64_t deadline_ms) {
  ProbeResult result {};
  result.outcome = ProbeOutcome::Pass;
  result.failure = ProbeFailure::None;

  const int socket_fd = ops.socket_fn != nullptr ? ops.socket_fn(ops.context, AF_INET, SOCK_STREAM, 0) : -1;
  if (socket_fd < 0) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  SocketGuard socket_guard(ops);
  socket_guard.reset(socket_fd);
  if (!configure_tcp_no_sigpipe(ops, socket_guard.get()) || !set_nonblocking(ops, socket_guard.get())) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  const sockaddr_in destination = make_destination(request);
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, 0, 0);
    }
    const int connect_result = ops.connect_fn(ops.context,
                                              socket_guard.get(),
                                              reinterpret_cast<const sockaddr*>(&destination),
                                              static_cast<socklen_t>(sizeof(destination)));
    if (connect_result == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno != EINPROGRESS && errno != EALREADY && errno != EWOULDBLOCK) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }

    const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLOUT, deadline_ms);
    if (wait_result == WaitResult::Timeout) {
      result = make_failure_result(ProbeOutcome::Timeout, ProbeFailure::Timeout, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (wait_result == WaitResult::Error) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }

    int socket_error = 0;
    socklen_t socket_error_length = static_cast<socklen_t>(sizeof(socket_error));
    while (true) {
      const int getsockopt_result = ops.getsockopt_fn(ops.context,
                                                      socket_guard.get(),
                                                      SOL_SOCKET,
                                                      SO_ERROR,
                                                      &socket_error,
                                                      &socket_error_length);
      if (getsockopt_result == 0) {
        break;
      }
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, 0, 0);
      }
      if (errno != EINTR) {
        result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
    }
    if (socket_error != 0) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    break;
  }

  size_t sent_bytes = 0;
  while (sent_bytes < request.payload_size) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), 0);
    }
    const ssize_t wrote = ops.send_fn(ops.context,
                                      socket_guard.get(),
                                      request.payload + sent_bytes,
                                      request.payload_size - sent_bytes,
                                      tcp_send_flags());
    if (wrote > 0) {
      sent_bytes += static_cast<size_t>(wrote);
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), 0);
      }
      continue;
    }
    if (wrote == 0) {
      result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, static_cast<uint32_t>(sent_bytes), 0);
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLOUT, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        result = make_failure_result(ProbeOutcome::Timeout, ProbeFailure::Timeout, static_cast<uint32_t>(sent_bytes), 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, static_cast<uint32_t>(sent_bytes), 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  if (request.kind == ProbeKind::TcpSend) {
    return make_finished_result(ops,
                                started_at_ms,
                                ProbeOutcome::Pass,
                                ProbeFailure::None,
                                static_cast<uint32_t>(sent_bytes),
                                0);
  }

  std::vector<uint8_t> response;
  response.reserve(kMaxHttpStatusLineBytes);
  size_t received_bytes = 0;
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), static_cast<uint32_t>(received_bytes));
    }
    uint8_t chunk[256];
    const ssize_t read = ops.recv_fn(ops.context, socket_guard.get(), chunk, sizeof(chunk), 0);
    if (read > 0) {
      received_bytes += static_cast<size_t>(read);
      if (request.kind == ProbeKind::TcpExchange) {
        return make_finished_result(ops,
                                    started_at_ms,
                                    ProbeOutcome::Pass,
                                    ProbeFailure::None,
                                    static_cast<uint32_t>(sent_bytes),
                                    static_cast<uint32_t>(received_bytes));
      }
      const size_t writable = std::min(static_cast<size_t>(read), kMaxHttpStatusLineBytes - std::min(response.size(), kMaxHttpStatusLineBytes));
      response.insert(response.end(), chunk, chunk + writable);
      size_t line_length = 0;
      if (is_valid_http_status_line(response, &line_length)) {
        return make_finished_result(ops,
                                    started_at_ms,
                                    ProbeOutcome::Pass,
                                    ProbeFailure::None,
                                    static_cast<uint32_t>(sent_bytes),
                                    static_cast<uint32_t>(received_bytes));
      }
      if (line_length > 0 || response.size() >= kMaxHttpStatusLineBytes) {
        return make_finished_result(ops,
                                    started_at_ms,
                                    ProbeOutcome::Fail,
                                    ProbeFailure::PayloadMismatch,
                                    static_cast<uint32_t>(sent_bytes),
                                    static_cast<uint32_t>(received_bytes));
      }
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), static_cast<uint32_t>(received_bytes));
      }
      continue;
    }
    if (read == 0) {
      return make_finished_result(ops,
                                  started_at_ms,
                                  ProbeOutcome::Fail,
                                  ProbeFailure::RecvFailed,
                                  static_cast<uint32_t>(sent_bytes),
                                  static_cast<uint32_t>(received_bytes));
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLIN, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        return make_timeout_result(ops, started_at_ms, static_cast<uint32_t>(sent_bytes), static_cast<uint32_t>(received_bytes));
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    return make_finished_result(ops,
                                started_at_ms,
                                ProbeOutcome::Fail,
                                ProbeFailure::RecvFailed,
                                static_cast<uint32_t>(sent_bytes),
                                static_cast<uint32_t>(received_bytes));
  }
}

ProbeResult run_udp_probe(const ProbeRequest& request, const PosixOps& ops, int64_t started_at_ms, int64_t deadline_ms) {
  ProbeResult result {};
  result.outcome = ProbeOutcome::Pass;
  result.failure = ProbeFailure::None;

  const int socket_fd = ops.socket_fn != nullptr ? ops.socket_fn(ops.context, AF_INET, SOCK_DGRAM, 0) : -1;
  if (socket_fd < 0) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  SocketGuard socket_guard(ops);
  socket_guard.reset(socket_fd);
  if (!set_nonblocking(ops, socket_guard.get())) {
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::ConnectFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  const sockaddr_in destination = make_destination(request);
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, 0, 0);
    }
    const ssize_t wrote = ops.sendto_fn(ops.context,
                                        socket_guard.get(),
                                        request.payload,
                                        request.payload_size,
                                        0,
                                        reinterpret_cast<const sockaddr*>(&destination),
                                        static_cast<socklen_t>(sizeof(destination)));
    if (wrote >= 0) {
      if (static_cast<size_t>(wrote) != request.payload_size) {
        result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, static_cast<uint32_t>(wrote), 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      result.bytes_sent = static_cast<uint32_t>(wrote);
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, result.bytes_sent, 0);
      }
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLOUT, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        result = make_failure_result(ProbeOutcome::Timeout, ProbeFailure::Timeout, 0, 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::SendFailed, 0, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }

  std::vector<uint8_t> response(request.payload_size);
  sockaddr_in peer {};
  socklen_t peer_length = static_cast<socklen_t>(sizeof(peer));
  while (true) {
    if (deadline_elapsed(ops, deadline_ms)) {
      return make_timeout_result(ops, started_at_ms, result.bytes_sent, result.bytes_received);
    }
    peer = {};
    peer_length = static_cast<socklen_t>(sizeof(peer));
    const ssize_t read = ops.recvfrom_fn(ops.context,
                                         socket_guard.get(),
                                         response.data(),
                                         response.size(),
                                         0,
                                         reinterpret_cast<sockaddr*>(&peer),
                                         &peer_length);
    if (read >= 0) {
      result.bytes_received = static_cast<uint32_t>(read);
      if (deadline_elapsed(ops, deadline_ms)) {
        return make_timeout_result(ops, started_at_ms, result.bytes_sent, result.bytes_received);
      }
      if (peer_length != static_cast<socklen_t>(sizeof(sockaddr_in)) ||
          peer.sin_family != AF_INET ||
          peer.sin_port != destination.sin_port ||
          peer.sin_addr.s_addr != destination.sin_addr.s_addr ||
          static_cast<size_t>(read) != request.payload_size ||
          std::memcmp(response.data(), request.payload, request.payload_size) != 0) {
        result.outcome = ProbeOutcome::Fail;
        result.failure = ProbeFailure::PayloadMismatch;
      }
      finish_result(ops, started_at_ms, &result);
      return result;
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      const WaitResult wait_result = wait_for_events(ops, socket_guard.get(), POLLIN, deadline_ms);
      if (wait_result == WaitResult::Timeout) {
        result = make_failure_result(ProbeOutcome::Timeout, ProbeFailure::Timeout, result.bytes_sent, 0);
        finish_result(ops, started_at_ms, &result);
        return result;
      }
      if (wait_result == WaitResult::Ready) {
        continue;
      }
    }
    result = make_failure_result(ProbeOutcome::Fail, ProbeFailure::RecvFailed, result.bytes_sent, 0);
    finish_result(ops, started_at_ms, &result);
    return result;
  }
}

ProbeResult probe_socket_impl(const ProbeRequest& request, const PosixOps& ops) {
  if (!validate_request(request)) {
    return make_invalid_argument_result();
  }

  const int64_t started_at_ms = ops.monotonic_now_ms_fn != nullptr ? ops.monotonic_now_ms_fn(ops.context) : 0;
  const int64_t deadline_ms = started_at_ms + static_cast<int64_t>(clamp_timeout_ms(request.timeout_ms));
  if (request.kind == ProbeKind::TcpEcho) {
    return run_tcp_probe(request, ops, started_at_ms, deadline_ms);
  }
  if (request.kind == ProbeKind::TcpHttp || request.kind == ProbeKind::TcpSend || request.kind == ProbeKind::TcpExchange) {
    return run_tcp_http_probe(request, ops, started_at_ms, deadline_ms);
  }
  return run_udp_probe(request, ops, started_at_ms, deadline_ms);
}

}  // namespace

ProbeResult probe_socket(const ProbeRequest& request) {
  return probe_socket_impl(request, make_real_ops());
}

#if defined(CMFA_PROBE_TESTING)
ProbeResult probe_socket_for_test(const ProbeRequest& request, const PosixOps& ops) {
  return probe_socket_impl(request, ops);
}
#endif

}  // namespace cmfa::probe
