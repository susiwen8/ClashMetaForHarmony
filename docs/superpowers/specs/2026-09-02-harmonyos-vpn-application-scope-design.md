# HarmonyOS VPN Application Scope Design

## Problem

HarmonyOS creates the VPN interface, but a VPN Extension receives no application UID ranges when `trustedApplications` is empty. The current production configuration passes an empty trustlist, so the system displays a VPN indicator while ordinary application traffic bypasses the TUN file descriptor.

This behavior is confirmed by the OpenHarmony `NetVpnImpl::GenerateUidRanges` implementation: VPN Extension calls with an empty accepted-application list return without generating UID ranges. On the physical API 24 phone, the VPN lifecycle reaches `tun-start-ok`, while browser and Traffic Probe requests do not increment `multitun-vpn1` counters.

## Decision

Resolve a non-empty list of launchable installed applications before creating the platform VPN. Use the normal-level `ohos.permission.GET_BUNDLE_INFO` permission and query abilities matching the launcher home action/entity. Normalize the result by trimming bundle names, removing duplicates, sorting deterministically, and excluding `com.github.kr328.clash.harmony` so the VPN core cannot capture its own outbound sockets.

Pass the resolved bundle names through `trustedApplications` and leave `blockedApplications` empty in the platform `VpnConfig`. The shared capture policy remains “all applications except self”; the platform driver translates that policy into the explicit allowlist required by HarmonyOS VPN Extension.

## Boundaries

- `VpnApplicationScopeResolver` owns installed-application discovery and normalization.
- `HarmonyVpnConnectionDriver` requests the application scope before `VpnConnection.create` and does not know BundleManager details.
- The default resolver uses the public BundleManager API; tests inject deterministic resolvers.
- Application discovery happens for every newly created VPN session so newly installed apps are included after the next restart.

## Failure Policy

Discovery failure, an empty result, or a result containing only the VPN app fails closed with a sanitized `VPN_CREATE_FAILED` error. The driver must not call `VpnConnection.create`, because an interface with no UID ranges is misleading and unusable.

Malformed and duplicate bundle names are ignored. The VPN app's own bundle name is always removed even if BundleManager returns it.

## Verification

1. Unit tests prove normalization, deterministic ordering, self-exclusion, non-empty enforcement, and that resolution failure prevents platform creation.
2. Entry ArkTS tests and the signed production build pass.
3. On the physical HarmonyOS 6/API 24 phone, `multitun-vpn1` counters increase for Traffic Probe traffic, the runtime journal records TUN ingress, and a browser HTTPS request succeeds.
4. Only after the debug device test passes is a release-mode signed HAP built and installed.

## Rejected Alternatives

- A manual per-app picker does not satisfy global capture.
- `GET_BUNDLE_INFO_PRIVILEGED` and `getAllBundleInfo` require system-level authority unavailable to a normal third-party release.
- Omitting both application lists still produces no UID ranges for a VPN Extension and therefore does not fix the device behavior.
