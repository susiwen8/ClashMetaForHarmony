import { SerialCommandQueue } from '../profile/SerialCommandQueue';
import type { CoreProxyQueryContext } from '../core/CoreProxyModels';
import type { CoreProxyDelaySnapshot } from '../core/CoreProxyDelayModels';
import type { Clock } from '../profile/ProfilePorts';
import type { VpnRuntimeSnapshot } from '../vpn/VpnModels';
import { VpnProxyCommandBus } from './VpnProxyCommandBus';
import {
  cloneProxyDelayResult,
  cloneProxyDelaySnapshotResult,
  createProxyDelaySnapshotResultFromCoreSnapshot,
  normalizeProxyDelayJobId,
  type ProxyDelayResult,
  type ProxyDelaySnapshotResult
} from './ProxyDelayModels';
import {
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyReconcileResult,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxyRuntimeIdentity,
  createProxySelectionRecord,
  createProxySelectionSavedForNextStartResult,
  normalizeProxyLabel,
  cloneProxySelectionResult,
  type ActiveProxyProfile,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyGroupSnapshot,
  type ProxyReconcileResult,
  type ProxyRejectedResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionRecord,
  type ProxySelectionResult
} from './ProxyModels';
import {
  cloneVpnProxyGroupPath,
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxyStartDelayTestCommand,
  createVpnProxySelectCommand,
  createVpnProxyCancelDelayTestCommand,
  type ActiveProfileProxyPort,
  type CoreProxyPort,
  type ProxyApplicationPort,
  type ProxyIdentityHasher,
  type ProxySelectionPair,
  type ProxySelectionRepository,
  type VpnStoppedProxyLease,
  type VpnRuntimeSnapshotPort
} from './ProxyPorts';

type RoutingKind = 'STOPPED' | 'RUNNING' | 'REJECTED';
type DelayRouteKind = 'STOPPED' | 'RUNNING';

interface RoutingResolution {
  kind: RoutingKind;
  active?: ActiveProxyProfile;
  identity?: ProxyRuntimeIdentity;
  rejected?: ProxyRejectedResult;
  lease?: VpnStoppedProxyLease;
}

interface ActiveDelayRecord {
  jobId: string;
  identity: ProxyRuntimeIdentity;
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;
  groupName: string;
  route: DelayRouteKind;
  lease?: VpnStoppedProxyLease;
  lastSnapshot: ProxyDelaySnapshotResult;
  finalizing: boolean;
  finalized: boolean;
}

interface RunningGenerationBinding {
  identity: ProxyRuntimeIdentity;
  generation: number;
}

class StoppedCoreQueryContextValue implements CoreProxyQueryContext {
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

function isSafePositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0 && value <= Number.MAX_SAFE_INTEGER;
}

function requireSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function normalizeInitialGeneration(initialGeneration: number): number {
  try {
    return requireSafeNonNegativeInteger(initialGeneration, 'Proxy initial generation');
  } catch {
    throw new Error('Proxy initial generation is invalid.');
  }
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

function sameIdentity(left: ProxyRuntimeIdentity, right: ProxyRuntimeIdentity): boolean {
  return left.profileId === right.profileId &&
    left.revisionId === right.revisionId &&
    left.revisionHash === right.revisionHash &&
    left.sessionId === right.sessionId;
}

function compareGroupName(left: ProxySelectionRecord, right: ProxySelectionRecord): number {
  if (left.groupName < right.groupName) {
    return -1;
  }
  if (left.groupName > right.groupName) {
    return 1;
  }
  return 0;
}

export class ProxyService implements ProxyApplicationPort {
  private readonly activeProfile: ActiveProfileProxyPort;
  private readonly coreProxy: CoreProxyPort;
  private readonly repository: ProxySelectionRepository;
  private readonly hasher: ProxyIdentityHasher;
  private readonly vpnSnapshotPort: VpnRuntimeSnapshotPort;
  private readonly commandBus: VpnProxyCommandBus;
  private readonly clock: Clock;
  private readonly queue: SerialCommandQueue = new SerialCommandQueue();
  private readonly latestGroupSnapshots: Map<string, ProxyGroupSnapshot> = new Map();
  private currentRouteIdentityKey?: string;
  private runningGenerationBinding?: RunningGenerationBinding;
  private activeDelayRecord?: ActiveDelayRecord;
  private finalDelayResult?: ProxyDelaySnapshotResult;
  private finalDelayIdentityKey?: string;
  private generationValue: number = 0;

  constructor(
    activeProfile: ActiveProfileProxyPort,
    coreProxy: CoreProxyPort,
    repository: ProxySelectionRepository,
    hasher: ProxyIdentityHasher,
    vpnSnapshotPort: VpnRuntimeSnapshotPort,
    commandBus: VpnProxyCommandBus,
    clock: Clock,
    initialGeneration: number = 0
  ) {
    this.activeProfile = activeProfile;
    this.coreProxy = coreProxy;
    this.repository = repository;
    this.hasher = hasher;
    this.vpnSnapshotPort = vpnSnapshotPort;
    this.commandBus = commandBus;
    this.clock = clock;
    this.generationValue = normalizeInitialGeneration(initialGeneration);
  }

  async listGroups(): Promise<ProxyGroupListQueryResult> {
    return await this.queue.execute(async (): Promise<ProxyGroupListQueryResult> => {
      const drainRejected: ProxyRejectedResult | undefined = await this.drainDelayTestInsideQueue();
      if (drainRejected !== undefined) {
        return drainRejected;
      }
      const routing: RoutingResolution = await this.resolveRouting();
      try {
        if (routing.kind === 'REJECTED') {
          return routing.rejected!;
        }
        const generation: number | undefined = this.resolveQueryGeneration(routing);
        if (generation === undefined) {
          return this.rejectQueryFailed();
        }
        if (routing.kind === 'RUNNING') {
          const result: ProxyGroupListQueryResult = await this.commandBus.submitQueryGroups(
            createVpnProxyQueryGroupsCommand(routing.identity!, generation, true)
          );
          if (result.kind === 'REJECTED') {
            return result;
          }
          return createProxyGroupListQuerySnapshot(routing.identity!, generation, result.groups);
        }
        return await this.queryStoppedGroups(routing.active!, routing.identity!, generation);
      } finally {
        routing.lease?.release();
      }
    });
  }

  async queryGroup(groupName: string, groupPath?: string[]): Promise<ProxyGroupQueryResult> {
    return await this.queue.execute(async (): Promise<ProxyGroupQueryResult> => {
      let normalizedGroupName: string;
      try {
        normalizedGroupName = normalizeProxyLabel(groupName, 'Proxy group name');
      } catch {
        return this.rejectQueryFailed();
      }
      const drainRejected: ProxyRejectedResult | undefined = await this.drainDelayTestInsideQueue();
      if (drainRejected !== undefined) {
        return drainRejected;
      }
      const routing: RoutingResolution = await this.resolveRouting();
      try {
        if (routing.kind === 'REJECTED') {
          return routing.rejected!;
        }
        const generation: number | undefined = this.resolveQueryGeneration(routing);
        if (generation === undefined) {
          return this.rejectQueryFailed();
        }
        if (routing.kind === 'RUNNING') {
          return await this.queryRunningGroup(routing.identity!, normalizedGroupName, generation, groupPath);
        }
        return await this.queryStoppedGroup(
          routing.active!,
          routing.identity!,
          normalizedGroupName,
          generation,
          true,
          groupPath
        );
      } finally {
        routing.lease?.release();
      }
    });
  }

  async select(
    groupName: string,
    memberName: string,
    snapshotGeneration: number,
    groupPath?: string[]
  ): Promise<ProxySelectionResult> {
    return await this.queue.execute(async (): Promise<ProxySelectionResult> => {
      let normalizedGroupName: string;
      let normalizedMemberName: string;
      try {
        normalizedGroupName = normalizeProxyLabel(groupName, 'Proxy group name');
        normalizedMemberName = normalizeProxyLabel(memberName, 'Proxy selected node name');
      } catch {
        return this.rejectSelectionStale();
      }
      if (!isSafePositiveInteger(snapshotGeneration)) {
        return this.rejectSelectionStale();
      }
      const drainRejected: ProxyRejectedResult | undefined = await this.drainDelayTestInsideQueue();
      if (drainRejected !== undefined) {
        return drainRejected;
      }
      const routing: RoutingResolution = await this.resolveRouting();
      try {
        if (routing.kind === 'REJECTED') {
          return routing.rejected!;
        }
        const identity: ProxyRuntimeIdentity = routing.identity!;
        const latest: ProxyGroupSnapshot | undefined =
          this.findLatestGroupSnapshot(identity, normalizedGroupName, groupPath);
        if (latest === undefined || latest.generation !== snapshotGeneration) {
          return this.rejectSelectionStale();
        }
        if (!this.hasTerminalMember(latest, normalizedMemberName)) {
          return this.rejectSelectionStale();
        }

        const confirmationGeneration: number | undefined = this.resolveQueryGeneration(routing);
        if (confirmationGeneration === undefined) {
          return this.rejectQueryFailed();
        }
        const confirmed: ProxyGroupQueryResult = routing.kind === 'RUNNING'
          ? await this.queryRunningGroup(identity, normalizedGroupName, confirmationGeneration, groupPath)
          : await this.queryStoppedGroup(
            routing.active!,
            identity,
            normalizedGroupName,
            confirmationGeneration,
            true,
            groupPath
          );
        if (confirmed.kind === 'REJECTED') {
          return confirmed;
        }
        const confirmedSnapshot: ProxyGroupSnapshot = confirmed.snapshot;
        if (confirmedSnapshot.group.name !== normalizedGroupName || !this.hasTerminalMember(confirmedSnapshot, normalizedMemberName)) {
          return this.rejectSelectionStale();
        }

        if (routing.kind === 'RUNNING') {
          const result: ProxySelectionResult = await this.commandBus.submitSelect(
            createVpnProxySelectCommand(
              identity,
              confirmedSnapshot.generation,
              normalizedGroupName,
              normalizedMemberName,
              groupPath
            )
          );
          return cloneProxySelectionResult(result);
        }

        const timestamp: string = this.clock.now();
        const record: ProxySelectionRecord = createProxySelectionRecord(
          identity.profileId,
          normalizedGroupName,
          normalizedMemberName,
          identity.revisionId,
          timestamp
        );
        try {
          await this.repository.upsert(record);
        } catch {
          return this.rejectPersistenceFailed();
        }
        return createProxySelectionSavedForNextStartResult(record, timestamp);
      } finally {
        routing.lease?.release();
      }
    });
  }

  async reconcileActiveSelections(): Promise<ProxyReconcileResult> {
    return await this.queue.execute(async (): Promise<ProxyReconcileResult> => {
      const drainRejected: ProxyRejectedResult | undefined = await this.drainDelayTestInsideQueue();
      if (drainRejected !== undefined) {
        return drainRejected;
      }
      const routing: RoutingResolution = await this.resolveRouting();
      try {
        if (routing.kind === 'REJECTED') {
          return routing.rejected!;
        }
        if (routing.kind !== 'STOPPED') {
          return this.rejectRuntimeNotReady();
        }
        const active: ActiveProxyProfile = routing.active!;
        const identity: ProxyRuntimeIdentity = routing.identity!;
        let profileHash: string;
        try {
          profileHash = await this.hasher.sha256(active.profileId);
        } catch {
          return this.rejectQueryFailed();
        }
        try {
          await this.coreProxy.loadConfiguration(active.configPath);
        } catch {
          return this.rejectRuntimeNotReady();
        }
        let records: ProxySelectionRecord[];
        try {
          records = await this.repository.listByProfile(active.profileId);
        } catch {
          return this.rejectPersistenceFailed();
        }
        const sorted: ProxySelectionRecord[] = records.slice().sort(compareGroupName);
        const validPairs: ProxySelectionPair[] = [];
        let deletedCount: number = 0;
        for (let index: number = 0; index < sorted.length; index += 1) {
          const generation: number | undefined = this.nextGeneration();
          if (generation === undefined) {
            return this.rejectQueryFailed();
          }
          const result: ProxyGroupQueryResult = await this.queryStoppedGroup(
            active,
            identity,
            sorted[index].groupName,
            generation,
            false
          );
          if (result.kind === 'REJECTED') {
            return result;
          }
          const snapshot: ProxyGroupSnapshot = result.snapshot;
          if (snapshot.group.name !== sorted[index].groupName || !this.hasTerminalMember(snapshot, sorted[index].selectedNodeName)) {
            deletedCount += 1;
            continue;
          }
          validPairs.push({
            groupName: sorted[index].groupName,
            selectedNodeName: sorted[index].selectedNodeName
          });
        }
        try {
          await this.repository.reconcileProfile(active.profileId, active.revisionId, cloneSelectionPairs(validPairs));
        } catch {
          return this.rejectPersistenceFailed();
        }
        return createProxyReconcileResult(profileHash, active.revisionHash, validPairs.length, deletedCount);
      } finally {
        routing.lease?.release();
      }
    });
  }

  async startDelayTest(groupName: string, snapshotGeneration: number, groupPath?: string[]): Promise<ProxyDelayResult> {
    return await this.queue.execute(async (): Promise<ProxyDelayResult> => {
      let normalizedGroupName: string;
      let normalizedGroupPath: string[] | undefined = undefined;
      try {
        normalizedGroupName = normalizeProxyLabel(groupName, 'Proxy group name');
        normalizedGroupPath = groupPath === undefined
          ? undefined
          : cloneVpnProxyGroupPath(groupPath, normalizedGroupName);
      } catch {
        return this.rejectSelectionStale();
      }
      if (!isSafePositiveInteger(snapshotGeneration)) {
        return this.rejectSelectionStale();
      }
      const drainRejected: ProxyRejectedResult | undefined = await this.drainDelayTestInsideQueue();
      if (drainRejected !== undefined) {
        return drainRejected;
      }
      const routing: RoutingResolution = await this.resolveRouting();
      if (routing.kind === 'REJECTED') {
        routing.lease?.release();
        return routing.rejected!;
      }
      const identity: ProxyRuntimeIdentity = routing.identity!;
      const latest: ProxyGroupSnapshot | undefined =
        this.findLatestGroupSnapshot(identity, normalizedGroupName, normalizedGroupPath);
      if (latest === undefined || latest.generation !== snapshotGeneration) {
        routing.lease?.release();
        return this.rejectSelectionStale();
      }
      if (routing.kind === 'RUNNING') {
        return await this.startRunningDelayTest(identity, normalizedGroupName, snapshotGeneration, normalizedGroupPath);
      }
      return await this.startStoppedDelayTest(
        routing.active!,
        identity,
        normalizedGroupName,
        snapshotGeneration,
        routing.lease!
      );
    });
  }

  async readDelayTest(jobId: string): Promise<ProxyDelayResult> {
    return await this.queue.execute(async (): Promise<ProxyDelayResult> => {
      let normalizedJobId: string;
      try {
        normalizedJobId = normalizeProxyDelayJobId(jobId);
      } catch {
        return this.rejectSessionChanged();
      }
      const finalResult: ProxyDelayResult | undefined = await this.tryReadFinalDelayResult(normalizedJobId);
      if (finalResult !== undefined) {
        return finalResult;
      }
      const record: ActiveDelayRecord | undefined = this.activeDelayRecord;
      if (record === undefined || record.jobId !== normalizedJobId) {
        return this.rejectSessionChanged();
      }
      const isCurrent: boolean = await this.isDelayIdentityCurrent(record.identity);
      if (!isCurrent) {
        if (record.route === 'RUNNING') {
          this.retireRunningDelayRecord(record);
        }
        return this.rejectSessionChanged();
      }
      return await this.readActiveDelayRecord(record);
    });
  }

  async cancelDelayTest(jobId: string): Promise<ProxyDelayResult> {
    return await this.queue.execute(async (): Promise<ProxyDelayResult> => {
      let normalizedJobId: string;
      try {
        normalizedJobId = normalizeProxyDelayJobId(jobId);
      } catch {
        return this.rejectSessionChanged();
      }
      const finalResult: ProxyDelayResult | undefined = await this.tryReadFinalDelayResult(normalizedJobId);
      if (finalResult !== undefined) {
        return finalResult;
      }
      const record: ActiveDelayRecord | undefined = this.activeDelayRecord;
      if (record === undefined || record.jobId !== normalizedJobId) {
        return this.rejectSessionChanged();
      }
      const isCurrent: boolean = await this.isDelayIdentityCurrent(record.identity);
      if (!isCurrent) {
        if (record.route === 'RUNNING') {
          this.retireRunningDelayRecord(record);
        }
        return this.rejectSessionChanged();
      }
      return await this.cancelActiveDelayRecord(record);
    });
  }

  async cancelAndDrainDelayTest(): Promise<ProxyRejectedResult | undefined> {
    return await this.queue.execute(async (): Promise<ProxyRejectedResult | undefined> => {
      return await this.drainDelayTestInsideQueue();
    });
  }

  private async startRunningDelayTest(
    identity: ProxyRuntimeIdentity,
    groupName: string,
    generation: number,
    groupPath?: string[]
  ): Promise<ProxyDelayResult> {
    const result: ProxyDelayResult = await this.commandBus.submitStartDelayTest(
      createVpnProxyStartDelayTestCommand(identity, generation, groupName, groupPath)
    );
    if (result.kind === 'REJECTED') {
      return cloneProxyDelayResult(result);
    }
    return this.admitRunningDelaySnapshot(identity, generation, groupName, result);
  }

  private async startStoppedDelayTest(
    active: ActiveProxyProfile,
    identity: ProxyRuntimeIdentity,
    groupName: string,
    generation: number,
    lease: VpnStoppedProxyLease
  ): Promise<ProxyDelayResult> {
    let context: CoreProxyQueryContext;
    try {
      context = await this.createStoppedContext(active, generation);
    } catch {
      lease.release();
      return this.rejectQueryFailed();
    }
    try {
      await this.coreProxy.loadConfiguration(active.configPath);
    } catch {
      lease.release();
      return this.rejectRuntimeNotReady();
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.startProxyDelayTest(context, groupName);
    } catch {
      lease.release();
      return this.rejectDelayTestFailed();
    }
    let result: ProxyDelaySnapshotResult;
    try {
      result = this.validateStoppedDelaySnapshot(identity, context, groupName, snapshot);
    } catch {
      lease.release();
      return this.rejectDelayTestFailed();
    }
    return this.admitDelaySnapshot({
      jobId: result.jobId,
      identity: createProxyRuntimeIdentity(
        identity.profileId,
        identity.revisionId,
        identity.revisionHash,
        identity.sessionId
      ),
      profileHash: context.profileHash,
      revisionHash: context.revisionHash,
      sessionHash: context.sessionHash,
      generation,
      groupName,
      route: 'STOPPED',
      lease,
      lastSnapshot: cloneProxyDelaySnapshotResult(result),
      finalizing: false,
      finalized: false
    }, result);
  }

  private async readActiveDelayRecord(record: ActiveDelayRecord): Promise<ProxyDelayResult> {
    if (record.route === 'RUNNING') {
      const result: ProxyDelayResult = await this.commandBus.submitReadDelayTest(
        createVpnProxyReadDelayTestCommand(record.identity, record.generation, record.jobId)
      );
      if (result.kind === 'REJECTED') {
        return cloneProxyDelayResult(result);
      }
      try {
        return this.publishValidatedRunningDelay(record, result, false);
      } catch {
        return this.rejectDelayTestFailed();
      }
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.readProxyDelayTest(record.jobId);
    } catch {
      return this.rejectDelayTestFailed();
    }
    try {
      const result: ProxyDelaySnapshotResult = this.validateStoppedDelaySnapshot(
        record.identity,
        this.createStoppedContextValue(record),
        record.groupName,
        snapshot,
        record.jobId
      );
      return this.publishValidatedDelay(record, result, false);
    } catch {
      return this.rejectDelayTestFailed();
    }
  }

  private async cancelActiveDelayRecord(record: ActiveDelayRecord): Promise<ProxyDelayResult> {
    if (record.route === 'RUNNING') {
      const result: ProxyDelayResult = await this.commandBus.submitCancelDelayTest(
        createVpnProxyCancelDelayTestCommand(record.identity, record.generation, record.jobId)
      );
      if (result.kind === 'REJECTED') {
        return cloneProxyDelayResult(result);
      }
      try {
        return this.publishValidatedRunningDelay(record, result, true);
      } catch {
        return this.rejectDelayTestFailed();
      }
    }
    let snapshot: CoreProxyDelaySnapshot;
    try {
      snapshot = await this.coreProxy.cancelProxyDelayTest(record.jobId);
    } catch {
      return this.rejectDelayTestFailed();
    }
    try {
      const result: ProxyDelaySnapshotResult = this.validateStoppedDelaySnapshot(
        record.identity,
        this.createStoppedContextValue(record),
        record.groupName,
        snapshot,
        record.jobId
      );
      return this.publishValidatedDelay(record, result, true);
    } catch {
      return this.rejectDelayTestFailed();
    }
  }

  private async drainDelayTestInsideQueue(): Promise<ProxyRejectedResult | undefined> {
    const record: ActiveDelayRecord | undefined = this.activeDelayRecord;
    if (record === undefined) {
      return undefined;
    }
    if (record.route === 'RUNNING' && !(await this.isDelayIdentityCurrent(record.identity))) {
      this.retireRunningDelayRecord(record);
      return undefined;
    }
    const result: ProxyDelayResult = await this.cancelActiveDelayRecord(record);
    if (result.kind === 'SNAPSHOT' && this.isTerminalDelayState(result.state)) {
      return undefined;
    }
    return this.rejectDelayDrainFailed();
  }

  private async tryReadFinalDelayResult(jobId: string): Promise<ProxyDelayResult | undefined> {
    const finalResult: ProxyDelaySnapshotResult | undefined = this.finalDelayResult;
    if (finalResult === undefined || finalResult.jobId !== jobId) {
      return undefined;
    }
    if (!(await this.isDelayIdentityCurrent(finalResult.identity))) {
      this.clearFinalDelayResult();
      return this.rejectSessionChanged();
    }
    return cloneProxyDelaySnapshotResult(finalResult);
  }

  private async isDelayIdentityCurrent(identity: ProxyRuntimeIdentity): Promise<boolean> {
    const currentIdentity: ProxyRuntimeIdentity | undefined = await this.resolveCurrentIdentityReference();
    return currentIdentity !== undefined && sameIdentity(currentIdentity, identity);
  }

  private async resolveCurrentIdentityReference(): Promise<ProxyRuntimeIdentity | undefined> {
    let active: ActiveProxyProfile | undefined;
    try {
      active = await this.activeProfile.resolve();
    } catch {
      return undefined;
    }
    if (active === undefined) {
      return undefined;
    }
    const snapshot: VpnRuntimeSnapshot = this.vpnSnapshotPort.snapshot();
    const activeRequest = snapshot.activeRequest;
    if (activeRequest !== null &&
      (activeRequest.profileId !== active.profileId || activeRequest.versionId !== active.revisionId)) {
      return undefined;
    }
    if (snapshot.state === 'RUNNING') {
      if (activeRequest === null) {
        return undefined;
      }
      return createProxyRuntimeIdentity(
        active.profileId,
        active.revisionId,
        active.revisionHash,
        activeRequest.sessionId
      );
    }
    if (snapshot.state === 'STOPPED' && activeRequest === null) {
      return createProxyRuntimeIdentity(
        active.profileId,
        active.revisionId,
        active.revisionHash,
        null
      );
    }
    return undefined;
  }

  private createStoppedContextValue(record: ActiveDelayRecord): CoreProxyQueryContext {
    return new StoppedCoreQueryContextValue(
      record.profileHash,
      record.revisionHash,
      record.sessionHash,
      record.generation
    );
  }

  private admitRunningDelaySnapshot(
    identity: ProxyRuntimeIdentity,
    generation: number,
    groupName: string,
    result: ProxyDelaySnapshotResult
  ): ProxyDelayResult {
    if (!sameIdentity(result.identity, identity) ||
      result.generation !== generation ||
      result.groupName !== groupName) {
      return this.rejectDelayTestFailed();
    }
    return this.admitDelaySnapshot({
      jobId: result.jobId,
      identity: createProxyRuntimeIdentity(
        identity.profileId,
        identity.revisionId,
        identity.revisionHash,
        identity.sessionId
      ),
      profileHash: '',
      revisionHash: identity.revisionHash,
      sessionHash: identity.sessionId,
      generation,
      groupName,
      route: 'RUNNING',
      lastSnapshot: cloneProxyDelaySnapshotResult(result),
      finalizing: false,
      finalized: false
    }, result);
  }

  private publishValidatedRunningDelay(
    record: ActiveDelayRecord,
    result: ProxyDelaySnapshotResult,
    requireTerminal: boolean
  ): ProxyDelayResult {
    if (!sameIdentity(result.identity, record.identity) ||
      result.generation !== record.generation ||
      result.groupName !== record.groupName ||
      result.jobId !== record.jobId) {
      throw new Error('Delay identity mismatch.');
    }
    return this.publishValidatedDelay(record, result, requireTerminal);
  }

  private publishValidatedDelay(
    record: ActiveDelayRecord,
    result: ProxyDelaySnapshotResult,
    requireTerminal: boolean
  ): ProxyDelayResult {
    if (requireTerminal && !this.isTerminalDelayState(result.state)) {
      return this.rejectDelayTestFailed();
    }
    record.lastSnapshot = cloneProxyDelaySnapshotResult(result);
    if (this.isTerminalDelayState(result.state)) {
      return this.finalizeDelayRecord(record, result);
    }
    this.activeDelayRecord = record;
    return cloneProxyDelaySnapshotResult(result);
  }

  private admitDelaySnapshot(record: ActiveDelayRecord, result: ProxyDelaySnapshotResult): ProxyDelayResult {
    this.clearFinalDelayResult();
    record.lastSnapshot = cloneProxyDelaySnapshotResult(result);
    record.finalizing = false;
    record.finalized = false;
    if (this.isTerminalDelayState(result.state)) {
      return this.finalizeDelayRecord(record, result);
    }
    this.activeDelayRecord = record;
    return cloneProxyDelaySnapshotResult(result);
  }

  private finalizeDelayRecord(record: ActiveDelayRecord, result: ProxyDelaySnapshotResult): ProxyDelayResult {
    if (!record.finalized) {
      record.finalizing = true;
      record.lastSnapshot = cloneProxyDelaySnapshotResult(result);
      this.finalDelayResult = cloneProxyDelaySnapshotResult(result);
      this.finalDelayIdentityKey = this.buildRouteIdentityKey(result.identity);
      this.activeDelayRecord = undefined;
      record.finalized = true;
      record.finalizing = false;
      record.lease?.release();
      record.lease = undefined;
    }
    return cloneProxyDelaySnapshotResult(record.lastSnapshot);
  }

  private clearFinalDelayResult(): void {
    this.finalDelayResult = undefined;
    this.finalDelayIdentityKey = undefined;
  }

  private retireRunningDelayRecord(record: ActiveDelayRecord): void {
    if (this.activeDelayRecord !== undefined &&
      this.activeDelayRecord.jobId === record.jobId &&
      sameIdentity(this.activeDelayRecord.identity, record.identity)) {
      this.activeDelayRecord = undefined;
    }
    const finalResult: ProxyDelaySnapshotResult | undefined = this.finalDelayResult;
    if (finalResult !== undefined &&
      finalResult.jobId === record.jobId &&
      sameIdentity(finalResult.identity, record.identity)) {
      this.clearFinalDelayResult();
    }
    record.finalizing = false;
    record.finalized = true;
    record.lease = undefined;
  }

  private validateStoppedDelaySnapshot(
    identity: ProxyRuntimeIdentity,
    context: CoreProxyQueryContext,
    expectedGroupName: string,
    snapshot: CoreProxyDelaySnapshot,
    expectedJobId?: string
  ): ProxyDelaySnapshotResult {
    if (snapshot.profileHash !== context.profileHash ||
      snapshot.revisionHash !== context.revisionHash ||
      snapshot.sessionHash !== context.sessionHash ||
      snapshot.generation !== context.generation ||
      snapshot.groupName !== expectedGroupName ||
      (expectedJobId !== undefined && snapshot.jobId !== expectedJobId)) {
      throw new Error('Delay context mismatch.');
    }
    return createProxyDelaySnapshotResultFromCoreSnapshot(identity, context.generation, expectedGroupName, snapshot);
  }

  private isTerminalDelayState(state: string): boolean {
    return state === 'COMPLETED' || state === 'CANCELLED' || state === 'FAILED';
  }

  private async resolveRouting(): Promise<RoutingResolution> {
    let active: ActiveProxyProfile | undefined;
    try {
      active = await this.activeProfile.resolve();
    } catch {
      return {
        kind: 'REJECTED',
        rejected: this.rejectProfileUnavailable()
      };
    }
    if (active === undefined) {
      return {
        kind: 'REJECTED',
        rejected: this.rejectProfileUnavailable()
      };
    }
    const snapshot: VpnRuntimeSnapshot = this.vpnSnapshotPort.snapshot();
    const activeRequest = snapshot.activeRequest;
    if (activeRequest !== null &&
      (activeRequest.profileId !== active.profileId || activeRequest.versionId !== active.revisionId)) {
      return {
        kind: 'REJECTED',
        rejected: this.rejectSessionChanged()
      };
    }
    if (snapshot.state === 'RUNNING') {
      if (activeRequest === null) {
        return {
          kind: 'REJECTED',
          rejected: this.rejectRuntimeNotReady()
        };
      }
      const identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity(
        active.profileId,
        active.revisionId,
        active.revisionHash,
        activeRequest.sessionId
      );
      this.synchronizeLatestSnapshots(identity);
      return {
        kind: 'RUNNING',
        active,
        identity
      };
    }
    if (snapshot.state === 'STOPPED') {
      const lease: VpnStoppedProxyLease | undefined = this.vpnSnapshotPort.acquireStoppedProxyLease();
      if (lease === undefined) {
        return {
          kind: 'REJECTED',
          rejected: this.rejectRuntimeNotReady()
        };
      }
      const leasedSnapshot: VpnRuntimeSnapshot = lease.snapshot();
      if (leasedSnapshot.activeRequest !== null) {
        return {
          kind: 'REJECTED',
          rejected: this.rejectSessionChanged(),
          lease
        };
      }
      if (leasedSnapshot.state !== 'STOPPED') {
        return {
          kind: 'REJECTED',
          rejected: this.rejectRuntimeNotReady(),
          lease
        };
      }
      const identity: ProxyRuntimeIdentity = createProxyRuntimeIdentity(
        active.profileId,
        active.revisionId,
        active.revisionHash,
        null
      );
      this.synchronizeLatestSnapshots(identity);
      return {
        kind: 'STOPPED',
        active,
        identity,
        lease
      };
    }
    return {
      kind: 'REJECTED',
      rejected: this.rejectRuntimeNotReady()
    };
  }

  private async queryStoppedGroups(
    active: ActiveProxyProfile,
    identity: ProxyRuntimeIdentity,
    generation: number
  ): Promise<ProxyGroupListQueryResult> {
    let context: CoreProxyQueryContext;
    try {
      context = await this.createStoppedContext(active, generation);
    } catch {
      return this.rejectQueryFailed();
    }
    try {
      await this.coreProxy.loadConfiguration(active.configPath);
    } catch {
      return this.rejectRuntimeNotReady();
    }
    try {
      const result = await this.coreProxy.queryProxyGroups(context, true);
      return createProxyGroupListQuerySnapshot(identity, generation, result.groups);
    } catch {
      return this.rejectQueryFailed();
    }
  }

  private async queryRunningGroup(
    identity: ProxyRuntimeIdentity,
    groupName: string,
    generation: number,
    groupPath?: string[]
  ): Promise<ProxyGroupQueryResult> {
    const result: ProxyGroupQueryResult = await this.commandBus.submitQueryGroup(
      createVpnProxyQueryGroupCommand(identity, generation, groupName, groupPath)
    );
    if (result.kind === 'REJECTED') {
      return result;
    }
    const snapshot: ProxyGroupSnapshot = createProxyGroupSnapshot(identity, generation, result.snapshot.group);
    this.storeLatestSnapshot(snapshot, groupPath);
    return createProxyGroupQuerySnapshot(snapshot);
  }

  private async queryStoppedGroup(
    active: ActiveProxyProfile,
    identity: ProxyRuntimeIdentity,
    groupName: string,
    generation: number,
    shouldLoadConfiguration: boolean,
    groupPath?: string[]
  ): Promise<ProxyGroupQueryResult> {
    let context: CoreProxyQueryContext;
    try {
      context = await this.createStoppedContext(active, generation);
    } catch {
      return this.rejectQueryFailed();
    }
    if (shouldLoadConfiguration) {
      try {
        await this.coreProxy.loadConfiguration(active.configPath);
      } catch {
        return this.rejectRuntimeNotReady();
      }
    }
    try {
      const result = await this.coreProxy.queryProxyGroup(context, groupName);
      const snapshot: ProxyGroupSnapshot = createProxyGroupSnapshot(identity, generation, result.group);
      this.storeLatestSnapshot(snapshot, groupPath);
      return createProxyGroupQuerySnapshot(snapshot);
    } catch {
      return this.rejectQueryFailed();
    }
  }

  private async createStoppedContext(active: ActiveProxyProfile, generation: number): Promise<CoreProxyQueryContext> {
    const profileHash: string = await this.hasher.sha256(active.profileId);
    return new StoppedCoreQueryContextValue(profileHash, active.revisionHash, null, generation);
  }

  private findLatestGroupSnapshot(
    identity: ProxyRuntimeIdentity,
    groupName: string,
    groupPath?: string[]
  ): ProxyGroupSnapshot | undefined {
    const snapshot: ProxyGroupSnapshot | undefined =
      this.latestGroupSnapshots.get(this.buildSnapshotKey(identity, groupName, groupPath));
    if (snapshot === undefined) {
      return undefined;
    }
    if (!sameIdentity(snapshot.identity, identity)) {
      return undefined;
    }
    return createProxyGroupSnapshot(snapshot.identity, snapshot.generation, snapshot.group);
  }

  private storeLatestSnapshot(snapshot: ProxyGroupSnapshot, groupPath?: string[]): void {
    this.latestGroupSnapshots.set(
      this.buildSnapshotKey(snapshot.identity, snapshot.group.name, groupPath),
      createProxyGroupSnapshot(snapshot.identity, snapshot.generation, snapshot.group)
    );
  }

  private buildSnapshotKey(identity: ProxyRuntimeIdentity, groupName: string, groupPath?: string[]): string {
    const sessionPart: string = identity.sessionId === null ? '<null>' : identity.sessionId;
    const pathPart: string = groupPath === undefined || groupPath.length === 0
      ? groupName
      : groupPath.join('\u0000');
    return `${identity.profileId}\u0000${identity.revisionId}\u0000${sessionPart}\u0000${pathPart}`;
  }

  private hasTerminalMember(snapshot: ProxyGroupSnapshot, memberName: string): boolean {
    for (let index: number = 0; index < snapshot.group.nodes.length; index += 1) {
      if (snapshot.group.nodes[index].name === memberName && !snapshot.group.nodes[index].isGroup) {
        return true;
      }
    }
    return false;
  }

  private nextGeneration(): number | undefined {
    if (this.generationValue >= Number.MAX_SAFE_INTEGER) {
      return undefined;
    }
    this.generationValue += 1;
    return this.generationValue;
  }

  private resolveQueryGeneration(routing: RoutingResolution): number | undefined {
    if (routing.kind !== 'RUNNING') {
      this.runningGenerationBinding = undefined;
      return this.nextGeneration();
    }
    const authoritativeGeneration: number | undefined = this.commandBus.activeSessionGeneration(routing.identity!);
    if (authoritativeGeneration !== undefined) {
      if (authoritativeGeneration > this.generationValue) {
        this.generationValue = authoritativeGeneration;
      }
      this.runningGenerationBinding = {
        identity: createProxyRuntimeIdentity(
          routing.identity!.profileId,
          routing.identity!.revisionId,
          routing.identity!.revisionHash,
          routing.identity!.sessionId
        ),
        generation: authoritativeGeneration
      };
      return authoritativeGeneration;
    }
    const cached: RunningGenerationBinding | undefined = this.runningGenerationBinding;
    if (cached !== undefined && sameIdentity(cached.identity, routing.identity!)) {
      return cached.generation;
    }
    const generation: number | undefined = this.nextGeneration();
    if (generation === undefined) {
      return undefined;
    }
    this.runningGenerationBinding = {
      identity: createProxyRuntimeIdentity(
        routing.identity!.profileId,
        routing.identity!.revisionId,
        routing.identity!.revisionHash,
        routing.identity!.sessionId
      ),
      generation
    };
    return generation;
  }

  private synchronizeLatestSnapshots(identity: ProxyRuntimeIdentity): void {
    const nextIdentityKey: string = this.buildRouteIdentityKey(identity);
    if (this.currentRouteIdentityKey === nextIdentityKey) {
      return;
    }
    this.currentRouteIdentityKey = nextIdentityKey;
    if (this.finalDelayIdentityKey !== undefined && this.finalDelayIdentityKey !== nextIdentityKey) {
      this.clearFinalDelayResult();
    }
    this.latestGroupSnapshots.clear();
  }

  private buildRouteIdentityKey(identity: ProxyRuntimeIdentity): string {
    const sessionPart: string = identity.sessionId === null ? '<null>' : identity.sessionId;
    return `${identity.profileId}\u0000${identity.revisionId}\u0000${sessionPart}`;
  }

  private rejectProfileUnavailable(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_PROFILE_UNAVAILABLE', false, this.clock.now())
    );
  }

  private rejectRuntimeNotReady(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_RUNTIME_NOT_READY', false, this.clock.now())
    );
  }

  private rejectSelectionStale(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_SELECTION_STALE', false, this.clock.now())
    );
  }

  private rejectQueryFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_QUERY_FAILED', true, this.clock.now())
    );
  }

  private rejectPersistenceFailed(): ProxyRejectedResult {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_PERSISTENCE_FAILED', false, this.clock.now())
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
