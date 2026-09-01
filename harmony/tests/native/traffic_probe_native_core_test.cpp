#include "probe_native_core.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using cmfa::probe::PosixOps;
using cmfa::probe::ProbeFailure;
using cmfa::probe::ProbeKind;
using cmfa::probe::ProbeOutcome;
using cmfa::probe::ProbeRequest;
using cmfa::probe::ProbeResult;

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
void expect_eq(const T& actual, const U& expected, const std::string& message) {
  if (!(actual == expected)) {
    throw TestFailure(message + " (actual=" + std::to_string(static_cast<long long>(actual)) +
                      ", expected=" + std::to_string(static_cast<long long>(expected)) + ")");
  }
}

void expect_outcome(const ProbeResult& result, ProbeOutcome expected, const std::string& message) {
  expect(result.outcome == expected, message);
}

void expect_failure(const ProbeResult& result, ProbeFailure expected, const std::string& message) {
  expect(result.failure == expected, message);
}

std::vector<uint8_t> bytes_from_string(const std::string& text) {
  return std::vector<uint8_t>(text.begin(), text.end());
}

std::vector<uint8_t> dns_query_payload() {
  return {
      0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x03, 'w',  'w',  'w',
      0x07, 'e',  'x',  'a',  'm', 'p',  'l',  'e',
      0x03, 'c',  'o',  'm',  0x00, 0x00, 0x01, 0x00,
      0x01,
  };
}

std::vector<uint8_t> http_status_payload(const std::string& line) {
  return bytes_from_string(line);
}

uint32_t ipv4_to_network_order(const std::string& host) {
  in_addr address {};
  const int parsed = ::inet_pton(AF_INET, host.c_str(), &address);
  expect_eq(parsed, 1, "test IPv4 literal must parse");
  return address.s_addr;
}

struct FakeConnectAction {
  int result = 0;
  int error = 0;
};

struct FakePollAction {
  int result = 0;
  short revents = 0;
  int error = 0;
};

struct FakeSockOptAction {
  int result = 0;
  int error = 0;
  int sockopt_value = 0;
};

struct FakeIoAction {
  ssize_t result = 0;
  int error = 0;
  std::vector<uint8_t> bytes;
  uint32_t peer_addr = 0;
  uint16_t peer_port = 0;
  sa_family_t peer_family = AF_INET;
};

struct FakeCloseAction {
  int result = 0;
  int error = 0;
};

struct FakeState {
  std::vector<int> socket_results;
  std::vector<int> fcntl_get_results;
  std::vector<int> fcntl_set_results;
  std::vector<FakeConnectAction> connect_actions;
  std::vector<FakePollAction> poll_actions;
  std::vector<FakeSockOptAction> getsockopt_actions;
  std::vector<FakeSockOptAction> setsockopt_actions;
  std::vector<FakeIoAction> send_actions;
  std::vector<FakeIoAction> recv_actions;
  std::vector<FakeIoAction> sendto_actions;
  std::vector<FakeIoAction> recvfrom_actions;
  std::vector<FakeCloseAction> close_actions;
  std::vector<int64_t> now_ms_values;

  size_t socket_index = 0;
  size_t fcntl_get_index = 0;
  size_t fcntl_set_index = 0;
  size_t connect_index = 0;
  size_t poll_index = 0;
  size_t getsockopt_index = 0;
  size_t setsockopt_index = 0;
  size_t send_index = 0;
  size_t recv_index = 0;
  size_t sendto_index = 0;
  size_t recvfrom_index = 0;
  size_t close_index = 0;
  size_t now_ms_index = 0;

  int last_poll_timeout = -1;
  int close_count = 0;
  std::vector<int> closed_fds;
  std::vector<size_t> send_lengths;
  std::vector<size_t> recv_lengths;
  std::vector<size_t> sendto_lengths;
  std::vector<size_t> recvfrom_lengths;
  uint32_t last_connect_addr = 0;
  uint16_t last_connect_port = 0;
  uint32_t last_sendto_addr = 0;
  uint16_t last_sendto_port = 0;
  std::vector<int> send_flags;
  std::vector<int> setsockopt_levels;
  std::vector<int> setsockopt_names;
  std::vector<int> setsockopt_values;
};

template <typename T>
const T& next_action(const std::vector<T>& actions, size_t* index, const char* name) {
  if (*index >= actions.size()) {
    throw TestFailure(std::string("missing fake action for ") + name);
  }
  const T& action = actions[*index];
  *index += 1;
  return action;
}

int fake_socket(void* context, int, int, int) {
  auto* state = static_cast<FakeState*>(context);
  if (state == nullptr || state->socket_index >= state->socket_results.size()) {
    return 41;
  }
  const int result = state->socket_results[state->socket_index];
  state->socket_index += 1;
  return result;
}

int fake_fcntl(void* context, int, int command, int) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_fcntl requires state");
  if (command == F_GETFL) {
    const int result = next_action(state->fcntl_get_results, &state->fcntl_get_index, "fcntl get");
    return result;
  }
  const int result = next_action(state->fcntl_set_results, &state->fcntl_set_index, "fcntl set");
  return result;
}

int fake_connect(void* context, int, const sockaddr* address, socklen_t) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_connect requires state");
  const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
  state->last_connect_addr = ipv4->sin_addr.s_addr;
  state->last_connect_port = ntohs(ipv4->sin_port);
  const FakeConnectAction& action = next_action(state->connect_actions, &state->connect_index, "connect");
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

int fake_poll(void* context, pollfd* fds, nfds_t count, int timeout_ms) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_poll requires state");
  expect_eq(count, static_cast<nfds_t>(1), "fake_poll expects one descriptor");
  state->last_poll_timeout = timeout_ms;
  const FakePollAction& action = next_action(state->poll_actions, &state->poll_index, "poll");
  fds[0].revents = action.revents;
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

