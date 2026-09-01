import { describe, expect, it } from '@ohos/hypium';
import {
  VpnProxyCommandBus,
  VpnProxyRuntimeHandler,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  createProfile,
  createProfileRevision,
  createProxyRuntimeIdentity,
  createProxySelectionRecord,
  createVpnProxyCancelDelayTestCommand,
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxyStartDelayTestCommand,
  createVpnProxySelectCommand,
  createVpnStartRequest,
  normalizeCoreError,
  type CoreProxyDelaySnapshot,
  type CoreProxyNodeSummary,
  type Clock,
  type CoreProxyGroupList,
  type CoreProxyGroupRef,
  type CoreProxyGroupResult,
  type CoreProxyGroupSnapshot,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type Profile,
  type ProfileRepository,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type VpnProxyCommandHandler,
  type ProxyRuntimeIdentity,
  type ProxyIdentityHasher,
  type ProxySelectionRecord,
  type ProxySelectionRepository,
  type ProxySelectionResult,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand,
  type VpnStartRequest
} from '../../Index';

const PROFILE_ID: string = 'profile-alpha';
const OTHER_PROFILE_ID: string = 'profile-beta';
const SESSION_ID: string = 'session-1';
const OTHER_SESSION_ID: string = 'session-2';
const REVISION_ID: string = '2026-08-23T08:00:00.000Z';
const REVISION_ID_NEXT: string = '2026-08-23T08:05:00.000Z';
const REVISION_HASH: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const REVISION_HASH_NEXT: string = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const PROFILE_HASH_BETA: string = '2222222222222222222222222222222222222222222222222222222222222222';
const SESSION_HASH: string = '3333333333333333333333333333333333333333333333333333333333333333';
const SESSION_HASH_NEXT: string = '4444444444444444444444444444444444444444444444444444444444444444';
const GROUP_ALPHA: string = 'Group Alpha';
const GROUP_BETA: string = 'Group Beta';
const GROUP_GAMMA: string = 'Group Gamma';
const NODE_ALPHA: string = 'Node Alpha';
const NODE_BETA: string = 'Node Beta';
const NODE_GAMMA: string = 'Node Gamma';
const NESTED_GROUP: string = 'Nested Group';
const TIMESTAMP_1: string = '2026-08-23T09:00:00.000Z';
const TIMESTAMP_2: string = '2026-08-23T09:00:01.000Z';
const TIMESTAMP_3: string = '2026-08-23T09:00:02.000Z';
const TIMESTAMP_4: string = '2026-08-23T09:00:03.000Z';
const TIMESTAMP_5: string = '2026-08-23T09:00:04.000Z';

interface QueryGroupsCall {
  context: CoreProxyQueryContext;
  selectableOnly: boolean;
}

interface QueryGroupCall {
  context: CoreProxyQueryContext;
  groupName: string;
}

interface SelectCall {
  context: CoreProxyQueryContext;
  groupName: string;
  memberName: string;
}

interface StartDelayCall {
  context: CoreProxyQueryContext;
  groupName: string;
}

interface ReadDelayCall {
  jobId: string;
}

interface CancelDelayCall {
  jobId: string;
}

class Deferred<T> {
  promise: Promise<T>;
  private resolveFn?: (value: T | PromiseLike<T>) => void;
  private rejectFn?: (reason?: Object) => void;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveFn = resolve;
      this.rejectFn = reject;
    });
  }

  resolve(value: T): void {
    this.resolveFn?.(value);
  }

  reject(reason?: Object): void {
    this.rejectFn?.(reason);
  }
}

class FakeClock implements Clock {
  private readonly values: string[];
  private nextIndex: number = 0;

  constructor(values: string[]) {
    this.values = values.slice();
  }

  now(): string {
    const value: string = this.values[Math.min(this.nextIndex, this.values.length - 1)];
    this.nextIndex += 1;
    return value;
  }
}

class FakeProfileRepository implements ProfileRepository {
  readonly profiles: Map<string, Profile> = new Map();
  getError?: Error;

  async list(): Promise<Profile[]> {
    return [];
  }

  async get(id: string): Promise<Profile | undefined> {
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : cloneProfile(profile);
  }

  async save(_profile: Profile): Promise<void> {
    throw new Error('save should stay unused in runtime handler tests');
  }

  async deleteAndClearActive(_id: string): Promise<void> {
    throw new Error('deleteAndClearActive should stay unused in runtime handler tests');
  }

  async getActiveId(): Promise<string | undefined> {
    return undefined;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
    throw new Error('setActiveId should stay unused in runtime handler tests');
  }
}

class FakeSelectionRepository implements ProxySelectionRepository {
  records: ProxySelectionRecord[] = [];
  readonly deleteCalls: string[] = [];
  readonly upsertCalls: ProxySelectionRecord[] = [];
  listByProfileCalls: number = 0;
  getCalls: number = 0;
  listError?: Error;
  deleteError?: Error;
  upsertError?: Error;
  deleteHook?: (profileId: string, groupName: string) => Promise<void>;
  upsertHook?: (record: ProxySelectionRecord) => Promise<void>;

  async listByProfile(profileId: string): Promise<ProxySelectionRecord[]> {
    this.listByProfileCalls += 1;
    if (this.listError !== undefined) {
      throw this.listError;
    }
    const result: ProxySelectionRecord[] = [];
    for (let index: number = 0; index < this.records.length; index += 1) {
      if (this.records[index].profileId === profileId) {
        result.push(cloneRecord(this.records[index]));
      }
    }
    return result;
  }

  async get(profileId: string, groupName: string): Promise<ProxySelectionRecord | undefined> {
    this.getCalls += 1;
    for (let index: number = 0; index < this.records.length; index += 1) {
      const record: ProxySelectionRecord = this.records[index];
      if (record.profileId === profileId && record.groupName === groupName) {
        return cloneRecord(record);
      }
    }
    return undefined;
  }

  async upsert(record: ProxySelectionRecord): Promise<void> {
    if (this.upsertError !== undefined) {
      throw this.upsertError;
    }
    if (this.upsertHook !== undefined) {
      await this.upsertHook(cloneRecord(record));
      return;
    }
    const clone: ProxySelectionRecord = cloneRecord(record);
    this.upsertCalls.push(clone);
    for (let index: number = 0; index < this.records.length; index += 1) {
      if (this.records[index].profileId === clone.profileId && this.records[index].groupName === clone.groupName) {
        this.records[index] = clone;
        return;
      }
    }
    this.records.push(clone);
  }

  async delete(profileId: string, groupName: string): Promise<void> {
    if (this.deleteError !== undefined) {
      throw this.deleteError;
    }
    if (this.deleteHook !== undefined) {
      await this.deleteHook(profileId, groupName);
      return;
    }
    this.deleteCalls.push(`${profileId}:${groupName}`);
    const kept: ProxySelectionRecord[] = [];
    for (let index: number = 0; index < this.records.length; index += 1) {
      const record: ProxySelectionRecord = this.records[index];
      if (record.profileId === profileId && record.groupName === groupName) {
        continue;
      }
      kept.push(record);
    }
    this.records = kept;
  }

  async deleteProfile(_profileId: string): Promise<void> {
    throw new Error('deleteProfile should stay unused in runtime handler tests');
  }

  async reconcileProfile(_profileId: string, _newRevisionId: string, _validPairs: never[]): Promise<void> {
    throw new Error('reconcileProfile should stay unused in runtime handler tests');
  }
}

class FakeHasher implements ProxyIdentityHasher {
  error?: Error;
  hook?: (value: string) => Promise<string>;
  readonly inputs: string[] = [];

