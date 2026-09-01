import { describe, expect, it } from '@ohos/hypium';
import {
  VpnRpcServer as BarrelVpnRpcServer
} from '../../Index';
import { encodeVpnRpcBodyToText } from '../main/ets/vpn/rpc/VpnRpcBodyCodec';
import {
  buildVpnOpaqueCatalog,
  type VpnCatalogGroupInput,
  type VpnOpaqueCatalog
} from '../main/ets/vpn/rpc/VpnOpaqueCatalog';
import {
  createVpnRpcBodyEvent,
  createVpnRpcBodyRequest,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod
} from '../main/ets/vpn/rpc/VpnRpcModels';
import {
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcDelayGroupRequestPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcRuntimeModePayload,
  createVpnRpcSelectNodeRequestPayload,
  type VpnRpcDelaySnapshotPayload,
  type VpnRpcPayload
} from '../main/ets/vpn/rpc/VpnRpcPayloads';
import type { CoreRuntimeMode } from '../main/ets/core/CoreModels';
import type {
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSchedulerPort,
  VpnRpcRuntimeDispatchPort
} from '../main/ets/vpn/rpc/VpnRpcPorts';
import type { VpnRpcServerSessionPort } from '../main/ets/vpn/rpc/VpnRpcServerSession';
import {
  createProxyDelayNodeResult,
  createProxyDelaySnapshotResult,
  type ProxyDelayResult
} from '../main/ets/proxy/ProxyDelayModels';
import {
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionRecord,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult
} from '../main/ets/proxy/ProxyModels';
import type {
  VpnProxyCancelDelayTestCommand,
  VpnProxyQueryGroupCommand,
  VpnProxyQueryGroupsCommand,
  VpnProxyReadDelayTestCommand,
  VpnProxySelectCommand,
  VpnProxyStartDelayTestCommand
} from '../main/ets/proxy/ProxyPorts';
import {
  createTunRuntimeSnapshot,
  createVpnCounters,
  createVpnRuntimeSnapshot,
  createVpnStartRequest,
  type VpnControllerStopResult,
  type VpnRuntimeSnapshot
} from '../main/ets/vpn/VpnModels';

const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const REVISION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';
const CATALOG_DIGEST_PLACEHOLDER: string = '3333333333333333333333333333333333333333333333333333333333333333';
const PROFILE_ID: string = 'profile-main';
const REVISION_ID: string = '2026-08-25T12:34:56.000Z';
const ALT_PROFILE_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const ALT_REVISION_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const ALT_PROFILE_ID: string = 'profile-next';
const ALT_REVISION_ID: string = '2026-08-26T12:34:56.000Z';
const ALT_SESSION_ID: string = 'vpn-session-2';
const GROUP_NAME: string = 'Proxy Group Alpha';
const NODE_A_NAME: string = 'Node Alpha';
const NODE_B_NAME: string = 'Node Beta';
const SESSION_ID: string = 'vpn-session-1';
const TIMESTAMP: string = '2026-08-26T00:00:00.000Z';
const JOB1_ID: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const JOB2_ID: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const CORE_JOB1_ID: string = 'core-delay-job-1';
const CORE_JOB2_ID: string = 'core-delay-job-2';
const RPC_JOB1_ID: string = '101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f';
const RPC_JOB2_ID: string = '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f';
const TUN_TX_BYTES: number = 70;
const TUN_RX_BYTES: number = 90;

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue: ((value: T) => void) | null = null;
  private rejectValue: ((reason?: Object) => void) | null = null;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (reason?: Object) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }

  reject(reason: Object): void {
    this.rejectValue?.(reason);
  }
}

class ManualTask {
  cancelCount: number = 0;
  canceled: boolean = false;

  cancel(): void {
    this.cancelCount += 1;
    this.canceled = true;
  }
}

class ScheduledRunner {
  readonly delayMs: number;
  readonly runner: () => Promise<void>;
  readonly cancelable: ManualTask;
  ran: boolean = false;

  constructor(delayMs: number, runner: () => Promise<void>, cancelable: ManualTask) {
    this.delayMs = delayMs;
    this.runner = runner;
    this.cancelable = cancelable;
  }

  async runOnce(): Promise<void> {
    if (this.ran || this.cancelable.canceled) {
      return;
    }
    this.ran = true;
    await this.runner();
  }
}

class ManualSchedulerPort implements VpnRpcSchedulerPort {
  readonly delays: number[] = [];
  readonly tasks: ScheduledRunner[] = [];
  throwOnSchedule: boolean = false;

  schedule(delayMs: number, runner: () => Promise<void>): ManualTask {
    if (this.throwOnSchedule) {
      throw new Error('schedule boom');
    }
    const cancelable: ManualTask = new ManualTask();
    this.delays.push(delayMs);
    this.tasks.push(new ScheduledRunner(delayMs, runner, cancelable));
    return cancelable;
  }

  async runNextPending(): Promise<void> {
    for (let index: number = 0; index < this.tasks.length; index += 1) {
      if (!this.tasks[index].ran && !this.tasks[index].cancelable.canceled) {
        await this.tasks[index].runOnce();
        return;
      }
    }
  }

  liveTaskCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.tasks.length; index += 1) {
      if (!this.tasks[index].ran && !this.tasks[index].cancelable.canceled) {
        count += 1;
      }
    }
    return count;
  }
}

class ScriptedRandomPort implements VpnRpcRandomPort {
  private readonly chunks: Uint8Array[];

  constructor(chunks: Uint8Array[]) {
    this.chunks = chunks;
  }

  bytes(length: number): Uint8Array {
    const next: Uint8Array | undefined = this.chunks.shift();
    if (next === undefined || next.length !== length) {
      throw new Error('Missing random bytes.');
    }
    return next;
  }
}

class CatalogCryptoPort implements VpnRpcCryptoPort {
  async prepare(): Promise<void> {}

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return this.hash(17, new Uint8Array(0), input);
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return this.hash(53, key, input);
  }

  private hash(seed: number, key: Uint8Array, input: Uint8Array): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(32);
    let acc: number = seed;
    for (let index: number = 0; index < key.length; index += 1) {
      acc = (acc + key[index] + index + 3) & 0xff;
    }
    for (let index: number = 0; index < input.length; index += 1) {
      acc = (acc + input[index] + index + 11) & 0xff;
    }
    for (let index: number = 0; index < bytes.length; index += 1) {
      const keyByte: number = key.length === 0 ? seed : key[index % key.length];
      const inputByte: number = input.length === 0 ? seed : input[index % input.length];
      acc = (acc + keyByte + inputByte + (index * 13)) & 0xff;
      bytes[index] = acc ^ ((keyByte + inputByte + index) & 0xff);
    }
    return bytes;
  }
}

class FakeServerSession implements VpnRpcServerSessionPort {
  listenCalls: number = 0;
  closeCalls: number = 0;
  readonly publishedEvents: VpnRpcBody[] = [];
  nextPublishResult: boolean = true;

  async listen(): Promise<void> {
    this.listenCalls += 1;
  }

