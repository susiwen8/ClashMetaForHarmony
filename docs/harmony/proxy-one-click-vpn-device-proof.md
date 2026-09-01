# Harmony One-Click VPN Device Proof

Persisted proof schema version: `2.0.0`

Persisted fields:

- `schemaVersion`
- `result`
- `packageSha256`
- `stoppedToVpnState`
- `runningSwitchState`
- `recreationState`
- `cleanupState`

No Local-to-VPN scenario is part of schema v2.

Command:

```sh
node harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap --out harmony/artifacts/proxy-one-click-vpn-device-proof.json
```

Proof document path:

- `harmony/artifacts/proxy-one-click-vpn-device-proof.json`

Controlled failure boundary:

- The saved-marker/retryable-error failure path is proven through injectable shared/entry Hypium tests, not through a production runtime hook.
- The physical-device runner proves the production stopped/running one-click paths, then exit only the UIAbility, relaunch `EntryAbility`, reopen the proxy screen, prove the running marker is restored, hot-switch once more, and finally prove cleanup.
- bundle force-stop is forbidden until final cleanup.
- If the ability-only exit cannot be distinguished from a backgrounded UI, the recreation lane fails closed and the persisted result stays the canonical `incomplete` shape.

Privacy guarantee:

- The persisted proof contains only fixed aggregate states and one package digest.
- No node text, transport address, subscription location, auth material, private runtime identity, or raw platform detail is written to the proof.
- The recreation lane persists only the fixed aggregate enum `RESTORED_RUNNING_SELECTED` or `NOT_PROVEN`; it never writes session/profile/version identity or raw failure detail.
- If the run cannot be fully proven, the runner writes the canonical `incomplete` shape with `NOT_PROVEN` state markers.
- zero private data is persisted beyond the fixed aggregate fields above.
