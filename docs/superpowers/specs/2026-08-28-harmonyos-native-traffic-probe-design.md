# HarmonyOS Native Traffic Probe Design

**Date:** 2026-08-28
**Scope:** test-only `harmony/traffic-probe` HAP
**Target:** HarmonyOS 6.x, API 20+, arm64-v8a

## Purpose

The physical-phone Phase 4 proof needs an external application whose TCP, UDP,
and DNS-format UDP packets follow ordinary POSIX routing into the VPN TUN.
On the verification phone, the existing NetworkKit HTTP/socket probe reached
the controlled LAN origin while the TUN journal remained unchanged, both
before and after recovery. The probe therefore cannot falsify global capture
on this platform.

The test-only probe will add one minimal N-API addon that creates POSIX sockets.
It does not enter the production HAP and does not implement a proxy, VPN, DNS
resolver, configuration loader, logger, or persistent store.

## Boundary

- Production remains `com.github.kr328.clash.harmony` and continues to exclude
  only itself from VPN capture.
- The probe remains the unrelated bundle `com.cmfa.phase4.trafficprobe`.
- The probe keeps only `ohos.permission.INTERNET`.
- `libprobeentry.so` is allowed only in the probe HAP. Production package
  inspection rejects its name, resources, types, and symbols.
- The addon links no mihomo/core library and exports no `cmfa_*`, `dlopen`, or
  `dlsym` surface.
- Native inspection treats the addon as the explicit `probeAddon` component.
  Package inspection must pass that component name directly; basename
  inference is forbidden because the existing `probe` component describes the
  unrelated Go ABI probe.
- `probeAddon` has its own DT_NEEDED/export contract. It must include the
  Harmony N-API runtime and platform C runtime dependencies used by the built
  addon, must exclude `libcmfa_mihomo.so`, and may expose only normal ELF
  lifecycle symbols. N-API registration is verified separately from public
  ELF exports.

## API

```ts
type ProbeSocketKind = 'tcpEcho' | 'udpEcho' | 'dnsUdpEcho';

interface ProbeSocketRequest {
  kind: ProbeSocketKind;
  hostIpv4: string;
  port: number;
  payload: ArrayBuffer;
  timeoutMs: number;
}

interface ProbeSocketResult {
  outcome: 'pass' | 'fail' | 'timeout';
  bytesSent: number;
  bytesReceived: number;
  durationMs: number;
  failureCode?: 'INVALID_ARGUMENT' | 'CONNECT_FAILED' | 'SEND_FAILED' |
    'RECV_FAILED' | 'TIMEOUT' | 'PAYLOAD_MISMATCH';
}

declare function probeSocket(request: ProbeSocketRequest): Promise<ProbeSocketResult>;
```

The addon accepts numeric IPv4 only. TCP sends the complete payload and reads
the exact echo. UDP and DNS-format UDP use the same datagram echo transport;
the kind only preserves protocol intent for fixed result mapping. The addon
never returns an address, payload, label, URL, certificate, session ID, or raw
system error.

## Runtime design

`probe_native_core.cpp` contains bounded socket operations and can be compiled
by host tests. `probe_native_napi.cpp` performs strict N-API decoding, copies
all JS data before queuing work, runs one `napi_async_work`, and creates the
result on the JS thread. Each operation owns one fd through RAII. The shared
host N-API shim is extended with the minimal async-work declarations and fake
implementation needed to prove queue, execute, complete, delete, and cleanup
behavior; the production addon does not gain a test-only API.

Sockets are non-blocking. `poll()` uses a monotonic deadline for connect,
send, and receive. Timeout is clamped to `250..10000 ms`; payload is bounded to
`1..8192` bytes for TCP and `1..1024` bytes for UDP. No detached thread,
subscription, TSFN, job registry, or cancel API is introduced.

## ArkTS integration

`NativeSocketProbe.ets` is the only file that imports `libprobeentry.so` and
implements a small injectable port. `DirectTrafficProbe` uses this port for:

- plain TCP exchange;
- IPv4 UDP echo;
- DNS-format IPv4 UDP echo.

`ProbeCommand` carries two independently validated destinations. `lanOrigin`
is used only by HTTPS and local HTTP/SOCKS checks. `externalOrigin` is a
validated public TCP exchange endpoint plus a separate canonical public IPv4
exact-echo target used only by the three native global operations. Missing,
private, reserved, partial, or non-canonical external values fail closed; they
never fall back to the LAN origin.

The TCP exchange request sends an opaque `cmfa-<flowId>` SSH identification
line, waits for any remote banner bytes, and never persists the response
content.

The first native port is explicitly IPv4-only. Even when NetworkKit reports
that IPv6 is available, `udp-ipv6` and `dns-packet-ipv6` produce `not-run` and
must not create an ArkTS UDP socket. A later IPv6 implementation must extend
the native port and its package/device tests first.

HTTPS, default DNS lookup, progress reporting, evidence writing, and local
HTTP/SOCKS checks remain in ArkTS. Evidence preserves the existing opaque
run/session/flow correlation and fixed outcome fields; native host/payload
values are never persisted. Tests scan serialized evidence and failure detail
to reject the request field name `hostIpv4`, raw payload/`.invalid` labels,
`errno`, POSIX symbolic errors, and operating-system error prose.

## Verification

- Host C++ tests cover validation, connect/send/receive, exact echo mismatch,
  UDP echo, timeout, short writes, EINTR, and single close.
- ArkTS tests use a fake `NativeSocketProbePort` and lock record/failure mapping.
- Structure tests require exactly one allowlisted `probeAddon`, require callers
  to select that component explicitly, and continue to reject any probe payload
  in production.
- Package inspection verifies the probe addon identity, needed-library
  allowlist, forbidden exports, absence of production core symbols, and the
  absence of dynamic-loader symbols.
- ArkTS/runner tests scan evidence JSON and failure detail for forbidden raw
  request, label, payload, address, and system-error material.
- The physical proof remains valid only when the external probe correlations
  match fresh TUN/mihomo records and positive counters.
- The pre-VPN public TCP exchange plus UDP/DNS exact echoes must pass. A
  VPN-round echo failure is classified only after one same-endpoint post-stop
  check.
- Connected-LAN native flows remain useful diagnostics but are not a global
  capture release gate because the platform selects the connected route.

## Non-goals

- No production diagnostic API.
- No TLS implementation in native code.
- No hostname resolution in native code.
- No native file, log, configuration, proxy, or VPN functionality.
- No simulator substitution for the physical-phone proof.
