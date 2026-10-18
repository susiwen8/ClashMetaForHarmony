# HarmonyOS VPN Cross-Process LocalSocket RPC Design

## Status

Approved in conversation for written-spec review.

This design supersedes the process-static runtime bridge described in `2026-08-25-harmonyos-vpn-runtime-bridge-design.md`. Fresh HarmonyOS 6 physical evidence proved that `EntryAbility` and `CmfaVpnExtensionAbility` run in separate OS processes. Attempts to force process co-location were rejected by Hvigor or remained split on the device. A process-global C++ store therefore cannot synchronize the UI with the VPN runtime.

## Goal

Provide a phone-compatible, application-private, authenticated cross-process RPC channel between the UI process and the VPN Extension process so the application can reliably:

- start and stop VPN global capture;
- display the real VPN runtime state;
- query proxy groups and nodes;
- select and hot-switch terminal nodes;
- start, observe, cancel, and drain batch delay tests;
- restore runtime state after UIAbility recreation;
- reject stale sessions, catalogs, clients, and responses;
- preserve the existing privacy and signed-device-proof requirements.

## Non-Goals

- Do not introduce a second VPN/TUN implementation.
- Do not move VPN core ownership back into the UI process.
- Do not add AppServiceExtensionAbility. Its current permission and device constraints do not satisfy the HarmonyOS phone/model-independent requirement.
- Do not use TCP loopback, public ports, files, RDB, AppStorage, LocalStorage, or sticky CommonEvents as the command transport.
- Do not transmit raw group names, node names, endpoints, URLs, credentials, subscription sources, raw session/profile/version identifiers, raw errors, or stacks over RPC.
- Do not add a ProxyService direct-native fallback.
- Do not keep the failed process-static native bridge after RPC migration is complete.
- Do not change Android behavior.

## Chosen Transport

Use Network Kit `LocalSocketServer` in the VPN Extension process and `LocalSocket` in the UI process.

Reasons:

- supported by the installed HarmonyOS SDK since API 11, below the project's API 20 minimum;
- full-duplex request/response and server push;
- explicit connection lifecycle, backpressure, reconnect, and close semantics;
- no IP route, port discovery, or VPN loopback risk;
- suitable for batch delay progress and cancellation;
- can be authenticated independently of the discoverable local socket address.

CommonEvent is not the business RPC transport. It may be considered later as a payload-free wake-up hint only, but the first implementation does not require it. CommonEvent-only RPC was rejected because it lacks a durable connection, has subscriber timing races, weak backpressure, and a 64 KB data limit.

## Process Responsibilities

### VPN Extension Process

The VPN process remains the sole runtime authority.

It owns:

- `VpnRuntimeCoordinator`;
- the real `VpnSessionRegistry`;
- the extension-side `VpnProxyRuntimeHandler`;
- the running core configuration and catalog;
- the active delay job;
- `VpnRpcServer` and its one authenticated control connection.

It alone may:

- publish real runtime snapshots;
- query the live proxy core;
- mutate the selected node;
- start/read/cancel delay tests;
- stop the live VPN session.

### UI Process

The UI process owns `VpnRpcClient` and presentation state only.

It:

- uses the HarmonyOS system API to start `CmfaVpnExtensionAbility` because no RPC server exists before extension launch;
- connects and authenticates after launch;
- reads the authoritative snapshot before publishing UI `RUNNING`;
- routes running proxy query/select/delay calls through RPC;
- reconnects and hydrates after UIAbility recreation;
- never treats cached state as proof that VPN remains active.

## Focused Units

### `VpnRpcProtocol`

Defines closed enums and exact wire objects for handshake, requests, responses, events, states, errors, and payloads. It owns validation and cloning but no socket I/O.

### `VpnRpcFramer`

Encodes and decodes the byte stream using a four-byte big-endian payload length followed by one UTF-8 JSON frame. It handles fragmented and coalesced socket messages, enforces size limits, and never logs frame content.

### `VpnRpcKeyProvider`

Creates or opens one non-exportable HUKS HMAC-SHA256 key under a versioned app-private alias. It handles simultaneous first-use races by retrying an already-created alias. It exposes HMAC operations, never root key bytes.

### `VpnOpaqueCatalog`

Builds the process-local mapping between raw local names and opaque group/node IDs. The wire layer sees only opaque IDs and catalog digests.

### `VpnRpcAuthenticator`