  async publishEvent(method: VpnRpcMethod, sessionGeneration: number, guards: VpnRpcGuards, payload: VpnRpcPayload): Promise<boolean> {
    if (!this.nextPublishResult) {
      return false;
    }
    this.publishedEvents.push(
      createVpnRpcBodyEvent(1, 1, method, sessionGeneration, guards, payload)
    );
    return true;
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class FakeRuntimeDispatchPort implements VpnRpcRuntimeDispatchPort {
  snapshotValue: VpnRuntimeSnapshot = createStoppedSnapshot();
  catalogValue: VpnOpaqueCatalog | null = null;
  readonly queryGroupsCalls: VpnProxyQueryGroupsCommand[] = [];
  readonly queryGroupCalls: VpnProxyQueryGroupCommand[] = [];
  readonly selectCalls: VpnProxySelectCommand[] = [];
  readonly startDelayCalls: VpnProxyStartDelayTestCommand[] = [];
  readonly readDelayCalls: VpnProxyReadDelayTestCommand[] = [];
  readonly cancelDelayCalls: VpnProxyCancelDelayTestCommand[] = [];
  readonly stopCalls: string[] = [];
  readonly setModeCalls: CoreRuntimeMode[] = [];
  modeValue: CoreRuntimeMode = 'RULE';
  queryGroupsImpl: ((command: VpnProxyQueryGroupsCommand) => Promise<ProxyGroupListQueryResult>) | null = null;
  queryGroupImpl: ((command: VpnProxyQueryGroupCommand) => Promise<ProxyGroupQueryResult>) | null = null;
  selectImpl: ((command: VpnProxySelectCommand) => Promise<ProxySelectionResult>) | null = null;
  startDelayImpl: ((command: VpnProxyStartDelayTestCommand) => Promise<ProxyDelayResult>) | null = null;
  readDelayImpl: ((command: VpnProxyReadDelayTestCommand) => Promise<ProxyDelayResult>) | null = null;
  cancelDelayImpl: ((command: VpnProxyCancelDelayTestCommand) => Promise<ProxyDelayResult>) | null = null;
  stopImpl: (() => Promise<VpnControllerStopResult>) | null = null;

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: this.snapshotValue.state,
      activeRequest: this.snapshotValue.activeRequest,
      activeHandle: this.snapshotValue.activeHandle,
      captureConfig: this.snapshotValue.captureConfig,
      tunSnapshot: this.snapshotValue.tunSnapshot,
      notificationActive: this.snapshotValue.notificationActive,
      recoveryAttempt: this.snapshotValue.recoveryAttempt,
      scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
      lastFailure: this.snapshotValue.lastFailure
    });
  }

  catalog(): VpnOpaqueCatalog {
    if (this.catalogValue === null) {
      throw new Error('catalog missing');
    }
    return this.catalogValue;
  }

  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    this.queryGroupsCalls.push(command);
    if (this.queryGroupsImpl === null) {
      throw new Error('queryGroups missing');
    }
    return await this.queryGroupsImpl(command);
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    this.queryGroupCalls.push(command);
    if (this.queryGroupImpl === null) {
      throw new Error('queryGroup missing');
    }
    return await this.queryGroupImpl(command);
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    this.selectCalls.push(command);
    if (this.selectImpl === null) {
      throw new Error('select missing');
    }
    return await this.selectImpl(command);
  }

  async startDelay(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    this.startDelayCalls.push(command);
    if (this.startDelayImpl === null) {
      throw new Error('startDelay missing');
    }
    return await this.startDelayImpl(command);
  }

  async readDelay(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    this.readDelayCalls.push(command);
    if (this.readDelayImpl === null) {
      throw new Error('readDelay missing');
    }
    return await this.readDelayImpl(command);
  }

  async cancelDelay(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    this.cancelDelayCalls.push(command);
    if (this.cancelDelayImpl === null) {
      throw new Error('cancelDelay missing');
    }
    return await this.cancelDelayImpl(command);
  }

  async queryMode(): Promise<CoreRuntimeMode> {
    return this.modeValue;
  }

  async setMode(mode: CoreRuntimeMode): Promise<CoreRuntimeMode> {
    this.modeValue = mode;
    this.setModeCalls.push(mode);
    return mode;
  }

  async stop(): Promise<VpnControllerStopResult> {
    this.stopCalls.push('STOP');
    if (this.stopImpl === null) {
      throw new Error('stop missing');
    }
    return await this.stopImpl();
  }
}

function createStoppedSnapshot(): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'STOPPED',
    activeRequest: null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: false,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function createRunningSnapshot(): VpnRuntimeSnapshot {
  return createRunningSnapshotWith(PROFILE_ID, REVISION_ID, SESSION_ID);
}

function createTunBackedSnapshot(
  state: 'RUNNING' | 'STOPPED',
  profileId: string,
  revisionId: string,
  sessionId: string,
  txBytes: number,
  rxBytes: number
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: state === 'STOPPED' ? null : createVpnStartRequest(profileId, revisionId, sessionId),
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: createTunRuntimeSnapshot({
      sessionId,
      state: 'READY',
      counters: createVpnCounters(7, txBytes, 9, rxBytes),
      ingressTraces: [],
      failure: null
    }),
    notificationActive: state === 'RUNNING',
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function createRunningSnapshotWithTunCounters(txBytes: number, rxBytes: number): VpnRuntimeSnapshot {
  return createTunBackedSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID, txBytes, rxBytes);
}

function createStoppedSnapshotWithTunCounters(txBytes: number, rxBytes: number): VpnRuntimeSnapshot {
  return createTunBackedSnapshot('STOPPED', PROFILE_ID, REVISION_ID, SESSION_ID, txBytes, rxBytes);
}

function createRunningSnapshotWith(profileId: string, revisionId: string, sessionId: string): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: 'RUNNING',
    activeRequest: createVpnStartRequest(profileId, revisionId, sessionId),
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: true,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function createRuntimeIdentity(): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID);
}

function createActiveGuards(catalogDigest: string): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, catalogDigest);
}

function createCatalogRequestGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, null);
}

function createRequest(
  ordinal: number,
  method: VpnRpcMethod,
  generation: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createVpnRpcBodyRequest(
    1,
    1,
    ordinal,
    `00000000-0000-4000-8000-${`${ordinal}`.padStart(12, '0')}`,
    method,
    generation,
    guards,
    payload
  );
}

function createGroupCatalogInput(): VpnCatalogGroupInput[] {
  return [
    {
      name: GROUP_NAME,
      type: 'Selector',
      members: [
        {
          kind: 'TERMINAL',
          name: NODE_A_NAME,
          type: 'Shadowsocks'
        },
        {
          kind: 'TERMINAL',
          name: NODE_B_NAME,
          type: 'Trojan'
        }
      ]
    }
  ];
}

function createQueryGroupsResult(generation: number): ProxyGroupListQueryResult {
  return createProxyGroupListQuerySnapshot(createRuntimeIdentity(), generation, [
    { name: GROUP_NAME, type: 'Selector' }
  ]);
}

function createQueryGroupResult(generation: number, selectedName: string): ProxyGroupQueryResult {
  return createProxyGroupQuerySnapshot(
    createProxyGroupSnapshot(createRuntimeIdentity(), generation, {
      name: GROUP_NAME,
      type: 'Selector',
      selectedName,
      nodes: [
        { name: NODE_A_NAME, type: 'Shadowsocks', isGroup: false, selected: selectedName === NODE_A_NAME },
        { name: NODE_B_NAME, type: 'Trojan', isGroup: false, selected: selectedName === NODE_B_NAME }
      ]
    })
  );
}

function createSelectionResult(generation: number, selectedName: string): ProxySelectionResult {
  return createProxySelectionAppliedNowResult(
    createProxyGroupSnapshot(createRuntimeIdentity(), generation, {
      name: GROUP_NAME,
      type: 'Selector',
      selectedName,
      nodes: [
        { name: NODE_A_NAME, type: 'Shadowsocks', isGroup: false, selected: selectedName === NODE_A_NAME },
        { name: NODE_B_NAME, type: 'Trojan', isGroup: false, selected: selectedName === NODE_B_NAME }
      ]
    }),
    createProxySelectionRecord(PROFILE_ID, GROUP_NAME, selectedName, REVISION_ID, TIMESTAMP),
    TIMESTAMP
  );
}

