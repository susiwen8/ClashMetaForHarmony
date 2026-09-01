# HarmonyOS VPN Cross-Process LocalSocket RPC Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the failed process-static VPN bridge with an authenticated LocalSocket RPC channel that makes VPN state, node selection, hot-switching, delay tests, and UI recreation work across the real separate UI/VPN processes.

**Architecture:** Pure protocol/framing/catalog/client/server units live in `@cmfa/shared`; HarmonyOS HUKS and LocalSocket adapters live in `@cmfa/platform`; entry composition wires one UI client and one VPN-process server into the existing controller, command bus, coordinator, and proxy handler. After device-proven cutover, the obsolete native process-static bridge is deleted so there is exactly one running command path.

**Tech Stack:** HarmonyOS 6.x/API 20+, ArkTS, Network Kit LocalSocket, HUKS HMAC-SHA256, Hypium, Node structure/device-proof tests, HDC/UITest.

**Design:** `docs/superpowers/specs/2026-08-25-harmonyos-vpn-cross-process-local-socket-rpc-design.md`

**Working constraint:** Do not commit or push. Preserve unrelated dirty-worktree changes. Every task uses RED → GREEN → independent spec review → independent quality/privacy review. The final signing window must restore `harmony/build-profile.json5` byte-for-byte to `"signingConfigs": []`.

---

## File Map

### Shared protocol and runtime units

- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcModels.ets` — closed wire enums, handshake/body/guard/error value objects and envelope validation.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPayloads.ets` — exact runtime/group/select/delay payload value objects, cloning, and method-specific validation.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBinaryCodec.ets` — U16/U32/U64 big-endian, hex, length-prefix, fixed-time comparison, and bounded UTF-8 helpers.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBodyCodec.ets` — exact key order and canonical compact JSON bytes for every handshake/request/response/event body.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcFramer.ets` — incremental stream framing, fragmentation/coalescing, MAC trailer handling, buffer limits, and close-on-truncation.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets` — HMAC, randomness, socket client/server/connection, scheduler, clock, and runtime-dispatch ports.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcAuthenticator.ets` — handshake state machine, role-separated key derivation, sequence/MAC verification, and authenticated connection wrapper.
- `harmony/shared/src/main/ets/vpn/rpc/VpnOpaqueCatalog.ets` — deterministic path-aware opaque ID maps and catalog digest.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcClient.ets` — connect/authenticate, pending requests, ordinal/cache reconciliation, events, reconnect, snapshot hydration, and disposal.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcServer.ets` — one-client server, client epochs, serialized dispatch, exactly-once response cache, state events, delay ownership, and shutdown.
- `harmony/shared/src/main/ets/vpn/rpc/VpnRpcProxyHandler.ets` — UI-side implementation of existing query/select/delay commands using opaque RPC.
- Matching focused tests under `harmony/shared/src/test/` and exports/registration in `harmony/shared/Index.ets` plus `harmony/shared/src/test/List.test.ets`.

### HarmonyOS platform adapters

- `harmony/platform/src/main/ets/vpn/HarmonyVpnRpcKeyProvider.ets` — versioned HUKS HMAC key get-or-create and bounded HMAC operations.
- `harmony/platform/src/main/ets/vpn/HarmonyVpnLocalSocketClient.ets` — Network Kit LocalSocket client adapter.
- `harmony/platform/src/main/ets/vpn/HarmonyVpnLocalSocketServer.ets` — LocalSocketServer and connection adapters with balanced event cleanup.
- `harmony/platform/src/main/ets/vpn/HarmonyVpnRpcPlatformFactory.ets` — small factory returning the shared ports from an ability context.
- Matching platform tests, `PlatformFactory.ets` integration where needed, exports, and `harmony/platform/src/test/List.test.ets` registration.

### Entry integration

- `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets` — replace process-static snapshot polling with authenticated RPC connect/snapshot/events/stop.
- `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets` — start and stop `VpnRpcServer`, expose coordinator/proxy authority, publish state events.
- `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets` — construct one UI RPC client/proxy handler and hydrate before `READY`.
- `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets` — retain safe hydration helpers but accept only authenticated RPC snapshots.
- Matching controller/composition/registry/application tests.

### Obsolete bridge deletion and contracts

- Delete native store/NAPI/host tests and entry-private `NativeVpnRuntimeBridge` files after RPC cutover.
- Update CMake, NAPI descriptors/types, native host runner, structure/privacy contracts, implementation docs, and physical proof runner.
- Retain generic package-inspector privacy fixes and all unrelated native proxy/TUN functionality.

## Per-Task Execution Protocol

For every Task 1–16:

1. add the focused failing test first;
2. run it and record an attributable RED;
3. implement the smallest production change;
4. run focused and stated regression gates to GREEN;
5. dispatch an independent spec reviewer and fix/re-review to approval;
6. only then dispatch a different quality/privacy reviewer and fix every Critical/Important issue;
7. run the checkpoint and leave the worktree uncommitted.

---

## Chunk 1: Protocol, Framing, Authentication, and Opaque Catalog

### Task 1: Add exact wire models and canonical body codec

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcModels.ets`
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPayloads.ets`
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBodyCodec.ets`
- Create: `harmony/shared/src/test/VpnRpcModels.test.ets`
- Create: `harmony/shared/src/test/VpnRpcPayloads.test.ets`
- Create: `harmony/shared/src/test/VpnRpcBodyCodec.test.ets`
- Create: `harmony/tests/fixtures/vpn-rpc-golden-v1.json`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing closed-model and golden-body tests**

