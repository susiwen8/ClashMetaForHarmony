import type { CoreProxyDelaySnapshot } from '../core/CoreProxyDelayModels';
import type {
  CoreProxyGroupList,
  CoreProxyGroupResult,
  CoreProxyGroupSnapshot,
  CoreProxyNodeSummary,
  CoreProxyQueryContext,
  CoreProxySelectionApplied
} from '../core/CoreProxyModels';
import { isCoreError } from '../core/CoreErrors';
import { isProfileEligibleForActivation, type Profile } from '../profile/ProfileModels';
import type { Clock, ProfileRepository } from '../profile/ProfilePorts';
import { SerialCommandQueue } from '../profile/SerialCommandQueue';
import { createVpnStartRequest, type VpnStartRequest } from '../vpn/VpnModels';
import {
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyRuntimeIdentity,
  createProxySelectionAppliedNowResult,
  createProxySelectionAppliedNotPersistedResult,
  createProxySelectionRecord,
  normalizeProxyLabel,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyGroupSnapshot,
  type ProxyRejectedResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionRecord,
  type ProxySelectionResult
} from './ProxyModels';
import {
  createProxyDelaySnapshotResultFromCoreSnapshot,
  type ProxyDelayResult,
  type ProxyDelaySnapshotResult
} from './ProxyDelayModels';
import {
  type VpnProxyCancelDelayTestCommand,
  type CoreProxyPort,
  type ProxyIdentityHasher,
  type ProxySelectionRepository,
  type VpnProxyCommandHandler,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyRuntimeLifecyclePort,
  type VpnProxyRuntimeMirrorPort,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand
} from './ProxyPorts';
import { VpnProxyCommandBus } from './VpnProxyCommandBus';

const SHA256_PATTERN: RegExp = /^[0-9a-f]{64}$/u;

interface ActiveRuntimeState {
  identity: ProxyRuntimeIdentity;
  profileHash: string;
  sessionHash: string;
}

interface ActiveDelayJobState {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  jobId: string;
}

class RunningCoreQueryContextValue implements CoreProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;

  constructor(profileHash: string, revisionHash: string, sessionHash: string | null, generation: number) {
    this.profileHash = profileHash;
    this.revisionHash = revisionHash;
    this.sessionHash = sessionHash;
    this.generation = generation;
  }
}

function sameIdentity(left: ProxyRuntimeIdentity, right: ProxyRuntimeIdentity): boolean {
  return left.profileId === right.profileId &&
    left.revisionId === right.revisionId &&
    left.revisionHash === right.revisionHash &&
    left.sessionId === right.sessionId;
}

function requireSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function requireLowercaseHash(value: string, label: string): string {
  if (!SHA256_PATTERN.test(value)) {
    throw new Error(`${label} must be a 64-character lowercase SHA-256 hex string.`);
  }
  return value;
}

function createActivationError(): Error {
  return new Error('Vpn proxy runtime activation failed.');
}

function normalizeInitialGeneration(initialGeneration: number): number {
  return requireSafeNonNegativeInteger(initialGeneration, 'Vpn proxy runtime handler initial generation');
}

function normalizeRollbackName(rawValue: string): string | undefined {
  if (rawValue.trim().length === 0) {
    return undefined;
  }
  try {
    return normalizeProxyLabel(rawValue, 'Proxy selected node name');
  } catch {
    return undefined;
  }
}

function findMember(group: CoreProxyGroupSnapshot, memberName: string): CoreProxyNodeSummary | undefined {
  for (let index: number = 0; index < group.nodes.length; index += 1) {
    if (group.nodes[index].name === memberName) {
      return group.nodes[index];
    }
  }
  return undefined;
}

function isTerminalMember(group: CoreProxyGroupSnapshot, memberName: string): boolean {
  const node: CoreProxyNodeSummary | undefined = findMember(group, memberName);
  return node !== undefined && !node.isGroup;
}

