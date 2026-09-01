#pragma once

#include <cstddef>
#include <cstdint>
#include <poll.h>
#include <sys/socket.h>

namespace cmfa::probe {

enum class ProbeKind {
  TcpEcho,
  TcpHttp,
  TcpSend,
  TcpExchange,
  UdpEcho,
  DnsUdpEcho,
};

enum class ProbeOutcome {
  Pass,
  Fail,
  Timeout,
};

enum class ProbeFailure {
  None,
  InvalidArgument,
  ConnectFailed,
  SendFailed,
  RecvFailed,
  Timeout,
  PayloadMismatch,
};

struct ProbeRequest {
  ProbeKind kind = ProbeKind::TcpEcho;
  const char *host_ipv4 = nullptr;
  uint16_t port = 0;
  const uint8_t *payload = nullptr;
  size_t payload_size = 0;
  uint32_t timeout_ms = 0;
};

struct ProbeResult {
  ProbeOutcome outcome = ProbeOutcome::Fail;
  ProbeFailure failure = ProbeFailure::None;
  uint32_t bytes_sent = 0;
  uint32_t bytes_received = 0;
  uint32_t duration_ms = 0;
};

using SocketFn = int (*)(void *context, int domain, int type, int protocol);
using FcntlFn = int (*)(void *context, int fd, int command, int value);
using ConnectFn = int (*)(void *context, int fd, const struct sockaddr *address, socklen_t address_length);
using PollFn = int (*)(void *context, struct pollfd *fds, nfds_t count, int timeout_ms);
using GetSockOptFn = int (*)(void *context,
                             int fd,
                             int level,
                             int option_name,
                             void *option_value,
                             socklen_t *option_length);
using SetSockOptFn = int (*)(void *context,
                             int fd,
                             int level,
                             int option_name,
                             const void *option_value,
                             socklen_t option_length);
using SendFn = ssize_t (*)(void *context, int fd, const void *buffer, size_t length, int flags);
using RecvFn = ssize_t (*)(void *context, int fd, void *buffer, size_t length, int flags);
using SendToFn = ssize_t (*)(void *context,
                             int fd,
                             const void *buffer,
                             size_t length,
                             int flags,
                             const struct sockaddr *address,
                             socklen_t address_length);
using RecvFromFn = ssize_t (*)(void *context,
                               int fd,
                               void *buffer,
                               size_t length,
                               int flags,
                               struct sockaddr *address,
                               socklen_t *address_length);
using CloseFn = int (*)(void *context, int fd);
using MonotonicNowMsFn = int64_t (*)(void *context);

struct PosixOps {
  void *context = nullptr;
  SocketFn socket_fn = nullptr;
  FcntlFn fcntl_fn = nullptr;
  ConnectFn connect_fn = nullptr;
  PollFn poll_fn = nullptr;
  GetSockOptFn getsockopt_fn = nullptr;
  SetSockOptFn setsockopt_fn = nullptr;
  SendFn send_fn = nullptr;
  RecvFn recv_fn = nullptr;
  SendToFn sendto_fn = nullptr;
  RecvFromFn recvfrom_fn = nullptr;
  CloseFn close_fn = nullptr;
  MonotonicNowMsFn monotonic_now_ms_fn = nullptr;
};

ProbeResult probe_socket(const ProbeRequest &request);

#if defined(CMFA_PROBE_TESTING)
ProbeResult probe_socket_for_test(const ProbeRequest &request, const PosixOps &ops);
#endif

}  // namespace cmfa::probe