Define exact protocol types from the design, including:

```ts
export type VpnRpcKind = 'REQUEST' | 'RESPONSE' | 'EVENT';
export type VpnRpcMethod =
  | 'PING' | 'GET_SNAPSHOT' | 'GET_CATALOG_DIGEST'
  | 'QUERY_GROUPS' | 'QUERY_GROUP' | 'SELECT_NODE'
  | 'START_DELAY_TEST' | 'READ_DELAY_TEST' | 'CANCEL_DELAY_TEST'
  | 'STOP_VPN' | 'RUNTIME_CHANGED' | 'DELAY_CHANGED' | 'SERVER_STOPPING';

export interface VpnRpcGuards {
  profileHash: string | null;
  revisionHash: string | null;
  catalogDigest: string | null;
}

export interface VpnRpcBody {
  protocolVersion: 1;
  kind: VpnRpcKind;
  sequence: number;
  clientEpoch: number;
  requestOrdinal: number | null;
  requestId: string | null;
  method: VpnRpcMethod;
  sessionGeneration: number;
  guards: VpnRpcGuards;
  ok: boolean | null;
  error: VpnRpcError | null;
  payload: VpnRpcPayload;
}
```

Copy the literal inputs/outputs from spec Appendix A into `vpn-rpc-golden-v1.json`. Tests pin all method-specific request/response/event payload key sets, closed errors, runtime failure codes, safe integers, exact hash/UUID/job formats, delay invariants, missing/extra keys, and the exact compact UTF-8 JSON golden bytes. Expected values must come from the fixture, never from production encoder helpers.

- [ ] **Step 2: Run shared tests and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because RPC models/codecs do not exist.

- [ ] **Step 3: Implement explicit value classes and method validators**

Use ArkTS-safe nominal classes. Do not use `any`, `unknown`, runtime prototype mutation, `Symbol`, or reflection. `VpnRpcBodyCodec` writes keys explicitly in normative order and accepts no arbitrary string payload.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run shared tests and `git diff --check` on owned files. Expected: golden bodies and every closed-model case pass.

### Task 2: Add binary helpers and incremental authenticated framing

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcBinaryCodec.ets`
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcFramer.ets`
- Create: `harmony/shared/src/test/VpnRpcBinaryCodec.test.ets`
- Create: `harmony/shared/src/test/VpnRpcFramer.test.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing binary/framing tests**

Cover exact U16/U32/U64 big-endian vectors, lower-hex, `LP`, bounded UTF-8, constant-time equality, fragmented header/body/MAC at every boundary, multiple coalesced frames, zero/oversize/truncated frames, pre-auth vs authenticated trailer rules, and buffer limits.

Use a frame port shaped as:

```ts
export interface VpnRpcDecodedFrame {
  bodyBytes: Uint8Array;
  macBytes: Uint8Array | null;
}

export class VpnRpcFramer {
  push(chunk: Uint8Array, authenticated: boolean): VpnRpcDecodedFrame[];
  finish(): void;
  reset(): void;
}
```

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `VpnRpcBinaryCodec`/`VpnRpcFramer` are missing.

- [ ] **Step 3: Implement bounded buffer/framer**

Never decode JSON or log bytes inside the framer. Reject body length outside `1..262144`; cap the total buffered bytes; copy returned frames so later pushes cannot mutate them.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run the exact shared command from Step 2, then:

```bash
cd ..
git diff --check -- harmony/shared/src/main/ets/vpn/rpc harmony/shared/src/test/VpnRpcBinaryCodec.test.ets harmony/shared/src/test/VpnRpcFramer.test.ets
```

Expected: shared build passes, all chunk-boundary/property loops pass without flake, diff check is clean.

### Task 3: Add HMAC/authentication state machine ports

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets`
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcAuthenticator.ets`
- Create: `harmony/shared/src/test/VpnRpcAuthenticator.test.ets`
- Create: `harmony/shared/src/test/fakes/VpnRpcFakes.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing handshake/MAC/replay tests**

Add ports:

```ts
export interface VpnRpcCryptoPort {
  prepare(): Promise<void>;
  rootHmac(input: Uint8Array): Promise<Uint8Array>;
  derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array>;
}

export interface VpnRpcRandomPort {
  bytes(length: number): Uint8Array;
}

export interface VpnRpcCancelableTaskPort {
  cancel(): void;
}

export interface VpnRpcSchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort;
}

export interface VpnRpcClockPort {
  nowMs(): number;
}
```

Test the spec golden vectors for client proof, server proof, C2S/S2C keys, address derivation, authenticated frame MAC, mutual role separation, authentication timeout, business-before-auth, nonce/MAC/sequence replay, clientEpoch adoption, constant-time failure behavior, and zero raw values in errors.

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because authenticator/crypto ports are missing.

- [ ] **Step 3: Implement client/server handshake machines**

Expose focused client and server authenticators rather than one mode-heavy class. `rootHmac` is backed by HUKS; `derivedHmac` is backed by a platform crypto adapter over connection-scoped bytes. Derived keys are copied only for connection lifetime and cleared on dispose. Sequence begins at one and increments exactly.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run the Step 2 command and:

```bash
cd ..
git diff --check -- harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets harmony/shared/src/main/ets/vpn/rpc/VpnRpcAuthenticator.ets harmony/shared/src/test/VpnRpcAuthenticator.test.ets harmony/shared/src/test/fakes/VpnRpcFakes.ets harmony/shared/Index.ets
```

Expected: Appendix A vectors, role separation, replay, timeout cleanup, and diff check pass.

### Task 4: Add path-aware opaque catalog and digest

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnOpaqueCatalog.ets`
- Create: `harmony/shared/src/test/VpnOpaqueCatalog.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing catalog tests**

Model a catalog input without transport dependencies:

```ts
export interface VpnCatalogGroupInput {
  name: string;
  type: string;
  members: VpnCatalogMemberInput[];
}
```

Cover root/nested IDs, duplicate names under different parents, duplicates within one group, stable order, path-specific references to one core group, depth 16, 4096-entry bound, cycle terminal edges, different revision/key/name, exact digest golden vectors, and encoded output containing no raw names.

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `VpnOpaqueCatalog` is missing.

- [ ] **Step 3: Implement deterministic DFS maps**

Use the existing proxy label validator, explicit member index, parent ID, closed type codes, and HMAC port. Return separate UI and VPN lookup views without exposing raw names from the wire model.

- [ ] **Step 4: Run shared GREEN and Chunk 1 checkpoint**

Run the Step 2 command and:

```bash
cd ..
git diff --check -- harmony/shared/src/main/ets/vpn/rpc/VpnOpaqueCatalog.ets harmony/shared/src/test/VpnOpaqueCatalog.test.ets harmony/shared/Index.ets
```

Expected: shared tests and Appendix A catalog vectors pass. Dispatch Chunk 1 spec/quality reviews before starting transport work.

---

## Chunk 2: HarmonyOS HUKS/LocalSocket Adapters and RPC Engines

### Task 5: Add the HarmonyOS HUKS RPC key provider

**Files:**
- Create: `harmony/platform/src/main/ets/vpn/HarmonyVpnRpcKeyProvider.ets`
- Create: `harmony/platform/src/test/HarmonyVpnRpcKeyProvider.test.ets`
- Modify: `harmony/platform/src/main/ets/secrets/HuksDriver.ets`
- Modify: `harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing HUKS key/HMAC tests**

Add only the generic HMAC operations needed by the RPC provider. Test fixed alias/options (`HUKS_ALG_HMAC`, SHA-256, sign/verify purpose as supported by SDK), non-exportability, get-or-create, concurrent already-exists race, HUKS session abort on failure, exact 32-byte output, and fixed privacy-safe errors.

The deterministic non-exportability seam is architectural: the RPC key/provider interfaces and fakeable HUKS operations expose no export method, tests assert the generated key options omit extractable/export tags, and the later structure contract rejects any `exportKeyItem` reference in RPC code. Do not add a fake export API solely for testing.

- [ ] **Step 2: Run platform RED**

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
```

- [ ] **Step 3: Implement minimal driver/provider additions**

Reuse the existing HUKS operations abstraction; do not couple RPC to subscription-secret encryption. Never call `exportKeyItem`.

- [ ] **Step 4: Run platform GREEN and checkpoint**

Run the Step 2 command, then:

```bash
cd ..
git diff --check -- harmony/platform/src/main/ets/vpn/HarmonyVpnRpcKeyProvider.ets harmony/platform/src/main/ets/secrets/HuksDriver.ets harmony/platform/src/main/ets/secrets/HarmonyHuksDriver.ets harmony/platform/src/test/HarmonyVpnRpcKeyProvider.test.ets
```

Expected: platform tests and diff check pass.

