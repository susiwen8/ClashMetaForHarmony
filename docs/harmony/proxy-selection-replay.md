# HarmonyOS Proxy Selection Replay

## Scope

This report records package-neutral Plan C evidence for proxy selection state,
durable intent, rollback, and replay ordering. It does not record private proxy
labels, transport endpoints, configuration content, runtime identifiers, or
package and signing locations.

## Contract

- Public application methods: `4`
- RDB schema version: `2`
- Durable table count added by Plan C: `1`
- Durable key columns: `2`
- Durable value and metadata columns: `3`
- Proxy result kinds: `4`
- Proxy error codes: `7`
- VPN replay error codes added: `1`
- Raw proxy names recorded: `0`
- Endpoint fields recorded: `0`

The four application methods cover group listing, one group snapshot, one
generation-bound selection, and active-revision reconciliation.

The four closed selection results are `APPLIED_NOW`,
`SAVED_FOR_NEXT_START`, `APPLIED_NOT_PERSISTED`, and `REJECTED`.

The proxy error allowlist is `PROXY_PROFILE_UNAVAILABLE`,
`PROXY_RUNTIME_NOT_READY`, `PROXY_SELECTION_STALE`, `PROXY_QUERY_FAILED`,
`PROXY_SELECTION_FAILED`, `PROXY_PERSISTENCE_FAILED`, and
`VPN_SESSION_CHANGED`.

The VPN lifecycle adds `VPN_PROXY_REPLAY_FAILED`.
Replay ordering: `TUN_READY -> REPLAY -> BIND -> RUNNING` for initial start and
recovery.
Invalidation closes command delivery synchronously. Deactivation drains queued
and active commands before TUN disposal.

## Persistence and rollback

The version two migration is additive and preserves existing profiles. The
selection table owns the only durable raw-label fields. Profile deletion removes
the related selections in the same transaction.

A running selection is reported as applied only after runtime confirmation and
durable persistence. A persistence failure triggers a confirmed rollback. If
rollback cannot be confirmed, the result remains truthfully
`APPLIED_NOT_PERSISTED`.

A stopped selection stores only validated intent. It never publishes a runtime
checkmark. Startup and recovery replay durable intent before the command bus is
bound and before the runtime reaches the running state.

## Host evidence

- Focused structure cases: `46`
- Native host cases: `5`
- Module verification gates: `5`
- Package-neutral provenance gates: `1`
- Physical-device result: `NOT_CLAIMED`
- Signed package result: `NOT_CLAIMED`

The host evidence proves type, migration, ordering, rollback, privacy, layer,
and package-neutral provenance contracts. ArkUI and physical-device acceptance
remain Plan D work.

## Plan D handoff

The exact consumer authority is `ProfileApplication.listGroups`,
`ProfileApplication.queryGroup`, `ProfileApplication.select`, and
`ProfileApplication.reconcileActiveSelections`. The authority is constructed
beside the shared command bus in `CoreComposition.ets`.

The handoff is pinned by `ApplicationComposition.test.ets`,
`PresentationFakes.ets`, and `Phase3RuntimeFlow.test.ets`. Plan C does not claim
an ArkUI node page, a current signed package, physical-device interaction, or
network success. Those claims require the separate Plan D host, package, and
physical-device gates.
