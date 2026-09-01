import { describe, expect, it } from '@ohos/hypium';
import {
  ActiveProfileProxyResolver,
  CORE_PROXY_DELAY_SCHEMA_VERSION,
  ProxyService,
  VpnProxyCommandBus,
  createActiveProxyProfile,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  createProfile,
  createProfileRevision,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  createVpnRuntimeSnapshot,
  type ActiveProfileProxyPort,
  type ActiveProxyProfile,
  type Clock,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupRef,
  type CoreProxyGroupResult,
  type CoreProxyGroupSnapshot,
  type CoreProxyPort,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied,
  type Profile,
  type ProfileContentStore,
  type ProfileRepository,
  type ProfileRevision,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyDelayResult,
  type ProxyIdentityHasher,
  type ProxyReconcileResult,
  type ProxySelectionPair,
  type ProxySelectionRecord,
  type ProxySelectionRepository,
  type ProxySelectionResult,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand,
  type VpnStoppedProxyLease,
  type VpnRuntimeSnapshot,
  type VpnRuntimeSnapshotPort
} from '../../Index';
import { createDeferred, expectThrowsMessage, type Deferred } from './fakes/ProfileFakes';

const PROFILE_ID: string = 'profile-alpha';
const PROFILE_ID_BETA: string = 'profile-beta';
const SESSION_ID: string = 'session-1';
const OTHER_SESSION_ID: string = 'session-2';
const GROUP_ALPHA: string = 'Group Alpha';
const GROUP_BETA: string = 'Group Beta';
const NODE_ALPHA: string = 'Node Alpha';
const NODE_BETA: string = 'Node Beta';
const NESTED_GROUP: string = 'Nested Group';
const REVISION_ID: string = '2026-08-22T09:00:00.000Z';
const REVISION_ID_NEXT: string = '2026-08-22T09:05:00.000Z';
const REVISION_HASH: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const REVISION_HASH_NEXT: string = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const PROFILE_HASH_BETA: string = '2222222222222222222222222222222222222222222222222222222222222222';
const TIMESTAMP_1: string = '2026-08-22T10:00:00.000Z';
const TIMESTAMP_2: string = '2026-08-22T10:00:01.000Z';
const TIMESTAMP_3: string = '2026-08-22T10:00:02.000Z';
const TIMESTAMP_4: string = '2026-08-22T10:00:03.000Z';

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

interface ReconcileCall {
  profileId: string;
  newRevisionId: string;
  validPairs: ProxySelectionPair[];
}

interface LeaseOperationState {
  acquiredAt: string;
  releasedAt: string;
}

interface StoppedServiceDependencies {
  activeProfile?: FakeActiveProfilePort;
  core?: FakeCoreProxyPort;
  repository?: FakeSelectionRepository;
  hasher?: FakeHasher;
  runtime?: FakeVpnRuntimeSnapshotPort;
  bus?: VpnProxyCommandBus;
  clock?: FakeClock;
  initialGeneration?: number;
}

interface RunningServiceDependencies {
  activeProfile?: FakeActiveProfilePort;
  core?: FakeCoreProxyPort;
  repository?: FakeSelectionRepository;
  runtime?: FakeVpnRuntimeSnapshotPort;
  clock?: FakeClock;
  initialGeneration?: number;
  sessionGeneration?: number;
}

class FakeProfileRepository implements ProfileRepository {
  activeIdValue?: string = PROFILE_ID;
  profiles: Map<string, Profile> = new Map();
  getActiveIdError?: Error;
  getError?: Error;

  async list(): Promise<Profile[]> {
    return [];
  }