### Task 6: Add LocalSocket client/server platform adapters

**Files:**
- Create: `harmony/platform/src/main/ets/vpn/HarmonyVpnLocalSocketClient.ets`
- Create: `harmony/platform/src/main/ets/vpn/HarmonyVpnLocalSocketServer.ets`
- Create: `harmony/platform/src/main/ets/vpn/HarmonyVpnRpcPlatformFactory.ets`
- Create: `harmony/platform/src/test/HarmonyVpnLocalSocketClient.test.ets`
- Create: `harmony/platform/src/test/HarmonyVpnLocalSocketServer.test.ets`
- Create: `harmony/platform/src/test/HarmonyVpnRpcPlatformFactory.test.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing balanced-lifecycle adapter tests**

Use the exact shared ports:

```ts
export interface VpnRpcSocketConnectionPort {
  send(bytes: Uint8Array): Promise<void>;
  subscribeData(listener: (bytes: Uint8Array) => void): number;
  unsubscribeData(id: number): void;
  subscribeClose(listener: () => void): number;
  unsubscribeClose(id: number): void;
  subscribeError(listener: () => void): number;
  unsubscribeError(id: number): void;
  close(): Promise<void>;
}

export interface VpnRpcSocketClientFactoryPort {
  connect(address: string, timeoutMs: number): Promise<VpnRpcSocketConnectionPort>;
}

export interface VpnRpcSocketServerPort {
  listen(address: string, listener: (connection: VpnRpcSocketConnectionPort) => void): Promise<void>;
  close(): Promise<void>;
}
```

Platform errors are normalized at the adapter boundary to `CONNECT_REFUSED | ADDRESS_IN_USE | SEND_FAILED | CLOSED | PLATFORM_FAILED`; no SDK error object crosses into shared code. Test sync callback during registration, fragmented `ArrayBuffer`, connect refusal, address in use, send failure, duplicate close, callback removal exactly once, server connection replacement, and no raw SDK errors/addresses.

- [ ] **Step 2: Run platform RED**

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
```

Expected: compile failure because LocalSocket adapters/ports are missing.

- [ ] **Step 3: Implement Network Kit adapters**

Wrap `socket.constructLocalSocketInstance()` and `constructLocalSocketServerInstance()` behind injectable SDK drivers. Convert callbacks to copied `Uint8Array`; never expose SDK socket objects to shared code. `HarmonyVpnRpcPlatformFactory` is the only public platform assembly point for RPC key/crypto/socket/random ports; export it from `harmony/platform/Index.ets` and keep generic `PlatformFactory.ets` unchanged in this task.

- [ ] **Step 4: Run platform GREEN and checkpoint**

Run the Step 2 command and a scoped `git diff --check` for both adapters/tests. Expected: platform tests and balanced-listener assertions pass.

### Task 7: Implement authenticated `VpnRpcClient`

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcClient.ets`
- Create: `harmony/shared/src/test/VpnRpcClient.test.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing client state-machine tests**

Cover DISCONNECTED→CONNECTING→AUTHENTICATING→READY, 15-second bounded retry, pending limit 64, request ordinal/retry, exact response matching, wrong epoch/request/method, server events, disconnect rejection, late response suppression, reconnect with server-assigned epoch, snapshot hydration, scheduler throw, timeout cleanup, route-exit delay cancel, and dispose idempotency. After reconnect, a remembered opaque delay job performs `READ_DELAY_TEST`; only snapshots with strictly greater `delayRevision` apply, and stale `DELAY_CHANGED` events are ignored.

Expose a port such as:

```ts
export interface VpnRpcClientPort {
  connect(): Promise<void>;
  request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload): Promise<VpnRpcBody>;
  snapshot(): VpnRuntimeSnapshot;
  subscribe(listener: VpnRpcEventListener): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}
```

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `VpnRpcClient` is missing.

- [ ] **Step 3: Implement one connection owner and bounded pending map**

No automatic replay across client epochs. Events and responses apply only after MAC/sequence/body validation. Every public failure maps to the closed error contract.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run the Step 2 command and scoped diff check. Expected: all client/reconnect/delay reconciliation tests pass.

### Task 8: Implement authenticated server session and exactly-once cache

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcServerSession.ets`
- Create: `harmony/shared/src/test/VpnRpcServerSession.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing server tests**

Cover listen/auth, one client replacement, server epoch allocation, frame/body validation, cached retry, different ID same ordinal close, 257th-entry FIFO eviction, `REQUEST_REPLAY_EXPIRED`, no duplicate dispatch, server stopping, address-in-use fail-close, and cleanup exactly once. This task does not implement VPN methods.

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `VpnRpcServerSession` is missing.

- [ ] **Step 3: Implement session against an injected request callback**

