# HarmonyOS Geodata Management Design

## Goal

Let users inspect, verify, update, and recover the GeoIP database without allowing startup to silently overwrite a trusted newer version.

## Scope

The first complete slice manages the currently required canonical asset `geoip.metadb`. GeoSite, DAT-mode GeoIP, ASN, and MRS bundle management remain later catalog extensions because they need separate native cache/reload semantics and are not currently packaged.

## Chosen approach

Separate the immutable packaged baseline lock from runtime installed metadata.

- Packaged baseline remains build-time pinned and is used to seed a missing/corrupt installation.
- Runtime metadata records installed size, SHA-256, source release, installed time, and optional previous-version descriptor.
- Startup preserves an installed version that matches durable runtime metadata; it no longer downgrades every non-baseline digest.
- Explicit “Restore bundled version” is the only action that replaces a healthy newer file with the packaged baseline.

Online update fetches the MetaCubeX latest release `geoip.metadb.sha256sum`, validates its strict digest format, streams the bounded database candidate, verifies digest/size, and stages it. GitHub HTTPS plus the sidecar protects transfer integrity; the previous known-good file is retained for rollback.

## Apply boundary

Download and validation may run while VPN is active, but commit/restore uses one exact gate: VPN registry is fully `STOPPED` with no pending/current session (so `AWAITING_CONSENT` is busy), and the local runtime is fully stopped. The first version does not hot-reload Mihomo readers. After commit, UI marks “restart app required”; the new file is used after process restart/new VPN Extension creation.

This avoids claiming unsafe live cache replacement. A future native reload API may remove the restart requirement.

## Repairable startup

Geodata health must be observable even when installation fails. `ApplicationCompositionState` adds `GEODATA_REPAIR_REQUIRED`, carrying only a repair-capable `GeodataService` plus a safe error; it does not expose ProfileApplication or runtime ports. `CoreComposition` first constructs a minimal geodata repair composition, checks/repairs health, then builds the full PlatformGraph. `Index` can route this state only to `GeodataPage`. A successful bundled restore calls composition retry, discards the minimal service, and rebuilds the entire graph from `LOADING` to `READY`.

## Durable transaction and crash recovery

The live database remains `<filesDir>/geoip.metadb`. Management state lives under `<filesDir>/geodata/`:

- `geoip-runtime-v1.json`: installed/previous descriptors and restart-required flag.
- `geoip-transaction-v1.json`: exact transaction stage plus candidate/previous digests.
- `geoip.candidate.metadb` and `geoip.previous.metadb`.

Apply order is: fully write/fsync/hash candidate; copy/fsync/hash previous; write transaction `PREPARED`; replace live; verify live; write runtime metadata; clear transaction. Restore uses the same journaled sequence.

Startup recovery matrix:

- Candidate exists without transaction: verify then expose as staged, or delete if invalid; never touch live.
- `PREPARED` with live still matching old metadata: keep live and previous, expose staged candidate.
- Live matches transaction candidate but runtime metadata is old: finalize metadata and preserve previous.
- Live matches neither transaction candidate nor previous: enter `GEODATA_REPAIR_REQUIRED`.
- Rollback/restore interruption with a valid previous digest: restore previous, verify, update metadata, then clear transaction.
- Runtime metadata digest not matching live with no recoverable transaction: enter repair state; never silently trust or overwrite it.

## UI

Home adds a Geodata entry. The page shows logical asset name, installed/bundled version digest prefix, size, status, source, installed time, pending candidate, and restart requirement. Actions:

- Verify installed file.
- Check/download update.
- Apply staged update when runtime is stopped.
- Restore previous version.
- Restore bundled version.

No absolute path, URL query, raw error, or full digest is written to public logs/semantic IDs.

## Testing and acceptance

- Installer tests: preserve trusted newer version, seed missing baseline, repair corrupt baseline, no silent downgrade.
- Manager tests: strict sidecar parsing, bounded stream, short IO, checksum/size failure, exclusive transaction, backup, apply rollback, restore previous/bundled, runtime-state gate.
- ViewModel tests: health/loading/download/apply/restart/repair states and stale result suppression.
- Structure tests separate build lock from runtime metadata and keep network/platform imports out of shared/UI layers.
- Physical tests: update while stopped, download while running but reject apply, restart adoption, corrupt candidate rollback, and offline bundled restore.
