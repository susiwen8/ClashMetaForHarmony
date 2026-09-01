# HarmonyOS VPN Ownership Recovery Design

## Goal

Make a system VPN created by Clash Meta addressable after UI/Extension recreation, process death, or an in-place HAP upgrade so the next start can clean stale ownership without requiring a phone reboot.

## Chosen approach

Use the API 20+ platform identity lifecycle end to end:

1. `VpnConnection.generateVpnId()` creates the platform identity.
2. The identity is atomically persisted before `VpnConnection.create()`.
3. `VpnConfig.vpnId` receives that exact identity.
4. Normal cleanup uses `destroy(vpnId)` and clears the store only after confirmed success.
5. A new Extension instance reads an old identity and attempts `destroy(oldVpnId)` before generating the next identity.

The current no-id legacy configuration remains only as a one-release migration fallback when the ownership store is empty and the platform reports `2203002`. It must not replace or clear a persisted identity.

Rejected alternatives:

- Keep retrying parameterless `destroy()`: physical evidence showed it cannot reclaim an orphan owned by an earlier process.
- Persist the whole runtime snapshot: it would leak session/profile facts and make stale UI state authoritative.
- Use the business `sessionId` as `vpnId`: it was never generated or registered by the VPN service.

## Components

- `VpnPlatformOwnershipStorePort` in shared VPN ports exposes `read`, `write`, and `clearExpected`.
- `HarmonyVpnOwnershipStore` stores one bounded JSON document under `<filesDir>/vpn/active-platform-vpn-v1.json` using temp-write, fsync, and rename-replace.
- `HarmonyVpnConnectionDriver` owns reconcile, generate, persist, create, destroy, and cleanup ordering.
- `VpnExtensionComposition` constructs the store from the Extension `filesDir` and injects it into the driver.

The persisted document contains only `{ "version": 1, "phase": "PREPARED|ACTIVE|RELEASED", "vpnId": "..." }`. `PREPARED` means an ID is durable but create is not confirmed; `ACTIVE` means create returned a valid FD; `RELEASED` means platform destroy succeeded and only store cleanup remains. It never contains profile/version/session IDs, file descriptors, timestamps, endpoints, or application runtime state. The raw ID must never enter RPC, public Hilog, evidence JSON, semantic IDs, or UI state.

The store is bounded to 256 UTF-8 bytes. Missing returns `null`. Malformed, oversized, wrong-version, duplicate-key, invalid-phase, or invalid-ID content throws `OwnershipStoreCorruptError`; start fails closed, does not run legacy fallback, and does not automatically delete the evidence. Every write uses a unique operation-ID temp file. `clearExpected(id)` atomically claims the current file, validates the claimed object, and removes it only when it still contains that exact ID; concurrent new writers are never deleted.

## Start and recovery flow

1. Create a `VpnConnection`.
2. Read the private ownership store.
3. Reconcile an old document by phase. `RELEASED` only retries exact store cleanup. `ACTIVE` calls `destroy(oldId)` then writes `RELEASED`. `PREPARED` calls destroy because create may have completed before the ACTIVE journal write. For a platform-generated, syntactically valid stored ID, BusinessError 19900001 during PREPARED/ACTIVE recovery is treated as “no remaining platform owner” and advances to RELEASED; 19900002 and all other errors fail closed. Message text is never inspected.
4. Call `generateVpnId()`.
5. Persist the generated ID atomically as `PREPARED`.
6. Build the unchanged full-capture config plus `vpnId`.
7. Call `create(config)` and validate the returned FD.
8. Persist the same ID as `ACTIVE`, then return a `TunHandle` with the real platform ID and the separate business session ID. If ACTIVE persistence fails, keep the live in-memory handle and PREPARED journal so recovery can destroy it.

If create or FD validation fails, attempt `destroy(vpnId)`. Clear only when cleanup succeeds. The existing one-shot legacy reclaim path remains for an empty store and never loops.

## Stop flow

The coordinator still drains proxy delay work, deactivates proxy replay, stops TUN, destroys the platform VPN, then stops notification. Driver destroy validates ownership, calls `destroy(vpnId)`, marks the in-memory handle platform-destroyed, writes `RELEASED`, then clears that same persisted ID. If platform destroy succeeded but journal/clear fails, later retries perform only durable cleanup and never call platform destroy twice. A failed platform destroy keeps ACTIVE memory/durable ownership for retry.

## Compatibility and privacy

Routes, addresses, DNS, MTU, IPv4/IPv6 acceptance, blocking mode, empty trusted list, and self-only blocked list remain byte-for-byte unchanged. API 20 is the minimum supported target, so inability to generate/persist a platform ID is a start failure rather than an untrackable legacy success.

The first upgraded build cannot reconstruct a legacy no-id orphan created by older code. The migration fallback is best effort; system reboot/settings remains the honest recovery if it cannot reclaim it. Once a generated ID has been persisted, subsequent builds must recover without reboot.

## Testing and acceptance

- Store tests: missing, malformed, oversized, invalid phase, unique-temp write/write race, short write, fsync/rename failure, exact-ID claim/clear, stale claim recovery, and idempotence.
- Driver tests: PREPARED/ACTIVE/RELEASED recovery; generate → PREPARED → create/FD → ACTIVE; create cleanup; ACTIVE journal failure; platform-destroy vs store-cleanup retry separation; persisted-ID privacy; legacy fallback.
- Structure tests replace the old ban on `generateVpnId`/`destroyWithVpnId` with exact ordering and privacy assertions.
- Existing contracts must explicitly change the driver constructor to accept the store; wire it in `VpnExtensionComposition.createPlatformPort`; require `config.vpnId`; require `handle.vpnId !== sessionId`; and require ID-based destroy/cleanup instead of parameterless destroy for persisted owners.
- Physical acceptance: active VPN in-place HAP upgrade, active VPN Extension kill, ordinary stop, and TCP/UDP/DNS full-capture with the `vpnId` config.

Retention of `filesDir` across an in-place HAP upgrade is a physical-device acceptance assumption, not inferred solely from SDK declarations. The upgrade test must prove the persisted ID survives before this path is considered complete.