int fake_getsockopt(void* context, int, int, int, void* option_value, socklen_t* option_length) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_getsockopt requires state");
  const FakeSockOptAction& action = next_action(state->getsockopt_actions, &state->getsockopt_index, "getsockopt");
  if (action.result < 0) {
    errno = action.error;
    return action.result;
  }
  expect(option_value != nullptr, "fake_getsockopt requires option value");
  expect(option_length != nullptr, "fake_getsockopt requires option length");
  expect(*option_length >= static_cast<socklen_t>(sizeof(int)), "fake_getsockopt requires int-sized buffer");
  *reinterpret_cast<int*>(option_value) = action.sockopt_value;
  *option_length = static_cast<socklen_t>(sizeof(int));
  return action.result;
}

int fake_setsockopt(void* context,
                    int,
                    int level,
                    int option_name,
                    const void* option_value,
                    socklen_t option_length) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_setsockopt requires state");
  state->setsockopt_levels.push_back(level);
  state->setsockopt_names.push_back(option_name);
  state->setsockopt_values.push_back(
      option_value != nullptr && option_length >= static_cast<socklen_t>(sizeof(int))
          ? *reinterpret_cast<const int*>(option_value)
          : 0);
  if (state->setsockopt_index >= state->setsockopt_actions.size()) {
    return 0;
  }
  const FakeSockOptAction& action =
      state->setsockopt_actions[state->setsockopt_index];
  state->setsockopt_index += 1;
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

ssize_t fake_send(void* context, int, const void*, size_t length, int flags) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_send requires state");
  state->send_lengths.push_back(length);
  state->send_flags.push_back(flags);
  const FakeIoAction& action = next_action(state->send_actions, &state->send_index, "send");
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

ssize_t fake_recv(void* context, int, void* buffer, size_t length, int) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_recv requires state");
  state->recv_lengths.push_back(length);
  const FakeIoAction& action = next_action(state->recv_actions, &state->recv_index, "recv");
  if (action.result < 0) {
    errno = action.error;
    return action.result;
  }
  expect(static_cast<size_t>(action.result) <= action.bytes.size(), "fake_recv bytes must cover result");
  expect(static_cast<size_t>(action.result) <= length, "fake_recv result must fit caller buffer");
  if (action.result > 0) {
    std::memcpy(buffer, action.bytes.data(), static_cast<size_t>(action.result));
  }
  return action.result;
}

ssize_t fake_sendto(void* context, int, const void*, size_t length, int, const sockaddr* address, socklen_t) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_sendto requires state");
  const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address);
  state->last_sendto_addr = ipv4->sin_addr.s_addr;
  state->last_sendto_port = ntohs(ipv4->sin_port);
  state->sendto_lengths.push_back(length);
  const FakeIoAction& action = next_action(state->sendto_actions, &state->sendto_index, "sendto");
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

ssize_t fake_recvfrom(void* context,
                      int,
                      void* buffer,
                      size_t length,
                      int,
                      sockaddr* address,
                      socklen_t* address_length) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_recvfrom requires state");
  state->recvfrom_lengths.push_back(length);
  const FakeIoAction& action = next_action(state->recvfrom_actions, &state->recvfrom_index, "recvfrom");
  if (action.result < 0) {
    errno = action.error;
    return action.result;
  }
  expect(static_cast<size_t>(action.result) <= action.bytes.size(), "fake_recvfrom bytes must cover result");
  expect(static_cast<size_t>(action.result) <= length, "fake_recvfrom result must fit caller buffer");
  expect(address != nullptr, "fake_recvfrom requires peer address");
  expect(address_length != nullptr, "fake_recvfrom requires peer length");
  expect(*address_length >= static_cast<socklen_t>(sizeof(sockaddr_in)), "fake_recvfrom peer buffer too small");
  auto* ipv4 = reinterpret_cast<sockaddr_in*>(address);
  std::memset(ipv4, 0, sizeof(*ipv4));
  ipv4->sin_family = action.peer_family;
  ipv4->sin_addr.s_addr = action.peer_addr;
  ipv4->sin_port = htons(action.peer_port);
  *address_length = static_cast<socklen_t>(sizeof(sockaddr_in));
  if (action.result > 0) {
    std::memcpy(buffer, action.bytes.data(), static_cast<size_t>(action.result));
  }
  return action.result;
}

int fake_close(void* context, int fd) {
  auto* state = static_cast<FakeState*>(context);
  expect(state != nullptr, "fake_close requires state");
  state->close_count += 1;
  state->closed_fds.push_back(fd);
  if (state->close_index >= state->close_actions.size()) {
    return 0;
  }
  const FakeCloseAction& action = state->close_actions[state->close_index];
  state->close_index += 1;
  if (action.result < 0) {
    errno = action.error;
  }
  return action.result;
}

int64_t fake_now_ms(void* context) {
  auto* state = static_cast<FakeState*>(context);
  if (state == nullptr || state->now_ms_values.empty()) {
    return 0;
  }
  if (state->now_ms_index >= state->now_ms_values.size()) {
    return state->now_ms_values.back();
  }
  const int64_t result = state->now_ms_values[state->now_ms_index];
  state->now_ms_index += 1;
  return result;
}

PosixOps make_fake_ops(FakeState* state) {
  PosixOps ops {};
  ops.context = state;
  ops.socket_fn = &fake_socket;
  ops.fcntl_fn = &fake_fcntl;
  ops.connect_fn = &fake_connect;
  ops.poll_fn = &fake_poll;
  ops.getsockopt_fn = &fake_getsockopt;
  ops.setsockopt_fn = &fake_setsockopt;
  ops.send_fn = &fake_send;
  ops.recv_fn = &fake_recv;
  ops.sendto_fn = &fake_sendto;
  ops.recvfrom_fn = &fake_recvfrom;
  ops.close_fn = &fake_close;
  ops.monotonic_now_ms_fn = &fake_now_ms;
  return ops;
}