  async sha256(value: string): Promise<string> {
    if (this.error !== undefined) {
      throw this.error;
    }
    if (this.hook !== undefined) {
      return await this.hook(value);
    }
    this.inputs.push(value);
    if (value === PROFILE_ID) {
      return PROFILE_HASH;
    }
    if (value === OTHER_PROFILE_ID) {
      return PROFILE_HASH_BETA;
    }
    if (value === SESSION_ID) {
      return SESSION_HASH;
    }
    if (value === OTHER_SESSION_ID) {
      return SESSION_HASH_NEXT;
    }
    throw new Error(`Unexpected hash input: ${value}`);
  }
}

class CoreFailureShape extends Error {
  name: string = 'CoreError';
  code: string;
  detail: string;
  retryable: boolean = false;
  action: string = 'Retry later.';

  constructor(code: string, detail: string) {
    super(detail);
    this.code = code;
    this.detail = detail;
  }
}

class FakeCoreProxyPort implements CoreProxyPort {
  readonly queryGroupsCalls: QueryGroupsCall[] = [];
  readonly queryGroupCalls: QueryGroupCall[] = [];
  readonly selectCalls: SelectCall[] = [];
  readonly startDelayCalls: StartDelayCall[] = [];
  readonly readDelayCalls: ReadDelayCall[] = [];
  readonly cancelDelayCalls: CancelDelayCall[] = [];
  private lastDelayGeneration: number = 19;
  private lastDelayGroupName: string = GROUP_ALPHA;
  queryGroupsHook?: (call: QueryGroupsCall, callIndex: number) => Promise<CoreProxyGroupList>;
  queryGroupHook?: (call: QueryGroupCall, callIndex: number) => Promise<CoreProxyGroupResult>;
  selectHook?: (call: SelectCall, callIndex: number) => Promise<CoreProxySelectionApplied>;
  startDelayHook?: (call: StartDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;
  readDelayHook?: (call: ReadDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;
  cancelDelayHook?: (call: CancelDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;

  async loadConfiguration(_path: string): Promise<void> {
    throw new Error('loadConfiguration should stay unused in runtime handler tests');
  }

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    const call: QueryGroupsCall = {
      context: cloneContext(context),
      selectableOnly
    };
    this.queryGroupsCalls.push(call);
    if (this.queryGroupsHook !== undefined) {
      return await this.queryGroupsHook(call, this.queryGroupsCalls.length);
    }
    return createCoreGroupList(call.context, [createGroupRef(GROUP_ALPHA), createGroupRef(GROUP_BETA)]);
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    const call: QueryGroupCall = {
      context: cloneContext(context),
      groupName
    };
    this.queryGroupCalls.push(call);
    if (this.queryGroupHook !== undefined) {
      return await this.queryGroupHook(call, this.queryGroupCalls.length);
    }
    return createCoreGroupResult(call.context, buildGroupSnapshot(groupName, NODE_ALPHA));
  }

  async selectProxy(
    context: CoreProxyQueryContext,
    groupName: string,
    memberName: string
  ): Promise<CoreProxySelectionApplied> {
    const call: SelectCall = {
      context: cloneContext(context),
      groupName,
      memberName
    };
    this.selectCalls.push(call);
    if (this.selectHook !== undefined) {
      return await this.selectHook(call, this.selectCalls.length);
    }
    return createCoreSelectionApplied(call.context, groupName, memberName, NODE_ALPHA);
  }

  async startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot> {
    const call: StartDelayCall = {
      context: cloneContext(context),
      groupName
    };
    this.startDelayCalls.push(call);
    this.lastDelayGeneration = call.context.generation;
    this.lastDelayGroupName = groupName;
    if (this.startDelayHook !== undefined) {
      return await this.startDelayHook(call, this.startDelayCalls.length);
    }
    return buildDelaySnapshot(call.context.generation, groupName, 'delay-job-1', 'RUNNING');
  }

  async readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    const call: ReadDelayCall = { jobId };
    this.readDelayCalls.push(call);
    if (this.readDelayHook !== undefined) {
      return await this.readDelayHook(call, this.readDelayCalls.length);
    }
    return buildDelaySnapshot(this.lastDelayGeneration, this.lastDelayGroupName, jobId, 'RUNNING');
  }

  async cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    const call: CancelDelayCall = { jobId };
    this.cancelDelayCalls.push(call);
    if (this.cancelDelayHook !== undefined) {
      return await this.cancelDelayHook(call, this.cancelDelayCalls.length);
    }
    return buildDelaySnapshot(this.lastDelayGeneration, this.lastDelayGroupName, jobId, 'CANCELLED');
  }
}

class CountingDeactivateBus extends VpnProxyCommandBus {
  readonly deactivateCalls: string[] = [];

  async deactivate(sessionId: string): Promise<void> {
    this.deactivateCalls.push(sessionId);
    await super.deactivate(sessionId);
  }
}

class ThrowingBindBus extends VpnProxyCommandBus {
  bind(_identity: ProxyRuntimeIdentity, _handler: VpnProxyCommandHandler): number {
    throw new Error('forced bind failure');
  }
}

function buildProfile(
  id: string = PROFILE_ID,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID' = 'VALID',
  validatedAt: string = REVISION_ID,
  digest: string = REVISION_HASH
): Profile {
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind: 'LOCAL_FILE',
    sourceDisplay: `${id}.yaml`,
    currentRevision: createProfileRevision('profiles/current.yaml', digest, 128, validatedAt),
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: TIMESTAMP_1,
    updatedAt: TIMESTAMP_2,
    lastSuccessfulUpdateAt: TIMESTAMP_2
  });
}

function cloneProfile(profile: Profile): Profile {
  return createProfile({
    id: profile.id,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceDisplay: profile.sourceDisplay,
    sourceSecretRef: profile.sourceSecretRef,
    currentRevision: profile.currentRevision,
    failedCandidate: profile.failedCandidate,
    availability: profile.availability,
    lastError: profile.lastError,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt
  });
}

function cloneRecord(record: ProxySelectionRecord): ProxySelectionRecord {
  return createProxySelectionRecord(
    record.profileId,
    record.groupName,
    record.selectedNodeName,
    record.revisionId,
    record.updatedAt
  );
}

function cloneContext(context: CoreProxyQueryContext): CoreProxyQueryContext {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation
  };
}

function createGroupRef(name: string): CoreProxyGroupRef {
  return {
    name,
    type: 'Selector'
  };
}

function buildGroupSnapshot(
  groupName: string,
  selectedName: string,
  nestedSelected: boolean = false,
  includeSelectedMember: boolean = true
): CoreProxyGroupSnapshot {
  const nodes: CoreProxyNodeSummary[] = [];
  if (includeSelectedMember) {
    nodes.push({
      name: selectedName,
      type: nestedSelected ? 'Selector' : 'Shadowsocks',
      isGroup: nestedSelected,
      selected: true
    });
  }
  nodes.push({
    name: selectedName === NODE_ALPHA ? NODE_BETA : NODE_ALPHA,
    type: 'Shadowsocks',
    isGroup: false,
    selected: false
  });
  nodes.push({
    name: NESTED_GROUP,
    type: 'Selector',
    isGroup: true,
    selected: false
  });
  return {
    name: groupName,
    type: 'Selector',
    selectedName,
    nodes
  };
}

function createCoreGroupList(context: CoreProxyQueryContext, groups: CoreProxyGroupRef[]): CoreProxyGroupList {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    schemaVersion: '1.0.0',
    kind: 'GROUP_LIST',
    groups
  };
}

function createCoreGroupResult(context: CoreProxyQueryContext, group: CoreProxyGroupSnapshot): CoreProxyGroupResult {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    schemaVersion: '1.0.0',
    kind: 'GROUP_SNAPSHOT',
    group
  };
}