Keep socket/auth/cache mechanics separate from VPN business dispatch. The session accepts one callback `(validatedRequest) => Promise<validatedResponse>`. Cache already encoded response bodies so a duplicate returns byte-equivalent output.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run the Step 2 command and scoped diff check; expected: session/cache tests pass independently of VPN fakes.

### Task 9: Implement `VpnRpcServer` runtime dispatch, events, and delay ownership

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcServer.ets`
- Create: `harmony/shared/src/test/VpnRpcServer.test.ets`
- Modify: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcPorts.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing business-dispatch tests**

Define the exact runtime dispatch port:

```ts
export interface VpnRpcRuntimeDispatchPort {
  snapshot(): VpnRuntimeSnapshot;
  catalog(): VpnOpaqueCatalog;
  queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult>;
  queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult>;
  select(command: VpnProxySelectCommand): Promise<ProxySelectionResult>;
  startDelay(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult>;
  readDelay(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult>;
  cancelDelay(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult>;
  stop(): Promise<VpnControllerStopResult>;
}
```

Cover guards and all methods, serialized mutation, opaque mapping, fixed errors, runtime events, one server-owned delay job, monotonic `delayRevision`, `DELAY_CHANGED` and `READ_DELAY_TEST` returning the same snapshot, stale event suppression, stop/shutdown drain, and zero raw names.

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because the business server/dispatch surface is missing.

- [ ] **Step 3: Implement business server over `VpnRpcServerSession`**

The business server never accesses SDK sockets or HUKS directly. It maps validated requests to the injected dispatch port and pushes only validated event bodies.

- [ ] **Step 4: Run shared/platform GREEN and Chunk 2 checkpoint**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
cd ..
git diff --check -- harmony/shared/src/main/ets/vpn/rpc harmony/shared/src/test/VpnRpcServer.test.ets harmony/platform/src/main/ets/vpn harmony/platform/src/test/HarmonyVpnRpcKeyProvider.test.ets harmony/platform/src/test/HarmonyVpnLocalSocketClient.test.ets harmony/platform/src/test/HarmonyVpnLocalSocketServer.test.ets
```

Expected: both module suites and diff check pass. Dispatch independent Chunk 2 reviews.

---

## Chunk 3: Proxy/VPN Domain Integration and Entry Wiring

### Task 10: Add the opaque RPC proxy handler

**Files:**
- Create: `harmony/shared/src/main/ets/vpn/rpc/VpnRpcProxyHandler.ets`
- Create: `harmony/shared/src/test/VpnRpcProxyHandler.test.ets`
- Modify: `harmony/shared/src/main/ets/proxy/ProxyPorts.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/shared/src/test/List.test.ets`

- [ ] **Step 1: Write failing query/select/delay mapping tests**

Cover local catalog lookup, catalog mismatch, group/node opaque mapping, proxy generation, selected marker, APPLIED_NOW/APPLIED_NOT_PERSISTED, all delay states/results, session change, timeout, disconnect, and zero raw names in captured wire requests.

- [ ] **Step 2: Run shared RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
```

Expected: compile failure because `VpnRpcProxyHandler` is missing.

- [ ] **Step 3: Implement the existing command-handler interfaces through RPC**

Bind this handler to the UI `VpnProxyCommandBus`; remove any need for a UI `VpnProxyRuntimeHandler` while running. Stopped-path `ProxyService` remains local and unchanged.

- [ ] **Step 4: Run shared GREEN and checkpoint**

Run the Step 2 command and scoped diff check. Expected: existing ProxyService/command-bus suites and new opaque RPC mapping tests pass.

### Task 11: Replace controller bridge polling with RPC connection/snapshot/events

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnSessionRegistry.ets`
- Modify: `harmony/shared/src/main/ets/vpn/VpnPorts.ets`
- Modify: `harmony/shared/Index.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/VpnSessionRegistry.test.ets`

- [ ] **Step 1: Write failing RPC-controller lifecycle tests**

Require start→connect→auth→snapshot, RUNNING gate, RPC unavailable timeout releases BUSY, runtime events, disconnect/reconnect, UI initialization hydration, stop RPC then system stop, broken-socket fallback, scheduler failure, late epoch suppression, and no native bridge reads.

- [ ] **Step 2: Run shared/entry RED**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: controller tests fail because native bridge polling still exists and RPC dependencies are unwired.

- [ ] **Step 3: Implement controller with `VpnRpcClientPort`**

Delete native snapshot-poll dependencies and tokens replaced by RPC client epoch. The UI registry accepts only authenticated RPC snapshots. Keep system ability API for launch/final stop.

- [ ] **Step 4: Run shared/entry GREEN and checkpoint**

Run both Step 2 commands and scoped diff check. Expected: start/stop/reconnect/hydration tests and existing controller regressions pass.

### Task 12: Wire the RPC server into VPN Extension composition

**Files:**
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/main/ets/vpn/CmfaVpnExtensionAbility.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/entry/src/test/UiOwnedVpnExtensionAbilityApi.test.ets` only if lifecycle expectations change
- Modify: `harmony/shared/Index.ets`

- [ ] **Step 1: Write failing extension-server tests**

Cover server starts before business readiness, STARTING snapshots, coordinator event pushes, live query/select/delay dispatch, stop command, client replacement, failed listen/auth, startup rollback, TUN events not used as RUNNING, delay drain, server close before resource release, and retryable cleanup.

- [ ] **Step 2: Run entry RED**

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: extension tests fail because server lifecycle/dispatch wiring is missing.

- [ ] **Step 3: Implement one server per accepted extension session**

Build the VPN opaque catalog from the committed profile/live core. Route server dispatch to existing coordinator/proxy handler. Do not add CommonEvent/TCP/file status paths.

- [ ] **Step 4: Run entry GREEN and checkpoint**

Run the Step 2 command and scoped diff check. Expected: server/coordinator/proxy/delay/cleanup tests pass.

### Task 13: Wire one UI client before application READY

**Files:**
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/src/main/ets/vpn/HarmonyVpnRpcPlatformFactory.ets`
- Modify: `harmony/platform/Index.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/platform/src/test/PlatformFactory.test.ets`
- Modify: `harmony/entry/src/test/ProxyViewModel.test.ets` only for real RPC refresh behavior

- [ ] **Step 1: Write failing composition/recreation tests**

Require same `VpnRpcClient` feeds controller and RPC proxy handler, initialization attempts hydration before READY, no server yields usable stopped UI, running server restores marker, application close cancels delay and closes client, new UI replaces old epoch, and no process-static/native import remains in production wiring.

- [ ] **Step 2: Run platform/entry RED**

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: composition/factory tests fail because one shared UI client is not assembled before READY.

- [ ] **Step 3: Implement focused factories and wiring**

Call the dedicated `HarmonyVpnRpcPlatformFactory` from entry composition; keep generic `PlatformFactory` edits limited to passing already-owned context/dependencies where unavoidable. Keep SDK creation in platform adapters and orchestration in entry. `ProxyService` keeps one command-bus running route. Do not expose test hooks in production.

- [ ] **Step 4: Run shared/platform/entry GREEN and Chunk 3 checkpoint**

```bash
cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
git diff --check -- harmony/shared/src/main/ets/vpn/rpc harmony/platform/src/main/ets/vpn harmony/entry/src/main/ets/bootstrap/CoreComposition.ets harmony/entry/src/main/ets/vpn
```

Expected: all three suites/diff check pass. Dispatch independent Chunk 3 reviews before deleting the old bridge.

---

## Chunk 4: Obsolete Bridge Removal, Contracts, Full Gates, and Device Delivery

### Task 14: Delete the failed process-static bridge after RPC cutover

**Files:**
- Delete: `harmony/entry/src/main/cpp/include/vpn_runtime_bridge_store.h`
- Delete: `harmony/entry/src/main/cpp/src/vpn_runtime_bridge_store.cpp`
- Delete: `harmony/entry/src/main/cpp/src/js_vpn_runtime_bridge.cpp`
- Delete: `harmony/tests/native/vpn_runtime_bridge_store_test.cpp`
- Delete: `harmony/tests/native/js_vpn_runtime_bridge_napi_test.cpp`
- Delete: `harmony/entry/src/main/ets/vpn/NativeVpnRuntimeBridge.ets`
- Delete: `harmony/entry/src/main/ets/vpn/VpnRuntimeBridgeModels.ets`
- Delete: `harmony/entry/src/test/NativeVpnRuntimeBridge.test.ets`
- Delete: `harmony/tests/structure/vpn-runtime-bridge-contract.test.mjs`
- Modify: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Modify: `harmony/entry/src/main/cpp/include/cmfa_napi.h`
- Modify: `harmony/entry/src/main/cpp/src/js_core_module.cpp`
- Modify: `harmony/entry/src/main/cpp/types/libentry/Index.d.ts`
- Modify: `harmony/tools/test-native-host.mjs`
- Modify: `harmony/entry/src/test/List.test.ets`
- Modify: `harmony/entry/src/main/ets/bootstrap/CoreComposition.ets`
- Modify: `harmony/entry/src/main/ets/vpn/HarmonyVpnController.ets`
- Modify: `harmony/entry/src/main/ets/vpn/VpnExtensionComposition.ets`
- Modify: `harmony/entry/src/test/ApplicationComposition.test.ets`
- Modify: `harmony/entry/src/test/HarmonyVpnController.test.ets`
- Modify: `harmony/entry/src/test/VpnExtensionComposition.test.ets`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-proof-contract.test.mjs`

- [ ] **Step 1: Write failing structure contracts requiring zero obsolete surface**

Require no four bridge NAPI exports, no store source/build case, no production imports, and no public/core ABI change. All reusable snapshot/error types must already be imported from `harmony/shared/src/main/ets/vpn/rpc/VpnRpcModels.ets`; no Task 14 executor may invent a second replacement model file.

- [ ] **Step 2: Run structure RED**

```bash
node --test \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase1-proof-contract.test.mjs
```

Expected: new zero-obsolete-surface assertions fail while native/ArkTS bridge files and exports remain.

- [ ] **Step 3: Delete obsolete code and registrations**

Remove every listed registration/import/test reference and delete the obsolete structure contract. Do not delete proxy/TUN NAPI code or the HUKS/package-inspector privacy fixes.

- [ ] **Step 4: Run native/entry/structure GREEN and checkpoint**

```bash
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
node --test \
  harmony/tests/structure/phase1-bridge-contract.test.mjs \
  harmony/tests/structure/phase1-proof-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..
git diff --check -- harmony/entry/src/main/cpp harmony/entry/src/main/ets/vpn harmony/tools/test-native-host.mjs harmony/tests/native harmony/tests/structure/phase1-bridge-contract.test.mjs harmony/tests/structure/phase1-proof-contract.test.mjs
```

Expected: all commands pass. Native host cases after deletion are exactly the established non-bridge cases; public core contract remains unchanged.

### Task 15: Lock cross-process/security/privacy contracts and full regressions

**Files:**
- Create: `harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-bridge-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-package-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-runner-contract.test.mjs`
- Modify: `harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs`
- Modify: `harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/signing-isolation.test.mjs`
- Modify: `harmony/tests/bin/inspect-phase4-packages.mjs`
- Modify: `harmony/tests/bin/run-phase4-device-proof.mjs`
- Modify: `harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs`
- Modify: `harmony/tests/bin/run-proxy-delay-device-proof.mjs`
- Modify: `docs/harmony/vpn-runtime-bridge.md`
- Modify: `docs/harmony/current-version-vpn-user-guide.md`

- [ ] **Step 1: Write failing structure/privacy/device-runner contracts**

Enforce LocalSocket-only business transport, HUKS non-exportability, no raw names/frames/addresses, server sole authority, exact RPC methods/errors, no CommonEvent/TCP/RDB/file/AppStorage fallback, two distinct PIDs, real system VPN, reconnect/hot-switch/delay/cleanup, and fixed proof aggregates only. Rogue/bad-MAC/replay rejection remains a deterministic shared protocol/authenticator test gate; production device runners prove successful authenticated two-process operation without adding a production adversarial hook.

- [ ] **Step 2: Run focused RED**

```bash
node --test \
  harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs \
  harmony/tests/structure/phase4-vpn-contract.test.mjs \
  harmony/tests/structure/phase4-package-contract.test.mjs \
  harmony/tests/structure/phase4-runner-contract.test.mjs \
  harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs \
  harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs
```

Expected: contracts fail until RPC-only boundaries, two-PID authenticated checks, and runner privacy/cleanup updates exist.

- [ ] **Step 3: Implement minimal runner/docs/contract updates**

Implement checks in the exact runners listed above. `run-phase4-device-proof` owns real system VPN/independent traffic/two-PID authentication proof; one-click owns marker/hot-switch/recreation; delay owns progress/cancel/drain. `inspect-phase4-packages` owns signed package/provenance separation. Do not persist PIDs, socket address, nonces, MACs, opaque IDs, labels, or raw dumps. Existing proof schema changes require an explicit reviewed version bump only if new persisted fields are unavoidable; prefer internal fail-close checks with unchanged aggregate shape.

- [ ] **Step 4: Run full regression matrix**

```bash
CMFA_REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$CMFA_REPO_ROOT/harmony/core/go"
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test ./... -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go test -race ./internal/proxygroups -run 'TestDelayJob' -count=1
GOMODCACHE="$CMFA_REPO_ROOT/harmony/artifacts/go-mod-cache" GOPROXY=off go vet ./...
cd "$CMFA_REPO_ROOT"
node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case tun-contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/test-native-host.mjs --case napi-proxy
node harmony/tools/test-native-host.mjs --case napi-tun
node --test harmony/tests/structure/*.test.mjs
cd harmony
./hvigorw --mode module -p module=core@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

- [ ] **Step 5: Run debug/privacy/signing hygiene**

Require `git diff --check`, signing isolation, empty build profile, no debug markers, no socket/temp residue, and independent Task 15 reviews.

### Task 16: Build fresh signed HAP and prove all physical behaviors

**Files/Artifacts:**
- Generate fresh provenance and signed HAP
- Generate separately signed traffic-probe HAP
- Generate phase4 traffic/system-VPN, one-click/recreation, and delay proof JSON for the same production HAP hash
- Keep canonical source fixtures release-independent

- [ ] **Step 1: Open the validated bounded signing window**

Validate production backup `.codex-secure/harmony-build-profile.signed.json5` and the separately provisioned traffic-probe signing backup without printing either. Capture exact bytes/hashes of `harmony/build-profile.json5` and `harmony/traffic-probe/build-profile.json5`, require secure directory/file modes, inject only during each project build, and arm unconditional restoration of both profiles. If the separate probe backup is absent, stop with fixed `SIGNING_REQUIRED`; never reuse the production signing identity.

- [ ] **Step 2: Clean, build, validate, and inspect production HAP**

Run exactly:

```bash
cd harmony
./hvigorw clean
cd ..
node harmony/tests/bin/build-phase1-native.mjs --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs --validate harmony/artifacts/phase1-native-provenance.json
cd harmony/traffic-probe
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug clean
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
cd ../..
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production
node harmony/tests/bin/inspect-phase4-packages.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --production-manifest harmony/artifacts/phase1-native-provenance.json \
  --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/phase4-package-inspection.json
```

Expected: every command exits zero; both packages are freshly signed with distinct verified signatures, current native libs are present, package inspector passes, and production contains no self-test hooks.

- [ ] **Step 3: Run authenticated RPC/device security checks**

First rerun the deterministic shared protocol/authenticator/server tests proving rogue/bad-MAC/replay rejection without a production hook. Then run the production Phase 4 proof:

```bash
node harmony/tests/bin/run-phase4-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --probe-hap harmony/traffic-probe/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/phase4-device-proof.json
```

Expected: real system VPN, TCP/UDP/DNS independent traffic with `ingress:tun`, UI/VPN separate PIDs, authenticated RPC readiness, lifecycle/recovery/stop, and cleanup all pass. Persist only existing privacy-safe aggregates.

- [ ] **Step 4: Run one-click/recreation proof**

```bash
node harmony/tests/bin/run-proxy-one-click-vpn-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-one-click-vpn-device-proof.json
```

Require stopped→VPN, local→VPN, running hot-switch same session, UI recreation authenticated reconnect/restore/hot-switch, system VPN active, and cleanup `pass`.

- [ ] **Step 5: Run delay proof on the exact same HAP**

```bash
node harmony/tests/bin/run-proxy-delay-device-proof.mjs \
  --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --out harmony/artifacts/proxy-delay-device-proof.json
```

Require all-node results, cancellation/drain, quiet window, and cleanup `pass`.

- [ ] **Step 6: Restore signing and run final regressions**

In unconditional `finally`, restore both build profiles exactly. Then run:

```bash
git diff --exit-code -- harmony/build-profile.json5 harmony/traffic-probe/build-profile.json5
node --test harmony/tests/structure/signing-isolation.test.mjs
node --test harmony/tests/structure/vpn-local-socket-rpc-contract.test.mjs
node --test harmony/tests/structure/phase4-proof-schema.test.mjs
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --test harmony/tests/structure/proxy-delay-device-proof-contract.test.mjs
```

Compute and compare hashes with:

```bash
node --input-type=module -e '
  import fs from "node:fs/promises";
  import crypto from "node:crypto";
  const hap = await fs.readFile("harmony/entry/build/default/outputs/default/entry-default-signed.hap");
  const actual = crypto.createHash("sha256").update(hap).digest("hex");
  const phase4 = JSON.parse(await fs.readFile("harmony/artifacts/phase4-device-proof.json", "utf8"));
  const oneClick = JSON.parse(await fs.readFile("harmony/artifacts/proxy-one-click-vpn-device-proof.json", "utf8"));
  const delay = JSON.parse(await fs.readFile("harmony/artifacts/proxy-delay-device-proof.json", "utf8"));
  const values = [phase4.bundles.hapSha256[0], oneClick.packageSha256, delay.packageSha256];
  if (!values.every((value) => value === actual)) throw new Error("FINAL_HAP_HASH_MISMATCH");
'
```

Re-run Task 15's full regression matrix, remote journal/temp/socket cleanup checks, `git diff --check`, and confirm no required processes or commit/push.

- [ ] **Step 7: Final whole-feature reviews**

After both proofs pass, dispatch separate whole-feature spec and quality/security reviewers. Resolve every blocker and re-run the exact final HAP proofs if code changes.

---

## Completion Criteria

The work is complete only when:

- the obsolete process-static bridge is absent;
- LocalSocket RPC is the only running control path;
- raw proxy names and private runtime values never cross/persist/log;
- UI no longer remains indefinitely BUSY;
- real system VPN is visible and captures independent app traffic;
- node marker, hot-switch, UI recreation, and all-node delay work on two processes;
- both strict physical proofs pass for one fresh signed HAP;
- signing config is restored exactly;
- no commit or push was created.