  async get(id: string): Promise<Profile | undefined> {
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const profile: Profile | undefined = this.profiles.get(id);
    return profile === undefined ? undefined : createProfile({
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

  async save(_profile: Profile): Promise<void> {
    throw new Error('save should stay unused in proxy service tests');
  }

  async deleteAndClearActive(_id: string): Promise<void> {
    throw new Error('delete should stay unused in proxy service tests');
  }

  async getActiveId(): Promise<string | undefined> {
    if (this.getActiveIdError !== undefined) {
      throw this.getActiveIdError;
    }
    return this.activeIdValue;
  }

  async setActiveId(_id: string | undefined): Promise<void> {
    throw new Error('setActiveId should stay unused in proxy service tests');
  }
}

class FakeProfileContentStore implements ProfileContentStore {
  resolvePathValue: string = '/sandbox/profiles/current.yaml';
  resolvePathError?: Error;

  async retain(_profileId: string, _staged: never, _kind: never): Promise<ProfileRevision> {
    throw new Error('retain should stay unused in proxy service tests');
  }

  async discard(_staged: never): Promise<void> {
    throw new Error('discard should stay unused in proxy service tests');
  }

  async removeRevision(_revision: ProfileRevision): Promise<void> {
    throw new Error('removeRevision should stay unused in proxy service tests');
  }

  async removeProfile(_profileId: string): Promise<void> {
    throw new Error('removeProfile should stay unused in proxy service tests');
  }

  async reconcile(_referenced: ProfileRevision[]): Promise<void> {
    throw new Error('reconcile should stay unused in proxy service tests');
  }

  resolveCorePath(_revision: ProfileRevision): string {
    if (this.resolvePathError !== undefined) {
      throw this.resolvePathError;
    }
    return this.resolvePathValue;
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

class FakeActiveProfilePort implements ActiveProfileProxyPort {
  value?: ActiveProxyProfile = createActiveProxyProfile(PROFILE_ID, REVISION_ID, REVISION_HASH, '/sandbox/profiles/current.yaml');
  error?: Error;

  async resolve(): Promise<ActiveProxyProfile | undefined> {
    if (this.error !== undefined) {
      throw this.error;
    }
    return this.value === undefined
      ? undefined
      : createActiveProxyProfile(
        this.value.profileId,
        this.value.revisionId,
        this.value.revisionHash,
        this.value.configPath
      );
  }
}

class FakeCoreProxyPort implements CoreProxyPort {
  readonly operations: string[] = [];
  readonly loadCalls: string[] = [];
  readonly queryGroupsCalls: QueryGroupsCall[] = [];
  readonly queryGroupCalls: QueryGroupCall[] = [];
  readonly selectCalls: SelectCall[] = [];
  readonly startDelayCalls: StartDelayCall[] = [];
  readonly readDelayCalls: ReadDelayCall[] = [];
  readonly cancelDelayCalls: CancelDelayCall[] = [];
  loadHook?: (path: string, callIndex: number) => Promise<void>;
  queryGroupsHook?: (call: QueryGroupsCall, callIndex: number) => Promise<CoreProxyGroupList>;
  queryGroupHook?: (call: QueryGroupCall, callIndex: number) => Promise<CoreProxyGroupResult>;
  selectHook?: (call: SelectCall, callIndex: number) => Promise<CoreProxySelectionApplied>;
  startDelayHook?: (call: StartDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;
  readDelayHook?: (call: ReadDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;
  cancelDelayHook?: (call: CancelDelayCall, callIndex: number) => Promise<CoreProxyDelaySnapshot>;

  async loadConfiguration(path: string): Promise<void> {
    this.operations.push(`load:${path}`);
    this.loadCalls.push(path);
    if (this.loadHook !== undefined) {
      await this.loadHook(path, this.loadCalls.length);
    }
  }

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    const call: QueryGroupsCall = {
      context: cloneQueryContext(context),
      selectableOnly
    };
    this.operations.push(`list:${call.context.generation}`);
    this.queryGroupsCalls.push(call);
    if (this.queryGroupsHook !== undefined) {
      return await this.queryGroupsHook(call, this.queryGroupsCalls.length);
    }
    return createCoreGroupList(call.context, buildGroupRefs([GROUP_ALPHA]));
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    const call: QueryGroupCall = {
      context: cloneQueryContext(context),
      groupName
    };
    this.operations.push(`group:${groupName}:${call.context.generation}`);
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
      context: cloneQueryContext(context),
      groupName,
      memberName
    };
    this.selectCalls.push(call);
    if (this.selectHook !== undefined) {
      return await this.selectHook(call, this.selectCalls.length);
    }
    return createCoreSelectionApplied(call.context, groupName, memberName);
  }

  async startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot> {
    const call: StartDelayCall = {
      context: cloneQueryContext(context),
      groupName
    };
    this.operations.push(`delay-start:${groupName}:${call.context.generation}`);
    this.startDelayCalls.push(call);
    if (this.startDelayHook !== undefined) {
      return await this.startDelayHook(call, this.startDelayCalls.length);
    }
    return buildCoreDelaySnapshot(call.context, groupName, 'delay-job-1', 'RUNNING');
  }

  async readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    const call: ReadDelayCall = { jobId };
    this.operations.push(`delay-read:${jobId}`);
    this.readDelayCalls.push(call);
    if (this.readDelayHook !== undefined) {
      return await this.readDelayHook(call, this.readDelayCalls.length);
    }
    return buildCoreDelaySnapshot(buildStoppedDelayContext(), GROUP_ALPHA, jobId, 'COMPLETED');
  }

  async cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    const call: CancelDelayCall = { jobId };
    this.operations.push(`delay-cancel:${jobId}`);
    this.cancelDelayCalls.push(call);
    if (this.cancelDelayHook !== undefined) {
      return await this.cancelDelayHook(call, this.cancelDelayCalls.length);
    }
    return buildCoreDelaySnapshot(buildStoppedDelayContext(), GROUP_ALPHA, jobId, 'CANCELLED');
  }
}

class FakeSelectionRepository implements ProxySelectionRepository {
  records: ProxySelectionRecord[] = [];
  readonly upsertCalls: ProxySelectionRecord[] = [];
  readonly reconcileCalls: ReconcileCall[] = [];
  upsertError?: Error;
  listError?: Error;
  reconcileError?: Error;
  upsertHook?: (record: ProxySelectionRecord) => Promise<void>;
  reconcileHook?: (
    profileId: string,
    newRevisionId: string,
    validPairs: ProxySelectionPair[]
  ) => Promise<void>;

  async listByProfile(profileId: string): Promise<ProxySelectionRecord[]> {
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
    for (let index: number = 0; index < this.records.length; index += 1) {
      if (this.records[index].profileId === profileId && this.records[index].groupName === groupName) {
        return cloneRecord(this.records[index]);
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

  async delete(_profileId: string, _groupName: string): Promise<void> {
    throw new Error('delete should stay unused in proxy service tests');
  }

  async deleteProfile(_profileId: string): Promise<void> {
    throw new Error('deleteProfile should stay unused in proxy service tests');
  }

  async reconcileProfile(profileId: string, newRevisionId: string, validPairs: ProxySelectionPair[]): Promise<void> {
    if (this.reconcileError !== undefined) {
      throw this.reconcileError;
    }
    if (this.reconcileHook !== undefined) {
      await this.reconcileHook(profileId, newRevisionId, cloneSelectionPairs(validPairs));
      return;
    }
    const clonedPairs: ProxySelectionPair[] = [];
    for (let index: number = 0; index < validPairs.length; index += 1) {
      clonedPairs.push({
        groupName: validPairs[index].groupName,
        selectedNodeName: validPairs[index].selectedNodeName
      });
    }
    this.reconcileCalls.push({
      profileId,
      newRevisionId,
      validPairs: clonedPairs
    });
  }
}

class FakeHasher implements ProxyIdentityHasher {
  values: Map<string, string> = new Map([
    [PROFILE_ID, PROFILE_HASH],
    [PROFILE_ID_BETA, PROFILE_HASH_BETA]
  ]);
  error?: Error;
  readonly inputs: string[] = [];

  async sha256(value: string): Promise<string> {
    if (this.error !== undefined) {
      throw this.error;
    }
    this.inputs.push(value);
    const mapped: string | undefined = this.values.get(value);
    if (mapped === undefined) {
      throw new Error(`missing hash for ${value}`);
    }
    return mapped;
  }
}

class FakeVpnRuntimeSnapshotPort implements VpnRuntimeSnapshotPort {
  value: VpnRuntimeSnapshot = buildVpnSnapshot('STOPPED');
  leaseDisabled: boolean = false;
  leaseSnapshotOverride?: VpnRuntimeSnapshot;
  readonly leaseStates: LeaseOperationState[] = [];
  acquireCalls: number = 0;
  releaseCalls: number = 0;
  blockedBeginCount: number = 0;
  successfulBeginCount: number = 0;
  activeLeaseCount: number = 0;

  snapshot(): VpnRuntimeSnapshot {
    return cloneVpnSnapshot(this.value);
  }

  acquireStoppedProxyLease(): VpnStoppedProxyLease | undefined {
    this.acquireCalls += 1;
    if (this.leaseDisabled) {
      return undefined;
    }
    this.activeLeaseCount += 1;
    const state: LeaseOperationState = {
      acquiredAt: `${this.acquireCalls}`,
      releasedAt: ''
    };
    this.leaseStates.push(state);
    return new FakeVpnStoppedProxyLease(this, cloneVpnSnapshot(this.leaseSnapshotOverride ?? this.value), state);
  }

  beginPending(nextSnapshot: VpnRuntimeSnapshot): boolean {
    if (this.activeLeaseCount > 0) {
      this.blockedBeginCount += 1;
      return false;
    }
    this.successfulBeginCount += 1;
    this.value = cloneVpnSnapshot(nextSnapshot);
    return true;
  }

  completeRelease(state: LeaseOperationState): void {
    if (state.releasedAt.length > 0) {
      return;
    }
    state.releasedAt = `${this.releaseCalls + 1}`;
    this.releaseCalls += 1;
    this.activeLeaseCount -= 1;
  }
}

class FakeVpnStoppedProxyLease implements VpnStoppedProxyLease {
  private readonly runtime: FakeVpnRuntimeSnapshotPort;
  private readonly snapshotValue: VpnRuntimeSnapshot;
  private readonly state: LeaseOperationState;
  private released: boolean = false;

  constructor(runtime: FakeVpnRuntimeSnapshotPort, snapshotValue: VpnRuntimeSnapshot, state: LeaseOperationState) {
    this.runtime = runtime;
    this.snapshotValue = snapshotValue;
    this.state = state;
  }

  snapshot(): VpnRuntimeSnapshot {
    return cloneVpnSnapshot(this.snapshotValue);
  }

  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.runtime.completeRelease(this.state);
  }
}

class ScriptedHandler implements VpnProxyCommandHandler {
  readonly queryGroupsInputs: VpnProxyQueryGroupsCommand[] = [];
  readonly queryGroupInputs: VpnProxyQueryGroupCommand[] = [];
  readonly selectInputs: VpnProxySelectCommand[] = [];
  readonly startDelayInputs: VpnProxyStartDelayTestCommand[] = [];
  readonly readDelayInputs: VpnProxyReadDelayTestCommand[] = [];
  readonly cancelDelayInputs: VpnProxyCancelDelayTestCommand[] = [];
  queryGroupsHook?: (command: VpnProxyQueryGroupsCommand, callIndex: number) => Promise<ProxyGroupListQueryResult>;
  queryGroupHook?: (command: VpnProxyQueryGroupCommand, callIndex: number) => Promise<ProxyGroupQueryResult>;
  selectHook?: (command: VpnProxySelectCommand, callIndex: number) => Promise<ProxySelectionResult>;
  startDelayHook?: (command: VpnProxyStartDelayTestCommand, callIndex: number) => Promise<ProxyDelayResult>;
  readDelayHook?: (command: VpnProxyReadDelayTestCommand, callIndex: number) => Promise<ProxyDelayResult>;
  cancelDelayHook?: (command: VpnProxyCancelDelayTestCommand, callIndex: number) => Promise<ProxyDelayResult>;

  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    const clone: VpnProxyQueryGroupsCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      selectableOnly: command.selectableOnly
    };
    this.queryGroupsInputs.push(clone);
    if (this.queryGroupsHook !== undefined) {
      return await this.queryGroupsHook(clone, this.queryGroupsInputs.length);
    }
    return {
      kind: 'SNAPSHOT',
      identity: clone.identity,
      generation: clone.generation,
      groups: buildGroupRefs([GROUP_ALPHA])
    };
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    const clone: VpnProxyQueryGroupCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      groupName: command.groupName,
      groupPath: command.groupPath?.slice()
    };
    this.queryGroupInputs.push(clone);
    if (this.queryGroupHook !== undefined) {
      return await this.queryGroupHook(clone, this.queryGroupInputs.length);
    }
    return createProxyGroupQuerySnapshot(
      createProxyGroupSnapshot(
        clone.identity,
        clone.generation,
        buildGroupSnapshot(clone.groupName, NODE_ALPHA)
      )
    );
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    const clone: VpnProxySelectCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      groupName: command.groupName,
      memberName: command.memberName,
      groupPath: command.groupPath?.slice()
    };
    this.selectInputs.push(clone);
    if (this.selectHook !== undefined) {
      return await this.selectHook(clone, this.selectInputs.length);
    }
    return createProxySelectionAppliedNowResult(
      createProxyGroupSnapshot(
        clone.identity,
        clone.generation,
        buildGroupSnapshot(clone.groupName, clone.memberName)
      ),
      createProxySelectionRecord(clone.identity.profileId, clone.groupName, clone.memberName, clone.identity.revisionId, TIMESTAMP_2),
      TIMESTAMP_2
    );
  }

  async startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    const clone: VpnProxyStartDelayTestCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      groupName: command.groupName,
      groupPath: command.groupPath?.slice()
    };
    this.startDelayInputs.push(clone);
    if (this.startDelayHook !== undefined) {
      return await this.startDelayHook(clone, this.startDelayInputs.length);
    }
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          clone.identity,
          clone.generation,
          clone.groupName,
          buildRunningDelaySnapshot(clone, clone.groupName, 'delay-job-1', 'RUNNING')
        );
  }

  async readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    const clone: VpnProxyReadDelayTestCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      jobId: command.jobId
    };
    this.readDelayInputs.push(clone);
    if (this.readDelayHook !== undefined) {
      return await this.readDelayHook(clone, this.readDelayInputs.length);
    }
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          clone.identity,
          clone.generation,
          GROUP_ALPHA,
          buildRunningDelaySnapshot(clone, GROUP_ALPHA, clone.jobId, 'COMPLETED')
        );
  }

  async cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    const clone: VpnProxyCancelDelayTestCommand = {
      identity: createProxyRuntimeIdentity(
        command.identity.profileId,
        command.identity.revisionId,
        command.identity.revisionHash,
        command.identity.sessionId
      ),
      generation: command.generation,
      jobId: command.jobId
    };
    this.cancelDelayInputs.push(clone);
    if (this.cancelDelayHook !== undefined) {
      return await this.cancelDelayHook(clone, this.cancelDelayInputs.length);
    }
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          clone.identity,
          clone.generation,
          GROUP_ALPHA,
          buildRunningDelaySnapshot(clone, GROUP_ALPHA, clone.jobId, 'CANCELLED')
        );
  }
}