void expect_all_actions_consumed(const FakeState& state) {
  expect_eq(state.socket_index, state.socket_results.size(), "all socket actions should be consumed");
  expect_eq(state.fcntl_get_index, state.fcntl_get_results.size(), "all fcntl get actions should be consumed");
  expect_eq(state.fcntl_set_index, state.fcntl_set_results.size(), "all fcntl set actions should be consumed");
  expect_eq(state.connect_index, state.connect_actions.size(), "all connect actions should be consumed");
  expect_eq(state.poll_index, state.poll_actions.size(), "all poll actions should be consumed");
  expect_eq(state.getsockopt_index, state.getsockopt_actions.size(), "all getsockopt actions should be consumed");
  expect_eq(state.setsockopt_index, state.setsockopt_actions.size(), "all setsockopt actions should be consumed");
  expect_eq(state.send_index, state.send_actions.size(), "all send actions should be consumed");
  expect_eq(state.recv_index, state.recv_actions.size(), "all recv actions should be consumed");
  expect_eq(state.sendto_index, state.sendto_actions.size(), "all sendto actions should be consumed");
  expect_eq(state.recvfrom_index, state.recvfrom_actions.size(), "all recvfrom actions should be consumed");
}

class TcpEchoServer {
 public:
  explicit TcpEchoServer(std::vector<uint8_t> response_payload)
      : response_payload_(std::move(response_payload)), thread_([this]() { run(); }) {
    wait_until_ready();
  }

  ~TcpEchoServer() {
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  uint16_t port() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return port_;
  }

  void assert_clean() const {
    std::lock_guard<std::mutex> lock(mutex_);
    expect(error_.empty(), error_);
  }

 private:
  void wait_until_ready() {
    for (size_t attempts = 0; attempts < 500; ++attempts) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (ready_) {
          if (!error_.empty()) {
            throw TestFailure(error_);
          }
          return;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    throw TestFailure("tcp echo server did not become ready");
  }

  void set_error(const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    error_ = message;
    ready_ = true;
  }

  void run() {
    const int listener = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
      set_error("tcp server socket failed");
      return;
    }

    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons(0);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
      ::close(listener);
      set_error("tcp server bind failed");
      return;
    }
    if (::listen(listener, 1) != 0) {
      ::close(listener);
      set_error("tcp server listen failed");
      return;
    }

    sockaddr_in bound {};
    socklen_t bound_length = static_cast<socklen_t>(sizeof(bound));
    if (::getsockname(listener, reinterpret_cast<sockaddr*>(&bound), &bound_length) != 0) {
      ::close(listener);
      set_error("tcp server getsockname failed");
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      port_ = ntohs(bound.sin_port);
      ready_ = true;
    }

    const int client = ::accept(listener, nullptr, nullptr);
    if (client < 0) {
      ::close(listener);
      set_error("tcp server accept failed");
      return;
    }

    size_t sent = 0;
    while (sent < response_payload_.size()) {
      const ssize_t wrote =
          ::send(client, response_payload_.data() + sent, response_payload_.size() - sent, 0);
      if (wrote <= 0) {
        ::close(client);
        ::close(listener);
        set_error("tcp server send failed");
        return;
      }
      sent += static_cast<size_t>(wrote);
    }

    ::shutdown(client, SHUT_RDWR);
    ::close(client);
    ::close(listener);
  }

  mutable std::mutex mutex_;
  std::vector<uint8_t> response_payload_;
  std::thread thread_;
  uint16_t port_ = 0;
  bool ready_ = false;
  std::string error_;
};

class UdpEchoServer {
 public:
  UdpEchoServer() : thread_([this]() { run(); }) { wait_until_ready(); }

  ~UdpEchoServer() {
    if (thread_.joinable()) {
      thread_.join();
    }
  }

  uint16_t port() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return port_;
  }

  void assert_clean() const {
    std::lock_guard<std::mutex> lock(mutex_);
    expect(error_.empty(), error_);
  }

 private:
  void wait_until_ready() {
    for (size_t attempts = 0; attempts < 500; ++attempts) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (ready_) {
          if (!error_.empty()) {
            throw TestFailure(error_);
          }
          return;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    throw TestFailure("udp echo server did not become ready");
  }

  void set_error(const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    error_ = message;
    ready_ = true;
  }

  void run() {
    const int socket_fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (socket_fd < 0) {
      set_error("udp server socket failed");
      return;
    }

    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons(0);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(socket_fd, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
      ::close(socket_fd);
      set_error("udp server bind failed");
      return;
    }

    sockaddr_in bound {};
    socklen_t bound_length = static_cast<socklen_t>(sizeof(bound));
    if (::getsockname(socket_fd, reinterpret_cast<sockaddr*>(&bound), &bound_length) != 0) {
      ::close(socket_fd);
      set_error("udp server getsockname failed");
      return;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      port_ = ntohs(bound.sin_port);
      ready_ = true;
    }

    std::array<uint8_t, 2048> buffer {};
    sockaddr_in peer {};
    socklen_t peer_length = static_cast<socklen_t>(sizeof(peer));
    const ssize_t received = ::recvfrom(socket_fd,
                                        buffer.data(),
                                        buffer.size(),
                                        0,
                                        reinterpret_cast<sockaddr*>(&peer),
                                        &peer_length);
    if (received <= 0) {
      ::close(socket_fd);
      set_error("udp server recvfrom failed");
      return;
    }

    size_t sent = 0;
    while (sent < static_cast<size_t>(received)) {
      const ssize_t wrote = ::sendto(socket_fd,
                                     buffer.data() + sent,
                                     static_cast<size_t>(received) - sent,
                                     0,
                                     reinterpret_cast<const sockaddr*>(&peer),
                                     peer_length);
      if (wrote <= 0) {
        ::close(socket_fd);
        set_error("udp server sendto failed");
        return;
      }
      sent += static_cast<size_t>(wrote);
    }

    ::close(socket_fd);
  }

  mutable std::mutex mutex_;
  std::thread thread_;
  uint16_t port_ = 0;
  bool ready_ = false;
  std::string error_;
};

ProbeResult run_with_fake(const ProbeRequest& request, FakeState* state) {
  return cmfa::probe::probe_socket_for_test(request, make_fake_ops(state));
}

