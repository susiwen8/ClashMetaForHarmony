# HarmonyOS Phase 4 VPN/TUN and Global Traffic Capture Design

**Date:** 2026-08-16  
**Target:** HarmonyOS 6.x, API 20+, AArch64 phones  
**Primary verification device:** HarmonyOS 6.1, API 24, arm64-v8a  
**Delivery identity:** ordinary third-party application  
**Core:** mihomo `v1.19.29`

## 1. Purpose

Phase 4 adds real device-wide traffic capture to the native HarmonyOS rewrite.
The application will use the public `VpnExtensionAbility` API to create a TUN
interface and hand the resulting file descriptor to a native `sing-tun` data
plane connected directly to the existing mihomo runtime.

When VPN mode is running, all applications except the VPN application itself
are captured by default. TCP, UDP, DNS, IPv4, and IPv6 traffic are in scope.
The existing loopback HTTP and SOCKS listeners remain available through the
same mihomo runtime.

The phase is complete only after an independently packaged probe application
generates real traffic on the physical phone and the resulting redacted proof
correlates that traffic with TUN and mihomo observations.

## 2. Confirmed Product Boundary

This is an ordinary third-party application, not a system application, device
owner, or enterprise super-administrator application.

HarmonyOS provides three different proxy-related surfaces that must not be
conflated:

| Surface | Ordinary application support | Phase 4 behavior |
| --- | --- | --- |
| `VpnExtensionAbility` and TUN | Yes, after the system VPN trust dialog | Implemented; provides device-wide capture |
| Loopback HTTP/SOCKS proxy | Yes | Retained and exposed as **Local proxy** |
| OS global HTTP proxy setting | No public write API for an ordinary application | Not called and not claimed |

`connection.setAppHttpProxy()` changes only the calling application. The
network-independent global HTTP proxy APIs are under enterprise device
management and require a super administrator plus
`ohos.permission.ENTERPRISE_MANAGE_NETWORK`. The deprecated settings-data
proxy key requires the system-level `ohos.permission.MANAGE_SETTINGS` and is
not a valid compatibility path.

The UI and evidence therefore use these exact terms:

- **Local proxy**: loopback HTTP/SOCKS listeners for explicit client use.
- **VPN global capture**: TUN-based capture of device traffic.

They do not label the local listener as an automatically installed system
proxy.

## 3. Permissions and Manifest

The production entry module requests only the ordinary permissions needed for
the feature:

- `ohos.permission.INTERNET`
- `ohos.permission.KEEP_BACKGROUND_RUNNING`

The entry module declares a non-exported VPN extension ability with type
`vpn`. The application does **not** request:

- `ohos.permission.MANAGE_VPN`
- `ohos.permission.MANAGE_SETTINGS`
- `ohos.permission.ENTERPRISE_MANAGE_NETWORK`
- any enterprise device-manager privilege

The first call to `startVpnExtensionAbility()` lets HarmonyOS display and own
the VPN trust dialog. A denial is a normal permission outcome, not a request to
open settings or retry in a loop.

While running, the application presents the system VPN indicator and an
ongoing application notification that returns to the VPN status screen. The
VPN extension owns the continuous-task request and releases it during the same
idempotent stop sequence as the TUN runtime.

## 4. Architecture

```text
ArkUI
  -> VpnController
    -> VpnExtensionAbility
      -> VpnConnection creates TUN fd
        -> ArkTS CoreService
          -> Node-API facade
            -> platform-neutral C ABI
              -> sing-tun gVisor stack
                -> mihomo tunnel, rules, DNS, and outbound adapters
```

### 4.1 `entry`

The entry module owns:

- the VPN start/stop interaction and status presentation;
- the `VpnExtensionAbility` declaration and implementation;
- the system trust transition;
- creation and destruction of `VpnConnection`;
- construction of `VpnConfig`;
- the continuous notification;
- translation between HarmonyOS lifecycle callbacks and shared use cases.

The extension and UI initially run in the same application process. The
extension, not a page or view model, owns the active VPN session. Closing or
recreating a page does not invoke stop. A future move to a separate process
requires a separately reviewed IPC design and is outside this phase.

### 4.2 `shared`

The shared module adds platform-neutral contracts for:

- `VpnControllerPort`;
- `TunRuntimePort`;
- capture state and events;
- start options and validated route/DNS settings;
- structured permission, configuration, state, core, network, and system-limit
  errors;
- a serialized `VpnRuntimeCoordinator`.

The shared layer never imports NetworkKit, ability classes, N-API, or fd APIs.