function buildRevision(validatedAt: string = REVISION_ID, digest: string = REVISION_HASH): ProfileRevision {
  return createProfileRevision('profiles/current.yaml', digest, 128, validatedAt);
}

function buildProfile(
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  currentRevision: ProfileRevision | null = buildRevision(),
  id: string = PROFILE_ID
): Profile {
  return createProfile({
    id,
    name: `Profile ${id}`,
    sourceKind: 'LOCAL_FILE',
    sourceDisplay: `${id}.yaml`,
    currentRevision,
    failedCandidate: null,
    availability,
    lastError: null,
    createdAt: TIMESTAMP_1,
    updatedAt: TIMESTAMP_2,
    lastSuccessfulUpdateAt: currentRevision === null ? null : TIMESTAMP_2
  });
}

function buildGroupRefs(names: string[]): CoreProxyGroupRef[] {
  const result: CoreProxyGroupRef[] = [];
  for (let index: number = 0; index < names.length; index += 1) {
    result.push({
      name: names[index],
      type: 'Selector'
    });
  }
  return result;
}

function buildGroupSnapshot(groupName: string, selectedName: string, nested: boolean = false): CoreProxyGroupSnapshot {
  const alternateName: string = selectedName === NODE_ALPHA ? NODE_BETA : NODE_ALPHA;
  return {
    name: groupName,
    type: 'Selector',
    selectedName,
    nodes: [
      {
        name: selectedName,
        type: nested ? 'Selector' : 'Shadowsocks',
        isGroup: nested,
        selected: true
      },
      {
        name: alternateName,
        type: 'Shadowsocks',
        isGroup: false,
        selected: false
      },
      {
        name: NESTED_GROUP,
        type: 'Selector',
        isGroup: true,
        selected: false
      }
    ]
  };
}

function buildMissingMemberGroupSnapshot(groupName: string, selectedName: string): CoreProxyGroupSnapshot {
  return {
    name: groupName,
    type: 'Selector',
    selectedName,
    nodes: [
      {
        name: selectedName,
        type: 'Shadowsocks',
        isGroup: false,
        selected: true
      },
      {
        name: NESTED_GROUP,
        type: 'Selector',
        isGroup: true,
        selected: false
      }
    ]
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
  memberName: string
): CoreProxySelectionApplied {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    schemaVersion: '1.0.0',
    kind: 'SELECTION_APPLIED',
    previousName: NODE_ALPHA,
    group: buildGroupSnapshot(groupName, memberName)
  };
}

function buildStoppedDelayContext(
  generation: number = 1,
  profileHash: string = PROFILE_HASH,
  revisionHash: string = REVISION_HASH,
  sessionHash: string | null = null
): CoreProxyQueryContext {
  return {
    profileHash,
    revisionHash,
    sessionHash,
    generation
  };
}

function buildCoreDelaySnapshot(
  context: CoreProxyQueryContext,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): CoreProxyDelaySnapshot {
  const secondaryState: 'TESTING' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' = state === 'RUNNING'
    ? 'TESTING'
    : state === 'COMPLETED'
      ? 'TIMEOUT'
      : state === 'FAILED'
        ? 'FAILED'
        : 'CANCELLED';
  return {
    schemaVersion: CORE_PROXY_DELAY_SCHEMA_VERSION,
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation,
    groupName,
    jobId,
    state,
    totalCount: 2,
    testableCount: 2,
    completedCount: state === 'RUNNING' ? 1 : 2,
    availableCount: 1,
    timeoutCount: secondaryState === 'TIMEOUT' ? 1 : 0,
    failedCount: secondaryState === 'FAILED' ? 1 : 0,
    cancelledCount: secondaryState === 'CANCELLED' ? 1 : 0,
    unsupportedCount: 0,
    fastestNodeIndex: 0,
    nodes: [
      {
        index: 0,
        name: NODE_ALPHA,
        type: 'Shadowsocks',
        state: 'AVAILABLE',
        delayMs: 91,
        source: 'PROVIDER',
        fastest: true
      },
      {
        index: 1,
        name: NODE_BETA,
        type: 'Shadowsocks',
        state: secondaryState,
        delayMs: null,
        source: null,
        fastest: false
      }
    ]
  };
}

function buildRunningDelaySnapshot(
  command: VpnProxyStartDelayTestCommand | VpnProxyReadDelayTestCommand | VpnProxyCancelDelayTestCommand,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED'
): CoreProxyDelaySnapshot {
  return buildCoreDelaySnapshot(
    buildStoppedDelayContext(command.generation, PROFILE_HASH, command.identity.revisionHash, 'running-session-hash'),
    groupName,
    jobId,
    state
  );
}

function buildStoppedService(
  dependencies?: StoppedServiceDependencies
): ProxyService {
  return new ProxyService(
    dependencies?.activeProfile ?? new FakeActiveProfilePort(),
    dependencies?.core ?? new FakeCoreProxyPort(),
    dependencies?.repository ?? new FakeSelectionRepository(),
    dependencies?.hasher ?? new FakeHasher(),
    dependencies?.runtime ?? new FakeVpnRuntimeSnapshotPort(),
    dependencies?.bus ?? new VpnProxyCommandBus(() => TIMESTAMP_4),
    dependencies?.clock ?? new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
    dependencies?.initialGeneration ?? 0
  );
}

function buildRunningService(
  handler: ScriptedHandler,
  dependencies?: RunningServiceDependencies
): ProxyService {
  const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
  bus.bind(
    createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID),
    handler,
    dependencies?.sessionGeneration
  );
  const runtime = dependencies?.runtime ?? new FakeVpnRuntimeSnapshotPort();
  runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID);
  return new ProxyService(
    dependencies?.activeProfile ?? new FakeActiveProfilePort(),
    dependencies?.core ?? new FakeCoreProxyPort(),
    dependencies?.repository ?? new FakeSelectionRepository(),
    new FakeHasher(),
    runtime,
    bus,
    dependencies?.clock ?? new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
    dependencies?.initialGeneration ?? 0
  );
}

function buildVpnSnapshot(
  state: 'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR',
  profileId?: string,
  revisionId?: string,
  sessionId?: string
): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: profileId === undefined || revisionId === undefined || sessionId === undefined
      ? null
      : {
        profileId,
        versionId: revisionId,
        sessionId
      },
    activeHandle: sessionId === undefined
      ? null
      : {
        sessionId,
        attached: state === 'RUNNING'
      },
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function cloneVpnSnapshot(snapshot: VpnRuntimeSnapshot): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state: snapshot.state,
    activeRequest: snapshot.activeRequest,
    activeHandle: snapshot.activeHandle,
    captureConfig: snapshot.captureConfig,
    tunSnapshot: snapshot.tunSnapshot,
    notificationActive: snapshot.notificationActive,
    recoveryAttempt: snapshot.recoveryAttempt,
    scheduledRetryDelayMs: snapshot.scheduledRetryDelayMs,
    lastFailure: snapshot.lastFailure
  });
}

function cloneQueryContext(context: CoreProxyQueryContext): CoreProxyQueryContext {
  return {
    profileHash: context.profileHash,
    revisionHash: context.revisionHash,
    sessionHash: context.sessionHash,
    generation: context.generation
  };
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

function cloneSelectionPairs(pairs: ProxySelectionPair[]): ProxySelectionPair[] {
  const cloned: ProxySelectionPair[] = [];
  for (let index: number = 0; index < pairs.length; index += 1) {
    cloned.push({
      groupName: pairs[index].groupName,
      selectedNodeName: pairs[index].selectedNodeName
    });
  }
  return cloned;
}

function expectRejected(
  result: ProxyGroupListQueryResult | ProxyGroupQueryResult | ProxySelectionResult | ProxyReconcileResult | ProxyDelayResult,
  code: string,
  timestamp: string
): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind !== 'REJECTED') {
    throw new Error(`Expected rejected result but received ${result.kind}.`);
  }
  expect(result.error.code).assertEqual(code);
  expect(result.error.timestamp).assertEqual(timestamp);
}

function expectDelaySnapshot(
  result: ProxyDelayResult,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED',
  groupName: string = GROUP_ALPHA
): void {
  expect(result.kind).assertEqual('SNAPSHOT');
  if (result.kind !== 'SNAPSHOT') {
    throw new Error(`Expected delay snapshot but received ${result.kind}.`);
  }
  expect(result.jobId).assertEqual(jobId);
  expect(result.state).assertEqual(state);
  expect(result.groupName).assertEqual(groupName);
}

function expectNoSensitiveFragments(message: string, fragments: string[]): void {
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(message.includes(fragments[index])).assertFalse();
  }
}