function createCoreSelectionApplied(
  context: CoreProxyQueryContext,
  groupName: string,
  selectedName: string,
  previousName: string
): CoreProxySelectionApplied {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    schemaVersion: '1.0.0',
    kind: 'SELECTION_APPLIED',
    previousName,
    group: buildGroupSnapshot(groupName, selectedName)
  };
}

function buildDelaySnapshot(
  generation: number,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): CoreProxyDelaySnapshot {
  const trailingState: 'TESTING' | 'TIMEOUT' | 'CANCELLED' | 'FAILED' = state === 'RUNNING'
    ? 'TESTING'
    : state === 'COMPLETED'
      ? 'TIMEOUT'
      : state === 'CANCELLED'
        ? 'CANCELLED'
        : 'FAILED';
  return {
    schemaVersion: '1.0.0',
    jobId,
    state,
    profileHash: PROFILE_HASH,
    revisionHash: REVISION_HASH,
    sessionHash: SESSION_HASH,
    generation,
    groupName,
    totalCount: 2,
    testableCount: 2,
    completedCount: state === 'RUNNING' ? 1 : 2,
    availableCount: 1,
    timeoutCount: trailingState === 'TIMEOUT' ? 1 : 0,
    failedCount: trailingState === 'FAILED' ? 1 : 0,
    cancelledCount: trailingState === 'CANCELLED' ? 1 : 0,
    unsupportedCount: 0,
    fastestNodeIndex: 0,
    nodes: [
      {
        index: 0,
        name: NODE_ALPHA,
        type: 'Trojan',
        state: 'AVAILABLE',
        delayMs: 41,
        source: 'PROVIDER',
        fastest: true
      },
      {
        index: 1,
        name: NODE_BETA,
        type: 'Shadowsocks',
        state: trailingState,
        delayMs: null,
        source: null,
        fastest: false
      }
    ]
  };
}

function createCoreFailure(operation: string, code: string, detail: string): Error {
  return normalizeCoreError(operation, new CoreFailureShape(code, detail));
}

function buildIdentity(sessionId: string = SESSION_ID): ProxyRuntimeIdentity {
  return createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, sessionId);
}

function buildHandler(
  repository: FakeProfileRepository,
  selectionRepository: FakeSelectionRepository,
  hasher: FakeHasher,
  core: FakeCoreProxyPort,
  clock: FakeClock,
  bus: VpnProxyCommandBus,
  initialGeneration: number = 0
): VpnProxyRuntimeHandler {
  return new VpnProxyRuntimeHandler(repository, selectionRepository, hasher, core, clock, bus, initialGeneration);
}

async function expectActivationFailure(
  handler: VpnProxyRuntimeHandler,
  request: VpnStartRequest,
  fragments: string[]
): Promise<void> {
  let message: string = '';
  try {
    await handler.activate(request);
  } catch (error) {
    message = error instanceof Error ? error.message : `${error}`;
  }
  expect(message).assertEqual('Vpn proxy runtime activation failed.');
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(message.includes(fragments[index])).assertFalse();
  }
}

async function expectBindFailure(
  handler: VpnProxyRuntimeHandler,
  request: VpnStartRequest,
  fragments: string[]
): Promise<void> {
  let message: string = '';
  try {
    await handler.bindExistingSession(request);
  } catch (error) {
    message = error instanceof Error ? error.message : `${error}`;
  }
  expect(message).assertEqual('Vpn proxy runtime activation failed.');
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(message.includes(fragments[index])).assertFalse();
  }
}

function expectRejected(
  result: ProxyGroupListQueryResult | ProxyGroupQueryResult | ProxySelectionResult | ProxyDelayResult,
  code: string,
  timestamp?: string
): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind !== 'REJECTED') {
    throw new Error(`Expected rejected result but received ${result.kind}.`);
  }
  expect(result.error.code).assertEqual(code);
  if (timestamp !== undefined) {
    expect(result.error.timestamp).assertEqual(timestamp);
  }
}

function expectDelaySnapshot(result: ProxyDelayResult, jobId: string, state: string): void {
  expect(result.kind).assertEqual('SNAPSHOT');
  if (result.kind !== 'SNAPSHOT') {
    throw new Error(`Expected delay snapshot but received ${result.kind}.`);
  }
  expect(result.jobId).assertEqual(jobId);
  expect(result.state).assertEqual(state);
}