function createDelayResult(
  generation: number,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED',
  availableNode: string | null
): ProxyDelayResult {
  const availableCount: number = state === 'COMPLETED' && availableNode !== null ? 1 : 0;
  const timeoutCount: number = state === 'COMPLETED' ? 1 : 0;
  const cancelledCount: number = state === 'CANCELLED' ? 2 : 0;
  return createProxyDelaySnapshotResult(
    createRuntimeIdentity(),
    generation,
    GROUP_NAME,
    jobId,
    state,
    2,
    2,
    state === 'RUNNING' ? 0 : 2,
    availableCount,
    timeoutCount,
    0,
    cancelledCount,
    0,
    availableNode === null ? null : availableNode === NODE_A_NAME ? 0 : 1,
    [
      createProxyDelayNodeResult(
        0,
        NODE_A_NAME,
        'Shadowsocks',
        state === 'RUNNING'
          ? 'WAITING'
          : state === 'CANCELLED'
            ? 'CANCELLED'
            : availableNode === NODE_A_NAME ? 'AVAILABLE' : 'TIMEOUT',
        state === 'COMPLETED' && availableNode === NODE_A_NAME ? 120 : null,
        state === 'COMPLETED' && availableNode === NODE_A_NAME
      ),
      createProxyDelayNodeResult(
        1,
        NODE_B_NAME,
        'Trojan',
        state === 'RUNNING'
          ? 'TESTING'
          : state === 'CANCELLED'
            ? 'CANCELLED'
            : availableNode === NODE_B_NAME ? 'AVAILABLE' : 'TIMEOUT',
        state === 'COMPLETED' && availableNode === NODE_B_NAME ? 80 : null,
        state === 'COMPLETED' && availableNode === NODE_B_NAME
      )
    ]
  );
}

function createStoppedResult(): VpnControllerStopResult {
  return {
    kind: 'STOPPED',
    snapshot: createStoppedSnapshot()
  };
}

function createStoppedResultWithTunCounters(txBytes: number, rxBytes: number): VpnControllerStopResult {
  return {
    kind: 'STOPPED',
    snapshot: createStoppedSnapshotWithTunCounters(txBytes, rxBytes)
  };
}

function createServer(
  session: FakeServerSession,
  runtime: FakeRuntimeDispatchPort,
  scheduler?: ManualSchedulerPort,
  random?: VpnRpcRandomPort
): BarrelVpnRpcServer {
  return new BarrelVpnRpcServer(
    session,
    runtime,
    scheduler ?? new ManualSchedulerPort(),
    random ?? new ScriptedRandomPort([bytesRange(0x10), bytesRange(0x40), bytesRange(0x70), bytesRange(0xa0)])
  );
}

function bytesRange(start: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(32);
  for (let index: number = 0; index < bytes.length; index += 1) {
    bytes[index] = (start + index) & 0xff;
  }
  return bytes;
}

async function buildTestCatalog(): Promise<VpnOpaqueCatalog> {
  return await buildVpnOpaqueCatalog(new CatalogCryptoPort(), PROFILE_HASH, REVISION_HASH, createGroupCatalogInput());
}

async function buildAlternateCatalog(): Promise<VpnOpaqueCatalog> {
  return await buildVpnOpaqueCatalog(new CatalogCryptoPort(), ALT_PROFILE_HASH, ALT_REVISION_HASH, createGroupCatalogInput());
}

