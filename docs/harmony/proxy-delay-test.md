# Harmony Proxy Delay Test Contract

API schema version: `1.0.0`

Raw Go exports: `cmfa_mihomo_proxy_delay_start_v1`, `cmfa_mihomo_proxy_delay_snapshot_v1`, `cmfa_mihomo_proxy_delay_cancel_v1`

Public C bridge: `cmfa_proxy_delay_start`, `cmfa_proxy_delay_snapshot`, `cmfa_proxy_delay_cancel`

Core service surface: `startProxyDelayTest`, `readProxyDelayTest`, `cancelProxyDelayTest`

Public enums:
- Job state: `RUNNING`, `COMPLETED`, `CANCELLED`, `FAILED`
- Node state: `WAITING`, `TESTING`, `AVAILABLE`, `TIMEOUT`, `FAILED`, `CANCELLED`, `UNSUPPORTED`
- URL source: `PROVIDER`, `FALLBACK`

Worker/count bounds: `16 workers`, `5s` per node, `250ms` poll cadence, `1024` nodes, `256` UTF-8 bytes, `1 MiB` JSON, `32` lowercase-hex job IDs

Expected-status rule: provider-backed URLs accept `200-299`; fallback accepts only fixed `204` probe responses from the canonical fallback endpoint invariant

Lifecycle rule: drain proxy delay work before config reload, VPN replay changes, or VPN stop cleanup

Delay-test results only describe node probing; they do not prove that system VPN/TUN capture is active.

Architecture rule:
- One active delay manager at a time in Go and one active shared delay record at a time in ArkTS
- Node order is preserved from the runtime snapshot through the shared bridge and UI rows
- Delay runs are session-scoped
- Delay probes never auto-select a proxy member
- Ordinary row outcomes still end as job `COMPLETED`; typed pre-job or bridge failures reject before publication

UI semantics: one active delay run, no auto-select, original node order preserved, `completedCount` excludes only live `WAITING`/`TESTING` rows and includes `UNSUPPORTED`

Focused verification command:

```sh
node --test harmony/tests/structure/proxy-delay-contract.test.mjs harmony/tests/structure/phase1-bridge-contract.test.mjs harmony/tests/structure/plan-c-proxy-selection-contract.test.mjs harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs harmony/tests/structure/phase3-layer-boundary.test.mjs harmony/tests/structure/phase4-vpn-contract.test.mjs harmony/tests/structure/go-ohos-build-contract.test.mjs harmony/tests/structure/phase4-package-contract.test.mjs
```

Full structure suite command:

```sh
node --test harmony/tests/structure/*.test.mjs
```

Focused structure cases verified on 2026-08-23: `101` passing tests.

Full structure suite verified on 2026-08-23: `420` passing tests.