export default function vpnProxyRuntimeHandlerTestsuite() {
  describe('VpnProxyRuntimeHandlerTest', () => {
    it('rejectsMissingInvalidMismatchAndSanitizesActivationFailures', 0, async () => {
      const repository = new FakeProfileRepository();
      const selections = new FakeSelectionRepository();
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      const handler = buildHandler(repository, selections, hasher, core, new FakeClock([TIMESTAMP_1]), bus);
      const request = createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID);

      await expectActivationFailure(handler, request, [PROFILE_ID, SESSION_ID]);

      repository.profiles.set(PROFILE_ID, buildProfile(PROFILE_ID, 'INVALID'));
      await expectActivationFailure(handler, request, [PROFILE_ID]);

      repository.profiles.set(PROFILE_ID, buildProfile(PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      await expectActivationFailure(handler, request, [REVISION_ID_NEXT, REVISION_HASH_NEXT]);

      repository.profiles.set(PROFILE_ID, buildProfile());
      hasher.error = new Error(`hash ${PROFILE_ID} ${SESSION_ID}`);
      await expectActivationFailure(handler, request, [PROFILE_ID, SESSION_ID, 'hash']);

      hasher.error = undefined;
      hasher.hook = async (value: string): Promise<string> => {
        if (value === PROFILE_ID) {
          return 'UPPERCASE_NOT_ALLOWED';
        }
        return SESSION_HASH;
      };
      await expectActivationFailure(handler, request, [PROFILE_ID, SESSION_HASH]);
    });

    it('rejectsMirrorBindValidationFailuresAndSanitizesBindErrors', 0, async () => {
      const repository = new FakeProfileRepository();
      const selections = new FakeSelectionRepository();
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      const handler = buildHandler(repository, selections, hasher, core, new FakeClock([TIMESTAMP_1]), bus);
      const request = createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID);

      await expectBindFailure(handler, request, [PROFILE_ID, SESSION_ID]);

      repository.profiles.set(PROFILE_ID, buildProfile(PROFILE_ID, 'INVALID'));
      await expectBindFailure(handler, request, [PROFILE_ID]);

      repository.profiles.set(PROFILE_ID, buildProfile(PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      await expectBindFailure(handler, request, [REVISION_ID_NEXT, REVISION_HASH_NEXT]);

      repository.profiles.set(PROFILE_ID, buildProfile());
      hasher.error = new Error(`hash ${PROFILE_ID} ${SESSION_ID}`);
      await expectBindFailure(handler, request, [PROFILE_ID, SESSION_ID, 'hash']);

      hasher.error = undefined;
      hasher.hook = async (value: string): Promise<string> => {
        if (value === PROFILE_ID) {
          return 'UPPERCASE_NOT_ALLOWED';
        }
        return SESSION_HASH;
      };
      await expectBindFailure(handler, request, [PROFILE_ID, SESSION_HASH]);
    });

    it('activatesEmptyRuntimeAndBindsQueriesWithExactContextsAndClonedResults', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const selections = new FakeSelectionRepository();
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(repository, selections, hasher, core, new FakeClock([TIMESTAMP_1]), bus);
      const identity = buildIdentity();

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      const groupsResult = await bus.submitQueryGroups(createVpnProxyQueryGroupsCommand(identity, 11, true));
      const groupResult = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(identity, 12, GROUP_ALPHA));

      expect(hasher.inputs.length).assertEqual(2);
      expect(hasher.inputs[0]).assertEqual(PROFILE_ID);
      expect(hasher.inputs[1]).assertEqual(SESSION_ID);
      expect(core.queryGroupsCalls.length).assertEqual(1);
      expect(core.queryGroupsCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.queryGroupsCalls[0].context.revisionHash).assertEqual(REVISION_HASH);
      expect(core.queryGroupsCalls[0].context.sessionHash).assertEqual(SESSION_HASH);
      expect(core.queryGroupsCalls[0].context.generation).assertEqual(11);
      expect(core.queryGroupCalls[0].context.generation).assertEqual(12);
      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      if (groupsResult.kind === 'SNAPSHOT') {
        groupsResult.groups[0].name = 'Mutated';
      }
      const secondGroups = await bus.submitQueryGroups(createVpnProxyQueryGroupsCommand(identity, 13, false));
      expect(secondGroups.kind).assertEqual('SNAPSHOT');
      if (secondGroups.kind === 'SNAPSHOT') {
        expect(secondGroups.groups[0].name).assertEqual(GROUP_ALPHA);
      }
    });

    it('bindsExistingRuntimeWithoutReplayAndEnablesMirrorCommandsThroughBus', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const selections = new FakeSelectionRepository();
      selections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        hasher,
        core,
        new FakeClock([TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        bus
      );
      const identity = buildIdentity();

      await handler.bindExistingSession(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      expect(hasher.inputs.length).assertEqual(2);
      expect(hasher.inputs[0]).assertEqual(PROFILE_ID);
      expect(hasher.inputs[1]).assertEqual(SESSION_ID);
      expect(selections.listByProfileCalls).assertEqual(0);
      expect(selections.getCalls).assertEqual(0);
      expect(selections.upsertCalls.length).assertEqual(0);
      expect(selections.deleteCalls.length).assertEqual(0);
      expect(core.selectCalls.length).assertEqual(0);
      expect(core.queryGroupCalls.length).assertEqual(0);
      expect(core.queryGroupsCalls.length).assertEqual(0);

      const groupsResult = await bus.submitQueryGroups(createVpnProxyQueryGroupsCommand(identity, 11, true));
      const groupResult = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(identity, 12, GROUP_ALPHA));
      const selectResult = await bus.submitSelect(createVpnProxySelectCommand(identity, 13, GROUP_ALPHA, NODE_BETA));
      const started = await bus.submitStartDelayTest(createVpnProxyStartDelayTestCommand(identity, 19, GROUP_ALPHA));
      const read = await bus.submitReadDelayTest(createVpnProxyReadDelayTestCommand(identity, 19, 'delay-job-1'));
      const cancelled = await bus.submitCancelDelayTest(createVpnProxyCancelDelayTestCommand(identity, 19, 'delay-job-1'));

      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      expect(selectResult.kind).assertEqual('APPLIED_NOW');
      expectDelaySnapshot(started, 'delay-job-1', 'RUNNING');
      expectDelaySnapshot(read, 'delay-job-1', 'RUNNING');
      expectDelaySnapshot(cancelled, 'delay-job-1', 'CANCELLED');
      expect(core.queryGroupsCalls.length).assertEqual(1);
      expect(core.queryGroupsCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.queryGroupsCalls[0].context.revisionHash).assertEqual(REVISION_HASH);
      expect(core.queryGroupsCalls[0].context.sessionHash).assertEqual(SESSION_HASH);
      expect(core.queryGroupsCalls[0].context.generation).assertEqual(11);
      expect(core.queryGroupCalls.length).assertEqual(2);
      expect(core.queryGroupCalls[0].context.generation).assertEqual(12);
      expect(core.queryGroupCalls[1].context.generation).assertEqual(13);
      expect(core.selectCalls.length).assertEqual(1);
      expect(core.selectCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.selectCalls[0].context.sessionHash).assertEqual(SESSION_HASH);
      expect(core.selectCalls[0].context.generation).assertEqual(13);
      expect(core.startDelayCalls.length).assertEqual(1);
      expect(core.startDelayCalls[0].context.sessionHash).assertEqual(SESSION_HASH);
      expect(selections.upsertCalls.length).assertEqual(1);
      expect(selections.upsertCalls[0].groupName).assertEqual(GROUP_ALPHA);
      expect(selections.upsertCalls[0].selectedNodeName).assertEqual(NODE_BETA);
      expect(selections.upsertCalls[0].updatedAt).assertEqual(TIMESTAMP_2);
      expect(selections.deleteCalls.length).assertEqual(0);
      expect(selections.listByProfileCalls).assertEqual(0);
      expect(selections.getCalls).assertEqual(0);
    });

    it('replaysRecordsInRepositoryOrderAndDeletesOrUpdatesBeforeBind', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const selections = new FakeSelectionRepository();
      selections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID, TIMESTAMP_1),
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_NEXT, TIMESTAMP_1)
      ];
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      core.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          throw createCoreFailure('queryProxyGroup', 'PROXY_GROUP_NOT_FOUND', `Missing ${call.groupName}`);
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      core.selectHook = async (call: SelectCall): Promise<CoreProxySelectionApplied> => {
        return createCoreSelectionApplied(call.context, call.groupName, call.memberName, NODE_BETA);
      };
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        hasher,
        core,
        new FakeClock([TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        bus
      );

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      expect(core.queryGroupCalls.length).assertEqual(2);
      expect(core.queryGroupCalls[0].groupName).assertEqual(GROUP_BETA);
      expect(core.queryGroupCalls[1].groupName).assertEqual(GROUP_ALPHA);
      expect(selections.deleteCalls.join(',')).assertEqual(`${PROFILE_ID}:${GROUP_BETA}`);
      expect(selections.upsertCalls.length).assertEqual(1);
      expect(selections.upsertCalls[0].groupName).assertEqual(GROUP_ALPHA);
      expect(selections.upsertCalls[0].revisionId).assertEqual(REVISION_ID);
      expect(selections.upsertCalls[0].updatedAt).assertEqual(TIMESTAMP_2);

      const queryResult = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 7, GROUP_ALPHA));
      expect(queryResult.kind).assertEqual('SNAPSHOT');
    });

    it('abortsActivationOnReplayDeleteUpsertOrGenerationFailureWithoutBinding', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const request = createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID);

      const staleSelections = new FakeSelectionRepository();
      staleSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      staleSelections.deleteError = new Error(`delete ${GROUP_ALPHA}`);
      const staleCore = new FakeCoreProxyPort();
      staleCore.queryGroupHook = async (): Promise<CoreProxyGroupResult> => {
        throw createCoreFailure('queryProxyGroup', 'PROXY_GROUP_NOT_FOUND', GROUP_ALPHA);
      };
      const staleBus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      const staleHandler = buildHandler(
        repository,
        staleSelections,
        new FakeHasher(),
        staleCore,
        new FakeClock([TIMESTAMP_1]),
        staleBus
      );
      await expectActivationFailure(staleHandler, request, [GROUP_ALPHA]);
      expectRejected(
        await staleBus.submitQueryGroups(createVpnProxyQueryGroupsCommand(buildIdentity(), 1, true)),
        'VPN_SESSION_CHANGED'
      );

      const upsertSelections = new FakeSelectionRepository();
      upsertSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      upsertSelections.upsertError = new Error(`upsert ${GROUP_ALPHA}`);
      const upsertCore = new FakeCoreProxyPort();
      const upsertHandler = buildHandler(
        repository,
        upsertSelections,
        new FakeHasher(),
        upsertCore,
        new FakeClock([TIMESTAMP_2]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await expectActivationFailure(upsertHandler, request, [GROUP_ALPHA]);

      const exhaustedSelections = new FakeSelectionRepository();
      exhaustedSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      const exhaustedHandler = buildHandler(
        repository,
        exhaustedSelections,
        new FakeHasher(),
        new FakeCoreProxyPort(),
        new FakeClock([TIMESTAMP_3]),
        new VpnProxyCommandBus(() => TIMESTAMP_4),
        Number.MAX_SAFE_INTEGER
      );
      await expectActivationFailure(exhaustedHandler, request, [PROFILE_ID, SESSION_ID]);
    });

    it('leavesNoBoundMirrorStateWhenExistingSessionBindFails', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const selections = new FakeSelectionRepository();
      const core = new FakeCoreProxyPort();
      const bus = new ThrowingBindBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1]),
        bus
      );

      await expectBindFailure(handler, createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID), []);

      expect(selections.listByProfileCalls).assertEqual(0);
      expect(selections.getCalls).assertEqual(0);
      expect(selections.upsertCalls.length).assertEqual(0);
      expect(selections.deleteCalls.length).assertEqual(0);
      expect(core.selectCalls.length).assertEqual(0);
      expectRejected(
        await handler.queryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 1, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );
      expectRejected(
        await bus.submitQueryGroups(createVpnProxyQueryGroupsCommand(buildIdentity(), 2, true)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_5
      );
    });

    it('mapsCoreQueryFailuresAndRejectsIdentityMismatchForDirectQueries', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      expectRejected(
        await handler.queryGroup(createVpnProxyQueryGroupCommand(buildIdentity(OTHER_SESSION_ID), 1, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );

      core.queryGroupsHook = async (): Promise<CoreProxyGroupList> => {
        throw createCoreFailure('queryProxyGroups', 'PROXY_RUNTIME_NOT_READY', 'runtime offline');
      };
      expectRejected(
        await handler.queryGroups(createVpnProxyQueryGroupsCommand(buildIdentity(), 2, true)),
        'PROXY_QUERY_FAILED',
        TIMESTAMP_2
      );
    });

    it('rejectsStaleMissingAndNestedMembersBeforeRunningSelectPatch', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA, false, false));
      };
      expectRejected(
        await handler.select(createVpnProxySelectCommand(buildIdentity(), 5, GROUP_ALPHA, NODE_ALPHA)),
        'PROXY_SELECTION_STALE',
        TIMESTAMP_1
      );

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA, true, true));
      };
      expectRejected(
        await handler.select(createVpnProxySelectCommand(buildIdentity(), 6, GROUP_ALPHA, NODE_ALPHA)),
        'PROXY_SELECTION_STALE',
        TIMESTAMP_2
      );

      expect(core.selectCalls.length).assertEqual(0);
      expect(selections.upsertCalls.length).assertEqual(0);
    });

    it('classifiesSelectPatchStaleCoreErrorsAsSelectionStaleButKeepsOtherPatchErrorsAsSelectionFailed', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      core.selectHook = async (): Promise<CoreProxySelectionApplied> => {
        throw createCoreFailure('selectProxy', 'PROXY_GROUP_NOT_FOUND', `missing ${GROUP_ALPHA}`);
      };
      expectRejected(
        await handler.select(createVpnProxySelectCommand(buildIdentity(), 7, GROUP_ALPHA, NODE_ALPHA)),
        'PROXY_SELECTION_STALE',
        TIMESTAMP_1
      );

      core.selectHook = async (): Promise<CoreProxySelectionApplied> => {
        throw createCoreFailure('selectProxy', 'PROXY_MEMBER_NOT_FOUND', `missing ${NODE_ALPHA}`);
      };
      expectRejected(
        await handler.select(createVpnProxySelectCommand(buildIdentity(), 8, GROUP_ALPHA, NODE_ALPHA)),
        'PROXY_SELECTION_STALE',
        TIMESTAMP_2
      );

      core.selectHook = async (): Promise<CoreProxySelectionApplied> => {
        throw createCoreFailure('selectProxy', 'PROXY_SELECTION_FAILED', `failed ${NODE_ALPHA}`);
      };
      const failed = await handler.select(createVpnProxySelectCommand(buildIdentity(), 9, GROUP_ALPHA, NODE_ALPHA));
      expectRejected(failed, 'PROXY_SELECTION_FAILED', TIMESTAMP_3);
      if (failed.kind === 'REJECTED') {
        expect(failed.error.code.includes(GROUP_ALPHA)).assertFalse();
        expect(failed.error.code.includes(NODE_ALPHA)).assertFalse();
      }
    });

    it('queriesThenPatchesThenPersistsConfirmedRunningSelection', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      core.selectHook = async (call: SelectCall): Promise<CoreProxySelectionApplied> => {
        return createCoreSelectionApplied(call.context, call.groupName, call.memberName, NODE_BETA);
      };

      const result = await handler.select(createVpnProxySelectCommand(buildIdentity(), 8, GROUP_ALPHA, NODE_ALPHA));

      expect(result.kind).assertEqual('APPLIED_NOW');
      if (result.kind === 'APPLIED_NOW') {
        expect(result.snapshot.identity.sessionId).assertEqual(SESSION_ID);
        expect(result.snapshot.generation).assertEqual(8);
        expect(result.snapshot.group.selectedName).assertEqual(NODE_ALPHA);
        expect(result.record.updatedAt).assertEqual(TIMESTAMP_1);
        expect(result.confirmedAt).assertEqual(TIMESTAMP_1);
      }
      expect(core.queryGroupCalls.length).assertEqual(1);
      expect(core.selectCalls.length).assertEqual(1);
      expect(core.queryGroupCalls[0].context.generation).assertEqual(8);
      expect(core.selectCalls[0].context.generation).assertEqual(8);
      expect(selections.upsertCalls.length).assertEqual(1);
      expect(selections.upsertCalls[0].selectedNodeName).assertEqual(NODE_ALPHA);
    });

    it('deletesReplayRecordAndContinuesWhenPatchTurnsStaleButAbortsOnDeleteFailureOrNonStalePatchError', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const request = createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID);

      const continueSelections = new FakeSelectionRepository();
      continueSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1),
        createProxySelectionRecord(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID, TIMESTAMP_1)
      ];
      const continueCore = new FakeCoreProxyPort();
      continueCore.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_BETA));
      };
      continueCore.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          throw createCoreFailure('selectProxy', 'PROXY_MEMBER_NOT_FOUND', `missing ${NODE_ALPHA}`);
        }
        return createCoreSelectionApplied(call.context, call.groupName, call.memberName, NODE_ALPHA);
      };
      const continueBus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const continueHandler = buildHandler(
        repository,
        continueSelections,
        new FakeHasher(),
        continueCore,
        new FakeClock([TIMESTAMP_2, TIMESTAMP_3]),
        continueBus
      );
      await continueHandler.activate(request);
      expect(continueSelections.deleteCalls.join(',')).assertEqual(`${PROFILE_ID}:${GROUP_ALPHA}`);
      expect(continueSelections.upsertCalls.length).assertEqual(1);
      expect(continueSelections.upsertCalls[0].groupName).assertEqual(GROUP_BETA);
      expect((await continueBus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 10, GROUP_BETA))).kind)
        .assertEqual('SNAPSHOT');

      const deleteFailSelections = new FakeSelectionRepository();
      deleteFailSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      deleteFailSelections.deleteError = new Error(`delete ${GROUP_ALPHA}`);
      const deleteFailCore = new FakeCoreProxyPort();
      deleteFailCore.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      deleteFailCore.selectHook = async (): Promise<CoreProxySelectionApplied> => {
        throw createCoreFailure('selectProxy', 'PROXY_GROUP_NOT_FOUND', `missing ${GROUP_ALPHA}`);
      };
      const deleteFailHandler = buildHandler(
        repository,
        deleteFailSelections,
        new FakeHasher(),
        deleteFailCore,
        new FakeClock([TIMESTAMP_4]),
        new VpnProxyCommandBus(() => TIMESTAMP_5)
      );
      await expectActivationFailure(deleteFailHandler, request, [GROUP_ALPHA, NODE_ALPHA]);

      const hardFailSelections = new FakeSelectionRepository();
      hardFailSelections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      const hardFailCore = new FakeCoreProxyPort();
      hardFailCore.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      hardFailCore.selectHook = async (): Promise<CoreProxySelectionApplied> => {
        throw createCoreFailure('selectProxy', 'PROXY_SELECTION_FAILED', `failed ${NODE_ALPHA}`);
      };
      const hardFailHandler = buildHandler(
        repository,
        hardFailSelections,
        new FakeHasher(),
        hardFailCore,
        new FakeClock([TIMESTAMP_5]),
        new VpnProxyCommandBus(() => TIMESTAMP_5)
      );
      await expectActivationFailure(hardFailHandler, request, [GROUP_ALPHA, NODE_ALPHA]);
    });

    it('rollsBackAndRejectsWhenPersistenceFailsButRollbackRestoresPreviousChoice', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      selections.upsertError = new Error(`persist ${GROUP_ALPHA}`);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      core.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        const selectedName: string = callIndex === 1 ? NODE_ALPHA : NODE_BETA;
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, selectedName));
      };
      core.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          return createCoreSelectionApplied(call.context, call.groupName, NODE_ALPHA, NODE_BETA);
        }
        return createCoreSelectionApplied(call.context, call.groupName, NODE_BETA, NODE_ALPHA);
      };

      const result = await handler.select(createVpnProxySelectCommand(buildIdentity(), 9, GROUP_ALPHA, NODE_ALPHA));

      expectRejected(result, 'PROXY_PERSISTENCE_FAILED', TIMESTAMP_1);
      expect(core.selectCalls.length).assertEqual(2);
      expect(core.selectCalls[1].memberName).assertEqual(NODE_BETA);
      expect(selections.upsertCalls.length).assertEqual(0);
    });

    it('trustsConfirmedRollbackPatchEvenWhenDefensiveRollbackQueryFails', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      selections.upsertError = new Error(`persist ${GROUP_ALPHA}`);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      core.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
        }
        throw createCoreFailure('queryProxyGroup', 'PROXY_RUNTIME_NOT_READY', `offline ${GROUP_ALPHA}`);
      };
      core.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          return createCoreSelectionApplied(call.context, call.groupName, NODE_ALPHA, NODE_BETA);
        }
        return createCoreSelectionApplied(call.context, call.groupName, NODE_BETA, NODE_ALPHA);
      };

      const result = await handler.select(createVpnProxySelectCommand(buildIdentity(), 12, GROUP_ALPHA, NODE_ALPHA));
      expectRejected(result, 'PROXY_PERSISTENCE_FAILED', TIMESTAMP_1);
      expect(core.selectCalls.length).assertEqual(2);
      expect(core.queryGroupCalls.length).assertEqual(1);
    });

    it('reportsAppliedNotPersistedWhenRollbackIsMissingFailsOrMismatches', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());

      const emptyPreviousCore = new FakeCoreProxyPort();
      const emptyPreviousSelections = new FakeSelectionRepository();
      emptyPreviousSelections.upsertError = new Error('persist failed');
      const emptyPreviousHandler = buildHandler(
        repository,
        emptyPreviousSelections,
        new FakeHasher(),
        emptyPreviousCore,
        new FakeClock([TIMESTAMP_1]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await emptyPreviousHandler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      emptyPreviousCore.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      emptyPreviousCore.selectHook = async (call: SelectCall): Promise<CoreProxySelectionApplied> => {
        return {
          profileHash: call.context.profileHash,
          revisionHash: call.context.revisionHash,
          sessionHash: call.context.sessionHash,
          generation: call.context.generation,
          schemaVersion: '1.0.0',
          kind: 'SELECTION_APPLIED',
          previousName: '',
          group: buildGroupSnapshot(call.groupName, NODE_ALPHA)
        };
      };
      const emptyPrevious = await emptyPreviousHandler.select(
        createVpnProxySelectCommand(buildIdentity(), 10, GROUP_ALPHA, NODE_ALPHA)
      );
      expect(emptyPrevious.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (emptyPrevious.kind === 'APPLIED_NOT_PERSISTED') {
        expect(emptyPrevious.snapshot.group.selectedName).assertEqual(NODE_ALPHA);
        expect(emptyPrevious.record.selectedNodeName).assertEqual(NODE_ALPHA);
        expect(emptyPrevious.error.code).assertEqual('PROXY_PERSISTENCE_FAILED');
      }

      const mismatchCore = new FakeCoreProxyPort();
      const mismatchSelections = new FakeSelectionRepository();
      mismatchSelections.upsertError = new Error('persist failed');
      const mismatchHandler = buildHandler(
        repository,
        mismatchSelections,
        new FakeHasher(),
        mismatchCore,
        new FakeClock([TIMESTAMP_2]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await mismatchHandler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      mismatchCore.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        const selectedName: string = callIndex === 1 ? NODE_ALPHA : NODE_GAMMA;
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, selectedName));
      };
      mismatchCore.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          return createCoreSelectionApplied(call.context, call.groupName, NODE_ALPHA, NODE_BETA);
        }
        return createCoreSelectionApplied(call.context, call.groupName, NODE_GAMMA, NODE_ALPHA);
      };
      const mismatch = await mismatchHandler.select(
        createVpnProxySelectCommand(buildIdentity(), 11, GROUP_ALPHA, NODE_ALPHA)
      );
      expect(mismatch.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (mismatch.kind === 'APPLIED_NOT_PERSISTED') {
        expect(mismatch.snapshot.group.selectedName).assertEqual(NODE_GAMMA);
        expect(mismatch.record.selectedNodeName).assertEqual(NODE_GAMMA);
        expect(mismatch.error.timestamp).assertEqual(TIMESTAMP_2);
      }
    });

    it('usesLatestConfirmedRollbackSnapshotWhenRollbackQueryFailsOrReturnsNonterminal', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());

      const queryFailCore = new FakeCoreProxyPort();
      const queryFailSelections = new FakeSelectionRepository();
      queryFailSelections.upsertError = new Error('persist failed');
      const queryFailHandler = buildHandler(
        repository,
        queryFailSelections,
        new FakeHasher(),
        queryFailCore,
        new FakeClock([TIMESTAMP_3]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await queryFailHandler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      queryFailCore.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
        }
        throw createCoreFailure('queryProxyGroup', 'PROXY_RUNTIME_NOT_READY', `offline ${GROUP_ALPHA}`);
      };
      queryFailCore.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          return createCoreSelectionApplied(call.context, call.groupName, NODE_ALPHA, NODE_BETA);
        }
        return createCoreSelectionApplied(call.context, call.groupName, NODE_GAMMA, NODE_ALPHA);
      };
      const queryFail = await queryFailHandler.select(
        createVpnProxySelectCommand(buildIdentity(), 13, GROUP_ALPHA, NODE_ALPHA)
      );
      expect(queryFail.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (queryFail.kind === 'APPLIED_NOT_PERSISTED') {
        expect(queryFail.snapshot.group.selectedName).assertEqual(NODE_GAMMA);
        expect(queryFail.record.selectedNodeName).assertEqual(NODE_GAMMA);
        expect(queryFail.record.groupName).assertEqual(GROUP_ALPHA);
      }

      const nonterminalCore = new FakeCoreProxyPort();
      const nonterminalSelections = new FakeSelectionRepository();
      nonterminalSelections.upsertError = new Error('persist failed');
      const nonterminalHandler = buildHandler(
        repository,
        nonterminalSelections,
        new FakeHasher(),
        nonterminalCore,
        new FakeClock([TIMESTAMP_4]),
        new VpnProxyCommandBus(() => TIMESTAMP_4)
      );
      await nonterminalHandler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      nonterminalCore.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_GAMMA, true, true));
      };
      nonterminalCore.selectHook = async (call: SelectCall, callIndex: number): Promise<CoreProxySelectionApplied> => {
        if (callIndex === 1) {
          return createCoreSelectionApplied(call.context, call.groupName, NODE_ALPHA, NODE_BETA);
        }
        return createCoreSelectionApplied(call.context, call.groupName, NODE_GAMMA, NODE_ALPHA);
      };
      const nonterminal = await nonterminalHandler.select(
        createVpnProxySelectCommand(buildIdentity(), 14, GROUP_ALPHA, NODE_ALPHA)
      );
      expect(nonterminal.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (nonterminal.kind === 'APPLIED_NOT_PERSISTED') {
        expect(nonterminal.snapshot.group.selectedName).assertEqual(NODE_GAMMA);
        expect(nonterminal.record.selectedNodeName).assertEqual(NODE_GAMMA);
        expect(nonterminal.error.code.includes(GROUP_ALPHA)).assertFalse();
        expect(nonterminal.error.code.includes(NODE_GAMMA)).assertFalse();
      }
    });

    it('startsReadsAndCancelsDelayTestsUsingRunningContextAndWithoutSelectionSideEffects', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]),
        new VpnProxyCommandBus(() => TIMESTAMP_5)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      const started = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(buildIdentity(), 19, GROUP_ALPHA)
      );
      const read = await handler.readDelayTest(
        createVpnProxyReadDelayTestCommand(buildIdentity(), 19, 'delay-job-1')
      );
      const cancelled = await handler.cancelDelayTest(
        createVpnProxyCancelDelayTestCommand(buildIdentity(), 19, 'delay-job-1')
      );

      expectDelaySnapshot(started, 'delay-job-1', 'RUNNING');
      expectDelaySnapshot(read, 'delay-job-1', 'RUNNING');
      expectDelaySnapshot(cancelled, 'delay-job-1', 'CANCELLED');
      expect(core.startDelayCalls.length).assertEqual(1);
      expect(core.startDelayCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.startDelayCalls[0].context.sessionHash).assertEqual(SESSION_HASH);
      expect(core.readDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls.length).assertEqual(1);
      expect(selections.listByProfileCalls).assertEqual(1);
      expect(selections.upsertCalls.length).assertEqual(0);
      expect(selections.deleteCalls.length).assertEqual(0);
    });

    it('rejectsDelayCommandsAcrossSessionGenerationOrJobBoundariesAndMapsCoreFailures', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        new VpnProxyCommandBus(() => TIMESTAMP_5)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 19, GROUP_ALPHA));

      expectRejected(
        await handler.readDelayTest(createVpnProxyReadDelayTestCommand(buildIdentity(OTHER_SESSION_ID), 19, 'delay-job-1')),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );
      expectRejected(
        await handler.cancelDelayTest(createVpnProxyCancelDelayTestCommand(buildIdentity(), 20, 'delay-job-1')),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_2
      );
      expectRejected(
        await handler.readDelayTest(createVpnProxyReadDelayTestCommand(buildIdentity(), 19, 'other-job')),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_3
      );

      core.startDelayHook = async (): Promise<CoreProxyDelaySnapshot> => {
        throw new Error('raw delay failure');
      };
      expectRejected(
        await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 21, GROUP_ALPHA)),
        'PROXY_DELAY_TEST_FAILED',
        TIMESTAMP_4
      );
    });

    it('drainsRememberedDelayJobsAcrossInvalidationDeactivationAndSessionReplacement', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      repository.profiles.set(OTHER_PROFILE_ID, buildProfile(OTHER_PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      const core = new FakeCoreProxyPort();
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4, TIMESTAMP_5]),
        new VpnProxyCommandBus(() => TIMESTAMP_5)
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 19, GROUP_ALPHA));

      handler.invalidate(SESSION_ID);
      await handler.cancelAndDrainDelayTest(SESSION_ID);
      expect(core.cancelDelayCalls.length).assertEqual(1);

      await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 20, GROUP_ALPHA));
      await handler.deactivate(SESSION_ID);
      expect(core.cancelDelayCalls.length).assertEqual(2);

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 21, GROUP_ALPHA));
      await handler.activate(createVpnStartRequest(OTHER_PROFILE_ID, REVISION_ID_NEXT, OTHER_SESSION_ID));
      expect(core.cancelDelayCalls.length).assertEqual(3);
    });

    it('deactivatePostFlushDrainsJobsPublishedByInflightStartDelayTests', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      const startEntered = new Deferred<boolean>();
      const releaseStart = new Deferred<CoreProxyDelaySnapshot>();
      core.startDelayHook = async (call: StartDelayCall): Promise<CoreProxyDelaySnapshot> => {
        startEntered.resolve(true);
        return await releaseStart.promise;
      };

      const startPromise = bus.submitStartDelayTest(
        createVpnProxyStartDelayTestCommand(buildIdentity(), 30, GROUP_ALPHA)
      );
      await startEntered.promise;

      let deactivateFinished: boolean = false;
      const deactivatePromise = handler.deactivate(SESSION_ID).then(() => {
        deactivateFinished = true;
      });
      await Promise.resolve();
      expect(deactivateFinished).assertFalse();
      expect(core.cancelDelayCalls.length).assertEqual(0);

      releaseStart.resolve(buildDelaySnapshot(30, GROUP_ALPHA, 'delay-job-1', 'RUNNING'));

      const startResult = await startPromise;
      expectRejected(startResult, 'VPN_SESSION_CHANGED', TIMESTAMP_5);
      await deactivatePromise;

      expect(deactivateFinished).assertTrue();
      expect(core.cancelDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls[0].jobId).assertEqual('delay-job-1');

      await handler.cancelAndDrainDelayTest(SESSION_ID);
      expect(core.cancelDelayCalls.length).assertEqual(1);
    });

    it('activateReplacementWaitsForInflightStartDrainBeforeRebinding', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      repository.profiles.set(OTHER_PROFILE_ID, buildProfile(OTHER_PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      const startEntered = new Deferred<boolean>();
      const releaseStart = new Deferred<CoreProxyDelaySnapshot>();
      core.startDelayHook = async (): Promise<CoreProxyDelaySnapshot> => {
        startEntered.resolve(true);
        return await releaseStart.promise;
      };

      const oldStartPromise = bus.submitStartDelayTest(
        createVpnProxyStartDelayTestCommand(buildIdentity(), 31, GROUP_ALPHA)
      );
      await startEntered.promise;

      let replacementFinished: boolean = false;
      const replacementPromise = handler.activate(
        createVpnStartRequest(OTHER_PROFILE_ID, REVISION_ID_NEXT, OTHER_SESSION_ID)
      ).then(() => {
        replacementFinished = true;
      });
      await Promise.resolve();
      expect(replacementFinished).assertFalse();
      expect(core.cancelDelayCalls.length).assertEqual(0);

      releaseStart.resolve(buildDelaySnapshot(31, GROUP_ALPHA, 'delay-job-1', 'RUNNING'));

      const oldStartResult = await oldStartPromise;
      expectRejected(oldStartResult, 'VPN_SESSION_CHANGED', TIMESTAMP_5);
      await replacementPromise;

      expect(replacementFinished).assertTrue();
      expect(core.cancelDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls[0].jobId).assertEqual('delay-job-1');

      const rebound = await bus.submitQueryGroup(
        createVpnProxyQueryGroupCommand(
          createProxyRuntimeIdentity(OTHER_PROFILE_ID, REVISION_ID_NEXT, REVISION_HASH_NEXT, OTHER_SESSION_ID),
          32,
          GROUP_ALPHA
        )
      );
      expect(rebound.kind).assertEqual('SNAPSHOT');

      await handler.cancelAndDrainDelayTest(SESSION_ID);
      expect(core.cancelDelayCalls.length).assertEqual(1);
    });

    it('bindReplacementWaitsForInflightStartDrainBeforeRebinding', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      repository.profiles.set(OTHER_PROFILE_ID, buildProfile(OTHER_PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      const core = new FakeCoreProxyPort();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        new FakeSelectionRepository(),
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );
      await handler.bindExistingSession(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));

      const startEntered = new Deferred<boolean>();
      const releaseStart = new Deferred<CoreProxyDelaySnapshot>();
      core.startDelayHook = async (): Promise<CoreProxyDelaySnapshot> => {
        startEntered.resolve(true);
        return await releaseStart.promise;
      };

      const oldStartPromise = bus.submitStartDelayTest(
        createVpnProxyStartDelayTestCommand(buildIdentity(), 33, GROUP_ALPHA)
      );
      await startEntered.promise;

      let replacementFinished: boolean = false;
      const replacementPromise = handler.bindExistingSession(
        createVpnStartRequest(OTHER_PROFILE_ID, REVISION_ID_NEXT, OTHER_SESSION_ID)
      ).then(() => {
        replacementFinished = true;
      });
      await Promise.resolve();
      expect(replacementFinished).assertFalse();
      expect(core.cancelDelayCalls.length).assertEqual(0);

      releaseStart.resolve(buildDelaySnapshot(33, GROUP_ALPHA, 'delay-job-1', 'RUNNING'));

      const oldStartResult = await oldStartPromise;
      expectRejected(oldStartResult, 'VPN_SESSION_CHANGED', TIMESTAMP_5);
      await replacementPromise;

      expect(replacementFinished).assertTrue();
      expect(core.cancelDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls[0].jobId).assertEqual('delay-job-1');

      expectRejected(
        await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 34, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_5
      );

      const rebound = await bus.submitQueryGroup(
        createVpnProxyQueryGroupCommand(
          createProxyRuntimeIdentity(OTHER_PROFILE_ID, REVISION_ID_NEXT, REVISION_HASH_NEXT, OTHER_SESSION_ID),
          35,
          GROUP_ALPHA
        )
      );
      expect(rebound.kind).assertEqual('SNAPSHOT');
    });

    it('invalidatesSynchronouslyDeactivatesAfterInflightDrainAndSupportsRecoveryReactivation', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );
      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      const pending = new Deferred<CoreProxyGroupResult>();
      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return await pending.promise;
      };

      const inFlight = bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 12, GROUP_ALPHA));
      handler.invalidate(SESSION_ID);
      const afterInvalidate = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 13, GROUP_ALPHA));
      expectRejected(afterInvalidate, 'VPN_SESSION_CHANGED', TIMESTAMP_5);

      let deactivated: boolean = false;
      const deactivatePromise = handler.deactivate(SESSION_ID).then(() => {
        deactivated = true;
      });
      expect(deactivated).assertFalse();

      pending.resolve(createCoreGroupResult({
        profileHash: PROFILE_HASH,
        revisionHash: REVISION_HASH,
        sessionHash: SESSION_HASH,
        generation: 12
      }, buildGroupSnapshot(GROUP_ALPHA, NODE_ALPHA)));
      const completed = await inFlight;
      expectRejected(completed, 'VPN_SESSION_CHANGED', TIMESTAMP_5);
      await deactivatePromise;
      expect(deactivated).assertTrue();

      expectRejected(
        await handler.queryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 14, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      const recovered = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 15, GROUP_ALPHA));
      expect(recovered.kind).assertEqual('SNAPSHOT');
    });

    it('treatsRepeatedSameSessionDeactivateAsIdempotentWithoutExtraBusSideEffects', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const bus = new CountingDeactivateBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      await handler.deactivate(SESSION_ID);
      await handler.deactivate(SESSION_ID);

      expect(bus.deactivateCalls.join(',')).assertEqual(`${SESSION_ID}`);
      expectRejected(
        await handler.queryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 16, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );

      await handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      const rebound = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 17, GROUP_ALPHA));
      expect(rebound.kind).assertEqual('SNAPSHOT');
    });

    it('deactivatesBoundMirrorSessionsIdempotentlyAndAllowsCleanRebind', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      const core = new FakeCoreProxyPort();
      const selections = new FakeSelectionRepository();
      const bus = new CountingDeactivateBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        new FakeHasher(),
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2]),
        bus
      );

      await handler.bindExistingSession(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      await handler.startDelayTest(createVpnProxyStartDelayTestCommand(buildIdentity(), 18, GROUP_ALPHA));
      await handler.deactivate(SESSION_ID);
      await handler.deactivate(SESSION_ID);

      expect(bus.deactivateCalls.join(',')).assertEqual(`${SESSION_ID}`);
      expect(core.cancelDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls[0].jobId).assertEqual('delay-job-1');
      expectRejected(
        await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 19, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_5
      );
      expectRejected(
        await handler.queryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 20, GROUP_ALPHA)),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_1
      );

      await handler.bindExistingSession(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      const rebound = await bus.submitQueryGroup(createVpnProxyQueryGroupCommand(buildIdentity(), 21, GROUP_ALPHA));
      expect(rebound.kind).assertEqual('SNAPSHOT');
    });

    it('serializesConcurrentLifecycleTransitionsSoOnlyLatestSessionRemainsBound', 0, async () => {
      const repository = new FakeProfileRepository();
      repository.profiles.set(PROFILE_ID, buildProfile());
      repository.profiles.set(OTHER_PROFILE_ID, buildProfile(OTHER_PROFILE_ID, 'VALID', REVISION_ID_NEXT, REVISION_HASH_NEXT));
      const selections = new FakeSelectionRepository();
      selections.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      const hasher = new FakeHasher();
      const core = new FakeCoreProxyPort();
      const pendingReplay = new Deferred<CoreProxyGroupResult>();
      core.queryGroupHook = async (call: QueryGroupCall, callIndex: number): Promise<CoreProxyGroupResult> => {
        if (callIndex === 1) {
          return await pendingReplay.promise;
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_5);
      const handler = buildHandler(
        repository,
        selections,
        hasher,
        core,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]),
        bus
      );

      const firstActivate = handler.activate(createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID));
      const secondActivate = handler.activate(createVpnStartRequest(OTHER_PROFILE_ID, REVISION_ID_NEXT, OTHER_SESSION_ID));

      pendingReplay.resolve(createCoreGroupResult({
        profileHash: PROFILE_HASH,
        revisionHash: REVISION_HASH,
        sessionHash: SESSION_HASH,
        generation: 1
      }, buildGroupSnapshot(GROUP_ALPHA, NODE_ALPHA)));
      await firstActivate;
      await secondActivate;

      expectRejected(
        await bus.submitQueryGroups(
          createVpnProxyQueryGroupsCommand(
            createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID),
            21,
            true
          )
        ),
        'VPN_SESSION_CHANGED',
        TIMESTAMP_5
      );

      const latestResult = await bus.submitQueryGroups(
        createVpnProxyQueryGroupsCommand(
          createProxyRuntimeIdentity(OTHER_PROFILE_ID, REVISION_ID_NEXT, REVISION_HASH_NEXT, OTHER_SESSION_ID),
          22,
          true
        )
      );
      expect(latestResult.kind).assertEqual('SNAPSHOT');
      expect(core.queryGroupsCalls[0].context.sessionHash).assertEqual(SESSION_HASH_NEXT);
    });
  });
}