### 4.3 `core`

The core boundary adds TUN operations without exposing HarmonyOS objects:

- start TUN from a validated integer fd and immutable options;
- stop TUN idempotently;
- query capture/runtime state and traffic counters;
- deliver structured TUN lifecycle and error events;
- request per-socket protection when the process-wide API is unavailable.

New C ABI fields are appended behind existing `struct_size` checks. Existing
callers with the older structure size remain valid. No Android JNI types,
`VpnService`, content URIs, or `/proc` UID lookups cross into `harmony/`.

### 4.4 Go/mihomo data plane

The Go backend uses the already pinned `github.com/metacubex/sing-tun`
dependency. It does not add a second proxy core or a TUN-to-SOCKS process.

The gVisor stack is the first supported stack because it is a user-space Go
implementation and does not depend on Linux route-management facilities that
HarmonyOS does not expose to the application. `AutoRoute` and
`AutoDetectInterface` stay disabled because HarmonyOS owns routes and outbound
escape.

The local HTTP/SOCKS listeners and TUN input feed the same mihomo tunnel. One
active configuration, rule engine, DNS engine, outbound pool, log stream, and
traffic accounting surface therefore serve both paths.

## 5. Runtime Ownership and State

The capture state is:

```text
Stopped
  -> AwaitingConsent
  -> Starting
  -> Running
  <-> Recovering
  -> Stopping
  -> Stopped

Any transition failure -> Error -> idempotent cleanup
```

Only confirmed platform and core events advance the state. Button presses do
not persist optimistic `Running` state.

The invariants are:

1. There is at most one mihomo runtime and at most one TUN runtime.
2. Commands are serialized through the existing command-queue pattern.
3. Repeated stop is successful and side-effect free.
4. A failed start leaves no listener, duplicated fd, TUN stack, continuous
   task, or `VpnConnection` behind.
5. The VPN application bundle is always excluded from capture.
6. Core outbound sockets must be protected before they connect.
7. `Running` means both the core and TUN packet loop are ready.
8. Persisted metadata is never treated as proof that a VPN survived process
   death; the live runtime is queried on UI reconstruction.

Switching from local-only mode to VPN mode performs a controlled core restart.
This closes outbound sockets created before socket protection was installed.
VPN mode then starts the same local listeners plus TUN capture.

## 6. Start and Data Flow

### 6.1 Start sequence

1. The UI submits the selected profile ID to `VpnRuntimeCoordinator`.
2. The coordinator verifies that a committed active profile exists and that no
   start or stop command is in flight.
3. `startVpnExtensionAbility()` triggers the system trust UI if required.
4. `VpnExtensionAbility.onCreate()` resolves the profile from application
   storage. Secrets are not placed in Want parameters.
5. The extension creates a `VpnConnection` and, on API 20+, generates a VPN ID.
6. The extension prepares outbound escape before creating any new core
   connection.
7. The extension calls `VpnConnection.create()` with the validated config.
8. Native code validates the returned fd and immediately calls `dup()`. The
   duplicate becomes the sole native/Go-owned descriptor. The platform
   connection retains its original handle until `destroy()`.
9. The core loads the committed mihomo configuration and starts its local
   listeners.
10. `sing-tun` starts on the duplicated fd and attaches to mihomo's tunnel.
11. The core emits readiness with the session correlation ID and non-secret
    listener/TUN metadata.
12. The extension starts its ongoing notification and the coordinator enters
    `Running`.

If any step fails, rollback executes in reverse ownership order.

### 6.2 VPN configuration

The initial full-capture configuration uses:

- IPv4 interface address in a private `/30` virtual subnet;
- IPv6 interface address in a private `/126` ULA subnet;
- routes `0.0.0.0/0` and `::/0`;
- virtual IPv4 and IPv6 DNS endpoints consumed by the TUN DNS hijack;
- MTU `1500` as the conservative cross-device default;
- non-blocking fd operation;
- IPv4 and IPv6 accepted;
- the VPN application's own bundle in the block list.

No user application allowlist or bypass list is part of this phase. All other
applications are captured. Per-application routing remains a later feature and
must preserve the self-exclusion invariant.

### 6.3 Outbound loop prevention

The VPN application's own bundle is excluded by `VpnConfig`. In addition:

- API 22+ calls `VpnConnection.protectProcessNet()` before the core opens new
  outbound sockets.
- API 20 and 21 use a host callback that waits on
  `VpnConnection.protect(fd)` before connect. The wait occurs on the Go/native
  worker goroutine, never on the ArkTS event loop, and has a bounded timeout.

