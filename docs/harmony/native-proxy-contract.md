# Harmony Native Proxy Contract

Plan B is host + packaged-native contract evidence only.

## Scope

- No current physical subscription query.
- No current product UI.
- No current persistence layer.
- No current VPN replay.
- No current physical HTTPS claim.
- Plan C/D/device gates remain.

## Architecture

- Schema version: `1.0.0`
- Kinds: `GROUP_LIST`, `GROUP_SNAPSHOT`, `SELECTION_APPLIED`
- Context: `profileHash`, `revisionHash`, `sessionHash`, `generation`
- Raw exports: `cmfa_mihomo_proxy_groups_v1`, `cmfa_mihomo_proxy_group_v1`, `cmfa_mihomo_proxy_select_v1`
- NAPI methods: `queryProxyGroups`, `queryProxyGroup`, `selectProxy`
- Shared methods: `queryProxyGroups`, `queryProxyGroup`, `selectProxy`

## Limits

- `maxGroupCount`: `128`
- `maxNodeCount`: `1024`
- `maxNameUtf8Bytes`: `256`
- `maxRawJsonBytes`: `1048576`

## Runtime Types

Pinned authority: `Direct`, `Reject`, `RejectDrop`, `Compatible`, `Pass`, `PassRule`, `Rematch`, `Dns`, `Relay`, `Selector`, `Fallback`, `URLTest`, `LoadBalance`, `Shadowsocks`, `ShadowsocksR`, `Snell`, `Socks5`, `Http`, `Vmess`, `Vless`, `Trojan`, `Hysteria`, `Hysteria2`, `WireGuard`, `Tuic`, `Ssh`, `Mieru`, `AnyTLS`, `Sudoku`, `Masque`, `TrustTunnel`, `ShadowQuic`, `OpenVPN`, `Tailscale`, `GostRelay`.

## Error Codes

Public proxy status mapping stays pinned to six codes:

| Code | Meaning |
| --- | --- |
| `PROXY_RUNTIME_NOT_READY` | Runtime missing or not loaded |
| `PROXY_GROUP_NOT_FOUND` | Requested group absent |
| `PROXY_GROUP_NOT_SELECTABLE` | Group cannot be patched |
| `PROXY_MEMBER_NOT_FOUND` | Requested member absent |
| `PROXY_SELECTION_FAILED` | Mutation did not stick |
| `PROXY_BRIDGE_INVALID` | Payload or bridge contract invalid |

## Buffer Rules

- Native writes caller-owned bounded buffers only.
- Success length excludes the trailing NUL.
- Buffer-too-small reports required length and writes no partial payload.
- Proofs and reports store counts and hashes only.

## Evidence

- Fresh host test counts from the local Asia/Shanghai August 23, 2026 run.
  - The packaged-native provenance timestamps remain in UTC on August 22, 2026, which is expected for the same local run window.
  - `go test ./...`: 5 packages with tests passed; 2 packages reported no test files.
  - Native host contract counts: contract `35`, mihomo-backend `23`, napi-environment `18`, napi-tun `12`, napi-proxy `11`.
  - Structure evidence gates in this scope: 20 structure checks passed for bridge, ArkTS boundary, plan-b proxy, and signing isolation.
- Fresh verified package and native hashes from the same run:
  - Unsigned package archive sha256: `b3a114bc7b8e709eb71fd6579dac6e10396c9a61681e800e5af81b8caae2e2c9`
  - Raw core sha256: `e72b0293ff544d2ce2b8a0aa773cdc1b24aa93f357e26a2692eae7ff6c640124`
  - Packaged core entry identity `libs/arm64-v8a/libcmfa_mihomo.so` sha256: `e72b0293ff544d2ce2b8a0aa773cdc1b24aa93f357e26a2692eae7ff6c640124`
  - Packaged addon entry identity `libs/arm64-v8a/libentry.so` sha256: `82cd653981e3a6659297c1968675120df7f98d99e94b3e49bcf3063c1cfff9c5`
  - Archive counts: total entries `14`; core occurrences `1`; addon occurrences `1`.
- Current remaining gate: signing prerequisite only. No local signing profile was configured during this run, so Plan B stops at verified unsigned package plus packaged-native contract evidence.