int passthrough_fcntl(void*, int fd, int command, int value) {
  if (command == F_GETFL) {
    return ::fcntl(fd, command);
  }
  return ::fcntl(fd, command, value);
}

ssize_t passthrough_send(void*, int fd, const void* buffer, size_t length, int flags) {
  return ::send(fd, buffer, length, flags);
}

int make_closed_stream_socket_fd() {
#if defined(SO_NOSIGPIPE)
  const int listener = ::socket(AF_INET, SOCK_STREAM, 0);
  expect(listener >= 0, "tcp listener should be created");

  sockaddr_in address {};
  address.sin_family = AF_INET;
  address.sin_port = htons(0);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  expect_eq(::bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)), 0, "tcp listener bind should succeed");
  expect_eq(::listen(listener, 1), 0, "tcp listener listen should succeed");

  sockaddr_in bound {};
  socklen_t bound_length = static_cast<socklen_t>(sizeof(bound));
  expect_eq(::getsockname(listener, reinterpret_cast<sockaddr*>(&bound), &bound_length), 0, "tcp listener getsockname should succeed");

  const int client = ::socket(AF_INET, SOCK_STREAM, 0);
  expect(client >= 0, "tcp client should be created");
  expect_eq(::connect(client, reinterpret_cast<const sockaddr*>(&bound), bound_length), 0, "tcp client connect should succeed");

#if defined(SO_NOSIGPIPE)
  const int enabled = 1;
  expect_eq(::setsockopt(client,
                         SOL_SOCKET,
                         SO_NOSIGPIPE,
                         &enabled,
                         static_cast<socklen_t>(sizeof(enabled))),
            0,
            "tcp client SO_NOSIGPIPE should succeed");
#endif

  const int server = ::accept(listener, nullptr, nullptr);
  expect(server >= 0, "tcp server accept should succeed");
  expect_eq(::close(listener), 0, "tcp listener close should succeed");
  linger reset_peer {};
  reset_peer.l_onoff = 1;
  reset_peer.l_linger = 0;
  expect_eq(::setsockopt(server,
                         SOL_SOCKET,
                         SO_LINGER,
                         &reset_peer,
                         static_cast<socklen_t>(sizeof(reset_peer))),
            0,
            "tcp server linger reset should succeed");
  expect_eq(::shutdown(server, SHUT_RDWR), 0, "tcp server shutdown should succeed");
  expect_eq(::close(server), 0, "tcp server close should succeed");
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  return client;
#else
  int pair[2] = {-1, -1};
  expect_eq(::socketpair(AF_UNIX, SOCK_STREAM, 0, pair), 0, "socketpair should succeed");
  expect_eq(::close(pair[1]), 0, "peer close should succeed");
  return pair[0];
#endif
}

void test_invalid_ipv4_literal() {
  FakeState state;
  state.now_ms_values = {0};
  const std::vector<uint8_t> payload = bytes_from_string("x");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "example.com";
  request.port = 80;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "invalid IPv4 should fail");
  expect_failure(result, ProbeFailure::InvalidArgument, "invalid IPv4 should map to invalid argument");
  expect_eq(state.socket_index, static_cast<size_t>(0), "invalid IPv4 should not create a socket");
}

void test_invalid_port() {
  FakeState state;
  state.now_ms_values = {0};
  const std::vector<uint8_t> payload = bytes_from_string("x");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 0;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "port zero should fail");
  expect_failure(result, ProbeFailure::InvalidArgument, "port zero should map to invalid argument");
  expect_eq(state.socket_index, static_cast<size_t>(0), "invalid port should not create a socket");
}

void test_invalid_tcp_payload_size() {
  FakeState state;
  state.now_ms_values = {0};
  std::vector<uint8_t> payload(8193, static_cast<uint8_t>('a'));
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 8080;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "oversized tcp payload should fail");
  expect_failure(result, ProbeFailure::InvalidArgument, "oversized tcp payload should map to invalid argument");
}

void test_invalid_udp_payload_size() {
  FakeState state;
  state.now_ms_values = {0};
  std::vector<uint8_t> payload(1025, static_cast<uint8_t>('b'));
  ProbeRequest request {};
  request.kind = ProbeKind::UdpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 5353;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "oversized udp payload should fail");
  expect_failure(result, ProbeFailure::InvalidArgument, "oversized udp payload should map to invalid argument");
}

void test_invalid_tcp_http_payload_size() {
  FakeState state;
  state.now_ms_values = {0};
  std::vector<uint8_t> payload(8193, static_cast<uint8_t>('h'));
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 8080;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "oversized tcpHttp payload should fail");
  expect_failure(result, ProbeFailure::InvalidArgument, "oversized tcpHttp payload should map to invalid argument");
}

void test_timeout_clamps_to_minimum() {
  FakeState state;
  state.socket_results = {11};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {1000, 1000, 1000};
  const std::vector<uint8_t> payload = bytes_from_string("z");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9001;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "short timeout should clamp then time out");
  expect_failure(result, ProbeFailure::Timeout, "timeout should map to timeout failure");
  expect_eq(state.last_poll_timeout, 250, "timeout should clamp to minimum 250ms");
  expect_eq(state.close_count, 1, "timed out connect should close once");
  expect_all_actions_consumed(state);
}