Protection failure fails the affected connection closed. It never silently
dials through the TUN and never falls back to an unreported direct path.

### 6.4 Packet paths

```text
Captured application packet
  -> HarmonyOS vpn-tun
  -> sing-tun gVisor TCP/UDP stack
  -> mihomo tunnel
  -> rules and DNS
  -> selected proxy or DIRECT outbound
  -> protected underlying network
```

```text
Explicit local HTTP/SOCKS client
  -> 127.0.0.1 mixed listener
  -> same mihomo tunnel, rules, DNS, and outbound pool
```

DNS packets addressed to the configured virtual DNS endpoints are handled by
mihomo rather than sent directly to the physical network. IPv6 is captured by
default so a dual-stack device cannot bypass the policy over `::/0`.

## 7. Stop and Recovery

The normal and failure stop path is:

1. enter `Stopping` and reject new start work;
2. stop accepting TUN packets;
3. close `sing-tun` and the native duplicated fd exactly once;
4. stop the mihomo runtime and local listeners;
5. call `VpnConnection.destroy()`;
6. stop the continuous task and notification;
7. clear live session ownership and enter `Stopped`.

`VpnExtensionAbility.onDestroy()`, user stop, permission revocation, another
VPN replacing this one, and partial-start rollback all call this same path.

An underlying Wi-Fi or cellular outage does not immediately destroy the TUN.
The state enters `Recovering`, existing unusable outbound connections are
closed, and new protected connections are attempted after NetworkKit reports
a usable network. Retry uses bounded exponential backoff. There is no infinite
process or VPN restart loop.

Stopping VPN restores the operating system's ordinary network routing. This
phase does not claim an always-on lockdown or kill switch after the VPN has
been destroyed.

## 8. Errors and User Feedback

Stable failure groups include:

- `VPN_PERMISSION_DENIED`
- `VPN_ALREADY_ACTIVE`
- `VPN_PROFILE_UNAVAILABLE`
- `VPN_CONFIG_INVALID`
- `VPN_CREATE_FAILED`
- `VPN_TUN_FD_INVALID`
- `VPN_TUN_START_FAILED`
- `VPN_SOCKET_PROTECT_FAILED`
- `VPN_LOCAL_PORT_CONFLICT`
- `VPN_BACKGROUND_TASK_FAILED`
- `VPN_SYSTEM_REVOKED`
- `VPN_STOP_FAILED`

Permission denial leaves the application stopped. An existing system VPN
produces an actionable message asking the user to disconnect it; the
application does not repeatedly attempt to take ownership. A local-listener
port conflict fails the whole VPN start because a partially available session
would contradict the confirmed product behavior.

Technical details remain available for local diagnostics, but subscription
URLs, credentials, node keys, full target URLs, VPN IDs, and device identifiers
are redacted.

## 9. Testing Strategy

Implementation follows red-green-refactor for each boundary.

### 9.1 ArkTS and structure tests

Tests cover:

- manifest extension type and allowed permission set;
- absence of system and enterprise permissions;
- state transitions and serialization;
- consent denial and cancellation;
- validated IPv4/IPv6 route, address, DNS, MTU, and self-exclusion config;
- exact rollback order for every partial-start boundary;
- repeated start/stop and stop-during-start;
- notification and live-state reconstruction;
- Wi-Fi/cellular loss and bounded recovery decisions.

### 9.2 Native host tests

Tests cover:

- invalid, negative, closed, and non-TUN fd rejection;
- `dup()` failure and duplicate ownership;
- one close per native fd under success, rollback, and repeated stop;
- ABI `struct_size` compatibility;
- Node-API Promise and event delivery;
- socket-protection success, rejection, and timeout;
- no ArkTS handle or callback retained after shutdown.

### 9.3 Go tests

The TUN constructor and packet loop are injected behind a small factory so
host tests can use a fake fd-backed device. Tests cover:

- gVisor options and disabled auto-route behavior;
- TCP, UDP, and DNS dispatch into the mihomo tunnel;
- start/stop races;
- connection protection before dial;
- traffic counter correlation;
- network recovery and cancellation;
- no goroutine, listener, or descriptor leak.

The full Go suite also runs with the race detector.

### 9.4 Package checks

The production AArch64 build must show:

- real pinned mihomo and sing-tun bytes;
- expected TUN ABI symbols in the addon and core;
- no test stub or companion probe payload in the production HAP;
- only the approved permissions;
- a signed, installable production HAP;
- recorded hashes for the HAP and packaged native libraries.