function isConfirmedSelection(
  group: CoreProxyGroupSnapshot,
  expectedGroupName: string,
  expectedSelectedName: string
): boolean {
  return group.name === expectedGroupName &&
    group.selectedName === expectedSelectedName &&
    isTerminalMember(group, expectedSelectedName);
}

function isStaleCoreError(error: Object): boolean {
  if (!isCoreError(error)) {
    return false;
  }
  const record: Record<string, Object> = error as Record<string, Object>;
  return record.code === 'PROXY_GROUP_NOT_FOUND' || record.code === 'PROXY_MEMBER_NOT_FOUND';
}

export class VpnProxyRuntimeHandler implements
  VpnProxyCommandHandler,
  VpnProxyRuntimeLifecyclePort,
  VpnProxyRuntimeMirrorPort {
  private readonly profileRepository: ProfileRepository;
  private readonly selectionRepository: ProxySelectionRepository;
  private readonly hasher: ProxyIdentityHasher;
  private readonly coreProxy: CoreProxyPort;
  private readonly clock: Clock;
  private readonly commandBus: VpnProxyCommandBus;
  private readonly lifecycleQueue: SerialCommandQueue = new SerialCommandQueue();
  private activeState?: ActiveRuntimeState;
  private activeDelayJob?: ActiveDelayJobState;
  private generationValue: number;

  constructor(
    profileRepository: ProfileRepository,
    selectionRepository: ProxySelectionRepository,
    hasher: ProxyIdentityHasher,
    coreProxy: CoreProxyPort,
    clock: Clock,
    commandBus: VpnProxyCommandBus,
    initialGeneration: number = 0
  ) {
    this.profileRepository = profileRepository;
    this.selectionRepository = selectionRepository;
    this.hasher = hasher;
    this.coreProxy = coreProxy;
    this.clock = clock;
    this.commandBus = commandBus;
    this.generationValue = normalizeInitialGeneration(initialGeneration);
  }

  async activate(request: VpnStartRequest): Promise<void> {
    const normalizedRequest: VpnStartRequest = createVpnStartRequest(
      request.profileId,
      request.versionId,
      request.sessionId
    );
    return await this.lifecycleQueue.execute(async (): Promise<void> => {
      try {
        await this.deactivateCurrentBindingIfNeeded();
        const state: ActiveRuntimeState = await this.resolveActivationState(normalizedRequest);
        const records: ProxySelectionRecord[] = await this.selectionRepository.listByProfile(state.identity.profileId);
        await this.replaySelections(state, records);
        this.bindState(state);
      } catch {
        throw createActivationError();
      }
    });
  }

  async bindExistingSession(request: VpnStartRequest): Promise<void> {
    const normalizedRequest: VpnStartRequest = createVpnStartRequest(
      request.profileId,
      request.versionId,
      request.sessionId
    );
    return await this.lifecycleQueue.execute(async (): Promise<void> => {
      try {
        await this.deactivateCurrentBindingIfNeeded();
        const state: ActiveRuntimeState = await this.resolveActivationState(normalizedRequest);
        this.bindState(state);
      } catch {
        throw createActivationError();
      }
    });
  }

  invalidate(sessionId: string): void {
    const state: ActiveRuntimeState | undefined = this.activeState;
    if (state === undefined || state.identity.sessionId !== sessionId) {
      return;
    }
    this.commandBus.invalidate(sessionId);
  }

  async cancelAndDrainDelayTest(sessionId: string): Promise<void> {
    return await this.lifecycleQueue.execute(async (): Promise<void> => {
      await this.cancelAndDrainDelayJob(sessionId);
    });
  }

  async deactivate(sessionId: string): Promise<void> {
    return await this.lifecycleQueue.execute(async (): Promise<void> => {
      const state: ActiveRuntimeState | undefined = this.activeState;
      if (state === undefined || state.identity.sessionId !== sessionId) {
        return;
      }
      await this.flushInvalidatedSession(sessionId);
      if (this.activeState !== undefined && this.activeState.identity.sessionId === sessionId) {
        this.activeDelayJob = undefined;
        this.activeState = undefined;
      }
    });
  }

  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveState(command.identity);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }
    try {
      const result: CoreProxyGroupList = await this.coreProxy.queryProxyGroups(
        this.createCommandContext(state, command.generation),
        command.selectableOnly
      );
      return createProxyGroupListQuerySnapshot(command.identity, command.generation, result.groups);
    } catch {
      return this.rejectQueryFailed();
    }
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveState(command.identity);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }
    try {
      const result: CoreProxyGroupResult = await this.coreProxy.queryProxyGroup(
        this.createCommandContext(state, command.generation),
        command.groupName
      );
      return createProxyGroupQuerySnapshot(
        createProxyGroupSnapshot(command.identity, command.generation, result.group)
      );
    } catch {
      return this.rejectQueryFailed();
    }
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveState(command.identity);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }

    let current: CoreProxyGroupResult;
    try {
      current = await this.coreProxy.queryProxyGroup(
        this.createCommandContext(state, command.generation),
        command.groupName
      );
    } catch {
      return this.rejectQueryFailed();
    }

    if (current.group.name !== command.groupName || !isTerminalMember(current.group, command.memberName)) {
      return this.rejectSelectionStale();
    }

    let applied: CoreProxySelectionApplied;
    try {
      applied = await this.coreProxy.selectProxy(
        this.createCommandContext(state, command.generation),
        command.groupName,
        command.memberName
      );
    } catch (error) {
      if (isStaleCoreError(error as Object)) {
        return this.rejectSelectionStale();
      }
      return this.rejectSelectionFailed();
    }

    if (!isConfirmedSelection(applied.group, command.groupName, command.memberName)) {
      return this.rejectSelectionFailed();
    }

    const timestamp: string = this.clock.now();
    const confirmedSnapshot: ProxyGroupSnapshot = createProxyGroupSnapshot(
      command.identity,
      command.generation,
      applied.group
    );
    const confirmedRecord: ProxySelectionRecord = createProxySelectionRecord(
      command.identity.profileId,
      applied.group.name,
      applied.group.selectedName,
      command.identity.revisionId,
      timestamp
    );

    try {
      await this.selectionRepository.upsert(confirmedRecord);
      return createProxySelectionAppliedNowResult(confirmedSnapshot, confirmedRecord, timestamp);
    } catch {
      return await this.handlePersistenceFailure(
        state,
        command,
        applied.previousName,
        timestamp,
        confirmedSnapshot,
        confirmedRecord
      );
    }
  }

  async startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveState(command.identity);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }
    try {
      await this.cancelExistingDelayJobIfNeeded(command.identity.sessionId!);
    } catch {
      return this.rejectDelayDrainFailed();
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.startProxyDelayTest(
        this.createCommandContext(state, command.generation),
        command.groupName
      );
    } catch {
      return this.rejectDelayTestFailed();
    }
    return this.publishDelaySnapshot(state, command.identity, command.generation, command.groupName, snapshot);
  }

  async readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveDelayJob(command.identity, command.generation, command.jobId);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.readProxyDelayTest(command.jobId);
    } catch {
      return this.rejectDelayTestFailed();
    }
    return this.publishDelaySnapshot(state, command.identity, command.generation, this.activeDelayJob!.groupName, snapshot);
  }

  async cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    const state: ActiveRuntimeState | undefined = this.requireActiveDelayJob(command.identity, command.generation, command.jobId);
    if (state === undefined) {
      return this.rejectSessionChanged();
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.cancelProxyDelayTest(command.jobId);
    } catch {
      return this.rejectDelayTestFailed();
    }
    return this.publishDelaySnapshot(state, command.identity, command.generation, this.activeDelayJob!.groupName, snapshot);
  }

  private async deactivateCurrentBindingIfNeeded(): Promise<void> {
    const state: ActiveRuntimeState | undefined = this.activeState;
    if (state === undefined || state.identity.sessionId === null) {
      return;
    }
    await this.flushInvalidatedSession(state.identity.sessionId);
    this.activeDelayJob = undefined;
    this.activeState = undefined;
  }

  private async resolveActivationState(request: VpnStartRequest): Promise<ActiveRuntimeState> {
    const profile: Profile | undefined = await this.profileRepository.get(request.profileId);
    if (profile === undefined || !isProfileEligibleForActivation(profile) || profile.currentRevision === null) {
      throw new Error('Profile unavailable.');
    }
    if (profile.currentRevision.validatedAt !== request.versionId) {
      throw new Error('Revision mismatch.');
    }
    const identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity(
      profile.id,
      profile.currentRevision.validatedAt,
      profile.currentRevision.sha256Digest,
      request.sessionId
    );
    const profileHash: string = requireLowercaseHash(
      await this.hasher.sha256(profile.id),
      'Proxy profile hash'
    );
    const sessionHash: string = requireLowercaseHash(
      await this.hasher.sha256(request.sessionId),
      'Proxy session hash'
    );
    return {
      identity,
      profileHash,
      sessionHash
    };
  }

  private async replaySelections(state: ActiveRuntimeState, records: ProxySelectionRecord[]): Promise<void> {
    for (let index: number = 0; index < records.length; index += 1) {
      const record: ProxySelectionRecord = records[index];
      let current: CoreProxyGroupResult;
      try {
        current = await this.coreProxy.queryProxyGroup(
          this.createLifecycleContext(state),
          record.groupName
        );
      } catch (error) {
        if (isStaleCoreError(error as Object)) {
          await this.selectionRepository.delete(state.identity.profileId, record.groupName);
          continue;
        }
        throw new Error('Replay query failed.');
      }

      if (current.group.name !== record.groupName || !isTerminalMember(current.group, record.selectedNodeName)) {
        await this.selectionRepository.delete(state.identity.profileId, record.groupName);
        continue;
      }

      let applied: CoreProxySelectionApplied;
      try {
        applied = await this.coreProxy.selectProxy(
          this.createLifecycleContext(state),
          record.groupName,
          record.selectedNodeName
        );
      } catch (error) {
        if (isStaleCoreError(error as Object)) {
          await this.selectionRepository.delete(state.identity.profileId, record.groupName);
          continue;
        }
        throw new Error('Replay selection failed.');
      }
      if (!isConfirmedSelection(applied.group, record.groupName, record.selectedNodeName)) {
        throw new Error('Replay selection confirmation failed.');
      }

      const updatedAt: string = this.clock.now();
      await this.selectionRepository.upsert(
        createProxySelectionRecord(
          state.identity.profileId,
          record.groupName,
          record.selectedNodeName,
          state.identity.revisionId,
          updatedAt
        )
      );
    }
  }

  private bindState(state: ActiveRuntimeState): void {
    this.activeState = state;
    try {
      this.commandBus.bind(state.identity, this);
    } catch {
      this.activeState = undefined;
      throw new Error('Binding failed.');
    }
  }

  private async handlePersistenceFailure(
    state: ActiveRuntimeState,
    command: VpnProxySelectCommand,
    previousNameRaw: string,
    timestamp: string,
    confirmedSnapshot: ProxyGroupSnapshot,
    confirmedRecord: ProxySelectionRecord
  ): Promise<ProxySelectionResult> {
    const persistenceError = createProxyRejectedError('PROXY_PERSISTENCE_FAILED', false, timestamp);
    const previousName: string | undefined = normalizeRollbackName(previousNameRaw);
    if (previousName === undefined) {
      return createProxySelectionAppliedNotPersistedResult(
        confirmedSnapshot,
        confirmedRecord,
        persistenceError,
        timestamp
      );
    }

    let latestConfirmedSnapshot: ProxyGroupSnapshot = confirmedSnapshot;
    let latestConfirmedRecord: ProxySelectionRecord = confirmedRecord;
    let rollbackApplied: CoreProxySelectionApplied;
    try {
      rollbackApplied = await this.coreProxy.selectProxy(
        this.createCommandContext(state, command.generation),
        command.groupName,
        previousName
      );
    } catch {
      return createProxySelectionAppliedNotPersistedResult(
        latestConfirmedSnapshot,
        latestConfirmedRecord,
        persistenceError,
        timestamp
      );
    }

    const rollbackSnapshot: ProxyGroupSnapshot | undefined = this.tryCreateActualSnapshot(
      command.identity,
      command.generation,
      rollbackApplied.group
    );
    if (rollbackSnapshot !== undefined) {
      latestConfirmedSnapshot = rollbackSnapshot;
      latestConfirmedRecord = this.createRecordFromSnapshot(rollbackSnapshot, timestamp);
      if (isConfirmedSelection(rollbackApplied.group, command.groupName, previousName)) {
        return createProxyRejectedResult(persistenceError);
      }
    }

    let rollbackState: CoreProxyGroupResult;
    try {
      rollbackState = await this.coreProxy.queryProxyGroup(
        this.createCommandContext(state, command.generation),
        command.groupName
      );
    } catch {
      return createProxySelectionAppliedNotPersistedResult(
        latestConfirmedSnapshot,
        latestConfirmedRecord,
        persistenceError,
        timestamp
      );
    }

    if (isConfirmedSelection(rollbackState.group, command.groupName, previousName)) {
      return createProxyRejectedResult(persistenceError);
    }

    const actualSnapshot: ProxyGroupSnapshot | undefined = this.tryCreateActualSnapshot(
      command.identity,
      command.generation,
      rollbackState.group
    );
    if (actualSnapshot !== undefined) {
      latestConfirmedSnapshot = actualSnapshot;
      latestConfirmedRecord = this.createRecordFromSnapshot(actualSnapshot, timestamp);
    }

    return createProxySelectionAppliedNotPersistedResult(
      latestConfirmedSnapshot,
      latestConfirmedRecord,
      persistenceError,
      timestamp
    );
  }

  private tryCreateActualSnapshot(
    identity: ProxyRuntimeIdentity,
    generation: number,
    group: CoreProxyGroupSnapshot
  ): ProxyGroupSnapshot | undefined {
    if (!isTerminalMember(group, group.selectedName)) {
      return undefined;
    }
    return createProxyGroupSnapshot(identity, generation, group);
  }

  private createRecordFromSnapshot(snapshot: ProxyGroupSnapshot, timestamp: string): ProxySelectionRecord {
    return createProxySelectionRecord(
      snapshot.identity.profileId,
      snapshot.group.name,
      snapshot.group.selectedName,
      snapshot.identity.revisionId,
      timestamp
    );
  }

  private createLifecycleContext(state: ActiveRuntimeState): CoreProxyQueryContext {
    const generation: number = this.nextLifecycleGeneration();
    return new RunningCoreQueryContextValue(
      state.profileHash,
      state.identity.revisionHash,
      state.sessionHash,
      generation
    );
  }

  private createCommandContext(state: ActiveRuntimeState, generation: number): CoreProxyQueryContext {
    return new RunningCoreQueryContextValue(
      state.profileHash,
      state.identity.revisionHash,
      state.sessionHash,
      generation
    );
  }

  private nextLifecycleGeneration(): number {
    if (this.generationValue >= Number.MAX_SAFE_INTEGER) {
      throw new Error('Vpn proxy runtime handler cannot allocate another generation.');
    }
    this.generationValue += 1;
    return this.generationValue;
  }

  private requireActiveState(identity: ProxyRuntimeIdentity): ActiveRuntimeState | undefined {
    const state: ActiveRuntimeState | undefined = this.activeState;
    if (state === undefined) {
      return undefined;
    }
    return sameIdentity(state.identity, identity) ? state : undefined;
  }

  private requireActiveDelayJob(
    identity: ProxyRuntimeIdentity,
    generation: number,
    jobId: string
  ): ActiveRuntimeState | undefined {
    const state: ActiveRuntimeState | undefined = this.requireActiveState(identity);
    if (state === undefined) {
      return undefined;
    }
    const job: ActiveDelayJobState | undefined = this.activeDelayJob;
    if (job === undefined) {
      return undefined;
    }
    if (!sameIdentity(job.identity, identity) || job.generation !== generation || job.jobId !== jobId) {
      return undefined;
    }
    return state;
  }

  private async cancelExistingDelayJobIfNeeded(sessionId: string): Promise<void> {
    const job: ActiveDelayJobState | undefined = this.activeDelayJob;
    if (job === undefined || job.identity.sessionId !== sessionId) {
      return;
    }
    await this.cancelAndDrainDelayJob(sessionId);
  }

  private async flushInvalidatedSession(sessionId: string): Promise<void> {
    this.commandBus.invalidate(sessionId);
    await this.cancelAndDrainDelayJob(sessionId);
    await this.commandBus.deactivate(sessionId);
    await this.cancelAndDrainDelayJob(sessionId);
  }

  private async cancelAndDrainDelayJob(sessionId: string): Promise<void> {
    const state: ActiveRuntimeState | undefined = this.activeState;
    const job: ActiveDelayJobState | undefined = this.activeDelayJob;
    if (state === undefined || job === undefined) {
      return;
    }
    if (state.identity.sessionId !== sessionId || job.identity.sessionId !== sessionId) {
      return;
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.cancelProxyDelayTest(job.jobId);
    } catch {
      throw new Error('Vpn proxy runtime delay drain failed.');
    }
    try {
      this.validateDelayContext(snapshot, state, job.generation, job.groupName, job.jobId);
      if (!this.isTerminalDelayState(snapshot.state)) {
        throw new Error('nonterminal');
      }
    } catch {
      throw new Error('Vpn proxy runtime delay drain failed.');
    }
    this.activeDelayJob = undefined;
  }

  private publishDelaySnapshot(
    state: ActiveRuntimeState,
    identity: ProxyRuntimeIdentity,
    generation: number,
    expectedGroupName: string,
    snapshot: CoreProxyDelaySnapshot
  ): ProxyDelayResult {
    try {
      this.validateDelayContext(snapshot, state, generation, expectedGroupName);
      const result: ProxyDelaySnapshotResult = createProxyDelaySnapshotResultFromCoreSnapshot(
        identity,
        generation,
        expectedGroupName,
        snapshot
      );
      if (this.isTerminalDelayState(snapshot.state)) {
        this.activeDelayJob = undefined;
      } else {
        this.activeDelayJob = {
          identity: createProxyRuntimeIdentity(
            identity.profileId,
            identity.revisionId,
            identity.revisionHash,
            identity.sessionId
          ),
          generation,
          groupName: expectedGroupName,
          jobId: result.jobId
        };
      }
      return result;
    } catch {
      return this.rejectDelayTestFailed();
    }
  }

  private validateDelayContext(
    snapshot: CoreProxyDelaySnapshot,
    state: ActiveRuntimeState,
    generation: number,
    expectedGroupName: string,
    expectedJobId?: string
  ): void {
    if (snapshot.profileHash !== state.profileHash ||
      snapshot.revisionHash !== state.identity.revisionHash ||
      snapshot.sessionHash !== state.sessionHash ||
      snapshot.generation !== generation ||
      snapshot.groupName !== expectedGroupName) {
      throw new Error('Delay context mismatch.');
    }
    if (expectedJobId !== undefined && snapshot.jobId !== expectedJobId) {
      throw new Error('Delay job mismatch.');
    }
  }

  private isTerminalDelayState(state: string): boolean {
    return state === 'COMPLETED' || state === 'CANCELLED' || state === 'FAILED';
  }

  private rejectQueryFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_QUERY_FAILED', true, this.clock.now())
    );
  }

  private rejectSelectionFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_SELECTION_FAILED', false, this.clock.now())
    );
  }

  private rejectSelectionStale(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_SELECTION_STALE', false, this.clock.now())
    );
  }

  private rejectDelayTestFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_DELAY_TEST_FAILED', true, this.clock.now())
    );
  }

  private rejectDelayDrainFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_DELAY_DRAIN_FAILED', true, this.clock.now())
    );
  }

  private rejectSessionChanged(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('VPN_SESSION_CHANGED', false, this.clock.now())
    );
  }
}