void test_timeout_clamps_to_maximum() {
  FakeState state;
  state.socket_results = {12};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {2000, 2000, 2000};
  const std::vector<uint8_t> payload = bytes_from_string("q");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9002;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 60000;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "long timeout should clamp then time out");
  expect_failure(result, ProbeFailure::Timeout, "long timeout should still map to timeout failure");
  expect_eq(state.last_poll_timeout, 10000, "timeout should clamp to maximum 10000ms");
  expect_eq(state.close_count, 1, "timed out connect should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_success_handles_eintr_and_short_io() {
  FakeState state;
  state.socket_results = {13};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {
      {-1, 0, EINTR},
      {1, POLLOUT, 0},
  };
  state.getsockopt_actions = {{0, 0, 0}};
  state.send_actions = {
      {-1, EINTR, {}},
      {2, 0, {}},
      {3, 0, {}},
  };
  state.recv_actions = {
      {-1, EINTR, {}},
      {2, 0, bytes_from_string("he")},
      {3, 0, bytes_from_string("llo")},
      {0, 0, {}},
  };
  state.close_actions = {{-1, EIO}};
  state.now_ms_values = {100, 100, 110, 120, 130};
  const std::vector<uint8_t> payload = bytes_from_string("hello");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9100;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Pass, "tcp success path should pass");
  expect_failure(result, ProbeFailure::None, "tcp success path should have no failure");
  expect_eq(result.bytes_sent, 5U, "tcp success path should count sent bytes");
  expect_eq(result.bytes_received, 5U, "tcp success path should count received bytes");
  expect_eq(result.duration_ms, 30U, "tcp success path should use monotonic duration");
  expect_eq(state.close_count, 1, "tcp success path should close once even if close fails");
  expect_eq(state.closed_fds.front(), 13, "tcp success path should close the socket fd");
  expect_eq(state.last_connect_addr, ipv4_to_network_order("127.0.0.1"), "tcp connect should use requested IPv4");
  expect_eq(state.last_connect_port, static_cast<uint16_t>(9100), "tcp connect should use requested port");
  expect_eq(state.send_lengths.size(), static_cast<size_t>(3), "tcp success should retry short sends");
  expect_eq(state.recv_lengths.size(), static_cast<size_t>(4), "tcp success should verify eof after matching payload");
#if defined(SO_NOSIGPIPE)
  expect_eq(state.setsockopt_levels.size(), static_cast<size_t>(1), "tcp success should configure SO_NOSIGPIPE once");
  expect_eq(state.setsockopt_levels[0], SOL_SOCKET, "SO_NOSIGPIPE should use SOL_SOCKET");
  expect_eq(state.setsockopt_names[0], SO_NOSIGPIPE, "SO_NOSIGPIPE option should be configured");
  expect_eq(state.setsockopt_values[0], 1, "SO_NOSIGPIPE should be enabled");
#elif defined(MSG_NOSIGNAL)
  expect_eq(state.send_flags.size(), static_cast<size_t>(3), "tcp success should capture send flags");
  expect_eq(state.send_flags[0], MSG_NOSIGNAL, "tcp send should use MSG_NOSIGNAL");
#endif
  expect_all_actions_consumed(state);
}

void test_tcp_connect_so_error_maps_to_connect_failed() {
  FakeState state;
  state.socket_results = {14};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {{1, POLLOUT, 0}};
  state.getsockopt_actions = {{0, 0, ECONNREFUSED}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {10, 10, 15};
  const std::vector<uint8_t> payload = bytes_from_string("hi");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9101;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "SO_ERROR should fail the connect");
  expect_failure(result, ProbeFailure::ConnectFailed, "SO_ERROR should map to connect failed");
  expect_eq(state.close_count, 1, "connect failure should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_connect_timeout() {
  FakeState state;
  state.socket_results = {15};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {20, 20, 40};
  const std::vector<uint8_t> payload = bytes_from_string("hi");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9102;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 300;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "connect timeout should return timeout outcome");
  expect_failure(result, ProbeFailure::Timeout, "connect timeout should map to timeout");
  expect_eq(state.close_count, 1, "connect timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_send_timeout() {
  FakeState state;
  state.socket_results = {16};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{-1, EAGAIN, {}}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {30, 30, 35, 40};
  const std::vector<uint8_t> payload = bytes_from_string("hey");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9103;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 400;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "send timeout should return timeout outcome");
  expect_failure(result, ProbeFailure::Timeout, "send timeout should map to timeout");
  expect_eq(state.close_count, 1, "send timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_recv_timeout() {
  FakeState state;
  state.socket_results = {17};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{3, 0, {}}};
  state.recv_actions = {{-1, EAGAIN, {}}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {40, 40, 45, 50};
  const std::vector<uint8_t> payload = bytes_from_string("hey");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9104;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 400;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "recv timeout should return timeout outcome");
  expect_failure(result, ProbeFailure::Timeout, "recv timeout should map to timeout");
  expect_eq(result.bytes_sent, 3U, "recv timeout should keep sent bytes");
  expect_eq(state.close_count, 1, "recv timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_payload_mismatch() {
  FakeState state;
  state.socket_results = {18};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{4, 0, {}}};
  state.recv_actions = {{4, 0, bytes_from_string("FAIL")}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {50, 50, 60};
  const std::vector<uint8_t> payload = bytes_from_string("pass");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9105;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 400;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "payload mismatch should fail");
  expect_failure(result, ProbeFailure::PayloadMismatch, "payload mismatch should map correctly");
  expect_eq(result.bytes_sent, 4U, "payload mismatch should report bytes sent");
  expect_eq(result.bytes_received, 4U, "payload mismatch should report bytes received");
  expect_eq(state.close_count, 1, "payload mismatch should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_short_send_respects_single_deadline() {
  FakeState state;
  state.socket_results = {21};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {
      {1, 0, {}},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 101, 400, 450};
  const std::vector<uint8_t> payload = bytes_from_string("ab");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9107;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 250;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "short send should not overrun the original deadline");
  expect_failure(result, ProbeFailure::Timeout, "short send deadline overrun should map to timeout");
  expect_eq(result.bytes_sent, 1U, "timeout after short send should preserve partial sent bytes");
  expect_eq(result.bytes_received, 0U, "timeout before recv should not report received bytes");
  expect_eq(state.close_count, 1, "short send timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_connect_eintr_respects_single_deadline() {
  FakeState state;
  state.socket_results = {22};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {
      {-1, EINTR},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 101, 400, 450};
  const std::vector<uint8_t> payload = bytes_from_string("go");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9108;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 250;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "connect EINTR retry should not overrun the original deadline");
  expect_failure(result, ProbeFailure::Timeout, "connect EINTR deadline overrun should map to timeout");
  expect_eq(result.bytes_sent, 0U, "connect timeout should not report sent bytes");
  expect_eq(result.bytes_received, 0U, "connect timeout should not report received bytes");
  expect_eq(state.close_count, 1, "connect EINTR timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_exact_echo_requires_eof_after_match() {
  FakeState state;
  state.socket_results = {23};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{4, 0, {}}};
  state.recv_actions = {
      {4, 0, bytes_from_string("ping")},
      {1, 0, bytes_from_string("!")},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120, 140};
  const std::vector<uint8_t> payload = bytes_from_string("ping");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9109;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "tcp exact echo should fail when trailing bytes exist");
  expect_failure(result, ProbeFailure::PayloadMismatch, "trailing tcp bytes should map to payload mismatch");
  expect_eq(result.bytes_sent, 4U, "trailing byte mismatch should preserve sent bytes");
  expect_eq(result.bytes_received, 5U, "trailing byte mismatch should include the suffix byte");
  expect_eq(state.close_count, 1, "trailing byte mismatch should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_exact_echo_with_eof_passes_fake() {
  FakeState state;
  state.socket_results = {24};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{4, 0, {}}};
  state.recv_actions = {
      {4, 0, bytes_from_string("pong")},
      {0, 0, {}},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120, 140};
  const std::vector<uint8_t> payload = bytes_from_string("pong");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9110;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Pass, "tcp exact echo should pass when payload match is followed by eof");
  expect_failure(result, ProbeFailure::None, "tcp exact echo with eof should keep no failure");
  expect_eq(result.bytes_sent, 4U, "exact echo pass should preserve sent bytes");
  expect_eq(result.bytes_received, 4U, "exact echo pass should not count eof as payload");
  expect_eq(state.close_count, 1, "exact echo pass should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_http_success_handles_eintr_short_io_and_stops_after_status_line() {
  FakeState state;
  state.socket_results = {26};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{-1, EINPROGRESS}};
  state.poll_actions = {
      {-1, 0, EINTR},
      {1, POLLOUT, 0},
  };
  state.getsockopt_actions = {{0, 0, 0}};
  state.send_actions = {
      {-1, EINTR, {}},
      {5, 0, {}},
      {6, 0, {}},
      {5, 0, {}},
  };
  state.recv_actions = {
      {-1, EINTR, {}},
      {8, 0, bytes_from_string("HTTP/1.1")},
      {9, 0, bytes_from_string(" 200 OK\r\n")},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 110, 120, 130};
  const std::vector<uint8_t> payload = bytes_from_string("GET / HTTP/1.1\r\n");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9200;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Pass, "tcpHttp status-line success should pass");
  expect_failure(result, ProbeFailure::None, "tcpHttp success should keep no failure");
  expect_eq(result.bytes_sent, static_cast<uint32_t>(payload.size()), "tcpHttp should count sent bytes");
  expect_eq(result.bytes_received, 17U, "tcpHttp should count received status-line bytes");
  expect_eq(state.close_count, 1, "tcpHttp success should close once");
  expect_eq(state.send_lengths.size(), static_cast<size_t>(4), "tcpHttp should retry short sends until the full request is written");
  expect_eq(state.recv_lengths.size(), static_cast<size_t>(3), "tcpHttp should stop reading after status line");
  expect_all_actions_consumed(state);
}