Performs mutual challenge-response, derives connection-scoped MAC material from HUKS operations, validates frame MACs and monotonically increasing sequence values, and rejects replays.

### `VpnRpcServer`

Owns the `LocalSocketServer`, one authenticated client epoch, request validation, serialized dispatch, response cache, state pushes, delay ownership, and shutdown.

### `VpnRpcClient`

Owns connection retries, authentication, pending request promises, timeouts, request cancellation, response/event dispatch, reconnect, and disposal.

### `VpnRpcProxyHandler`

Implements the UI-side running proxy command handler by translating existing shared command objects to RPC methods and mapping opaque responses back through the UI catalog. It performs no local native proxy mutations.

## HUKS Key and Socket Address

Use one versioned non-exportable HUKS HMAC key alias dedicated to the VPN RPC protocol. The alias is fixed source code and contains no user data.

Key creation uses an app-scoped get-or-create operation. If both processes race on first use, one creates the alias; the other treats "already exists" as success and reopens it. Any other HUKS error fails closed with `AUTH_FAILED`. The protocol never deletes or rotates the alias during an active VPN session. Protocol-version migration uses a new alias and socket address.

Both processes independently compute the LocalSocket address as a bounded lowercase hexadecimal prefix of:

```text
HMAC(rootKey, "cmfa-vpn-rpc/socket-address/v1")
```

The exact address is:

```text
"cmfa_vpn_rpc_v1_" || first 32 lowercase hex characters of the HMAC result
```

The address is therefore deterministic for the installed app, bounded, collision-resistant, and does not disclose the bundle name or key. Address secrecy is not treated as authentication.

The server rejects all business frames until mutual authentication succeeds.

### HarmonyOS 7 transport selection

API 20–25 retain the original app-private LocalSocket transport. API 26+ use TCP bound strictly to IPv4 loopback, because isolated VPN processes can lack socket permissions on debug-labelled application data. UI and Extension select the same transport from the actual device API. Failures never cause automatic transport fallback.

The opaque HUKS-derived address maps deterministically to one port in 30000–59999. A discoverable port is not an authentication boundary: mutual HUKS authentication, per-frame MACs, epochs, sequences and budgets remain mandatory. Port conflicts fail closed without killing or reclaiming an unknown listener. No discovery file or raw endpoint is persisted or logged.

The TCP adapter admits at most four native connections, including pending/closing sockets. It never replaces an authenticated socket on raw accept. Its server-session policy preserves a pending candidate against further unauthenticated accepts until the existing three-second timeout or completion; only successful mutual authentication promotes a replacement. Process socket protection runs before TCP listener creation.

### Address lifecycle

- one `VpnExtensionComposition` owns one server instance;
- the server calls `listen` once after key/address derivation and before accepting business work;
- normal stop/destroy closes every connection and awaits `LocalSocketServer.close()` exactly once;
- on API 20–25, process death relies on the original LocalSocket lifecycle; on API 26+, the kernel releases the TCP listener without filesystem endpoint cleanup;
- `address already in use` never triggers unlink/removal of an unknown socket and maps to fixed `RPC_UNAVAILABLE`;
- a client that reaches a stale or rogue listener cannot authenticate and continues only inside its bounded connection retry window;
- server restart uses the same address but a new `serverInstance`, nonce pair, role keys, sequences, client epoch, response cache, and catalog map;
- no socket address is written to logs, proof artifacts, or durable app state.

## Handshake

### Normative byte encoding

All cryptographic inputs use the following helpers. These rules are normative; no JSON serialization is used for handshake proofs or catalog IDs.

- `ASCII(text)`: exact bytes of the displayed ASCII literal, without a terminator unless `NUL` is shown.
- `NUL`: one `0x00` byte.
- `U16BE`, `U32BE`, `U64BE`: unsigned big-endian integers of exactly 2, 4, or 8 bytes.
- `HEX(bytes)`: lowercase hexadecimal, exactly two characters per byte.
- `UNHEX(text)`: rejects uppercase, odd length, or non-hex input.
- `LP(bytes)`: `U32BE(bytes.length) || bytes`.
- `HMAC(key, bytes)`: HMAC-SHA256, raw 32-byte result.
- all protocol constants are ASCII and include the exact `/v1` suffix shown below.

Nonce and proof formats:

- `serverNonce`: 32 random bytes encoded as 64 lowercase hex characters;
- `clientNonce`: 32 random bytes encoded as 64 lowercase hex characters;
- `serverInstance`: 16 random bytes encoded as 32 lowercase hex characters;
- proofs and opaque IDs: 32 bytes encoded as 64 lowercase hex characters;
- request IDs: canonical lowercase UUID text (`8-4-4-4-12`), validated before use.