### 9.5 Independent physical-phone proof

A test-only traffic-probe HAP uses a different bundle name and is never
included in the production package. The VPN application excludes only its own
bundle, so probe traffic represents an external application.

The probe produces correlated, non-secret checks for:

- HTTPS/TCP;
- UDP echo;
- DNS resolution and a uniquely identified DNS packet;
- IPv4;
- IPv6 when the underlying test network supports it;
- local HTTP and SOCKS listeners;
- app switch, return to the launcher, and screen-off continuity;
- system VPN indicator and ongoing notification;
- Wi-Fi loss/recovery and, when safely available, Wi-Fi/cellular transition;
- stop cleanup and ordinary-network restoration.

The proof is accepted only when the external probe result, TUN packet/byte
counters, and mihomo session events share the same generated correlation ID.
An in-app request from the excluded VPN bundle cannot satisfy this gate.

The runner writes `harmony/artifacts/phase4-device-proof.json` containing:

- result and timestamps;
- redacted target alias, OS/API level, architecture, and device class;
- production and probe HAP hashes;
- native library hashes and core version;
- route/DNS/MTU feature assertions;
- TCP, UDP, DNS, IPv4, optional IPv6, local HTTP, and SOCKS results;
- TUN counters and correlated mihomo events;
- lifecycle, recovery, notification, and stop-cleanup results;
- `stubDetected: false`.

The proof never contains a real device serial, subscription content, secrets,
complete browsing targets, or signing material.

## 10. Acceptance Criteria

Phase 4 is complete only when all of the following are true:

1. The ordinary third-party HAP installs and receives system VPN trust on the
   HarmonyOS 6.1 phone without system or enterprise permissions.
2. `VpnConnection.create()` returns a usable TUN fd and ownership tests show no
   descriptor leak or double close.
3. The independent probe's TCP, UDP, and DNS traffic crosses TUN and mihomo.
4. IPv4 is captured; IPv6 is captured whenever the network offers IPv6 and
   cannot leak outside the configured `::/0` policy.
5. Core outbound connections do not loop back into TUN.
6. The local HTTP and SOCKS listeners continue to work in VPN mode.
7. Leaving the UI and turning the screen off do not stop the active session
   during the verification window.
8. Network loss and recovery do not leave an optimistic false-running state.
9. Stopping releases the TUN interface, runtime, listener ports, notification,
   and native descriptors, then restores ordinary networking.
10. The production HAP and redacted Phase 4 proof pass all structure, ABI,
    package, and schema validators.

Simulator, host-only, package-byte, or VPN-application-self-test results cannot
replace the independent physical-phone traffic proof.

## 11. Risks and Constraints

| Risk | Mitigation |
| --- | --- |
| Retail-device behavior differs from SDK declarations | Treat physical-phone proof as a hard gate |
| Core outbound traffic loops into TUN | Self-exclude the bundle plus process/per-socket protection |
| API 20/21 lack `protectProcessNet()` | Use bounded per-socket `protect(fd)` fallback |
| TUN fd ownership is ambiguous across ArkTS and Go | Native immediately duplicates; each layer closes only its owned handle |
| IPv6 bypasses IPv4-only capture | Configure `::/0`, virtual IPv6 DNS, and explicit leak checks |
| Background policy stops the process | Ongoing notification, continuous task, lifecycle observation, and screen-off proof |
| Partial startup appears successful | Reverse-order rollback and event-confirmed state only |
| A self-generated probe gives false confidence | Use a separate test-only bundle and correlated TUN/core evidence |
| Local proxy is mistaken for an OS global proxy | Use precise product text and prohibit unsupported claims in tests |

## 12. Reviewed Platform References

- Local HarmonyOS 6.1 SDK:
  `ets/api/@ohos.net.vpnExtension.d.ts`
- Local VPN ability declaration:
  `ets/api/@ohos.app.ability.VpnExtensionAbility.d.ts`
- Local permission metadata:
  `toolchains/lib/PermissionDefinitions.json`
- Local ordinary application proxy API:
  `ets/api/@ohos.net.connection.d.ts`
- Local enterprise global proxy API:
  `ets/api/@ohos.enterprise.networkManager.d.ts`
- [OpenHarmony third-party VPN guide, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/network/net-vpnExtension.md)
- [OpenHarmony VPN Extension API, reviewed snapshot](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-network-kit/js-apis-net-vpnExtension.md)