void test_tcp_http_invalid_status_line_maps_payload_mismatch() {
  FakeState state;
  state.socket_results = {27};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{3, 0, {}}};
  state.recv_actions = {{12, 0, bytes_from_string("NOTHTTP\r\nBAD")}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120};
  const std::vector<uint8_t> payload = bytes_from_string("GET");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9201;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "invalid http status line should fail");
  expect_failure(result, ProbeFailure::PayloadMismatch, "invalid http status line should map to payload mismatch");
  expect_eq(state.close_count, 1, "invalid http status line should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_http_rejects_status_without_required_reason_separator() {
  FakeState state;
  state.socket_results = {30};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{3, 0, {}}};
  state.recv_actions = {{14, 0, bytes_from_string("HTTP/1.1 200\r\n")}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120};
  const std::vector<uint8_t> payload = bytes_from_string("GET");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9204;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "status without reason separator should fail");
  expect_failure(result, ProbeFailure::PayloadMismatch, "missing reason separator should map to payload mismatch");
  expect_eq(state.close_count, 1, "missing reason separator should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_http_eof_before_status_line_maps_recv_failed() {
  FakeState state;
  state.socket_results = {28};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{3, 0, {}}};
  state.recv_actions = {
      {5, 0, bytes_from_string("HTTP/")},
      {0, 0, {}},
  };
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120, 140};
  const std::vector<uint8_t> payload = bytes_from_string("GET");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9202;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "eof before status line should fail");
  expect_failure(result, ProbeFailure::RecvFailed, "eof before status line should map to recv failed");
  expect_eq(result.bytes_received, 5U, "partial status line bytes should be counted");
  expect_eq(state.close_count, 1, "eof before status line should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_http_timeout_maps_timeout() {
  FakeState state;
  state.socket_results = {29};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{3, 0, {}}};
  state.recv_actions = {{-1, EAGAIN, {}}};
  state.poll_actions = {{0, 0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 120, 140};
  const std::vector<uint8_t> payload = bytes_from_string("GET");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9203;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Timeout, "tcpHttp timeout should return timeout");
  expect_failure(result, ProbeFailure::Timeout, "tcpHttp timeout should map to timeout");
  expect_eq(state.close_count, 1, "tcpHttp timeout should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_send_passes_after_complete_marker_write_without_receiving() {
  FakeState state;
  state.socket_results = {31};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{2, 0, {}}, {2, 0, {}}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 110, 120};
  const std::vector<uint8_t> payload = bytes_from_string("MARK");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpSend;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9443;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Pass, "tcpSend complete marker write should pass");
  expect_failure(result, ProbeFailure::None, "tcpSend success should keep no failure");
  expect_eq(result.bytes_sent, 4U, "tcpSend should count every sent byte");
  expect_eq(result.bytes_received, 0U, "tcpSend must not read a response");
  expect_eq(state.recv_lengths.size(), static_cast<size_t>(0), "tcpSend must not call recv");
  expect_eq(state.close_count, 1, "tcpSend success should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_exchange_waits_for_remote_bytes_after_complete_marker_write() {
  FakeState state;
  state.socket_results = {32};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{4, 0, {}}};
  state.recv_actions = {{8, 0, bytes_from_string("SSH-2.0-")}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 110, 120, 130};
  const std::vector<uint8_t> payload = bytes_from_string("MARK");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpExchange;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9443;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Pass, "tcpExchange remote bytes should pass");
  expect_failure(result, ProbeFailure::None, "tcpExchange success should keep no failure");
  expect_eq(result.bytes_sent, 4U, "tcpExchange should count sent marker bytes");
  expect_eq(result.bytes_received, 8U, "tcpExchange should count remote bytes");
  expect_eq(state.close_count, 1, "tcpExchange success should close once");
  expect_all_actions_consumed(state);
}