### Server hello

```text
SERVER_HELLO
protocolVersion
serverNonce
serverInstance
```

`serverNonce` is cryptographically random. `serverInstance` is a random per-server-start opaque value and is not a PID or session ID.

### Client authentication

```text
CLIENT_AUTH
protocolVersion
clientNonce
clientProof = HMAC(rootKey, context | serverNonce | clientNonce | serverInstance)
```

The exact client proof input is:

```text
ASCII("CMFA-VPN-RPC/CLIENT-AUTH/v1") || NUL ||
UNHEX(serverNonce) || UNHEX(clientNonce) || UNHEX(serverInstance)
```

### Server authentication

```text
SERVER_AUTH
serverProof = HMAC(rootKey, context | clientNonce | serverNonce | serverInstance)
```

The exact server proof input is:

```text
ASCII("CMFA-VPN-RPC/SERVER-AUTH/v1") || NUL ||
UNHEX(clientNonce) || UNHEX(serverNonce) || UNHEX(serverInstance)
```

After verifying the client proof, the server allocates a safe positive `clientEpoch`, closes the prior authenticated client, and returns that epoch inside `SERVER_AUTH`.

Both sides derive two role-separated connection keys:

```text
c2sKey = HMAC(rootKey,
  ASCII("CMFA-VPN-RPC/C2S-KEY/v1") || NUL ||
  UNHEX(serverNonce) || UNHEX(clientNonce) || UNHEX(serverInstance) || U64BE(clientEpoch))

s2cKey = HMAC(rootKey,
  ASCII("CMFA-VPN-RPC/S2C-KEY/v1") || NUL ||
  UNHEX(serverNonce) || UNHEX(clientNonce) || UNHEX(serverInstance) || U64BE(clientEpoch))
```

The root key remains non-exportable. Derived keys exist only in process memory for the connection lifetime and are dropped on close. Client-to-server frames use `c2sKey`; server-to-client frames use `s2cKey`, preventing reflection between roles.

Handshake requirements:

- protocol version must match exactly;
- nonce lengths and alphabets are exact and bounded;
- handshake timeout is three seconds;
- business frames before authentication close the connection;
- bad proof, replayed nonce, malformed key set, or extra field closes the connection;
- no authentication input appears in logs, errors, proofs, or persisted files.

## Framing and Wire Envelope

LocalSocket is treated as a byte stream.

```text
uint32 bodyLength (big endian)
bodyLength bytes of UTF-8 JSON body
32 raw HMAC bytes after authentication
```

Handshake frames use only `U32BE(bodyLength) || bodyBytes`; business frames append the 32-byte HMAC. The receiver knows which form is valid from its connection authentication state. A buffered business frame before authentication is a protocol error and closes the connection.

The business frame MAC is computed over the exact transmitted bytes, not by parsing and re-serializing JSON:

```text
HMAC(directionKey,
  ASCII("CMFA-VPN-RPC/FRAME/v1") || NUL ||
  U32BE(bodyLength) || bodyBytes)
```

The receiver buffers the full body and MAC, verifies HMAC in constant time, then parses JSON. It never dispatches a body before MAC success.

Limits:

- maximum frame payload: 256 KB;
- maximum buffered incomplete frame: 256 KB plus header;
- maximum 64 pending UI requests;
- maximum 256 cached server responses per client epoch;
- reject zero-length, oversized, truncated-on-close, invalid UTF-8, embedded NUL, duplicate/unknown key, unsafe integer, or unsupported enum;
- never log raw bytes or JSON.

### Normative JSON body

The sender constructs body objects in the following key order, and tests pin the exact UTF-8 bytes:

```text
protocolVersion, kind, sequence, clientEpoch,
requestOrdinal, requestId, method, sessionGeneration,
guards, ok, error, payload
```

Keys not applicable to a kind are still present with `null`, except `payload`, which is always an exact method-specific object. JSON constraints:

- UTF-8 without BOM;
- no insignificant whitespace;
- keys use the order above and exact ASCII spelling;
- strings use JSON escaping with lowercase `\u` hex only when escaping is required;
- opaque IDs/hashes remain lowercase ASCII hex and therefore require no Unicode escaping;
- booleans and `null` use JSON literals;
- numbers are base-10 safe integers only, with no leading zero, plus sign, fraction, or exponent;
- arrays preserve protocol-defined order;
- objects reject missing, extra, duplicate, inherited, symbol, or non-enumerable keys at the ArkTS model boundary;
- payload strings are validated closed values; arbitrary strings are forbidden.