export default function proxyServiceTestsuite() {
  describe('ActiveProfileProxyResolverTest', () => {
    it('returnsUndefinedForMissingInactiveInvalidOrRevisionlessProfiles', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const resolver = new ActiveProfileProxyResolver(repository, contentStore);

      repository.activeIdValue = undefined;
      expect(await resolver.resolve()).assertUndefined();

      repository.activeIdValue = PROFILE_ID;
      repository.profiles.set(PROFILE_ID, buildProfile('INVALID'));
      expect(await resolver.resolve()).assertUndefined();

      repository.profiles.set(PROFILE_ID, buildProfile('INVALID', null));
      expect(await resolver.resolve()).assertUndefined();

      repository.profiles.set(PROFILE_ID, buildProfile('UPDATE_FAILED_USING_VALID'));
      const active = await resolver.resolve();
      expect(active?.profileId).assertEqual(PROFILE_ID);
      expect(active?.revisionId).assertEqual(REVISION_ID);
      expect(active?.revisionHash).assertEqual(REVISION_HASH);
      expect(active?.configPath).assertEqual('/sandbox/profiles/current.yaml');
    });

    it('sanitizesRepositoryAndPathFailuresWithoutLeakingRawValues', 0, async () => {
      const repository = new FakeProfileRepository();
      const contentStore = new FakeProfileContentStore();
      const resolver = new ActiveProfileProxyResolver(repository, contentStore);
      const leakedId: string = 'profile-secret-id';
      const leakedPath: string = '/sandbox/private/secret.yaml';
      repository.activeIdValue = leakedId;
      repository.profiles.set(leakedId, buildProfile('VALID', buildRevision(), leakedId));

      repository.getActiveIdError = new Error(`active ${leakedId} failed`);
      let firstThrown: string = '';
      try {
        await resolver.resolve();
      } catch {
        firstThrown = 'Active proxy profile resolution failed.';
      }
      expect(firstThrown).assertEqual('Active proxy profile resolution failed.');

      repository.getActiveIdError = undefined;
      repository.getError = new Error(`profile ${leakedId} missing`);
      let secondThrown: string = '';
      try {
        await resolver.resolve();
      } catch {
        secondThrown = 'Active proxy profile resolution failed.';
      }
      expect(secondThrown).assertEqual('Active proxy profile resolution failed.');

      repository.getError = undefined;
      contentStore.resolvePathValue = leakedPath;
      contentStore.resolvePathError = new Error(`path ${leakedPath} denied`);
      let thrownMessage: string = '';
      try {
        await resolver.resolve();
      } catch {
        thrownMessage = 'Active proxy profile resolution failed.';
      }

      expect(thrownMessage).assertEqual('Active proxy profile resolution failed.');
      expectNoSensitiveFragments(thrownMessage, [leakedId, leakedPath, 'secret']);
    });
  });

  describe('ProxyServiceTest', () => {
    it('loadsStoppedConfigBeforeListAndGroupQueriesAndUsesExactHashedContexts', 0, async () => {
      const core = new FakeCoreProxyPort();
      const hasher = new FakeHasher();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const service = buildStoppedService({
        core,
        hasher,
        runtime,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3])
      });

      const groupsResult = await service.listGroups();
      const groupResult = await service.queryGroup(GROUP_ALPHA);

      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      if (groupsResult.kind === 'SNAPSHOT') {
        expect(groupsResult.identity.profileId).assertEqual(PROFILE_ID);
        expect(groupsResult.identity.revisionId).assertEqual(REVISION_ID);
        expect(groupsResult.identity.revisionHash).assertEqual(REVISION_HASH);
        expect(groupsResult.identity.sessionId).assertNull();
        expect(groupsResult.generation).assertEqual(1);
        expect(groupsResult.groups[0].name).assertEqual(GROUP_ALPHA);
      }
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      if (groupResult.kind === 'SNAPSHOT') {
        expect(groupResult.snapshot.identity.sessionId).assertNull();
        expect(groupResult.snapshot.generation).assertEqual(2);
        expect(groupResult.snapshot.group.name).assertEqual(GROUP_ALPHA);
      }

      expect(hasher.inputs.join(',')).assertEqual(`${PROFILE_ID},${PROFILE_ID}`);
      expect(core.operations.join('>')).assertEqual(
        'load:/sandbox/profiles/current.yaml>list:1>load:/sandbox/profiles/current.yaml>group:Group Alpha:2'
      );
      expect(core.queryGroupsCalls[0].selectableOnly).assertTrue();
      expect(core.queryGroupsCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.queryGroupsCalls[0].context.revisionHash).assertEqual(REVISION_HASH);
      expect(core.queryGroupsCalls[0].context.sessionHash).assertNull();
      expect(core.queryGroupsCalls[0].context.generation).assertEqual(1);
      expect(core.queryGroupCalls[0].context.profileHash).assertEqual(PROFILE_HASH);
      expect(core.queryGroupCalls[0].context.sessionHash).assertNull();
      expect(core.queryGroupCalls[0].context.generation).assertEqual(2);
    });

    it('keepsLatestStoppedGroupSnapshotPerExactGroupWhileListDoesNotInvalidateIt', 0, async () => {
      const core = new FakeCoreProxyPort();
      let queryGroupCount: number = 0;
      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        queryGroupCount += 1;
        if (queryGroupCount === 1) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_BETA));
      };
      const repository = new FakeSelectionRepository();
      const service = buildStoppedService({
        core,
        repository,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4])
      });

      const firstQuery = await service.queryGroup(GROUP_ALPHA);
      await service.listGroups();
      const saved = await service.select(GROUP_ALPHA, NODE_ALPHA, firstQuery.kind === 'SNAPSHOT' ? firstQuery.snapshot.generation : -1);
      const secondQuery = await service.queryGroup(GROUP_ALPHA);
      const stale = await service.select(GROUP_ALPHA, NODE_ALPHA, firstQuery.kind === 'SNAPSHOT' ? firstQuery.snapshot.generation : -1);

      expect(saved.kind).assertEqual('SAVED_FOR_NEXT_START');
      if (saved.kind === 'SAVED_FOR_NEXT_START') {
        expect(saved.record.selectedNodeName).assertEqual(NODE_ALPHA);
      }
      expect(secondQuery.kind).assertEqual('SNAPSHOT');
      if (secondQuery.kind === 'SNAPSHOT') {
        expect(secondQuery.snapshot.generation).assertEqual(4);
        expect(secondQuery.snapshot.group.selectedName).assertEqual(NODE_BETA);
      }
      expectRejected(stale, 'PROXY_SELECTION_STALE', TIMESTAMP_2);
      expect(core.selectCalls.length).assertEqual(0);
      expect(repository.upsertCalls.length).assertEqual(1);
      expect(core.operations.join('>')).assertEqual(
        'load:/sandbox/profiles/current.yaml>group:Group Alpha:1>' +
        'load:/sandbox/profiles/current.yaml>list:2>' +
        'load:/sandbox/profiles/current.yaml>group:Group Alpha:3>' +
        'load:/sandbox/profiles/current.yaml>group:Group Alpha:4'
      );
    });

    it('requeriesBeforeStoppedPersistenceAndNeverCallsNativeSelect', 0, async () => {
      const core = new FakeCoreProxyPort();
      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        const selected: string = call.context.generation === 1 ? NODE_ALPHA : NODE_BETA;
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, selected));
      };
      const repository = new FakeSelectionRepository();
      const service = buildStoppedService({
        core,
        repository,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2])
      });

      const snapshot = await service.queryGroup(GROUP_ALPHA);
      const result = await service.select(
        GROUP_ALPHA,
        NODE_BETA,
        snapshot.kind === 'SNAPSHOT' ? snapshot.snapshot.generation : -1
      );

      expect(result.kind).assertEqual('SAVED_FOR_NEXT_START');
      if (result.kind !== 'SAVED_FOR_NEXT_START') {
        throw new Error(`Expected saved result but received ${result.kind}.`);
      }
      expect(result.savedAt).assertEqual(TIMESTAMP_1);
      expect(result.record.updatedAt).assertEqual(TIMESTAMP_1);
      expect(result.record.revisionId).assertEqual(REVISION_ID);
      expect(result.record.groupName).assertEqual(GROUP_ALPHA);
      expect(result.record.selectedNodeName).assertEqual(NODE_BETA);
      expect(core.selectCalls.length).assertEqual(0);
      expect(repository.upsertCalls.length).assertEqual(1);
      expect(core.queryGroupCalls.length).assertEqual(2);
      expect(core.queryGroupCalls[1].context.generation).assertEqual(2);
    });

    it('rejectsStoppedSelectionsForStaleMissingOrNestedMembers', 0, async () => {
      const core = new FakeCoreProxyPort();
      const service = buildStoppedService({
        core,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3])
      });

      const initial = await service.queryGroup(GROUP_ALPHA);
      const initialGeneration: number = initial.kind === 'SNAPSHOT' ? initial.snapshot.generation : -1;
      const stale = await service.select(GROUP_ALPHA, NODE_ALPHA, 99);

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA, true));
      };
      const nested = await service.select(GROUP_ALPHA, NODE_ALPHA, initialGeneration);

      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        return createCoreGroupResult(call.context, buildMissingMemberGroupSnapshot(call.groupName, NODE_BETA));
      };
      const missing = await service.select(GROUP_ALPHA, NODE_ALPHA, initialGeneration);

      expectRejected(stale, 'PROXY_SELECTION_STALE', TIMESTAMP_1);
      expectRejected(nested, 'PROXY_SELECTION_STALE', TIMESTAMP_2);
      expectRejected(missing, 'PROXY_SELECTION_STALE', TIMESTAMP_3);
    });

    it('routesRunningQueriesAndSelectionOnlyThroughTheBusWithExactRawIdentity', 0, async () => {
      const handler = new ScriptedHandler();
      handler.readDelayHook = async (command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> => {
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          command.identity,
          command.generation,
          GROUP_ALPHA,
          buildRunningDelaySnapshot(command, GROUP_ALPHA, command.jobId, 'RUNNING')
        );
      };
      handler.cancelDelayHook = async (command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> => {
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          command.identity,
          command.generation,
          GROUP_ALPHA,
          buildRunningDelaySnapshot(command, GROUP_ALPHA, command.jobId, 'CANCELLED')
        );
      };
      const core = new FakeCoreProxyPort();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const service = buildRunningService(handler, {
        core,
        runtime,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4])
      });

      const groupsResult = await service.listGroups();
      const queryResult = await service.queryGroup(GROUP_ALPHA);
      const selectionResult = await service.select(
        GROUP_ALPHA,
        NODE_ALPHA,
        queryResult.kind === 'SNAPSHOT' ? queryResult.snapshot.generation : -1
      );
      const started = await service.startDelayTest(
        GROUP_ALPHA,
        selectionResult.kind === 'APPLIED_NOW' ? selectionResult.snapshot.generation : -1
      );
      const jobId: string = started.kind === 'SNAPSHOT' ? started.jobId : '';
      const read = await service.readDelayTest(jobId);
      const cancelled = await service.cancelDelayTest(jobId);

      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(queryResult.kind).assertEqual('SNAPSHOT');
      expect(selectionResult.kind).assertEqual('APPLIED_NOW');
      expect(started.kind).assertEqual('SNAPSHOT');
      expect(read.kind).assertEqual('SNAPSHOT');
      expect(cancelled.kind).assertEqual('SNAPSHOT');
      expect(runtime.acquireCalls).assertEqual(0);
      expect(core.loadCalls.length).assertEqual(0);
      expect(core.queryGroupsCalls.length).assertEqual(0);
      expect(core.queryGroupCalls.length).assertEqual(0);
      expect(handler.queryGroupsInputs.length).assertEqual(1);
      expect(handler.queryGroupInputs.length).assertEqual(2);
      expect(handler.selectInputs.length).assertEqual(1);
      expect(handler.startDelayInputs.length).assertEqual(1);
      expect(handler.readDelayInputs.length).assertEqual(1);
      expect(handler.cancelDelayInputs.length).assertEqual(1);
      expect(handler.queryGroupsInputs[0].identity.profileId).assertEqual(PROFILE_ID);
      expect(handler.queryGroupsInputs[0].identity.revisionId).assertEqual(REVISION_ID);
      expect(handler.queryGroupsInputs[0].identity.revisionHash).assertEqual(REVISION_HASH);
      expect(handler.queryGroupsInputs[0].identity.sessionId).assertEqual(SESSION_ID);
      expect(handler.queryGroupsInputs[0].generation > 0).assertTrue();
      expect(handler.queryGroupsInputs[0].generation).assertEqual(1);
      expect(handler.queryGroupInputs[0].generation).assertEqual(1);
      expect(handler.queryGroupInputs[1].generation).assertEqual(1);
      expect(handler.selectInputs[0].generation).assertEqual(1);
      expect(handler.startDelayInputs[0].generation).assertEqual(1);
      expect(handler.readDelayInputs[0].generation).assertEqual(1);
      expect(handler.cancelDelayInputs[0].generation).assertEqual(1);
      expect(handler.selectInputs[0].groupName).assertEqual(GROUP_ALPHA);
      expect(handler.selectInputs[0].memberName).assertEqual(NODE_ALPHA);
    });

    it('usesTheBoundRpcSessionGenerationInsteadOfTheLocalGenerationHistory', 0, async () => {
      const handler = new ScriptedHandler();
      const service = buildRunningService(handler, {
        initialGeneration: 19,
        sessionGeneration: 7
      });

      const groupsResult = await service.listGroups();
      const groupResult = await service.queryGroup(GROUP_ALPHA);

      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      expect(handler.queryGroupsInputs[0].generation).assertEqual(7);
      expect(handler.queryGroupInputs[0].generation).assertEqual(7);
    });

    it('advancesGenerationOnlyWhenTheRunningIdentityActuallyChanges', 0, async () => {
      const firstHandler = new ScriptedHandler();
      const secondHandler = new ScriptedHandler();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID);
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID), firstHandler);
      const service = new ProxyService(
        new FakeActiveProfilePort(),
        new FakeCoreProxyPort(),
        new FakeSelectionRepository(),
        new FakeHasher(),
        runtime,
        bus,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        0
      );

      const firstList = await service.listGroups();
      const firstQuery = await service.queryGroup(GROUP_ALPHA);

      bus.invalidate(SESSION_ID);
      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, OTHER_SESSION_ID);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, OTHER_SESSION_ID), secondHandler);

      const secondList = await service.listGroups();
      const secondQuery = await service.queryGroup(GROUP_ALPHA);

      expect(firstList.kind).assertEqual('SNAPSHOT');
      expect(firstQuery.kind).assertEqual('SNAPSHOT');
      expect(secondList.kind).assertEqual('SNAPSHOT');
      expect(secondQuery.kind).assertEqual('SNAPSHOT');
      expect(firstHandler.queryGroupsInputs.length).assertEqual(1);
      expect(firstHandler.queryGroupInputs.length).assertEqual(1);
      expect(secondHandler.queryGroupsInputs.length).assertEqual(1);
      expect(secondHandler.queryGroupInputs.length).assertEqual(1);
      expect(firstHandler.queryGroupsInputs[0].generation).assertEqual(1);
      expect(firstHandler.queryGroupInputs[0].generation).assertEqual(1);
      expect(secondHandler.queryGroupsInputs[0].generation).assertEqual(2);
      expect(secondHandler.queryGroupInputs[0].generation).assertEqual(2);
      expect(secondHandler.queryGroupsInputs[0].generation > firstHandler.queryGroupsInputs[0].generation).assertTrue();
    });

    it('forwardsExactRunningGroupPathsForDuplicateNestedBranches', 0, async () => {
      const handler = new ScriptedHandler();
      handler.startDelayHook = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
        return createProxyDelaySnapshotResultFromCoreSnapshot(
          command.identity,
          command.generation,
          command.groupName,
          buildRunningDelaySnapshot(command, command.groupName, 'duplicate-branch-delay', 'RUNNING')
        );
      };
      const service = buildRunningService(handler, {
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4])
      });

      const gatewayShared = await service.queryGroup('Shared', ['Gateway', 'Shared']);
      const selected = await service.select(
        'Shared',
        NODE_ALPHA,
        gatewayShared.kind === 'SNAPSHOT' ? gatewayShared.snapshot.generation : -1,
        ['Gateway', 'Shared']
      );
      const mirrorShared = await service.queryGroup('Shared', ['Mirror', 'Shared']);
      const started = await service.startDelayTest(
        'Shared',
        mirrorShared.kind === 'SNAPSHOT' ? mirrorShared.snapshot.generation : -1,
        ['Mirror', 'Shared']
      );

      expect(gatewayShared.kind).assertEqual('SNAPSHOT');
      expect(selected.kind).assertEqual('APPLIED_NOW');
      expect(started.kind).assertEqual('SNAPSHOT');
      expect((handler.queryGroupInputs[0].groupPath ?? []).join('/')).assertEqual('Gateway/Shared');
      expect((handler.selectInputs[0].groupPath ?? []).join('/')).assertEqual('Gateway/Shared');
      expect((handler.queryGroupInputs[2].groupPath ?? []).join('/')).assertEqual('Mirror/Shared');
      expect((handler.startDelayInputs[0].groupPath ?? []).join('/')).assertEqual('Mirror/Shared');
    });

    it('rejectsNonRunningStatesMismatchesAndUnboundBusWithoutFallback', 0, async () => {
      const states: ('AWAITING_CONSENT' | 'STARTING' | 'RECOVERING' | 'STOPPING' | 'ERROR')[] = [
        'AWAITING_CONSENT',
        'STARTING',
        'RECOVERING',
        'STOPPING',
        'ERROR'
      ];
      for (let index: number = 0; index < states.length; index += 1) {
        const runtime = new FakeVpnRuntimeSnapshotPort();
        runtime.value = buildVpnSnapshot(states[index]);
        const service = buildStoppedService({
          runtime,
          clock: new FakeClock([TIMESTAMP_1])
        });
        const result = await service.listGroups();
        expectRejected(result, 'PROXY_RUNTIME_NOT_READY', TIMESTAMP_1);
      }

      const mismatchRuntime = new FakeVpnRuntimeSnapshotPort();
      mismatchRuntime.value = buildVpnSnapshot('RUNNING', PROFILE_ID_BETA, REVISION_ID, SESSION_ID);
      const mismatchService = buildStoppedService({
        runtime: mismatchRuntime,
        clock: new FakeClock([TIMESTAMP_2])
      });
      const mismatchResult = await mismatchService.listGroups();
      expectRejected(mismatchResult, 'VPN_SESSION_CHANGED', TIMESTAMP_2);

      const unboundRuntime = new FakeVpnRuntimeSnapshotPort();
      unboundRuntime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, OTHER_SESSION_ID);
      const unboundBus = new VpnProxyCommandBus(() => TIMESTAMP_3);
      const unboundService = buildStoppedService({
        runtime: unboundRuntime,
        bus: unboundBus,
        clock: new FakeClock([TIMESTAMP_3])
      });
      const unboundResult = await unboundService.listGroups();
      expectRejected(unboundResult, 'VPN_SESSION_CHANGED', TIMESTAMP_3);
    });

    it('mapsHasherQueryLoadAndRepositoryFailuresToSanitizedClosedErrors', 0, async () => {
      const hasher = new FakeHasher();
      hasher.error = new Error(`hash failure ${PROFILE_ID}`);
      const hasherService = buildStoppedService({
        hasher,
        clock: new FakeClock([TIMESTAMP_1])
      });
      const hasherResult = await hasherService.listGroups();
      expectRejected(hasherResult, 'PROXY_QUERY_FAILED', TIMESTAMP_1);

      const loadCore = new FakeCoreProxyPort();
      loadCore.loadHook = async (): Promise<void> => {
        throw new Error('/sandbox/private/current.yaml');
      };
      const loadService = buildStoppedService({
        core: loadCore,
        clock: new FakeClock([TIMESTAMP_2])
      });
      const loadResult = await loadService.listGroups();
      expectRejected(loadResult, 'PROXY_RUNTIME_NOT_READY', TIMESTAMP_2);

      const queryCore = new FakeCoreProxyPort();
      queryCore.queryGroupHook = async (): Promise<CoreProxyGroupResult> => {
        throw new Error('native failed with Node Alpha');
      };
      const queryService = buildStoppedService({
        core: queryCore,
        clock: new FakeClock([TIMESTAMP_3])
      });
      const queryResult = await queryService.queryGroup(GROUP_ALPHA);
      expectRejected(queryResult, 'PROXY_QUERY_FAILED', TIMESTAMP_3);

      const selectCore = new FakeCoreProxyPort();
      const selectRepository = new FakeSelectionRepository();
      selectRepository.upsertError = new Error(`repo write failed ${NODE_ALPHA}`);
      const selectService = buildStoppedService({
        core: selectCore,
        repository: selectRepository,
        clock: new FakeClock([TIMESTAMP_4])
      });
      const snapshot = await selectService.queryGroup(GROUP_ALPHA);
      const selectResult = await selectService.select(
        GROUP_ALPHA,
        NODE_ALPHA,
        snapshot.kind === 'SNAPSHOT' ? snapshot.snapshot.generation : -1
      );
      expectRejected(selectResult, 'PROXY_PERSISTENCE_FAILED', TIMESTAMP_4);
    });

    it('reconcilesStoppedSelectionsAtomicallyAndSkipsRepositoryMutationOnNonStaleQueryFailure', 0, async () => {
      const core = new FakeCoreProxyPort();
      const repository = new FakeSelectionRepository();
      repository.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID, TIMESTAMP_1),
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_2),
        createProxySelectionRecord(PROFILE_ID, 'Group Gamma', 'Missing Node', REVISION_ID, TIMESTAMP_3)
      ];
      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        if (call.groupName === GROUP_ALPHA) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(GROUP_ALPHA, NODE_ALPHA));
        }
        if (call.groupName === GROUP_BETA) {
          return createCoreGroupResult(call.context, buildGroupSnapshot(GROUP_BETA, NODE_BETA, true));
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot('Other Group', 'Missing Node'));
      };
      const service = buildStoppedService({
        core,
        repository,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3])
      });

      const reconcileResult = await service.reconcileActiveSelections();

      expect(reconcileResult.kind).assertEqual('RECONCILED');
      if (reconcileResult.kind !== 'RECONCILED') {
        throw new Error(`Expected reconciled result but received ${reconcileResult.kind}.`);
      }
      expect(reconcileResult.profileIdHash).assertEqual(PROFILE_HASH);
      expect(reconcileResult.revisionHash).assertEqual(REVISION_HASH);
      expect(reconcileResult.keptCount).assertEqual(1);
      expect(reconcileResult.deletedCount).assertEqual(2);
      expect(core.operations.join('>')).assertEqual(
        'load:/sandbox/profiles/current.yaml>group:Group Alpha:1>group:Group Beta:2>group:Group Gamma:3'
      );
      expect(repository.reconcileCalls.length).assertEqual(1);
      expect(repository.reconcileCalls[0].profileId).assertEqual(PROFILE_ID);
      expect(repository.reconcileCalls[0].newRevisionId).assertEqual(REVISION_ID);
      expect(repository.reconcileCalls[0].validPairs.length).assertEqual(1);
      expect(repository.reconcileCalls[0].validPairs[0].groupName).assertEqual(GROUP_ALPHA);
      expect(repository.reconcileCalls[0].validPairs[0].selectedNodeName).assertEqual(NODE_ALPHA);

      const failingCore = new FakeCoreProxyPort();
      const failingRepository = new FakeSelectionRepository();
      failingRepository.records = repository.records.slice();
      failingCore.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        if (call.groupName === GROUP_ALPHA) {
          throw new Error('native query explosion');
        }
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      const failingService = buildStoppedService({
        core: failingCore,
        repository: failingRepository,
        clock: new FakeClock([TIMESTAMP_4])
      });
      const failingResult = await failingService.reconcileActiveSelections();
      expectRejected(failingResult, 'PROXY_QUERY_FAILED', TIMESTAMP_4);
      expect(failingRepository.reconcileCalls.length).assertEqual(0);
    });

    it('serializesConcurrentStoppedCommandsAndReturnsClonedSnapshots', 0, async () => {
      const core = new FakeCoreProxyPort();
      const firstStarted: Deferred<void> = createDeferred<void>();
      const firstRelease: Deferred<void> = createDeferred<void>();
      const secondStarted: Deferred<void> = createDeferred<void>();
      core.loadHook = async (_path: string, callIndex: number): Promise<void> => {
        if (callIndex === 1) {
          firstStarted.resolve(undefined);
          await firstRelease.promise;
          return;
        }
        secondStarted.resolve(undefined);
      };
      const service = buildStoppedService({
        core,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3])
      });

      const firstPromise = service.queryGroup(GROUP_ALPHA);
      await firstStarted.promise;
      const secondPromise = service.queryGroup(GROUP_BETA);

      let secondStartedResolved: boolean = false;
      secondStarted.promise.then(() => {
        secondStartedResolved = true;
      });
      expect(secondStartedResolved).assertFalse();

      firstRelease.resolve(undefined);
      const firstResult = await firstPromise;
      await secondStarted.promise;
      const secondResult = await secondPromise;

      expect(core.queryGroupCalls.length).assertEqual(2);
      expect(core.queryGroupCalls[0].groupName).assertEqual(GROUP_ALPHA);
      expect(core.queryGroupCalls[1].groupName).assertEqual(GROUP_BETA);
      expect(core.queryGroupCalls[0].context.generation).assertEqual(1);
      expect(core.queryGroupCalls[1].context.generation).assertEqual(2);
      expect(firstResult.kind).assertEqual('SNAPSHOT');
      if (firstResult.kind === 'SNAPSHOT') {
        firstResult.snapshot.group.selectedName = 'Mutated';
      }
      const selectResult = await service.select(GROUP_ALPHA, NODE_ALPHA, 1);
      expect(selectResult.kind).assertEqual('SAVED_FOR_NEXT_START');
      expect(secondResult.kind).assertEqual('SNAPSHOT');
    });

    it('holdsStoppedLeaseAcrossAwaitBoundariesAndReleasesForEveryStoppedCommand', 0, async () => {
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const core = new FakeCoreProxyPort();
      const repository = new FakeSelectionRepository();
      const service = buildStoppedService({
        runtime,
        core,
        repository,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4])
      });

      const listStarted: Deferred<void> = createDeferred<void>();
      const listRelease: Deferred<void> = createDeferred<void>();
      core.loadHook = async (_path: string, callIndex: number): Promise<void> => {
        if (callIndex === 1) {
          listStarted.resolve(undefined);
          await listRelease.promise;
        }
      };
      const listPromise = service.listGroups();
      await listStarted.promise;
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.beginPending(buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID))).assertFalse();
      listRelease.resolve(undefined);
      await listPromise;
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(1);

      core.loadHook = undefined;
      const groupStarted: Deferred<void> = createDeferred<void>();
      const groupRelease: Deferred<void> = createDeferred<void>();
      core.queryGroupHook = async (call: QueryGroupCall): Promise<CoreProxyGroupResult> => {
        groupStarted.resolve(undefined);
        await groupRelease.promise;
        return createCoreGroupResult(call.context, buildGroupSnapshot(call.groupName, NODE_ALPHA));
      };
      const groupPromise = service.queryGroup(GROUP_ALPHA);
      await groupStarted.promise;
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.beginPending(buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID))).assertFalse();
      groupRelease.resolve(undefined);
      await groupPromise;
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(2);

      core.queryGroupHook = undefined;
      const baseline = await service.queryGroup(GROUP_ALPHA);
      const upsertStarted: Deferred<void> = createDeferred<void>();
      const upsertRelease: Deferred<void> = createDeferred<void>();
      repository.upsertHook = async (record: ProxySelectionRecord): Promise<void> => {
        upsertStarted.resolve(undefined);
        await upsertRelease.promise;
        repository.records = [cloneRecord(record)];
      };
      const selectPromise = service.select(
        GROUP_ALPHA,
        NODE_ALPHA,
        baseline.kind === 'SNAPSHOT' ? baseline.snapshot.generation : -1
      );
      await upsertStarted.promise;
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.beginPending(buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID))).assertFalse();
      upsertRelease.resolve(undefined);
      await selectPromise;
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(4);

      repository.records = [
        createProxySelectionRecord(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID, TIMESTAMP_1)
      ];
      const reconcileStarted: Deferred<void> = createDeferred<void>();
      const reconcileRelease: Deferred<void> = createDeferred<void>();
      repository.reconcileHook = async (
        _profileId: string,
        _newRevisionId: string,
        _validPairs: ProxySelectionPair[]
      ): Promise<void> => {
        reconcileStarted.resolve(undefined);
        await reconcileRelease.promise;
      };
      const reconcilePromise = service.reconcileActiveSelections();
      await reconcileStarted.promise;
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.beginPending(buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID))).assertFalse();
      reconcileRelease.resolve(undefined);
      await reconcilePromise;
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(5);
      expect(runtime.acquireCalls).assertEqual(5);
      expect(runtime.blockedBeginCount).assertEqual(4);
    });

    it('rejectsStoppedCommandsWithoutUsableLeaseAndReleasesLeasesOnFailure', 0, async () => {
      const noLeaseRuntime = new FakeVpnRuntimeSnapshotPort();
      noLeaseRuntime.leaseDisabled = true;
      const noLeaseCore = new FakeCoreProxyPort();
      const noLeaseService = buildStoppedService({
        runtime: noLeaseRuntime,
        core: noLeaseCore,
        clock: new FakeClock([TIMESTAMP_1])
      });
      const noLeaseResult = await noLeaseService.listGroups();
      expectRejected(noLeaseResult, 'PROXY_RUNTIME_NOT_READY', TIMESTAMP_1);
      expect(noLeaseCore.loadCalls.length).assertEqual(0);
      expect(noLeaseRuntime.releaseCalls).assertEqual(0);

      const changedLeaseRuntime = new FakeVpnRuntimeSnapshotPort();
      changedLeaseRuntime.leaseSnapshotOverride = buildVpnSnapshot('STOPPED', PROFILE_ID, REVISION_ID, SESSION_ID);
      const changedCore = new FakeCoreProxyPort();
      const changedService = buildStoppedService({
        runtime: changedLeaseRuntime,
        core: changedCore,
        clock: new FakeClock([TIMESTAMP_2])
      });
      const changedResult = await changedService.listGroups();
      expectRejected(changedResult, 'VPN_SESSION_CHANGED', TIMESTAMP_2);
      expect(changedCore.loadCalls.length).assertEqual(0);
      expect(changedLeaseRuntime.releaseCalls).assertEqual(1);

      const notReadyLeaseRuntime = new FakeVpnRuntimeSnapshotPort();
      notReadyLeaseRuntime.leaseSnapshotOverride = buildVpnSnapshot('STARTING');
      const notReadyCore = new FakeCoreProxyPort();
      const notReadyService = buildStoppedService({
        runtime: notReadyLeaseRuntime,
        core: notReadyCore,
        clock: new FakeClock([TIMESTAMP_3])
      });
      const notReadyResult = await notReadyService.listGroups();
      expectRejected(notReadyResult, 'PROXY_RUNTIME_NOT_READY', TIMESTAMP_3);
      expect(notReadyCore.loadCalls.length).assertEqual(0);
      expect(notReadyLeaseRuntime.releaseCalls).assertEqual(1);

      const failureRuntime = new FakeVpnRuntimeSnapshotPort();
      const failureCore = new FakeCoreProxyPort();
      const failureStarted: Deferred<void> = createDeferred<void>();
      const failureRelease: Deferred<void> = createDeferred<void>();
      failureCore.loadHook = async (): Promise<void> => {
        failureStarted.resolve(undefined);
        await failureRelease.promise;
        throw new Error('load failure');
      };
      const failureService = buildStoppedService({
        runtime: failureRuntime,
        core: failureCore,
        clock: new FakeClock([TIMESTAMP_4])
      });
      const failurePromise = failureService.listGroups();
      await failureStarted.promise;
      expect(failureRuntime.activeLeaseCount).assertEqual(1);
      failureRelease.resolve(undefined);
      const failureResult = await failurePromise;
      expectRejected(failureResult, 'PROXY_RUNTIME_NOT_READY', TIMESTAMP_4);
      expect(failureRuntime.activeLeaseCount).assertEqual(0);
      expect(failureRuntime.releaseCalls).assertEqual(1);
    });

    it('clearsLatestSnapshotsWhenExactRouteIdentityChanges', 0, async () => {
      const activeProfile = new FakeActiveProfilePort();
      const service = buildStoppedService({
        activeProfile,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2])
      });

      const first = await service.queryGroup(GROUP_ALPHA);
      activeProfile.value = createActiveProxyProfile(
        PROFILE_ID_BETA,
        REVISION_ID_NEXT,
        REVISION_HASH_NEXT,
        '/sandbox/profiles/beta.yaml'
      );
      await service.queryGroup(GROUP_ALPHA);
      activeProfile.value = createActiveProxyProfile(PROFILE_ID, REVISION_ID, REVISION_HASH, '/sandbox/profiles/current.yaml');

      const staleAfterIdentityChange = await service.select(
        GROUP_ALPHA,
        NODE_ALPHA,
        first.kind === 'SNAPSHOT' ? first.snapshot.generation : -1
      );

      expectRejected(staleAfterIdentityChange, 'PROXY_SELECTION_STALE', TIMESTAMP_1);
    });

    it('rejectsGenerationExhaustionWithoutThrowingAndAllowsValidatedInitialGeneration', 0, async () => {
      const saturatedRuntime = new FakeVpnRuntimeSnapshotPort();
      const saturatedCore = new FakeCoreProxyPort();
      const saturatedService = buildStoppedService({
        runtime: saturatedRuntime,
        core: saturatedCore,
        clock: new FakeClock([TIMESTAMP_1]),
        initialGeneration: Number.MAX_SAFE_INTEGER
      });

      const saturatedResult = await saturatedService.listGroups();
      expectRejected(saturatedResult, 'PROXY_QUERY_FAILED', TIMESTAMP_1);
      expect(saturatedCore.loadCalls.length).assertEqual(0);
      expect(saturatedRuntime.releaseCalls).assertEqual(1);

      const seededService = buildStoppedService({
        runtime: new FakeVpnRuntimeSnapshotPort(),
        clock: new FakeClock([TIMESTAMP_2]),
        initialGeneration: 3
      });
      const seededResult = await seededService.listGroups();
      expect(seededResult.kind).assertEqual('SNAPSHOT');
      if (seededResult.kind === 'SNAPSHOT') {
        expect(seededResult.generation).assertEqual(4);
      }
    });

    it('doesNotExposePostConstructionGenerationMutationApiAndRejectsInvalidSeedGenerically', 0, () => {
      const service = buildStoppedService();
      const serializedService: string = JSON.stringify(service);
      expect(serializedService.includes('setInitialGeneration')).assertFalse();

      expectThrowsMessage(() => {
        new ProxyService(
          new FakeActiveProfilePort(),
          new FakeCoreProxyPort(),
          new FakeSelectionRepository(),
          new FakeHasher(),
          new FakeVpnRuntimeSnapshotPort(),
          new VpnProxyCommandBus(() => TIMESTAMP_1),
          new FakeClock([TIMESTAMP_1]),
          -1
        );
      }, 'Proxy initial generation is invalid.');
    });

    it('holdsStoppedDelayLeaseUntilTerminalReadAndKeepsAFinalSnapshotCache', 0, async () => {
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const core = new FakeCoreProxyPort();
      const repository = new FakeSelectionRepository();
      let startedContext: CoreProxyQueryContext | undefined = undefined;
      const service = buildStoppedService({
        runtime,
        core,
        repository,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        initialGeneration: 4
      });
      const queried = await service.queryGroup(GROUP_ALPHA);
      core.startDelayHook = async (call: StartDelayCall): Promise<CoreProxyDelaySnapshot> => {
        startedContext = cloneQueryContext(call.context);
        expect(call.context.profileHash).assertEqual(PROFILE_HASH);
        expect(call.context.revisionHash).assertEqual(REVISION_HASH);
        expect(call.context.sessionHash).assertNull();
        return buildCoreDelaySnapshot(call.context, call.groupName, 'delay-job-1', 'RUNNING');
      };
      core.readDelayHook = async (call: ReadDelayCall): Promise<CoreProxyDelaySnapshot> => {
        expect(call.jobId).assertEqual('delay-job-1');
        return buildCoreDelaySnapshot(
          buildStoppedDelayContext(
            startedContext?.generation ?? -1,
            startedContext?.profileHash ?? '',
            startedContext?.revisionHash ?? '',
            startedContext?.sessionHash ?? null
          ),
          GROUP_ALPHA,
          call.jobId,
          'COMPLETED'
        );
      };

      const started = await service.startDelayTest(
        GROUP_ALPHA,
        queried.kind === 'SNAPSHOT' ? queried.snapshot.generation : -1
      );

      const baselineReleaseCalls: number = runtime.releaseCalls;
      expectDelaySnapshot(started, 'delay-job-1', 'RUNNING');
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.releaseCalls).assertEqual(baselineReleaseCalls);
      expect(repository.upsertCalls.length).assertEqual(0);
      expect(repository.reconcileCalls.length).assertEqual(0);

      const finished = await service.readDelayTest('delay-job-1');
      expectDelaySnapshot(finished, 'delay-job-1', 'COMPLETED');
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(baselineReleaseCalls + 1);
      expect(core.readDelayCalls.length).assertEqual(1);

      const cachedRead = await service.readDelayTest('delay-job-1');
      const cachedCancel = await service.cancelDelayTest('delay-job-1');
      expectDelaySnapshot(cachedRead, 'delay-job-1', 'COMPLETED');
      expectDelaySnapshot(cachedCancel, 'delay-job-1', 'COMPLETED');
      expect(core.readDelayCalls.length).assertEqual(1);
      expect(core.cancelDelayCalls.length).assertEqual(0);
    });

    it('drainsExistingDelayWorkBeforeMutationAndRetainsTheLeaseAcrossDrainFailures', 0, async () => {
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const core = new FakeCoreProxyPort();
      let startedContext: CoreProxyQueryContext | undefined = undefined;
      const service = buildStoppedService({
        runtime,
        core,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        initialGeneration: 2
      });
      const initial = await service.queryGroup(GROUP_ALPHA);
      core.startDelayHook = async (call: StartDelayCall): Promise<CoreProxyDelaySnapshot> => {
        startedContext = cloneQueryContext(call.context);
        return buildCoreDelaySnapshot(call.context, call.groupName, 'delay-job-drain', 'RUNNING');
      };
      await service.startDelayTest(
        GROUP_ALPHA,
        initial.kind === 'SNAPSHOT' ? initial.snapshot.generation : -1
      );
      const baselineReleaseCalls: number = runtime.releaseCalls;
      expect(runtime.activeLeaseCount).assertEqual(1);

      core.cancelDelayHook = async (): Promise<CoreProxyDelaySnapshot> => {
        throw new Error('drain failed');
      };
      const blocked = await service.listGroups();
      expectRejected(blocked, 'PROXY_DELAY_DRAIN_FAILED', TIMESTAMP_2);
      expect(runtime.activeLeaseCount).assertEqual(1);
      expect(runtime.releaseCalls).assertEqual(baselineReleaseCalls);

      const publicDrainFailure = await service.cancelAndDrainDelayTest();
      expect(publicDrainFailure === undefined).assertFalse();
      expectRejected(publicDrainFailure!, 'PROXY_DELAY_DRAIN_FAILED', TIMESTAMP_4);
      expect(runtime.activeLeaseCount).assertEqual(1);

      core.cancelDelayHook = async (call: CancelDelayCall): Promise<CoreProxyDelaySnapshot> => {
        return buildCoreDelaySnapshot(
          buildStoppedDelayContext(
            startedContext?.generation ?? -1,
            startedContext?.profileHash ?? '',
            startedContext?.revisionHash ?? '',
            startedContext?.sessionHash ?? null
          ),
          GROUP_ALPHA,
          call.jobId,
          'CANCELLED'
        );
      };
      const publicDrainSuccess = await service.cancelAndDrainDelayTest();
      expect(publicDrainSuccess).assertUndefined();
      expect(runtime.activeLeaseCount).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(baselineReleaseCalls + 1);

      const listAfterDrain = await service.listGroups();
      expect(listAfterDrain.kind).assertEqual('SNAPSHOT');
    });

    it('usesTheRunningBusPathWithoutStoppedLeasesAndDrainsBeforeReplacementStart', 0, async () => {
      const handler = new ScriptedHandler();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      const service = buildRunningService(handler, {
        runtime,
        clock: new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4])
      });
      const queried = await service.queryGroup(GROUP_ALPHA);
      handler.startDelayHook = async (command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> => {
          return createProxyDelaySnapshotResultFromCoreSnapshot(
            command.identity,
            command.generation,
            command.groupName,
            buildRunningDelaySnapshot(command, command.groupName, 'running-job-1', 'RUNNING')
          );
        };
      handler.cancelDelayHook = async (command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> => {
          return createProxyDelaySnapshotResultFromCoreSnapshot(
            command.identity,
            command.generation,
            GROUP_ALPHA,
            buildRunningDelaySnapshot(command, GROUP_ALPHA, command.jobId, 'CANCELLED')
          );
        };

      const started = await service.startDelayTest(
        GROUP_ALPHA,
        queried.kind === 'SNAPSHOT' ? queried.snapshot.generation : -1
      );
      expectDelaySnapshot(started, 'running-job-1', 'RUNNING');
      expect(runtime.acquireCalls).assertEqual(0);
      expect(runtime.releaseCalls).assertEqual(0);

      const refreshed = await service.queryGroup(GROUP_ALPHA);
      expect(refreshed.kind).assertEqual('SNAPSHOT');
      expect(handler.cancelDelayInputs.length).assertEqual(1);

      const nextQuery = await service.queryGroup(GROUP_ALPHA);
      const nextStarted = await service.startDelayTest(
        GROUP_ALPHA,
        nextQuery.kind === 'SNAPSHOT' ? nextQuery.snapshot.generation : -1
      );
      expectDelaySnapshot(nextStarted, 'running-job-1', 'RUNNING');
      expect(handler.startDelayInputs.length).assertEqual(2);
    });

    it('retiresStaleRunningDelayDuringDrainAndRoutesTheReplacementSession', 0, async () => {
      const firstHandler = new ScriptedHandler();
      const secondHandler = new ScriptedHandler();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID);
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID), firstHandler);
      const service = new ProxyService(
        new FakeActiveProfilePort(),
        new FakeCoreProxyPort(),
        new FakeSelectionRepository(),
        new FakeHasher(),
        runtime,
        bus,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        0
      );

      const initialQuery = await service.queryGroup(GROUP_ALPHA);
      const started = await service.startDelayTest(
        GROUP_ALPHA,
        initialQuery.kind === 'SNAPSHOT' ? initialQuery.snapshot.generation : -1
      );
      expectDelaySnapshot(started, 'delay-job-1', 'RUNNING');

      bus.invalidate(SESSION_ID);
      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, OTHER_SESSION_ID);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, OTHER_SESSION_ID), secondHandler);

      const listAfterSwitch = await service.listGroups();
      const queryAfterSwitch = await service.queryGroup(GROUP_ALPHA);
      const publicDrain = await service.cancelAndDrainDelayTest();

      expect(listAfterSwitch.kind).assertEqual('SNAPSHOT');
      expect(queryAfterSwitch.kind).assertEqual('SNAPSHOT');
      expect(publicDrain).assertUndefined();
      expect(firstHandler.cancelDelayInputs.length).assertEqual(0);
      expect(secondHandler.queryGroupsInputs.length).assertEqual(1);
      expect(secondHandler.queryGroupInputs.length).assertEqual(1);
      expect(secondHandler.queryGroupsInputs[0].generation).assertEqual(2);
      expect(secondHandler.queryGroupInputs[0].generation).assertEqual(2);
    });

    it('retiresRecoveringRunningDelayOnCancelWithoutLosingTheSameSessionGeneration', 0, async () => {
      const firstHandler = new ScriptedHandler();
      const resumedHandler = new ScriptedHandler();
      const runtime = new FakeVpnRuntimeSnapshotPort();
      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID);
      const bus = new VpnProxyCommandBus(() => TIMESTAMP_4);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID), firstHandler);
      const service = new ProxyService(
        new FakeActiveProfilePort(),
        new FakeCoreProxyPort(),
        new FakeSelectionRepository(),
        new FakeHasher(),
        runtime,
        bus,
        new FakeClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_4]),
        0
      );

      const initialQuery = await service.queryGroup(GROUP_ALPHA);
      const started = await service.startDelayTest(
        GROUP_ALPHA,
        initialQuery.kind === 'SNAPSHOT' ? initialQuery.snapshot.generation : -1
      );
      expectDelaySnapshot(started, 'delay-job-1', 'RUNNING');

      bus.invalidate(SESSION_ID);
      runtime.value = buildVpnSnapshot('RECOVERING', PROFILE_ID, REVISION_ID, SESSION_ID);
      const staleCancel = await service.cancelDelayTest('delay-job-1');

      runtime.value = buildVpnSnapshot('RUNNING', PROFILE_ID, REVISION_ID, SESSION_ID);
      bus.bind(createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, REVISION_HASH, SESSION_ID), resumedHandler);
      const queryAfterRecovery = await service.queryGroup(GROUP_ALPHA);
      const publicDrain = await service.cancelAndDrainDelayTest();

      expectRejected(staleCancel, 'VPN_SESSION_CHANGED', TIMESTAMP_1);
      expect(queryAfterRecovery.kind).assertEqual('SNAPSHOT');
      expect(publicDrain).assertUndefined();
      expect(firstHandler.cancelDelayInputs.length).assertEqual(0);
      expect(resumedHandler.queryGroupInputs.length).assertEqual(1);
      expect(resumedHandler.queryGroupInputs[0].generation).assertEqual(1);
    });
  });
}