void test_udp_unexpected_peer_mismatch() {
  FakeState state;
  state.socket_results = {19};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.sendto_actions = {{3, 0, {}}};
  state.recvfrom_actions = {{
      3,
      0,
      bytes_from_string("udp"),
      ipv4_to_network_order("127.0.0.2"),
      5354,
      AF_INET,
  }};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {60, 60, 70};
  const std::vector<uint8_t> payload = bytes_from_string("udp");
  ProbeRequest request {};
  request.kind = ProbeKind::UdpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 5353;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "unexpected udp peer should fail");
  expect_failure(result, ProbeFailure::PayloadMismatch, "unexpected udp peer should map to payload mismatch");
  expect_eq(result.bytes_sent, 3U, "udp mismatch should report bytes sent");
  expect_eq(result.bytes_received, 3U, "udp mismatch should report bytes received");
  expect_eq(state.last_sendto_addr, ipv4_to_network_order("127.0.0.1"), "udp send should target requested IPv4");
  expect_eq(state.last_sendto_port, static_cast<uint16_t>(5353), "udp send should target requested port");
  expect_eq(state.close_count, 1, "udp mismatch should close once");
  expect_all_actions_consumed(state);
}

void test_failure_path_closes_once_on_send_failure() {
  FakeState state;
  state.socket_results = {20};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.connect_actions = {{0, 0}};
  state.send_actions = {{-1, EPIPE, {}}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {70, 70, 75};
  const std::vector<uint8_t> payload = bytes_from_string("boom");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9106;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "send failure should fail");
  expect_failure(result, ProbeFailure::SendFailed, "send failure should map to send failed");
  expect_eq(state.close_count, 1, "send failure path should close once");
  expect_all_actions_consumed(state);
}

void test_tcp_peer_close_returns_send_failed_without_sigpipe() {
  FakeState state;
  state.socket_results = {make_closed_stream_socket_fd()};
  state.connect_actions = {{0, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 100, 110};
  const std::vector<uint8_t> payload = bytes_from_string("sigpipe");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9111;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  PosixOps ops = make_fake_ops(&state);
  ops.fcntl_fn = &passthrough_fcntl;
  ops.send_fn = &passthrough_send;

  const ProbeResult result = cmfa::probe::probe_socket_for_test(request, ops);
  expect_outcome(result, ProbeOutcome::Fail, "closed peer should fail send without terminating the process");
  expect_eq(static_cast<int>(result.failure),
            static_cast<int>(ProbeFailure::SendFailed),
            "closed peer should map to send failed");
  expect_eq(state.close_count, 1, "closed peer send failure should close once");
  expect_all_actions_consumed(state);
}

#if defined(SO_NOSIGPIPE)
void test_tcp_nosigpipe_configuration_failure_maps_to_connect_failed() {
  FakeState state;
  state.socket_results = {25};
  state.fcntl_get_results = {0};
  state.fcntl_set_results = {0};
  state.setsockopt_actions = {{-1, EINVAL, 0}};
  state.close_actions = {{0, 0}};
  state.now_ms_values = {100, 110};
  const std::vector<uint8_t> payload = bytes_from_string("pipe");
  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = 9112;
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 500;

  const ProbeResult result = run_with_fake(request, &state);
  expect_outcome(result, ProbeOutcome::Fail, "SO_NOSIGPIPE setup failure should fail");
  expect_failure(result, ProbeFailure::ConnectFailed, "SO_NOSIGPIPE setup failure should map to connect failed");
  expect_eq(state.close_count, 1, "SO_NOSIGPIPE setup failure should close once");
  expect_all_actions_consumed(state);
}
#endif

void test_real_loopback_tcp_echo() {
  const std::vector<uint8_t> payload = bytes_from_string("real-tcp");
  TcpEchoServer server(payload);

  ProbeRequest request {};
  request.kind = ProbeKind::TcpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = server.port();
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = cmfa::probe::probe_socket(request);
  expect_outcome(result, ProbeOutcome::Pass, "real tcp echo should pass");
  expect_failure(result, ProbeFailure::None, "real tcp echo should have no failure");
  expect_eq(result.bytes_sent, static_cast<uint32_t>(payload.size()), "real tcp echo should report sent bytes");
  expect_eq(result.bytes_received, static_cast<uint32_t>(payload.size()), "real tcp echo should report received bytes");
  server.assert_clean();
}

void test_real_loopback_udp_echo() {
  const std::vector<uint8_t> payload = bytes_from_string("real-udp");
  UdpEchoServer server;

  ProbeRequest request {};
  request.kind = ProbeKind::UdpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = server.port();
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = cmfa::probe::probe_socket(request);
  expect_outcome(result, ProbeOutcome::Pass, "real udp echo should pass");
  expect_failure(result, ProbeFailure::None, "real udp echo should have no failure");
  expect_eq(result.bytes_sent, static_cast<uint32_t>(payload.size()), "real udp echo should report sent bytes");
  expect_eq(result.bytes_received, static_cast<uint32_t>(payload.size()), "real udp echo should report received bytes");
  server.assert_clean();
}

void test_real_loopback_dns_udp_echo() {
  const std::vector<uint8_t> payload = dns_query_payload();
  UdpEchoServer server;

  ProbeRequest request {};
  request.kind = ProbeKind::DnsUdpEcho;
  request.host_ipv4 = "127.0.0.1";
  request.port = server.port();
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = cmfa::probe::probe_socket(request);
  expect_outcome(result, ProbeOutcome::Pass, "real dns udp echo should pass");
  expect_failure(result, ProbeFailure::None, "real dns udp echo should have no failure");
  expect_eq(result.bytes_sent, static_cast<uint32_t>(payload.size()), "real dns echo should report sent bytes");
  expect_eq(result.bytes_received, static_cast<uint32_t>(payload.size()), "real dns echo should report received bytes");
  server.assert_clean();
}

void test_real_loopback_tcp_http_status_line() {
  const std::vector<uint8_t> payload = bytes_from_string("GET / HTTP/1.1\r\n");
  TcpEchoServer server(http_status_payload("HTTP/1.1 204 No Content\r\nBODY"));

  ProbeRequest request {};
  request.kind = ProbeKind::TcpHttp;
  request.host_ipv4 = "127.0.0.1";
  request.port = server.port();
  request.payload = payload.data();
  request.payload_size = payload.size();
  request.timeout_ms = 1000;

  const ProbeResult result = cmfa::probe::probe_socket(request);
  expect_outcome(result, ProbeOutcome::Pass, "real tcpHttp should pass on valid status line");
  expect_failure(result, ProbeFailure::None, "real tcpHttp should have no failure");
  expect_eq(result.bytes_sent, static_cast<uint32_t>(payload.size()), "real tcpHttp should report sent bytes");
  expect(result.bytes_received >= 25U, "real tcpHttp should report received status-line bytes");
  server.assert_clean();
}

struct TestCase {
  const char* name;
  void (*run)();
};

}  // namespace