Receivers require semantic validity and the exact key set but do not recompute JSON bytes for MAC verification; MAC already covers the raw transmitted bytes.

Authenticated business envelope:

```text
protocolVersion
kind: REQUEST | RESPONSE | EVENT
sequence
clientEpoch
requestOrdinal | null
requestId | null
method
sessionGeneration
guards
ok | null
error | null
payload
```

`guards` always has the exact keys `profileHash`, `revisionHash`, and `catalogDigest`, each lowercase 64-hex or `null`. Sequence values begin at one after authentication and must increase by exactly one per direction. A duplicate, gap, backward value, or reused sequence closes the connection.

## Opaque Catalog

Raw group and node names never cross the socket.

Both processes load the same committed profile revision and independently calculate a revision-scoped catalog salt:

```text
catalogSalt = HMAC(rootKey,
  ASCII("CMFA-VPN-RPC/CATALOG-SALT/v1") || NUL ||
  UNHEX(profileHash) || UNHEX(revisionHash))
```

IDs:

```text
rootParent = 32 zero bytes

groupId = HMAC(catalogSalt,
  ASCII("CMFA-VPN-RPC/GROUP-ID/v1") || NUL ||
  parentGroupId || U32BE(memberIndex) || LP(normalizedGroupNameUtf8) || U16BE(groupTypeCode))

nodeId = HMAC(catalogSalt,
  ASCII("CMFA-VPN-RPC/NODE-ID/v1") || NUL ||
  groupId || U32BE(memberIndex) || LP(normalizedNodeNameUtf8) || U16BE(nodeTypeCode))
```

Top-level groups use `rootParent` and their top-level list index as `memberIndex`. Nested groups receive path-specific IDs; the same core group referenced from two parents therefore has two different wire IDs that both map to the same local core name. Duplicate names inside one parent remain distinct because `memberIndex` is included.

`normalized*NameUtf8` is produced by the existing closed proxy-label validator: trim the same Unicode whitespace already handled by that validator, preserve the remaining exact Unicode scalar sequence, encode UTF-8, reject embedded NUL and over-limit labels, and do not perform locale-dependent case folding.

Catalog construction uses deterministic depth-first traversal in core-reported order, maximum depth 16, maximum 4096 entries, and ancestor-stack cycle detection. A cycle is represented as an unsupported terminal edge and is never recursively expanded.

Normative numeric codes:

- `kindCode`: `GROUP=1`, `TERMINAL=2`;
- `edgeStateCode`: `NORMAL=1`, `CYCLE_UNSUPPORTED=2`;
- `typeCode` is the one-based index in this exact list:
  `Direct, Reject, RejectDrop, Compatible, Pass, PassRule, Rematch, Dns, Relay, Selector, Fallback, URLTest, LoadBalance, Shadowsocks, ShadowsocksR, Snell, Socks5, Http, Vmess, Vless, Trojan, Hysteria, Hysteria2, WireGuard, Tuic, Ssh, Mieru, AnyTLS, Sudoku, Masque, TrustTunnel, ShadowQuic, OpenVPN, Tailscale, GostRelay`.

Unknown proxy types are rejected as `CATALOG_MISMATCH`; they do not receive an implementation-defined code.

The UI map is `opaque ID -> local display model`. The VPN map is `opaque ID -> live core name`.

The catalog digest input is exact binary data:

```text
ASCII("CMFA-VPN-RPC/CATALOG-DIGEST/v1") || NUL || U32BE(entryCount) ||
for each entry in deterministic depth-first order:
  U16BE(kindCode) || U16BE(typeCode) || U16BE(depth) || U32BE(memberIndex) ||
  parentId(32 bytes) || entryId(32 bytes) || U16BE(edgeStateCode)
```

The digest is `HEX(HMAC(catalogSalt, input))`. It contains no raw names.

Before query, select, or delay operations, the client and server require exact equality of:

- profile hash;
- revision hash;
- catalog digest;
- session generation.

A mismatch returns fixed `CATALOG_MISMATCH`; the UI invalidates its catalog and reloads the committed profile. It never guesses an opaque mapping.

## RPC Methods

### Common payload types

`RuntimeSnapshotPayload` has the exact keys:

```text
state
profileHash | null
revisionHash | null
catalogDigest | null
notificationActive
recoveryAttempt
scheduledRetryDelayMs | null
runtimeFailureCode | null
```

`state` is the existing closed VPN runtime state. `runtimeFailureCode` is the existing closed `VpnFailureCode` union, including `VPN_SYSTEM_REVOKED`; it is runtime domain state, not an RPC transport error. It never contains failure detail.

`DelaySnapshotPayload` has the exact keys:

```text
jobId
delayRevision
proxyGeneration
groupId
state
totalCount
completedCount
results
```

Each `results` item has exact keys `nodeId`, `status`, and `delayMs`. `status` is `WAITING | TESTING | AVAILABLE | TIMEOUT | FAILED | CANCELLED | UNSUPPORTED`; `delayMs` is a safe positive integer only for `AVAILABLE`, otherwise `null`. Results use catalog order.

Request bodies use `ok:null` and `error:null`. Successful responses use `ok:true`, `error:null`. Failed responses use `ok:false`, an exact `error:{code,retryable}`, and `payload:{}`. Events use `requestOrdinal:null`, `requestId:null`, `ok:null`, and `error:null`.

### Exact method contract

| Method | Required guards | Request payload | Success payload |
| --- | --- | --- | --- |
| `PING` | all guard fields `null`, generation `0` allowed | `{}` | `{serverInstance}` |
| `GET_SNAPSHOT` | all guard fields `null`, generation `0` allowed | `{}` | `RuntimeSnapshotPayload` |
| `GET_CATALOG_DIGEST` | profile/revision exact; catalog `null`; active generation exact | `{}` | `{catalogDigest,entryCount}` |
| `QUERY_GROUPS` | all guards and generation exact | `{}` | `{proxyGeneration,groups}` |
| `QUERY_GROUP` | all guards and generation exact | `{groupId}` | `{proxyGeneration,groupId,selectedNodeId,nodes}` |
| `SELECT_NODE` | all guards and generation exact | `{proxyGeneration,groupId,nodeId}` | `{proxyGeneration,groupId,selectedNodeId,persisted}` |
| `START_DELAY_TEST` | all guards and generation exact | `{proxyGeneration,groupId}` | `DelaySnapshotPayload` |
| `READ_DELAY_TEST` | all guards and generation exact | `{jobId}` | `DelaySnapshotPayload` |
| `CANCEL_DELAY_TEST` | all guards and generation exact | `{jobId}` | `DelaySnapshotPayload` |
| `STOP_VPN` | all active guards and generation exact | `{}` | `RuntimeSnapshotPayload` |

Array item shapes are exact:

- `groups`: `{groupId,type,isSelectable}`;
- `nodes`: `{nodeId,kind,type,selected}`;
- `kind`: `GROUP | TERMINAL`;
- `selectedNodeId`: lowercase 64-hex or `null`;
- `persisted`: boolean only;
- `proxyGeneration`, `delayRevision`, counts, and `entryCount`: safe non-negative integers, positive where the existing domain model requires it;
- `jobId`: 32 random bytes encoded as lowercase 64-hex, unrelated to core job IDs or private names.

The server translates the opaque RPC job ID to the real core delay job ID in process memory. The real job ID never crosses the socket.

### Runtime

- `GET_SNAPSHOT`: authoritative VPN snapshot.
- `PING`: authenticated liveness check.
- `STOP_VPN`: serialized coordinator stop and terminal snapshot.

VPN start is not an RPC method. The UI launches the extension with the existing system API, then connects to the server.

### Proxy

- `GET_CATALOG_DIGEST`
- `QUERY_GROUPS`
- `QUERY_GROUP`
- `SELECT_NODE`

Responses contain opaque IDs, closed proxy types, booleans, safe generations, delay values, and fixed errors only.

### Delay

- `START_DELAY_TEST`
- `READ_DELAY_TEST`
- `CANCEL_DELAY_TEST`

One delay job may exist for the active session. The server owns cancellation and drain. UI route exit or disposal requests cancel and waits for a terminal state before considering cleanup complete.

### Events

- `RUNTIME_CHANGED`
- `DELAY_CHANGED`
- `SERVER_STOPPING`

Runtime and delay events reuse the same closed, opaque payload models as their corresponding responses. `SERVER_STOPPING` deliberately carries an empty payload.