async function waitForCondition(predicate: () => boolean, label: string, maxTurns: number = 60): Promise<void> {
  for (let index: number = 0; index < maxTurns; index += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error(`Condition not satisfied: ${label}.`);
}

async function flushAsync(turns: number = 8): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

export default function vpnRpcServerTestsuite() {
  describe('VpnRpcServerTest', () => {
    it('queriesAndMutatesRuntimeModeOnlyForTheGuardedRunningSession', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      const server = createServer(session, runtime);

      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const queryResponse: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'GET_MODE', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      const setResponse: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'SET_MODE', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcRuntimeModePayload('GLOBAL'))
      );

      expect(queryResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(queryResponse.payload)).assertEqual('{"mode":"RULE"}');
      expect(setResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(setResponse.payload)).assertEqual('{"mode":"GLOBAL"}');
      expect(runtime.setModeCalls.join(',')).assertEqual('GLOBAL');

      runtime.snapshotValue = createStoppedSnapshot();
      const stoppedResponse: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'SET_MODE', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcRuntimeModePayload('DIRECT'))
      );
      expect(stoppedResponse.ok).assertFalse();
      expect(stoppedResponse.error?.code).assertEqual('COMMAND_BUSY');
      expect(runtime.setModeCalls.join(',')).assertEqual('GLOBAL');
    });

    it('derivesWireGuardsFromCatalogMetadataInsteadOfRawRuntimeIds', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const groupEntry = catalog.resolveEntry(groupId);
      if (groupEntry === undefined) {
        throw new Error('Group entry missing.');
      }
      const nodeBId: string = groupEntry.childIds[1];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.queryGroupsImpl = async (): Promise<ProxyGroupListQueryResult> => createQueryGroupsResult(4);
      runtime.queryGroupImpl = async (): Promise<ProxyGroupQueryResult> => createQueryGroupResult(4, NODE_A_NAME);
      runtime.selectImpl = async (): Promise<ProxySelectionResult> => createSelectionResult(4, NODE_B_NAME);

      const server = createServer(session, runtime);

      const snapshotResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      const catalogResponse: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const groupsResponse: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'QUERY_GROUPS', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      const groupResponse: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'QUERY_GROUP', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcQueryGroupRequestPayload(groupId))
      );
      const selectResponse: VpnRpcBody = await server.handleRequest(
        createRequest(5, 'SELECT_NODE', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcSelectNodeRequestPayload(4, groupId, nodeBId))
      );

      expect(snapshotResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(snapshotResponse.payload).includes(PROFILE_HASH)).assertTrue();
      expect(encodeVpnRpcBodyToText(snapshotResponse.payload).includes(PROFILE_ID)).assertFalse();
      expect(encodeVpnRpcBodyToText(snapshotResponse.payload).includes(REVISION_ID)).assertFalse();
      expect(catalogResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(catalogResponse.payload).includes(catalog.catalogDigest)).assertTrue();
      expect(groupsResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(groupsResponse).includes(GROUP_NAME)).assertFalse();
      expect(encodeVpnRpcBodyToText(groupsResponse).includes(groupId)).assertTrue();
      expect(groupResponse.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(groupResponse).includes(NODE_A_NAME)).assertFalse();
      expect(encodeVpnRpcBodyToText(groupResponse).includes(nodeBId)).assertTrue();
      expect(selectResponse.ok).assertTrue();
      expect(runtime.queryGroupsCalls[0].identity.profileId).assertEqual(PROFILE_ID);
      expect(runtime.queryGroupsCalls[0].identity.revisionId).assertEqual(REVISION_ID);
      expect(runtime.queryGroupsCalls[0].identity.revisionHash).assertEqual(REVISION_HASH);
      expect(runtime.selectCalls[0].groupName).assertEqual(GROUP_NAME);
      expect(runtime.selectCalls[0].memberName).assertEqual(NODE_B_NAME);
    });

    it('returnsActiveGenerationOnGetSnapshotWhileKeepingEnvelopeGuardsNull', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.queryGroupsImpl = async (): Promise<ProxyGroupListQueryResult> => createQueryGroupsResult(1);
      const server = createServer(session, runtime);

      const bootstrapResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(bootstrapResponse.ok).assertTrue();
      expect(bootstrapResponse.sessionGeneration).assertEqual(0);
      expect(bootstrapResponse.guards.profileHash).assertNull();
      expect(bootstrapResponse.guards.revisionHash).assertNull();
      expect(bootstrapResponse.guards.catalogDigest).assertNull();

      const activeRequestResponse: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'QUERY_GROUPS', 1, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      expect(activeRequestResponse.ok).assertTrue();

      const resumedResponse: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(resumedResponse.ok).assertTrue();
      expect(resumedResponse.sessionGeneration).assertEqual(1);
      expect(resumedResponse.guards.profileHash).assertNull();
      expect(resumedResponse.guards.revisionHash).assertNull();
      expect(resumedResponse.guards.catalogDigest).assertNull();
      expect(encodeVpnRpcBodyToText(resumedResponse.payload).includes(catalog.catalogDigest)).assertTrue();
    });

    it('mapsTunCountersThroughSnapshotEventAndStopPayloadsAndFallsBackToZeroWithoutTun', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      runtime.snapshotValue = createRunningSnapshotWithTunCounters(TUN_TX_BYTES, TUN_RX_BYTES);
      runtime.catalogValue = catalog;
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => createStoppedResultWithTunCounters(TUN_TX_BYTES + 5, TUN_RX_BYTES + 6);
      const server = createServer(session, runtime);

      const snapshotResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(encodeVpnRpcBodyToText(snapshotResponse.payload).includes(`"txBytes":${TUN_TX_BYTES}`)).assertTrue();
      expect(encodeVpnRpcBodyToText(snapshotResponse.payload).includes(`"rxBytes":${TUN_RX_BYTES}`)).assertTrue();

      await server.handleRequest(
        createRequest(2, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const published: boolean = await server.publishRuntimeChanged(createRunningSnapshotWithTunCounters(TUN_TX_BYTES + 1, TUN_RX_BYTES + 2));
      expect(published).assertTrue();
      expect(encodeVpnRpcBodyToText(session.publishedEvents[0].payload).includes(`"txBytes":${TUN_TX_BYTES + 1}`)).assertTrue();
      expect(encodeVpnRpcBodyToText(session.publishedEvents[0].payload).includes(`"rxBytes":${TUN_RX_BYTES + 2}`)).assertTrue();

      const stopResponse: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      expect(encodeVpnRpcBodyToText(stopResponse.payload).includes(`"txBytes":${TUN_TX_BYTES + 5}`)).assertTrue();
      expect(encodeVpnRpcBodyToText(stopResponse.payload).includes(`"rxBytes":${TUN_RX_BYTES + 6}`)).assertTrue();

      const zeroSession: FakeServerSession = new FakeServerSession();
      const zeroRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      zeroRuntime.snapshotValue = createRunningSnapshot();
      zeroRuntime.catalogValue = catalog;
      const zeroServer = createServer(zeroSession, zeroRuntime);
      const zeroSnapshotResponse: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      const freshZeroSnapshotResponse: VpnRpcBody = await zeroServer.handleRequest(
        createRequest(5, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      expect(encodeVpnRpcBodyToText(freshZeroSnapshotResponse.payload).includes('"txBytes":0')).assertTrue();
      expect(encodeVpnRpcBodyToText(freshZeroSnapshotResponse.payload).includes('"rxBytes":0')).assertTrue();
      expect(zeroSnapshotResponse.ok).assertTrue();
    });

    it('failsGuardMismatchesAndUnknownOpaqueIdsWithoutRuntimeCalls', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.queryGroupsImpl = async (): Promise<ProxyGroupListQueryResult> => createQueryGroupsResult(4);

      const server = createServer(session, runtime);
      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const groupsCallCount: number = runtime.queryGroupsCalls.length;

      const staleGeneration: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'QUERY_GROUPS', 5, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      const badCatalog: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'QUERY_GROUP', 4, createActiveGuards(CATALOG_DIGEST_PLACEHOLDER), createVpnRpcQueryGroupRequestPayload(catalog.topLevelGroupIds()[0]))
      );
      const unknownGroup: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'QUERY_GROUP', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcQueryGroupRequestPayload(CATALOG_DIGEST_PLACEHOLDER))
      );

      expect(staleGeneration.ok).assertFalse();
      expect(staleGeneration.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(badCatalog.ok).assertFalse();
      expect(badCatalog.error?.code ?? '').assertEqual('CATALOG_MISMATCH');
      expect(unknownGroup.ok).assertFalse();
      expect(unknownGroup.error?.code ?? '').assertEqual('CATALOG_MISMATCH');
      expect(runtime.queryGroupsCalls.length).assertEqual(groupsCallCount);
      expect(runtime.queryGroupCalls.length).assertEqual(0);
    });

    it('usesServerOwnedOpaqueRpcJobIdsAndKeepsCoreJobIdsInsideRuntimeOnly', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const firstRandomBytes: Uint8Array = bytesRange(0x10);
      const secondRandomBytes: Uint8Array = bytesRange(0x40);
      const random: ScriptedRandomPort = new ScriptedRandomPort([firstRandomBytes, secondRandomBytes]);
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        return createDelayResult(command.generation, runtime.startDelayCalls.length === 1 ? CORE_JOB1_ID : CORE_JOB2_ID, 'RUNNING', null);
      };
      runtime.readDelayImpl = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        if (command.jobId === CORE_JOB1_ID) {
          return createDelayResult(command.generation, CORE_JOB1_ID, 'COMPLETED', NODE_A_NAME);
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'COMPLETED', NODE_B_NAME);
      };
      runtime.cancelDelayImpl = async (command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> =>
        createDelayResult(command.generation, command.jobId, 'CANCELLED', null);

      const server = createServer(session, runtime, scheduler, random);

      const firstStart: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      firstRandomBytes.fill(0xff);
      const firstJobId: string = encodeVpnRpcBodyToText(firstStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      await scheduler.runNextPending();
      const firstRead: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(firstJobId))
      );
      const secondStart: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const secondJobId: string = encodeVpnRpcBodyToText(secondStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const staleRead: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(firstJobId))
      );
      const secondCancel: VpnRpcBody = await server.handleRequest(
        createRequest(5, 'CANCEL_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(secondJobId))
      );

      expect(firstStart.ok).assertTrue();
      expect(firstJobId).assertEqual(RPC_JOB1_ID);
      expect(firstJobId.includes(CORE_JOB1_ID)).assertFalse();
      expect(firstRead.ok).assertTrue();
      expect(runtime.readDelayCalls[0].jobId).assertEqual(CORE_JOB1_ID);
      expect(secondStart.ok).assertTrue();
      expect(secondJobId).assertEqual(RPC_JOB2_ID);
      expect(secondJobId === firstJobId).assertFalse();
      expect(runtime.cancelDelayCalls[runtime.cancelDelayCalls.length - 1].jobId).assertEqual(CORE_JOB2_ID);
      expect(staleRead.ok).assertFalse();
      expect(staleRead.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(secondCancel.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(secondCancel).includes(CORE_JOB2_ID)).assertFalse();
    });

    it('pollsDelayOnlyThroughSchedulerTicksAndStopsAfterTerminal', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.readDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'COMPLETED', NODE_B_NAME);

      const server = createServer(session, runtime, scheduler);

      const startResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );

      expect(startResponse.ok).assertTrue();
      expect(runtime.readDelayCalls.length).assertEqual(0);
      expect(scheduler.delays.join(',')).assertEqual('250');
      expect(scheduler.liveTaskCount()).assertEqual(1);

      await scheduler.runNextPending();
      const readJobId: string = encodeVpnRpcBodyToText(startResponse.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const readResponse: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(readJobId))
      );

      expect(runtime.readDelayCalls.length).assertEqual(1);
      expect((startResponse.payload as VpnRpcDelaySnapshotPayload).delayRevision).assertEqual(1);
      expect(session.publishedEvents[0].method).assertEqual('DELAY_CHANGED');
      expect((session.publishedEvents[0].payload as VpnRpcDelaySnapshotPayload).delayRevision).assertEqual(2);
      expect(encodeVpnRpcBodyToText(readResponse.payload)).assertEqual(encodeVpnRpcBodyToText(session.publishedEvents[0].payload));
      expect(encodeVpnRpcBodyToText(session.publishedEvents[0]).includes(NODE_B_NAME)).assertFalse();
      expect(scheduler.liveTaskCount()).assertEqual(0);
      expect(scheduler.tasks[0].cancelable.cancelCount).assertEqual(0);
    });

    it('suppressesLateDelayResultsAcrossReplacementAndCancelsPendingPollsOnStopAndClose', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const oldReadDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        if (runtime.startDelayCalls.length === 1) {
          return createDelayResult(command.generation, CORE_JOB1_ID, 'RUNNING', null);
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'RUNNING', null);
      };
      runtime.readDelayImpl = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        if (command.jobId === CORE_JOB1_ID) {
          return await oldReadDeferred.promise;
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'COMPLETED', NODE_A_NAME);
      };
      runtime.cancelDelayImpl = async (command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> =>
        createDelayResult(command.generation, command.jobId, 'CANCELLED', null);
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => createStoppedResult();

      const server = createServer(session, runtime, scheduler);

      const firstStart: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const firstRpcJobId: string = encodeVpnRpcBodyToText(firstStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      expect(firstStart.ok).assertTrue();
      const firstPollPromise: Promise<void> = scheduler.runNextPending();
      await waitForCondition((): boolean => runtime.readDelayCalls.length === 1, 'first scheduled read');
      const secondStartPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      oldReadDeferred.resolve(createDelayResult(4, CORE_JOB1_ID, 'COMPLETED', NODE_B_NAME));
      await firstPollPromise;
      const secondStart: VpnRpcBody = await secondStartPromise;
      const secondRpcJobId: string = encodeVpnRpcBodyToText(secondStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      expect(scheduler.tasks[0].cancelable.cancelCount).assertEqual(0);
      expect(scheduler.liveTaskCount()).assertEqual(1);

      const stopResponse: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      expect(scheduler.tasks[1].cancelable.cancelCount).assertEqual(1);
      runtime.queryGroupImpl = async (): Promise<ProxyGroupQueryResult> => {
        throw new Error(`secret ${GROUP_NAME} ${NODE_A_NAME}`);
      };
      const failedQuery: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'QUERY_GROUP', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcQueryGroupRequestPayload(groupId))
      );

      await server.close();
      expect(scheduler.tasks[1].cancelable.cancelCount).assertEqual(1);
      expect(scheduler.liveTaskCount()).assertEqual(0);

      expect(secondStart.ok).assertTrue();
      expect(runtime.cancelDelayCalls.length).assertEqual(2);
      expect(runtime.cancelDelayCalls[0].jobId).assertEqual(CORE_JOB1_ID);
      expect(firstRpcJobId === secondRpcJobId).assertFalse();
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => {
        return encodeVpnRpcBodyToText(event.payload).includes(firstRpcJobId) || encodeVpnRpcBodyToText(event.payload).includes(CORE_JOB1_ID);
      }).length).assertEqual(0);
      expect(stopResponse.ok).assertTrue();
      expect(runtime.stopCalls.length).assertEqual(1);
      expect(session.publishedEvents.some((event: VpnRpcBody): boolean => event.method === 'RUNTIME_CHANGED')).assertTrue();
      expect(failedQuery.ok).assertFalse();
      expect(failedQuery.error?.code ?? '').assertEqual('CORE_OPERATION_FAILED');
      expect(encodeVpnRpcBodyToText(failedQuery).includes('secret')).assertFalse();
    });

    it('failsDelayJobLocallyWhenScheduleThrowsOrScheduledReadFails', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const scheduleThrowSession: FakeServerSession = new FakeServerSession();
      const scheduleThrowRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const throwingScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      throwingScheduler.throwOnSchedule = true;
      scheduleThrowRuntime.snapshotValue = createRunningSnapshot();
      scheduleThrowRuntime.catalogValue = catalog;
      scheduleThrowRuntime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      const scheduleThrowServer = createServer(scheduleThrowSession, scheduleThrowRuntime, throwingScheduler);

      const scheduleThrowStart: VpnRpcBody = await scheduleThrowServer.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const scheduleThrowJobId: string = encodeVpnRpcBodyToText(scheduleThrowStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const scheduleThrowRead: VpnRpcBody = await scheduleThrowServer.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(scheduleThrowJobId))
      );
      const scheduleThrowCancel: VpnRpcBody = await scheduleThrowServer.handleRequest(
        createRequest(3, 'CANCEL_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(scheduleThrowJobId))
      );

      expect(scheduleThrowStart.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(scheduleThrowStart.payload).includes('"state":"FAILED"')).assertTrue();
      expect(scheduleThrowSession.publishedEvents.length).assertEqual(0);
      expect(scheduleThrowRuntime.readDelayCalls.length).assertEqual(0);
      expect(scheduleThrowRead.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(scheduleThrowRead.payload)).assertEqual(encodeVpnRpcBodyToText(scheduleThrowStart.payload));
      expect(scheduleThrowCancel.ok).assertTrue();
      expect(scheduleThrowRuntime.cancelDelayCalls.length).assertEqual(0);

      const failingSession: FakeServerSession = new FakeServerSession();
      const failingRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const failingScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      failingRuntime.snapshotValue = createRunningSnapshot();
      failingRuntime.catalogValue = catalog;
      failingRuntime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB2_ID, 'RUNNING', null);
      failingRuntime.readDelayImpl = async (): Promise<ProxyDelayResult> => {
        throw new Error(`read failed ${GROUP_NAME}`);
      };
      const failingServer = createServer(failingSession, failingRuntime, failingScheduler);

      const failingStart: VpnRpcBody = await failingServer.handleRequest(
        createRequest(4, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const failingRpcJobId: string = encodeVpnRpcBodyToText(failingStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      await failingScheduler.runNextPending();
      const failingRead: VpnRpcBody = await failingServer.handleRequest(
        createRequest(5, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(failingRpcJobId))
      );

      expect(failingSession.publishedEvents.length).assertEqual(1);
      expect(encodeVpnRpcBodyToText(failingSession.publishedEvents[0].payload).includes('"state":"FAILED"')).assertTrue();
      expect(encodeVpnRpcBodyToText(failingSession.publishedEvents[0]).includes(CORE_JOB2_ID)).assertFalse();
      expect(failingRead.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(failingRead.payload)).assertEqual(encodeVpnRpcBodyToText(failingSession.publishedEvents[0].payload));
    });

    it('boundsDelayDrainWhenRuntimeNeverLeavesRunning', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.cancelDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.readDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => createStoppedResult();
      const server = createServer(session, runtime, scheduler);

      const start: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const stop: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      await server.close();

      expect(start.ok).assertTrue();
      expect(stop.ok).assertTrue();
      expect(runtime.readDelayCalls.length <= 8).assertTrue();
      expect(runtime.cancelDelayCalls.length).assertEqual(1);
      expect(session.closeCalls).assertEqual(1);
      expect(scheduler.liveTaskCount()).assertEqual(0);
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => event.method === 'DELAY_CHANGED').length).assertEqual(0);
    });

    it('closeCancelsInFlightDelayReadAndSuppressesLateCompletion', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const delayReadDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      const cancelDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.readDelayImpl = async (): Promise<ProxyDelayResult> => await delayReadDeferred.promise;
      runtime.cancelDelayImpl = async (): Promise<ProxyDelayResult> => await cancelDeferred.promise;
      const server = createServer(session, runtime, scheduler);

      const startResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const delayRpcJobId: string = encodeVpnRpcBodyToText(startResponse.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const readPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(delayRpcJobId))
      );
      await waitForCondition((): boolean => runtime.readDelayCalls.length === 1, 'manual delay read entered runtime');

      let closeResolved: boolean = false;
      const closePromise: Promise<void> = server.close().then((): void => {
        closeResolved = true;
      });
      await waitForCondition((): boolean => runtime.cancelDelayCalls.length === 1, 'close triggered concurrent delay cancel');
      expect(runtime.cancelDelayCalls.length).assertEqual(1);
      expect(runtime.cancelDelayCalls[0].jobId).assertEqual(CORE_JOB1_ID);
      expect(closeResolved).assertFalse();
      expect(session.closeCalls).assertEqual(0);

      cancelDeferred.resolve(createDelayResult(4, CORE_JOB1_ID, 'CANCELLED', null));
      await closePromise;
      expect(session.closeCalls).assertEqual(1);

      delayReadDeferred.resolve(createDelayResult(4, CORE_JOB1_ID, 'COMPLETED', NODE_A_NAME));
      const staleRead: VpnRpcBody = await readPromise;

      expect(staleRead.ok).assertFalse();
      expect(staleRead.error !== null && (staleRead.error.code === 'SESSION_CHANGED' || staleRead.error.code === 'SERVER_STOPPING')).assertTrue();
      expect(encodeVpnRpcBodyToText(staleRead).includes(delayRpcJobId)).assertFalse();
      expect(encodeVpnRpcBodyToText(staleRead).includes(CORE_JOB1_ID)).assertFalse();
      expect(encodeVpnRpcBodyToText(staleRead).includes(NODE_A_NAME)).assertFalse();
      expect(session.publishedEvents.length).assertEqual(0);
    });

    it('closeFallsBackToLocalFailedWhenConcurrentCancelReturnsNonTerminal', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const delayReadDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.readDelayImpl = async (): Promise<ProxyDelayResult> => await delayReadDeferred.promise;
      runtime.cancelDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      const server = createServer(session, runtime, scheduler);

      const startResponse: VpnRpcBody = await server.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const delayRpcJobId: string = encodeVpnRpcBodyToText(startResponse.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const readPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(delayRpcJobId))
      );
      await waitForCondition((): boolean => runtime.readDelayCalls.length === 1, 'manual delay read entered runtime');

      let closeResolved: boolean = false;
      const closePromise: Promise<void> = server.close().then((): void => {
        closeResolved = true;
      });
      await waitForCondition((): boolean => runtime.cancelDelayCalls.length === 1, 'close triggered fallback delay cancel');
      await waitForCondition((): boolean => closeResolved, 'close resolved after nonterminal cancel');

      expect(runtime.cancelDelayCalls.length).assertEqual(1);
      expect(runtime.cancelDelayCalls[0].jobId).assertEqual(CORE_JOB1_ID);
      expect(session.closeCalls).assertEqual(1);
      expect(session.publishedEvents.length).assertEqual(0);
      await closePromise;

      delayReadDeferred.resolve(createDelayResult(4, CORE_JOB1_ID, 'COMPLETED', NODE_B_NAME));
      const staleRead: VpnRpcBody = await readPromise;

      expect(staleRead.ok).assertFalse();
      expect(staleRead.error !== null && (staleRead.error.code === 'SESSION_CHANGED' || staleRead.error.code === 'SERVER_STOPPING')).assertTrue();
      expect(encodeVpnRpcBodyToText(staleRead).includes('"state":"FAILED"')).assertFalse();
      expect(encodeVpnRpcBodyToText(staleRead).includes(delayRpcJobId)).assertFalse();
      expect(encodeVpnRpcBodyToText(staleRead).includes(CORE_JOB1_ID)).assertFalse();
      expect(encodeVpnRpcBodyToText(staleRead).includes(NODE_B_NAME)).assertFalse();
    });

    it('returnsStaleErrorsForThrownAndRejectedManualDelayReadsAfterClose', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];

      const throwingSession: FakeServerSession = new FakeServerSession();
      const throwingRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const throwingScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const throwingDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      throwingRuntime.snapshotValue = createRunningSnapshot();
      throwingRuntime.catalogValue = catalog;
      throwingRuntime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      throwingRuntime.readDelayImpl = async (): Promise<ProxyDelayResult> => await throwingDeferred.promise;
      throwingRuntime.cancelDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'CANCELLED', null);
      const throwingServer = createServer(throwingSession, throwingRuntime, throwingScheduler);

      const throwingStart: VpnRpcBody = await throwingServer.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const throwingRpcJobId: string = encodeVpnRpcBodyToText(throwingStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const throwingReadPromise: Promise<VpnRpcBody> = throwingServer.handleRequest(
        createRequest(2, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(throwingRpcJobId))
      );
      await waitForCondition((): boolean => throwingRuntime.readDelayCalls.length === 1, 'throwing read entered runtime');
      const throwingClosePromise: Promise<void> = throwingServer.close();
      await waitForCondition((): boolean => throwingRuntime.cancelDelayCalls.length === 1, 'throwing close cancel invoked');
      await throwingClosePromise;
      throwingDeferred.promise.catch((): void => {});

      const rejectedSession: FakeServerSession = new FakeServerSession();
      const rejectedRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const rejectedScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const rejectedDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      rejectedRuntime.snapshotValue = createRunningSnapshot();
      rejectedRuntime.catalogValue = catalog;
      rejectedRuntime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB2_ID, 'RUNNING', null);
      rejectedRuntime.readDelayImpl = async (): Promise<ProxyDelayResult> => await rejectedDeferred.promise;
      rejectedRuntime.cancelDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB2_ID, 'CANCELLED', null);
      const rejectedServer = createServer(rejectedSession, rejectedRuntime, rejectedScheduler);

      const rejectedStart: VpnRpcBody = await rejectedServer.handleRequest(
        createRequest(3, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const rejectedRpcJobId: string = encodeVpnRpcBodyToText(rejectedStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const rejectedReadPromise: Promise<VpnRpcBody> = rejectedServer.handleRequest(
        createRequest(4, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(rejectedRpcJobId))
      );
      await waitForCondition((): boolean => rejectedRuntime.readDelayCalls.length === 1, 'rejected read entered runtime');
      const rejectedClosePromise: Promise<void> = rejectedServer.close();
      await waitForCondition((): boolean => rejectedRuntime.cancelDelayCalls.length === 1, 'rejected close cancel invoked');
      await rejectedClosePromise;

      throwingDeferred.reject(new Error('stale read boom'));
      rejectedDeferred.resolve(createProxyRejectedResult(createProxyRejectedError('PROXY_DELAY_TEST_FAILED', true, TIMESTAMP)));

      const throwingRead: VpnRpcBody = await throwingReadPromise;
      const rejectedRead: VpnRpcBody = await rejectedReadPromise;

      expect(throwingRead.ok).assertFalse();
      expect(throwingRead.error !== null && (throwingRead.error.code === 'SESSION_CHANGED' || throwingRead.error.code === 'SERVER_STOPPING')).assertTrue();
      expect(encodeVpnRpcBodyToText(throwingRead).includes('"state":"FAILED"')).assertFalse();
      expect(encodeVpnRpcBodyToText(throwingRead).includes(throwingRpcJobId)).assertFalse();
      expect(rejectedRead.ok).assertFalse();
      expect(rejectedRead.error !== null && (rejectedRead.error.code === 'SESSION_CHANGED' || rejectedRead.error.code === 'SERVER_STOPPING')).assertTrue();
      expect(encodeVpnRpcBodyToText(rejectedRead).includes('"state":"FAILED"')).assertFalse();
      expect(encodeVpnRpcBodyToText(rejectedRead).includes(rejectedRpcJobId)).assertFalse();
      expect(throwingSession.publishedEvents.length).assertEqual(0);
      expect(rejectedSession.publishedEvents.length).assertEqual(0);
    });

    it('suppressesThrownAndRejectedScheduledDelayReadFailuresAfterContextReplacement', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const replacementCatalog: VpnOpaqueCatalog = await buildAlternateCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];

      const throwingSession: FakeServerSession = new FakeServerSession();
      const throwingRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const throwingScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const scheduledThrowDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      throwingRuntime.snapshotValue = createRunningSnapshot();
      throwingRuntime.catalogValue = catalog;
      throwingRuntime.startDelayImpl = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        if (throwingRuntime.startDelayCalls.length === 1) {
          return createDelayResult(command.generation, CORE_JOB1_ID, 'RUNNING', null);
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'RUNNING', null);
      };
      throwingRuntime.readDelayImpl = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        if (command.jobId === CORE_JOB1_ID) {
          return await scheduledThrowDeferred.promise;
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'COMPLETED', NODE_A_NAME);
      };
      const throwingServer = createServer(throwingSession, throwingRuntime, throwingScheduler);

      const throwingStart: VpnRpcBody = await throwingServer.handleRequest(
        createRequest(1, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const throwingFirstRpcJobId: string = encodeVpnRpcBodyToText(throwingStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const throwingPollPromise: Promise<void> = throwingScheduler.runNextPending();
      await waitForCondition((): boolean => throwingRuntime.readDelayCalls.length === 1, 'scheduled throwing read entered runtime');
      throwingRuntime.snapshotValue = createRunningSnapshotWith(ALT_PROFILE_ID, ALT_REVISION_ID, ALT_SESSION_ID);
      throwingRuntime.catalogValue = replacementCatalog;
      const throwingReplacementSnapshot: VpnRpcBody = await throwingServer.handleRequest(
        createRequest(2, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      const throwingReplacementStart: VpnRpcBody = await throwingServer.handleRequest(
        createRequest(
          3,
          'START_DELAY_TEST',
          8,
          createVpnRpcGuards(ALT_PROFILE_HASH, ALT_REVISION_HASH, replacementCatalog.catalogDigest),
          createVpnRpcDelayGroupRequestPayload(8, replacementCatalog.topLevelGroupIds()[0])
        )
      );
      const throwingSecondRpcJobId: string = encodeVpnRpcBodyToText(throwingReplacementStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';

      const rejectedSession: FakeServerSession = new FakeServerSession();
      const rejectedRuntime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const rejectedScheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const scheduledRejectedDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      rejectedRuntime.snapshotValue = createRunningSnapshot();
      rejectedRuntime.catalogValue = catalog;
      rejectedRuntime.startDelayImpl = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        if (rejectedRuntime.startDelayCalls.length === 1) {
          return createDelayResult(command.generation, CORE_JOB1_ID, 'RUNNING', null);
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'RUNNING', null);
      };
      rejectedRuntime.readDelayImpl = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        if (command.jobId === CORE_JOB1_ID) {
          return await scheduledRejectedDeferred.promise;
        }
        return createDelayResult(command.generation, CORE_JOB2_ID, 'COMPLETED', NODE_B_NAME);
      };
      const rejectedServer = createServer(rejectedSession, rejectedRuntime, rejectedScheduler);

      const rejectedStart: VpnRpcBody = await rejectedServer.handleRequest(
        createRequest(4, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const rejectedFirstRpcJobId: string = encodeVpnRpcBodyToText(rejectedStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';
      const rejectedPollPromise: Promise<void> = rejectedScheduler.runNextPending();
      await waitForCondition((): boolean => rejectedRuntime.readDelayCalls.length === 1, 'scheduled rejected read entered runtime');
      rejectedRuntime.snapshotValue = createRunningSnapshotWith(ALT_PROFILE_ID, ALT_REVISION_ID, ALT_SESSION_ID);
      rejectedRuntime.catalogValue = replacementCatalog;
      const rejectedReplacementSnapshot: VpnRpcBody = await rejectedServer.handleRequest(
        createRequest(5, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      const rejectedReplacementStart: VpnRpcBody = await rejectedServer.handleRequest(
        createRequest(
          6,
          'START_DELAY_TEST',
          8,
          createVpnRpcGuards(ALT_PROFILE_HASH, ALT_REVISION_HASH, replacementCatalog.catalogDigest),
          createVpnRpcDelayGroupRequestPayload(8, replacementCatalog.topLevelGroupIds()[0])
        )
      );
      const rejectedSecondRpcJobId: string = encodeVpnRpcBodyToText(rejectedReplacementStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';

      scheduledThrowDeferred.reject(new Error('scheduled stale read boom'));
      scheduledRejectedDeferred.resolve(createProxyRejectedResult(createProxyRejectedError('PROXY_DELAY_TEST_FAILED', true, TIMESTAMP)));

      await throwingPollPromise;
      await rejectedPollPromise;
      const throwingCurrentRead: VpnRpcBody = await throwingServer.handleRequest(
        createRequest(
          7,
          'READ_DELAY_TEST',
          8,
          createVpnRpcGuards(ALT_PROFILE_HASH, ALT_REVISION_HASH, replacementCatalog.catalogDigest),
          createVpnRpcDelayJobRequestPayload(throwingSecondRpcJobId)
        )
      );
      const rejectedCurrentRead: VpnRpcBody = await rejectedServer.handleRequest(
        createRequest(
          8,
          'READ_DELAY_TEST',
          8,
          createVpnRpcGuards(ALT_PROFILE_HASH, ALT_REVISION_HASH, replacementCatalog.catalogDigest),
          createVpnRpcDelayJobRequestPayload(rejectedSecondRpcJobId)
        )
      );

      expect(throwingReplacementSnapshot.ok).assertTrue();
      expect(throwingReplacementStart.ok).assertTrue();
      expect(throwingFirstRpcJobId === throwingSecondRpcJobId).assertFalse();
      expect(throwingCurrentRead.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(throwingCurrentRead.payload).includes('"state":"FAILED"')).assertFalse();
      expect(encodeVpnRpcBodyToText(throwingCurrentRead).includes(throwingFirstRpcJobId)).assertFalse();
      expect(rejectedReplacementSnapshot.ok).assertTrue();
      expect(rejectedReplacementStart.ok).assertTrue();
      expect(rejectedFirstRpcJobId === rejectedSecondRpcJobId).assertFalse();
      expect(rejectedCurrentRead.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(rejectedCurrentRead.payload).includes('"state":"FAILED"')).assertFalse();
      expect(encodeVpnRpcBodyToText(rejectedCurrentRead).includes(rejectedFirstRpcJobId)).assertFalse();
      expect(throwingSession.publishedEvents.length).assertEqual(0);
      expect(rejectedSession.publishedEvents.length).assertEqual(0);
      expect(throwingScheduler.liveTaskCount()).assertEqual(0);
      expect(rejectedScheduler.liveTaskCount()).assertEqual(0);
    });

    it('returnsSessionChangedForInFlightQueriesAndReadsAfterStopOrCloseInvalidatesContext', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const groupId: string = catalog.topLevelGroupIds()[0];
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const queryGroupsDeferred: DeferredValue<ProxyGroupListQueryResult> = new DeferredValue<ProxyGroupListQueryResult>();
      const queryGroupDeferred: DeferredValue<ProxyGroupQueryResult> = new DeferredValue<ProxyGroupQueryResult>();
      const delayReadDeferred: DeferredValue<ProxyDelayResult> = new DeferredValue<ProxyDelayResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.queryGroupsImpl = async (): Promise<ProxyGroupListQueryResult> => await queryGroupsDeferred.promise;
      runtime.queryGroupImpl = async (): Promise<ProxyGroupQueryResult> => await queryGroupDeferred.promise;
      runtime.startDelayImpl = async (): Promise<ProxyDelayResult> => createDelayResult(4, CORE_JOB1_ID, 'RUNNING', null);
      runtime.readDelayImpl = async (): Promise<ProxyDelayResult> => await delayReadDeferred.promise;
      runtime.cancelDelayImpl = async (command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> =>
        createDelayResult(command.generation, command.jobId, 'CANCELLED', null);
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => createStoppedResult();

      const server = createServer(session, runtime, scheduler);
      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const delayStart: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'START_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayGroupRequestPayload(4, groupId))
      );
      const delayRpcJobId: string = encodeVpnRpcBodyToText(delayStart.payload).match(/"jobId":"([0-9a-f]{64})"/u)?.[1] ?? '';

      const queryGroupsPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(3, 'QUERY_GROUPS', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      const queryGroupPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(4, 'QUERY_GROUP', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcQueryGroupRequestPayload(groupId))
      );
      const readDelayPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(5, 'READ_DELAY_TEST', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcDelayJobRequestPayload(delayRpcJobId))
      );

      const stopResponse: VpnRpcBody = await server.handleRequest(
        createRequest(6, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      queryGroupsDeferred.resolve(createQueryGroupsResult(4));
      queryGroupDeferred.resolve(createQueryGroupResult(4, NODE_A_NAME));
      delayReadDeferred.resolve(createDelayResult(4, CORE_JOB1_ID, 'COMPLETED', NODE_A_NAME));

      const staleGroups: VpnRpcBody = await queryGroupsPromise;
      const staleGroup: VpnRpcBody = await queryGroupPromise;
      const staleDelay: VpnRpcBody = await readDelayPromise;

      expect(stopResponse.ok).assertTrue();
      expect(staleGroups.ok).assertFalse();
      expect(staleGroups.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(encodeVpnRpcBodyToText(staleGroups).includes(GROUP_NAME)).assertFalse();
      expect(staleGroup.ok).assertFalse();
      expect(staleGroup.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(encodeVpnRpcBodyToText(staleGroup).includes(NODE_A_NAME)).assertFalse();
      expect(staleDelay.ok).assertFalse();
      expect(staleDelay.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(encodeVpnRpcBodyToText(staleDelay).includes(delayRpcJobId)).assertFalse();
      expect(encodeVpnRpcBodyToText(staleDelay).includes(CORE_JOB1_ID)).assertFalse();
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => event.method === 'DELAY_CHANGED').length).assertEqual(0);
    });

    it('rejectsSnapshotRefreshWhileStopIsInProgressWithoutRehydratingActiveContext', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const stopDeferred: DeferredValue<VpnControllerStopResult> = new DeferredValue<VpnControllerStopResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => await stopDeferred.promise;
      const server = createServer(session, runtime, scheduler);

      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const stopPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      await flushAsync();
      const concurrentSnapshot: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );
      const concurrentGroups: VpnRpcBody = await server.handleRequest(
        createRequest(4, 'QUERY_GROUPS', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      stopDeferred.resolve(createStoppedResult());
      const stopResponse: VpnRpcBody = await stopPromise;

      expect(concurrentSnapshot.ok).assertFalse();
      expect(concurrentSnapshot.error?.code ?? '').assertEqual('SERVER_STOPPING');
      expect(concurrentGroups.ok).assertFalse();
      expect(concurrentGroups.error?.code ?? '').assertEqual('SERVER_STOPPING');
      expect(runtime.queryGroupsCalls.length).assertEqual(0);
      expect(stopResponse.ok).assertTrue();
    });

    it('suppressesOldStopEventAndReturnsSessionChangedAfterContextReplacement', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const replacementCatalog: VpnOpaqueCatalog = await buildAlternateCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const stopDeferred: DeferredValue<VpnControllerStopResult> = new DeferredValue<VpnControllerStopResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => await stopDeferred.promise;
      const server = createServer(session, runtime, scheduler);

      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const stopPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      await flushAsync();
      runtime.snapshotValue = createRunningSnapshotWith(ALT_PROFILE_ID, ALT_REVISION_ID, ALT_SESSION_ID);
      runtime.catalogValue = replacementCatalog;
      stopDeferred.resolve(createStoppedResult());
      const stopResponse: VpnRpcBody = await stopPromise;

      expect(stopResponse.ok).assertFalse();
      expect(stopResponse.error?.code ?? '').assertEqual('SESSION_CHANGED');
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => event.method === 'RUNTIME_CHANGED').length).assertEqual(0);
    });

    it('suppressesLateStopEventWhenCloseWinsTheRace', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      const stopDeferred: DeferredValue<VpnControllerStopResult> = new DeferredValue<VpnControllerStopResult>();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => await stopDeferred.promise;
      const server = createServer(session, runtime, scheduler);

      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const stopPromise: Promise<VpnRpcBody> = server.handleRequest(
        createRequest(2, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      await flushAsync();
      const closePromise: Promise<void> = server.close();
      stopDeferred.resolve(createStoppedResult());
      const stopResponse: VpnRpcBody = await stopPromise;
      await closePromise;

      expect(stopResponse.ok).assertFalse();
      expect(stopResponse.error?.code ?? '').assertEqual('SERVER_STOPPING');
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => event.method === 'RUNTIME_CHANGED').length).assertEqual(0);
      expect(session.closeCalls).assertEqual(1);
    });

    it('publishesExactlyOneStoppedRuntimeEventOnNormalStop', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildTestCatalog();
      const session: FakeServerSession = new FakeServerSession();
      const runtime: FakeRuntimeDispatchPort = new FakeRuntimeDispatchPort();
      const scheduler: ManualSchedulerPort = new ManualSchedulerPort();
      runtime.snapshotValue = createRunningSnapshot();
      runtime.catalogValue = catalog;
      runtime.stopImpl = async (): Promise<VpnControllerStopResult> => createStoppedResult();
      const server = createServer(session, runtime, scheduler);

      await server.handleRequest(
        createRequest(1, 'GET_CATALOG_DIGEST', 4, createCatalogRequestGuards(), createVpnRpcEmptyPayload())
      );
      const stopResponse: VpnRpcBody = await server.handleRequest(
        createRequest(2, 'STOP_VPN', 4, createActiveGuards(catalog.catalogDigest), createVpnRpcEmptyPayload())
      );
      const afterStopSnapshot: VpnRpcBody = await server.handleRequest(
        createRequest(3, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcEmptyPayload())
      );

      expect(stopResponse.ok).assertTrue();
      expect(session.publishedEvents.filter((event: VpnRpcBody): boolean => event.method === 'RUNTIME_CHANGED').length).assertEqual(1);
      expect(encodeVpnRpcBodyToText(session.publishedEvents[0].payload)).assertEqual(encodeVpnRpcBodyToText(stopResponse.payload));
      expect(afterStopSnapshot.ok).assertTrue();
      expect(encodeVpnRpcBodyToText(afterStopSnapshot.payload).includes('"state":"STOPPED"')).assertTrue();
    });
  });
}