int main() {
#if defined(SO_NOSIGPIPE)
  const std::array<TestCase, 32> tests = {{
#else
  const std::array<TestCase, 31> tests = {{
#endif
      {"invalid_ipv4_literal", &test_invalid_ipv4_literal},
      {"invalid_port", &test_invalid_port},
      {"invalid_tcp_payload_size", &test_invalid_tcp_payload_size},
      {"invalid_udp_payload_size", &test_invalid_udp_payload_size},
      {"invalid_tcp_http_payload_size", &test_invalid_tcp_http_payload_size},
      {"timeout_clamps_to_minimum", &test_timeout_clamps_to_minimum},
      {"timeout_clamps_to_maximum", &test_timeout_clamps_to_maximum},
      {"tcp_success_handles_eintr_and_short_io", &test_tcp_success_handles_eintr_and_short_io},
      {"tcp_connect_so_error_maps_to_connect_failed", &test_tcp_connect_so_error_maps_to_connect_failed},
      {"tcp_connect_timeout", &test_tcp_connect_timeout},
      {"tcp_send_timeout", &test_tcp_send_timeout},
      {"tcp_recv_timeout", &test_tcp_recv_timeout},
      {"tcp_payload_mismatch", &test_tcp_payload_mismatch},
      {"tcp_short_send_respects_single_deadline", &test_tcp_short_send_respects_single_deadline},
      {"tcp_connect_eintr_respects_single_deadline", &test_tcp_connect_eintr_respects_single_deadline},
      {"tcp_exact_echo_requires_eof_after_match", &test_tcp_exact_echo_requires_eof_after_match},
      {"tcp_exact_echo_with_eof_passes_fake", &test_tcp_exact_echo_with_eof_passes_fake},
      {"tcp_http_success_handles_eintr_short_io_and_stops_after_status_line", &test_tcp_http_success_handles_eintr_short_io_and_stops_after_status_line},
      {"tcp_http_invalid_status_line_maps_payload_mismatch", &test_tcp_http_invalid_status_line_maps_payload_mismatch},
      {"tcp_http_rejects_status_without_required_reason_separator", &test_tcp_http_rejects_status_without_required_reason_separator},
      {"tcp_http_eof_before_status_line_maps_recv_failed", &test_tcp_http_eof_before_status_line_maps_recv_failed},
      {"tcp_http_timeout_maps_timeout", &test_tcp_http_timeout_maps_timeout},
      {"tcp_send_passes_after_complete_marker_write_without_receiving", &test_tcp_send_passes_after_complete_marker_write_without_receiving},
      {"tcp_exchange_waits_for_remote_bytes_after_complete_marker_write", &test_tcp_exchange_waits_for_remote_bytes_after_complete_marker_write},
      {"udp_unexpected_peer_mismatch", &test_udp_unexpected_peer_mismatch},
      {"failure_path_closes_once_on_send_failure", &test_failure_path_closes_once_on_send_failure},
      {"tcp_peer_close_returns_send_failed_without_sigpipe", &test_tcp_peer_close_returns_send_failed_without_sigpipe},
#if defined(SO_NOSIGPIPE)
      {"tcp_nosigpipe_configuration_failure_maps_to_connect_failed", &test_tcp_nosigpipe_configuration_failure_maps_to_connect_failed},
#endif
      {"real_loopback_tcp_echo", &test_real_loopback_tcp_echo},
      {"real_loopback_tcp_http_status_line", &test_real_loopback_tcp_http_status_line},
      {"real_loopback_udp_echo", &test_real_loopback_udp_echo},
      {"real_loopback_dns_udp_echo", &test_real_loopback_dns_udp_echo},
  }};

  try {
    for (const TestCase& test : tests) {
      test.run();
    }
    std::cout << "traffic_probe_native_core_test: " << tests.size() << " passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "traffic_probe_native_core_test failure: " << error.what() << '\n';
    return 1;
  }
}