- `RUNTIME_CHANGED` payload is exactly `RuntimeSnapshotPayload` and carries the active guards in the envelope.
- `DELAY_CHANGED` payload is exactly `DelaySnapshotPayload` and carries the active guards in the envelope.
- `SERVER_STOPPING` payload is `{}` and carries the last active generation/guards when available, otherwise generation zero and null guards.

`DELAY_CHANGED` is an opportunistic low-latency update, not a second owner. The server delay job and `delayRevision` are authoritative. `READ_DELAY_TEST` and `DELAY_CHANGED` return the same snapshot shape. The UI applies only a snapshot with a greater `delayRevision`; after reconnect it uses `READ_DELAY_TEST` to catch up.

## Server Dispatch and Idempotency

The server uses one serialized command queue for state-changing operations.

Rules:

- one active authenticated client;
- a newly authenticated client increments `clientEpoch` and closes the previous client;
- one proxy selection mutation at a time;
- one delay job at a time;
- request IDs are client-generated UUIDs validated as exact lowercase canonical values;
- `requestOrdinal` is a safe positive integer, starts at one per client epoch, and normally increases by exactly one per new logical request;
- retry frames use a new frame sequence but reuse the same `requestOrdinal` and `requestId`;
- a bounded FIFO response cache stores the latest 256 `(requestOrdinal, requestId, response)` entries and returns the byte-equivalent response for a cached retry;
- the server stores the highest accepted request ordinal separately from the cache;
- `requestOrdinal == highest + 1` executes as new work;
- `requestOrdinal <= highest` returns the cached response when present; if evicted, it returns fixed `REQUEST_REPLAY_EXPIRED` and never executes again;
- `requestOrdinal > highest + 1` is `FRAME_INVALID` and closes the connection;
- a reused ordinal with a different request ID is `FRAME_INVALID` and closes the connection;
- a duplicate request never repeats `SELECT_NODE`, `START_DELAY_TEST`, `CANCEL_DELAY_TEST`, or `STOP_VPN`;
- response cache entries expire after the connection closes or server restarts;
- old client epoch, session generation, profile revision, or catalog requests fail closed.

Pending requests are not replayed across reconnect/client-epoch replacement. They fail with `RPC_DISCONNECTED`. The new client obtains a fresh snapshot/query to reconcile whether a prior mutation completed.

## UI Client State Machine

```text
DISCONNECTED
CONNECTING
AUTHENTICATING
READY
RECONNECTING
CLOSED
```

### Start flow

1. Arm the existing bounded start confirmation.
2. Launch `CmfaVpnExtensionAbility` through HarmonyOS.
3. Retry LocalSocket connection for at most 15 seconds.
4. Authenticate within three seconds.
5. Request `GET_SNAPSHOT`.
6. For `STARTING`, wait for state events inside the original bounded confirmation window.
7. Publish UI `RUNNING` only after an authenticated matching server snapshot reports `RUNNING` and the catalog digest matches.
8. On timeout/failure, release UI pending state and expose one fixed safe error. The action must not remain BUSY indefinitely.

### Reconnect and hydration

On UIAbility creation, try the fixed LocalSocket address before publishing application `READY`:

- no server: hydrate stopped/unknown safely without claiming `RUNNING`;
- authenticated server: read snapshot and catalog digest, then hydrate;
- transient disconnect: mark `RECOVERING`, reject all pending promises, and bounded-reconnect;
- reconnect success: receive and adopt the new server-allocated client epoch, then replace state from a fresh snapshot;
- reconnect exhaustion: publish fixed `RPC_UNAVAILABLE`, not stale cached `RUNNING`.

### Stop flow

```text
UI STOP_VPN request
server coordinator.stop()
server STOPPED response/event
UI closes RPC
UI calls system stopVpnExtensionAbility
```

If RPC is already unavailable, the UI still calls the system stop API and exposes a bounded "stop result unknown" error until server absence/extension destruction is confirmed.

## Disconnect and Cleanup

### UI disconnect

- reject every pending request with fixed `RPC_DISCONNECTED`;
- invalidate the client epoch;
- cancel/drain UI-owned delay work through the server when the connection is still writable;
- never stop VPN merely because the UI disappears.

### VPN server disconnect or crash

- UI clears its running node marker;
- UI publishes fixed `VPN_SYSTEM_REVOKED` or `RPC_UNAVAILABLE` according to system extension state;
- no cached snapshot may preserve `RUNNING`;
- server restart creates a new server instance, transcript, sequence space, and client epoch.

### Server shutdown

