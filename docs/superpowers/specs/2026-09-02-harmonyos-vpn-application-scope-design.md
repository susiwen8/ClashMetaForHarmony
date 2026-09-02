# HarmonyOS VPN Application Scope Design

## Problem

HarmonyOS creates the VPN interface, but ordinary application traffic does not enter its TUN file descriptor. The system shows a VPN indicator while browser requests fail and `multitun-vpn1` application counters remain unchanged.

The regression was introduced when platform ownership persistence added `vpnId` to `VpnConfig`. OpenHarmony parses a configuration containing `vpnId` through a different multi-VPN/system-VPN path. On the physical Huawei device that path creates the interface but does not install effective application UID ranges for the product's empty trustlist/block-self configuration. The public upstream source does not fully explain the vendor device behavior, so the device observation and the last physically proven legacy configuration are the release gate rather than an asserted upstream implementation detail.

Commit `953c1657` had deliberately omitted `vpnId` from the platform configuration and used parameterless `destroy()` to keep real full-device capture working. Commit `468757e4` restored `vpnId` for durable ownership, but its commit record states that physical device proof was not run.

## Decision

Keep the shared policy as full-device capture except the VPN application's own sockets, and translate it through the legacy VPN Extension configuration path:

- Do not include `vpnId` in the `PlatformVpnConfig` passed to `VpnConnection.create`.
- Continue to pass `blockedApplications: [com.github.kr328.clash.harmony]` and an empty `trustedApplications` list.
- Continue generating a private identifier for durable ownership records and RPC/session correlation, but record that it is not bound to the platform VPN configuration.
- Destroy a live legacy VPN with parameterless `VpnConnection.destroy()`.

## Recovery and Migration

The ownership store remains a `PREPARED -> ACTIVE -> RELEASED` state machine, but its document schema advances to version 2 and adds an explicit binding:

- `PLATFORM_ID`: the identifier is a real multi-VPN platform ID written by the broken version-1 build.
- `LEGACY_GLOBAL`: the identifier is only a private ownership marker for a legacy single-VPN session.

Version-1 documents are read as `PLATFORM_ID` and rewritten in version-2 form on the next state transition. New sessions always write `LEGACY_GLOBAL`.

Recovery branches on binding and phase. `PLATFORM_ID` records use the existing exact `destroyWithVpnId` cleanup. Only an `ACTIVE + LEGACY_GLOBAL` record proves this bundle previously owned a live single VPN and may authorize one bounded parameterless reclaim if the next legacy create reports `2203002`. `PREPARED` never proves live ownership, while `RELEASED` proves successful teardown; both are exact-cleared without platform destroy or reclaim authority. A successful create means no stale single VPN remained.

For a live `LEGACY_GLOBAL` session, stop and post-create failure cleanup use parameterless destroy, then persist `RELEASED` and clear only the matching ownership marker. Pre-live failures never call platform destroy; they best-effort transition the private marker to `RELEASED` and exact-clear it. Repeated cleanup stays idempotent.

Parameterless fallback destroy is restricted to an ownership record created by this bundle and to one attempt. The product maintains at most one VPN owner for its calling UID; migration first removes any `PLATFORM_ID` record, so fallback cannot intentionally delete a second product-created multi-VPN entry. It never targets another application's UID, but same-UID collateral deletion remains a platform behavior and is covered by the single-owner invariant.

## Verification

1. A failing driver test first proves that a production platform config containing `vpnId` violates the global-capture contract.
2. Unit tests prove v1-to-v2 binding migration, parameterless live stop/cleanup, persisted old-ID migration, one bounded legacy reclaim, and exact ownership-store transitions.
3. Entry and focused structure tests pass; the signed debug HAP builds without stub code.
4. On the physical HarmonyOS 6/API 24 phone, Traffic Probe traffic increments `multitun-vpn1`, the runtime journal records TUN ingress, and browser HTTPS succeeds.
5. Only after the debug device proof passes is a release-mode signed HAP built and installed.

## Rejected Alternatives

- Enumerating launcher applications into `trustedApplications` is neither proven available to an ordinary third-party app nor equivalent to all installed applications.
- `GET_BUNDLE_INFO_PRIVILEGED` cannot be granted to a normal third-party release.
- A manual per-app picker does not satisfy global capture.
- Removing ownership persistence entirely would regress the requested abnormal-recovery behavior.