- reject new work with `SERVER_STOPPING`;
- cancel and drain delay work;
- stop/finish coordinator lifecycle;
- send terminal event when possible;
- close active connection and LocalSocketServer;
- release derived connection material and opaque catalog maps.

## Timeouts

- connection retry window: 15 seconds;
- authentication: 3 seconds;
- ordinary query: 5 seconds;
- selection mutation: 8 seconds;
- stop: 15 seconds;
- delay start/cancel: 8 seconds;
- delay job total bound: existing configured delay bound, never unbounded;
- reconnect: bounded attempts with capped backoff inside the UI lifecycle.

Scheduler failure itself maps to fixed `RPC_UNAVAILABLE` and releases pending UI state.

## Error Contract

Wire errors are closed:

- `RPC_UNAVAILABLE`
- `RPC_DISCONNECTED`
- `AUTH_FAILED`
- `PROTOCOL_MISMATCH`
- `FRAME_INVALID`
- `SESSION_CHANGED`
- `CATALOG_MISMATCH`
- `COMMAND_BUSY`
- `COMMAND_TIMEOUT`
- `CORE_OPERATION_FAILED`
- `REQUEST_REPLAY_EXPIRED`
- `SERVER_STOPPING`

Errors contain only code and retryable boolean. Raw exception messages, paths, identifiers, socket addresses, payloads, HUKS results, stacks, and core details are forbidden.

## Migration from the Failed Native Bridge

After the LocalSocket RPC path is green and physically proven:

- replace `HarmonyVpnController` native snapshot polling with `VpnRpcClient` snapshots/events;
- replace the UI local `VpnProxyRuntimeHandler` mirror with `VpnRpcProxyHandler`;
- start and stop `VpnRpcServer` from `VpnExtensionComposition`;
- keep the extension-side `VpnProxyRuntimeHandler`, replay order, and command authority;
- remove `vpn_runtime_bridge_store.h/.cpp`;
- remove `js_vpn_runtime_bridge.cpp` and its four NAPI exports;
- remove `NativeVpnRuntimeBridge` and process-static ownership code;
- remove tests/contracts that assert the obsolete process-global transport;
- retain reusable closed snapshot/failure models only after renaming them as RPC models and removing transport-specific semantics;
- preserve one-click orchestration, selection persistence, delay presentation, and proof schemas unless the new transport requires an explicitly reviewed version bump.

No fallback path remains. The application has one running proxy command path: authenticated LocalSocket RPC to the VPN process.

## Testing Strategy

### Protocol and framing

- golden byte vectors for both handshake proofs, role keys, socket address, frame MACs, opaque IDs, and catalog digest;
- exact method request/response/event JSON byte vectors and key order;
- fragmented header/body and every chunk boundary;
- multiple coalesced frames;
- zero, oversized, truncated, invalid UTF-8, embedded NUL;
- extra/missing/duplicate keys and invalid enums;
- unsafe integers and length overflow;
- random chunk/property tests and bounded fuzzing;
- frame MAC byte stability over the exact transmitted body.

### Authentication and security

- successful mutual authentication;
- missing/wrong HUKS key;
- bad proof, nonce replay, sequence replay, MAC mutation;
- business frame before authentication;
- old server instance/client epoch;
- HUKS key cannot be exported;
- no handshake/frame/name/address/error value enters logs or artifacts.

### Opaque catalog

- deterministic mapping across UI/VPN fixtures;
- different revision/key/name produces different IDs;
- normalization consistency;
- nested groups and duplicate names under different parents;
- catalog digest mismatch fails closed;
- raw names absent from encoded frames and persisted outputs.

### Client/server lifecycle

- server unavailable and bounded connect retry;
- handshake timeout;
- one active client and new-epoch replacement;
- duplicate request idempotency;
- ordinal reuse with a different request ID closes the connection;
- cached duplicate returns byte-equivalent response;
- duplicate after FIFO eviction returns `REQUEST_REPLAY_EXPIRED` and never re-executes mutation;
- disconnect rejects all pending requests;
- late response/event cannot update a new client;
- UI recreation reconnects and hydrates before `READY`;
- VPN process exit clears UI running state;
- scheduler failure cannot leave BUSY;
- server shutdown drains and closes exactly once.
- address-in-use fails closed without unlinking an unknown listener;
- server restart receives a new instance/epoch and stale frames fail authentication.

### Functional integration

- start/stop VPN;
- query groups/group;
- select opaque terminal node;
- running hot-switch without session restart;
- list/start/read/cancel/drain delay job;
- local proxy automatically stops before VPN start;
- network change `RECOVERING -> RUNNING`;
- profile revision/catalog drift;
- UI route exit and process recreation.
- every RPC method validates its exact guards and method-specific payload shape.

### Structure and privacy

- LocalSocket is the only running RPC transport;
- no CommonEvent business payload, TCP fallback, RDB/file/AppStorage bridge, or direct-native UI path;
- VPN process remains sole writer/mutator;
- raw private fields absent from wire models, logs, semantic IDs, docs examples, and proof artifacts;
- signing isolation remains exact.

## Physical Device Acceptance

Use one fresh signed production HAP on a connected HarmonyOS 6 phone while confirming UI and VPN Extension remain separate PIDs.

Required proof:

1. stopped runtime: select node, system VPN connects, same node becomes runtime-selected;
2. local runtime: local stops automatically, VPN connects, node becomes selected;
3. running VPN: hot-switch node without changing VPN session;
4. UIAbility exits/recreates: authenticated reconnect restores state and hot-switch capability;
5. batch delay: all nodes report terminal outcomes; cancellation drains;
6. system VPN indicator/settings show a real active VPN;
7. independent browser and probe application traffic is captured;
8. stopping VPN removes capture and restores traffic;
9. successful authenticated two-process operation is proven on the production HAP, while deterministic protocol/authenticator tests prove unauthenticated, bad-MAC, and replay clients are rejected without state mutation; no production adversarial hook is added;
10. cleanup removes remote evidence, sockets, jobs, temp roots, and leaves both bundles stopped;
11. one-click/recreation proof and delay proof both validate as `pass` for the same HAP hash;
12. build profile is restored exactly to `signingConfigs: []`.

Any missing physical invariant results in `incomplete`; no code-only or simulator-only claim may substitute.

## Delivery Constraints

- HarmonyOS 6.x phone, model-independent.
- No new third-party dependencies.
- No commit or push unless the user later changes the standing instruction.
- Preserve unrelated dirty-worktree changes.
- TDD for every implementation task, followed by independent spec and quality review.
- Fresh signed HAP and both physical proofs are mandatory for completion.

## Appendix A: Normative Golden Vector V1

All hex values are lowercase. These are test-only public fixtures; they are not production keys or identities.

Inputs:

```text
rootKey       = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
serverNonce   = 202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
clientNonce   = 404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f
serverInstance= 606162636465666768696a6b6c6d6e6f
clientEpoch   = 7
profileHash   = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
revisionHash  = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

Authentication/address outputs:

```text
clientProof = 971120fc74215711b7de184881eb809ef8cb8bff91b23cf5452f1b3c797918d6
serverProof = 3cb796ee27a9e40d0ee39dd41321673242dd4c25b33a3efb06fa181fabdec5cf
c2sKey      = 17490f3b8bcfcabf9fea8acbfb448aa912d0c4c000ea6404603201571ca79f34
s2cKey      = 547dcc95ad1dea16c6b87b305be8f228fe56e73492f5649a485dfa35223d83aa
socketAddress = cmfa_vpn_rpc_v1_f3c721d1d7466775b7f4687f04762580
```

Catalog fixture: one top-level `Selector` group named `Proxy` at index zero with one terminal `Vmess` node named `HK` at index zero.

```text
catalogSalt  = 6ed74afc4b4442d50cb34e3d7d3dcf194f08eefcfe362d55d2d896572c9101ab
groupId      = f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a1
nodeId       = b0a8d82ab2b6e1ad9a5e2eccc169707e55492a94a5f346435864b66a78284757
catalogDigest= 439490f7d5c249e4568e736a9e7a0f45c674f6fb355adf8d61d82a1d0276f219
```

Canonical PING request body (`bodyLength=282`):

```json
{"protocolVersion":1,"kind":"REQUEST","sequence":1,"clientEpoch":7,"requestOrdinal":1,"requestId":"00000000-0000-4000-8000-000000000001","method":"PING","sessionGeneration":0,"guards":{"profileHash":null,"revisionHash":null,"catalogDigest":null},"ok":null,"error":null,"payload":{}}
```

Using `c2sKey`, the authenticated frame MAC is:

```text
483e45b6d88e7ba872ec135d4049e334acc7230c36bd60c23f39bf7fd4f28f32
```

Tests must copy these literals into an independent fixture. They must not generate expected values through production RPC code.
