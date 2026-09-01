import {
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcTransportErrorCode
} from './VpnRpcModels';
import {
  createVpnRpcCatalogDigestPayload,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcGroupNode,
  createVpnRpcGroupRef,
  createVpnRpcPingSuccessPayload,
  createVpnRpcQueryGroupPayload,
  createVpnRpcQueryGroupsPayload,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnRpcRuntimeModePayload,
  createVpnRpcSelectNodeResultPayload,
  type VpnRpcDelayGroupRequestPayload,
  type VpnRpcDelayJobRequestPayload,
  type VpnRpcDelayResult,
  type VpnRpcDelaySnapshotPayload,
  type VpnRpcGroupNode,
  type VpnRpcGroupRef,
  type VpnRpcPayload,
  type VpnRpcQueryGroupRequestPayload,
  type VpnRpcRuntimeModePayload,
  type VpnRpcSelectNodeRequestPayload
} from './VpnRpcPayloads';
import { encodeVpnRpcLowercaseHex } from './VpnRpcBinaryCodec';
import type {
  VpnRpcCancelableTaskPort,
  VpnRpcRandomPort,
  VpnRpcRuntimeDispatchPort,
  VpnRpcSchedulerPort
} from './VpnRpcPorts';
import type { VpnRpcServerSessionPort } from './VpnRpcServerSession';
import type { VpnOpaqueCatalog, VpnOpaqueCatalogEntry } from './VpnOpaqueCatalog';
import type {
  ProxyDelayNodeResult,
  ProxyDelayResult,
  ProxyDelaySnapshotResult
} from '../../proxy/ProxyDelayModels';
import type {
  ProxyGroupListQueryResult,
  ProxyGroupQueryResult,
  ProxyRejectedResult,
  ProxyRuntimeIdentity,
  ProxySelectionResult
} from '../../proxy/ProxyModels';
import type { CoreProxyNodeSummary } from '../../core/CoreProxyModels';
import type { CoreRuntimeMode } from '../../core/CoreModels';
import type {
  VpnProxyCancelDelayTestCommand,
  VpnProxyQueryGroupCommand,
  VpnProxyQueryGroupsCommand,
  VpnProxyReadDelayTestCommand,
  VpnProxySelectCommand,
  VpnProxyStartDelayTestCommand
} from '../../proxy/ProxyPorts';
import type {
  VpnControllerStopResult,
  VpnRuntimeSnapshot
} from '../VpnModels';

const DEFAULT_SERVER_INSTANCE: string = '00000000000000000000000000000000';
const DELAY_POLL_INTERVAL_MS: number = 250;
const MAX_DELAY_DRAIN_READS: number = 8;

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue: ((value: T) => void) | null = null;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void): void => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }
}

class SerialGate {
  private tail: Promise<void> = Promise.resolve();

  async runExclusive<T>(runner: () => Promise<T>): Promise<T> {
    const waitFor: Promise<void> = this.tail;
    const release: DeferredValue<void> = new DeferredValue<void>();
    this.tail = release.promise;
    await waitFor;
    try {
      return await runner();
    } finally {
      release.resolve();
    }
  }
}

class RpcGuardFailure extends Error {
  readonly code: VpnRpcTransportErrorCode;
  readonly retryable: boolean;

  constructor(code: VpnRpcTransportErrorCode, retryable: boolean) {
    super(code);
    this.code = code;
    this.retryable = retryable;
  }
}

interface ActiveRuntimeContext {
  token: number;
  profileHash: string;
  revisionHash: string;
  catalogDigest: string;
  profileId: string;
  revisionId: string;
  sessionId: string;
  generation: number;
  catalog: VpnOpaqueCatalog;
}

interface RpcErrorMapping {
  code: VpnRpcTransportErrorCode;
  retryable: boolean;
}

interface RuntimeTrafficCounters {
  txBytes: number;
  rxBytes: number;
}

interface DelaySnapshotAcceptance {
  payload: VpnRpcDelaySnapshotPayload;
  changed: boolean;
}

interface DelayJobState {
  contextToken: number;
  profileHash: string;
  revisionHash: string;
  catalogDigest: string;
  sessionId: string;
  generation: number;
  groupId: string;
  groupName: string;
  rpcJobId: string;
  coreJobId: string;
  payload: VpnRpcDelaySnapshotPayload;
  fingerprint: string;
  terminal: boolean;
  monitorToken: number;
  readGate: SerialGate;
  pollTask: VpnRpcCancelableTaskPort | null;
  readInFlight: boolean;
}

class ProxyRuntimeIdentityValue implements ProxyRuntimeIdentity {
  profileId: string;
  revisionId: string;
  revisionHash: string;
  sessionId: string | null;

  constructor(profileId: string, revisionId: string, revisionHash: string, sessionId: string) {
    this.profileId = profileId;
    this.revisionId = revisionId;
    this.revisionHash = revisionHash;
    this.sessionId = sessionId;
  }
}

class QueryGroupsCommandValue implements VpnProxyQueryGroupsCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  selectableOnly: boolean;

  constructor(identity: ProxyRuntimeIdentity, generation: number, selectableOnly: boolean) {
    this.identity = identity;
    this.generation = generation;
    this.selectableOnly = selectableOnly;
  }
}

class QueryGroupCommandValue implements VpnProxyQueryGroupCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;

  constructor(identity: ProxyRuntimeIdentity, generation: number, groupName: string) {
    this.identity = identity;
    this.generation = generation;
    this.groupName = groupName;
  }
}

class SelectCommandValue implements VpnProxySelectCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;
  memberName: string;

  constructor(identity: ProxyRuntimeIdentity, generation: number, groupName: string, memberName: string) {
    this.identity = identity;
    this.generation = generation;
    this.groupName = groupName;
    this.memberName = memberName;
  }
}

class StartDelayCommandValue implements VpnProxyStartDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  groupName: string;

  constructor(identity: ProxyRuntimeIdentity, generation: number, groupName: string) {
    this.identity = identity;
    this.generation = generation;
    this.groupName = groupName;
  }
}

class ReadDelayCommandValue implements VpnProxyReadDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  jobId: string;

  constructor(identity: ProxyRuntimeIdentity, generation: number, jobId: string) {
    this.identity = identity;
    this.generation = generation;
    this.jobId = jobId;
  }
}

class CancelDelayCommandValue implements VpnProxyCancelDelayTestCommand {
  identity: ProxyRuntimeIdentity;
  generation: number;
  jobId: string;

  constructor(identity: ProxyRuntimeIdentity, generation: number, jobId: string) {
    this.identity = identity;
    this.generation = generation;
    this.jobId = jobId;
  }
}

function readRuntimeTrafficCounters(snapshot: VpnRuntimeSnapshot): RuntimeTrafficCounters {
  const counters = snapshot.tunSnapshot?.counters;
  return {
    txBytes: counters?.txBytes ?? 0,
    rxBytes: counters?.rxBytes ?? 0
  };
}

function zeroBytes(bytes: Uint8Array): void {
  for (let index: number = 0; index < bytes.length; index += 1) {
    bytes[index] = 0;
  }
}

export interface VpnRpcServerPort {
  listen(): Promise<void>;
  handleRequest(request: VpnRpcBody): Promise<VpnRpcBody>;
  publishRuntimeChanged(snapshot: VpnRuntimeSnapshot): Promise<boolean>;
  close(): Promise<void>;
}

export class VpnRpcServer implements VpnRpcServerPort {
  private readonly session: VpnRpcServerSessionPort;
  private readonly runtime: VpnRpcRuntimeDispatchPort;
  private readonly scheduler: VpnRpcSchedulerPort;
  private readonly random: VpnRpcRandomPort;
  private readonly serverInstance: string;
  private readonly mutationGate: SerialGate = new SerialGate();
  private closed: boolean = false;
  private closePromise: Promise<void> | null = null;
  private activeContext: ActiveRuntimeContext | null = null;
  private delayJob: DelayJobState | null = null;
  private delayDrainPromise: Promise<void> | null = null;
  private settledSnapshot: VpnRuntimeSnapshot | null = null;
  private stopInProgress: boolean = false;
  private nextContextToken: number = 0;
  private nextDelayRevision: number = 0;
  private nextMonitorToken: number = 0;
  private nextStopToken: number = 0;
  private currentStopToken: number = 0;

  constructor(
    session: VpnRpcServerSessionPort,
    runtime: VpnRpcRuntimeDispatchPort,
    scheduler: VpnRpcSchedulerPort,
    random: VpnRpcRandomPort,
    serverInstance: string = DEFAULT_SERVER_INSTANCE
  ) {
    this.session = session;
    this.runtime = runtime;
    this.scheduler = scheduler;
    this.random = random;
    this.serverInstance = serverInstance;
  }

  async listen(): Promise<void> {
    await this.session.listen();
  }

  async handleRequest(request: VpnRpcBody): Promise<VpnRpcBody> {
    if (this.closed) {
      return this.createErrorResponse(request, 'SERVER_STOPPING', true);
    }
    if (this.stopInProgress) {
      return this.createErrorResponse(request, 'SERVER_STOPPING', true);
    }
    try {
      switch (request.method) {
        case 'PING':
          return this.createSuccessResponse(request, createVpnRpcPingSuccessPayload(this.serverInstance));
        case 'GET_SNAPSHOT':
          return await this.handleGetSnapshot(request);
        case 'GET_CATALOG_DIGEST':
          return await this.handleGetCatalogDigest(request);
        case 'GET_MODE':
          return await this.handleGetMode(request);
        case 'SET_MODE':
          return await this.handleSerializedMutation(request, async (): Promise<VpnRpcBody> => {
            return await this.handleSetMode(request);
          });
        case 'QUERY_GROUPS':
          return await this.handleQueryGroups(request);
        case 'QUERY_GROUP':
          return await this.handleQueryGroup(request);
        case 'SELECT_NODE':
          return await this.handleSerializedMutation(request, async (): Promise<VpnRpcBody> => {
            return await this.handleSelectNode(request);
          });
        case 'START_DELAY_TEST':
          return await this.handleSerializedMutation(request, async (): Promise<VpnRpcBody> => {
            return await this.handleStartDelayTest(request);
          });
        case 'READ_DELAY_TEST':
          return await this.handleReadDelayTest(request);
        case 'CANCEL_DELAY_TEST':
          return await this.handleSerializedMutation(request, async (): Promise<VpnRpcBody> => {
            return await this.handleCancelDelayTest(request);
          });
        case 'STOP_VPN':
          return await this.handleSerializedMutation(request, async (): Promise<VpnRpcBody> => {
            return await this.handleStopVpn(request);
          });
        default:
          return this.createErrorResponse(request, 'CORE_OPERATION_FAILED', false);
      }
    } catch (error) {
      if (error instanceof RpcGuardFailure) {
        return this.createErrorResponse(request, error.code, error.retryable);
      }
      return this.createErrorResponse(request, 'CORE_OPERATION_FAILED', false);
    }
  }

  async publishRuntimeChanged(snapshot: VpnRuntimeSnapshot): Promise<boolean> {
    if (this.closed || this.stopInProgress) {
      return false;
    }
    let context: ActiveRuntimeContext | null = null;
    try {
      context = this.resolveContextForRuntimeEvent(snapshot);
    } catch {
      return false;
    }
    if (context === null) {
      return false;
    }
    const payload: VpnRpcPayload = this.createRuntimeSnapshotPayload(snapshot, context);
    try {
      return await this.session.publishEvent(
        'RUNTIME_CHANGED',
        context.generation,
        createVpnRpcGuards(context.profileHash, context.revisionHash, context.catalogDigest),
        payload
      );
    } catch {
      return false;
    }
  }

  async close(): Promise<void> {
    if (this.closePromise !== null) {
      return await this.closePromise;
    }
    const promise: Promise<void> = this.closeInternal().finally((): void => {
      if (this.closePromise === promise) {
        this.closePromise = null;
      }
    });
    this.closePromise = promise;
    return await promise;
  }

  private async closeInternal(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const stoppingContext: ActiveRuntimeContext | null = this.detachActiveContext();
    await this.drainDelayJob(stoppingContext, false);
    this.invalidateDelayJob();
    await this.session.close();
  }

  private async handleGetSnapshot(request: VpnRpcBody): Promise<VpnRpcBody> {
    const snapshot: VpnRuntimeSnapshot = this.activeContext === null && this.settledSnapshot !== null
      ? this.settledSnapshot
      : this.runtime.snapshot();
    const context: ActiveRuntimeContext | null = this.refreshContextFromSnapshot(snapshot, 0);
    return this.createSuccessResponse(
      request,
      this.createRuntimeSnapshotPayload(snapshot, context),
      context === null ? 0 : context.generation,
      createVpnRpcGuards(null, null, null)
    );
  }

  private async handleGetCatalogDigest(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    return this.createSuccessResponse(
      request,
      createVpnRpcCatalogDigestPayload(context.catalogDigest, context.catalog.entryCount)
    );
  }

  private async handleGetMode(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    this.requireRuntimeReadyForMode();
    const queryMode: (() => Promise<CoreRuntimeMode>) | undefined = this.runtime.queryMode;
    if (queryMode === undefined) {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    const mode: CoreRuntimeMode = await this.runtime.queryMode!();
    this.requireStillCurrent(context);
    return this.createSuccessResponse(request, createVpnRpcRuntimeModePayload(mode));
  }

  private async handleSetMode(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    this.requireRuntimeReadyForMode();
    const setMode: ((mode: CoreRuntimeMode) => Promise<CoreRuntimeMode>) | undefined = this.runtime.setMode;
    if (setMode === undefined) {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    const payload: VpnRpcRuntimeModePayload = request.payload as VpnRpcRuntimeModePayload;
    const mode: CoreRuntimeMode = await this.runtime.setMode!(payload.mode);
    this.requireStillCurrent(context);
    return this.createSuccessResponse(request, createVpnRpcRuntimeModePayload(mode));
  }

  private requireRuntimeReadyForMode(): void {
    if (this.runtime.snapshot().state !== 'RUNNING') {
      throw new RpcGuardFailure('COMMAND_BUSY', true);
    }
  }

  private async handleQueryGroups(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const result: ProxyGroupListQueryResult = await this.runtime.queryGroups(
      new QueryGroupsCommandValue(this.createRuntimeIdentity(context), context.generation, true)
    );
    this.requireStillCurrent(context);
    if (result.kind === 'REJECTED') {
      const rejected: RpcErrorMapping = this.mapRejectedCode(result);
      return this.createErrorResponse(request, rejected.code, rejected.retryable);
    }
    const pools: Map<string, string[]> = this.buildTopLevelIdPools(context.catalog);
    const groups: VpnRpcGroupRef[] = [];
    for (let index: number = 0; index < result.groups.length; index += 1) {
      const group = result.groups[index];
      const groupId: string = this.takeMappedId(pools, group.name, group.type, 'GROUP');
      groups.push(createVpnRpcGroupRef(groupId, group.type, true));
    }
    return this.createSuccessResponse(request, createVpnRpcQueryGroupsPayload(context.generation, groups));
  }

  private async handleQueryGroup(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const payload: VpnRpcQueryGroupRequestPayload = request.payload as VpnRpcQueryGroupRequestPayload;
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, payload.groupId);
    const result: ProxyGroupQueryResult = await this.runtime.queryGroup(
      new QueryGroupCommandValue(this.createRuntimeIdentity(context), context.generation, groupEntry.localName)
    );
    this.requireStillCurrent(context);
    if (result.kind === 'REJECTED') {
      const rejected: RpcErrorMapping = this.mapRejectedCode(result);
      return this.createErrorResponse(request, rejected.code, rejected.retryable);
    }
    const selectedNodeId: string | null = this.findSelectedNodeId(groupEntry, result.snapshot.group.selectedName, result.snapshot.group.nodes);
    const nodes: VpnRpcGroupNode[] = this.mapGroupNodes(groupEntry, result.snapshot.group.nodes);
    return this.createSuccessResponse(
      request,
      createVpnRpcQueryGroupPayload(context.generation, groupEntry.id, selectedNodeId, nodes)
    );
  }

  private async handleSelectNode(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const payload: VpnRpcSelectNodeRequestPayload = request.payload as VpnRpcSelectNodeRequestPayload;
    if (payload.proxyGeneration !== context.generation) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, payload.groupId);
    const nodeEntry: VpnOpaqueCatalogEntry = this.requireChildEntry(context.catalog, groupEntry, payload.nodeId, 'TERMINAL');
    const result: ProxySelectionResult = await this.runtime.select(
      new SelectCommandValue(this.createRuntimeIdentity(context), context.generation, groupEntry.localName, nodeEntry.localName)
    );
    this.requireStillCurrent(context);
    if (result.kind === 'REJECTED') {
      const rejected: RpcErrorMapping = this.mapRejectedCode(result);
      return this.createErrorResponse(request, rejected.code, rejected.retryable);
    }
    if (result.kind !== 'APPLIED_NOW' && result.kind !== 'APPLIED_NOT_PERSISTED') {
      return this.createErrorResponse(request, 'CORE_OPERATION_FAILED', false);
    }
    const selectedNodeId: string | null = this.findSelectedNodeId(groupEntry, result.snapshot.group.selectedName, result.snapshot.group.nodes);
    return this.createSuccessResponse(
      request,
      createVpnRpcSelectNodeResultPayload(context.generation, groupEntry.id, selectedNodeId, result.kind === 'APPLIED_NOW')
    );
  }

  private async handleStartDelayTest(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const payload: VpnRpcDelayGroupRequestPayload = request.payload as VpnRpcDelayGroupRequestPayload;
    if (payload.proxyGeneration !== context.generation) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, payload.groupId);
    await this.cancelExistingDelayJobIfNeeded(context);
    const result: ProxyDelayResult = await this.runtime.startDelay(
      new StartDelayCommandValue(this.createRuntimeIdentity(context), context.generation, groupEntry.localName)
    );
    this.requireStillCurrent(context);
    if (result.kind === 'REJECTED') {
      const rejected: RpcErrorMapping = this.mapRejectedCode(result);
      return this.createErrorResponse(request, rejected.code, rejected.retryable);
    }
    const accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    const activeJob: DelayJobState | null = this.delayJob;
    if (activeJob === null) {
      return this.createErrorResponse(request, 'CORE_OPERATION_FAILED', false);
    }
    if (!this.scheduleDelayPollIfNeeded()) {
      return this.createSuccessResponse(request, this.failDelayJob(context, activeJob, false));
    }
    return this.createSuccessResponse(request, accepted.payload);
  }

  private async handleReadDelayTest(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const payload: VpnRpcDelayJobRequestPayload = request.payload as VpnRpcDelayJobRequestPayload;
    const job: DelayJobState | null = this.delayJob;
    if (job === null || job.generation !== context.generation || job.rpcJobId !== payload.jobId) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (job.terminal) {
      return this.createSuccessResponse(request, job.payload);
    }
    let result: ProxyDelayResult;
    try {
      result = await this.executeDelayRead(context, job);
    } catch {
      const failed: VpnRpcDelaySnapshotPayload | null = this.failDelayJobIfCurrent(context, job, true);
      if (failed !== null) {
        return this.createSuccessResponse(request, failed);
      }
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      const failed: VpnRpcDelaySnapshotPayload | null = this.failDelayJobIfCurrent(context, job, true);
      if (failed !== null) {
        return this.createSuccessResponse(request, failed);
      }
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    this.requireStillCurrent(context);
    this.requireStillCurrentDelayJob(job);
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    const accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    return this.createSuccessResponse(request, accepted.payload);
  }

  private async handleCancelDelayTest(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const payload: VpnRpcDelayJobRequestPayload = request.payload as VpnRpcDelayJobRequestPayload;
    const job: DelayJobState | null = this.delayJob;
    if (job === null || job.generation !== context.generation || job.rpcJobId !== payload.jobId) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (job.terminal) {
      return this.createSuccessResponse(request, job.payload);
    }
    this.cancelDelayPoll(job);
    let result: ProxyDelayResult;
    try {
      result = await this.executeDelayCancel(context, job);
    } catch {
      const failed: VpnRpcDelaySnapshotPayload | null = this.failDelayJobIfCurrent(context, job, true);
      if (failed !== null) {
        return this.createSuccessResponse(request, failed);
      }
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      const failed: VpnRpcDelaySnapshotPayload | null = this.failDelayJobIfCurrent(context, job, true);
      if (failed !== null) {
        return this.createSuccessResponse(request, failed);
      }
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    this.requireStillCurrent(context);
    this.requireStillCurrentDelayJob(job);
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    const accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    return this.createSuccessResponse(request, accepted.payload);
  }

  private async handleStopVpn(request: VpnRpcBody): Promise<VpnRpcBody> {
    const context: ActiveRuntimeContext = this.requireContextForRequest(request, true);
    const stopToken: number = this.beginStopOperation(context);
    const stoppingContext: ActiveRuntimeContext = this.detachSpecificContext(context);
    try {
      await this.drainDelayJob(stoppingContext, false);
      if (!this.isCurrentStopOperation(stopToken)) {
        return this.createErrorResponse(request, this.closed ? 'SERVER_STOPPING' : 'SESSION_CHANGED', true);
      }
      const stopResult: VpnControllerStopResult = await this.runtime.stop();
      if (!this.isCurrentStopOperation(stopToken)) {
        return this.createErrorResponse(request, this.closed ? 'SERVER_STOPPING' : 'SESSION_CHANGED', true);
      }
      if (this.hasReplacementContextSinceStop(stoppingContext)) {
        return this.createErrorResponse(request, 'SESSION_CHANGED', true);
      }
      this.settledSnapshot = stopResult.snapshot;
      const payload: VpnRpcPayload = this.createRuntimeSnapshotPayload(stopResult.snapshot, stoppingContext);
      await this.session.publishEvent(
        'RUNTIME_CHANGED',
        stoppingContext.generation,
        createVpnRpcGuards(stoppingContext.profileHash, stoppingContext.revisionHash, stoppingContext.catalogDigest),
        payload
      );
      return this.createSuccessResponse(request, payload);
    } finally {
      this.finishStopOperation(stopToken);
    }
  }

  private async handleSerializedMutation(request: VpnRpcBody, runner: () => Promise<VpnRpcBody>): Promise<VpnRpcBody> {
    return await this.mutationGate.runExclusive(async (): Promise<VpnRpcBody> => {
      if (this.closed) {
        return this.createErrorResponse(request, 'SERVER_STOPPING', true);
      }
      return await runner();
    });
  }

  private createRuntimeSnapshotPayload(snapshot: VpnRuntimeSnapshot, context: ActiveRuntimeContext | null): VpnRpcPayload {
    const counters: RuntimeTrafficCounters = readRuntimeTrafficCounters(snapshot);
    return createVpnRpcRuntimeSnapshotPayload(
      snapshot.state,
      context === null ? null : context.profileHash,
      context === null ? null : context.revisionHash,
      context === null ? null : context.catalogDigest,
      snapshot.notificationActive,
      snapshot.recoveryAttempt,
      snapshot.scheduledRetryDelayMs,
      snapshot.lastFailure === null ? null : snapshot.lastFailure.code,
      counters.txBytes,
      counters.rxBytes
    );
  }

  private resolveContextForRuntimeEvent(snapshot: VpnRuntimeSnapshot): ActiveRuntimeContext | null {
    const activeRequest = snapshot.activeRequest;
    if (activeRequest !== null) {
      const requestedGeneration: number = this.activeContext !== null && this.activeContext.generation > 0
        ? this.activeContext.generation
        : 1;
      return this.refreshContextFromSnapshot(snapshot, requestedGeneration);
    }
    if (snapshot.state !== 'STOPPED' && snapshot.state !== 'ERROR') {
      return null;
    }
    const current: ActiveRuntimeContext | null = this.activeContext;
    if (current === null) {
      this.settledSnapshot = snapshot;
      return null;
    }
    this.settledSnapshot = snapshot;
    return current;
  }

  private requireContextForRequest(request: VpnRpcBody, allowBootstrap: boolean): ActiveRuntimeContext {
    let context: ActiveRuntimeContext | null = this.activeContext;
    if (context === null && allowBootstrap) {
      context = this.refreshContextFromSnapshot(this.runtime.snapshot(), request.sessionGeneration);
    } else if (context !== null) {
      this.ensureCatalogStillMatches(context);
    }
    if (context === null) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (context.generation === 0 && request.sessionGeneration > 0) {
      context.generation = request.sessionGeneration;
      this.activeContext = context;
    }
    if (request.sessionGeneration !== context.generation) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (request.guards.profileHash !== context.profileHash || request.guards.revisionHash !== context.revisionHash) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    if (request.method === 'GET_CATALOG_DIGEST') {
      if (request.guards.catalogDigest !== null) {
        throw new RpcGuardFailure('CATALOG_MISMATCH', true);
      }
      return context;
    }
    if (request.guards.catalogDigest !== context.catalogDigest) {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    return context;
  }

  private refreshContextFromSnapshot(snapshot: VpnRuntimeSnapshot, requestedGeneration: number): ActiveRuntimeContext | null {
    if (this.stopInProgress) {
      return null;
    }
    const activeRequest = snapshot.activeRequest;
    if (activeRequest === null) {
      this.detachActiveContext();
      this.settledSnapshot = snapshot;
      return null;
    }
    this.settledSnapshot = null;
    const catalog: VpnOpaqueCatalog = this.readCatalog('CORE_OPERATION_FAILED');
    const nextContext: ActiveRuntimeContext = {
      token: this.allocateContextToken(),
      profileHash: catalog.profileHash,
      revisionHash: catalog.revisionHash,
      catalogDigest: catalog.catalogDigest,
      profileId: activeRequest.profileId,
      revisionId: activeRequest.versionId,
      sessionId: activeRequest.sessionId,
      generation: requestedGeneration,
      catalog
    };
    if (this.activeContext !== null &&
      this.activeContext.profileId === nextContext.profileId &&
      this.activeContext.revisionId === nextContext.revisionId &&
      this.activeContext.sessionId === nextContext.sessionId) {
      nextContext.token = this.activeContext.token;
      if (this.activeContext.generation > 0) {
        nextContext.generation = this.activeContext.generation;
      }
    } else {
      this.invalidateDelayJob();
    }
    this.activeContext = nextContext;
    return nextContext;
  }

  private readCatalog(onInvalidCode: VpnRpcTransportErrorCode): VpnOpaqueCatalog {
    let catalog: VpnOpaqueCatalog;
    try {
      catalog = this.runtime.catalog();
    } catch {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    try {
      createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
    } catch {
      throw new RpcGuardFailure(onInvalidCode, onInvalidCode === 'CATALOG_MISMATCH');
    }
    return catalog;
  }

  private ensureCatalogStillMatches(context: ActiveRuntimeContext): void {
    const catalog: VpnOpaqueCatalog = this.readCatalog('CATALOG_MISMATCH');
    if (catalog.profileHash !== context.profileHash ||
      catalog.revisionHash !== context.revisionHash ||
      catalog.catalogDigest !== context.catalogDigest) {
      this.detachSpecificContext(context);
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
  }

  private createRuntimeIdentity(context: ActiveRuntimeContext): ProxyRuntimeIdentity {
    return new ProxyRuntimeIdentityValue(
      context.profileId,
      context.revisionId,
      context.revisionHash,
      context.sessionId
    );
  }

  private requireGroupEntry(catalog: VpnOpaqueCatalog, groupId: string): VpnOpaqueCatalogEntry {
    const entry: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(groupId);
    if (entry === undefined || entry.kind !== 'GROUP') {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    return entry;
  }

  private requireChildEntry(
    catalog: VpnOpaqueCatalog,
    groupEntry: VpnOpaqueCatalogEntry,
    childId: string,
    kind: 'GROUP' | 'TERMINAL'
  ): VpnOpaqueCatalogEntry {
    let found: boolean = false;
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      if (groupEntry.childIds[index] === childId) {
        found = true;
        break;
      }
    }
    if (!found) {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    const child: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(childId);
    if (child === undefined || child.kind !== kind) {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    return child;
  }

  private buildTopLevelIdPools(catalog: VpnOpaqueCatalog): Map<string, string[]> {
    const pools: Map<string, string[]> = new Map<string, string[]>();
    const ids: string[] = catalog.topLevelGroupIds();
    for (let index: number = 0; index < ids.length; index += 1) {
      const entry: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(ids[index]);
      if (entry === undefined) {
        continue;
      }
      const key: string = this.buildEntryKey(entry.localName, entry.type, entry.kind);
      const values: string[] | undefined = pools.get(key);
      if (values === undefined) {
        pools.set(key, [entry.id]);
      } else {
        values.push(entry.id);
      }
    }
    return pools;
  }

  private buildChildIdPools(catalog: VpnOpaqueCatalog, groupEntry: VpnOpaqueCatalogEntry): Map<string, string[]> {
    const pools: Map<string, string[]> = new Map<string, string[]>();
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      const child: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(groupEntry.childIds[index]);
      if (child === undefined) {
        continue;
      }
      const key: string = this.buildEntryKey(child.localName, child.type, child.kind);
      const values: string[] | undefined = pools.get(key);
      if (values === undefined) {
        pools.set(key, [child.id]);
      } else {
        values.push(child.id);
      }
    }
    return pools;
  }

  private buildEntryKey(name: string, type: string, kind: string): string {
    return `${kind}:${type}:${name}`;
  }

  private takeMappedId(pools: Map<string, string[]>, name: string, type: string, kind: string): string {
    const values: string[] | undefined = pools.get(this.buildEntryKey(name, type, kind));
    if (values === undefined || values.length === 0) {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    const value: string | undefined = values.shift();
    if (value === undefined) {
      throw new RpcGuardFailure('CATALOG_MISMATCH', true);
    }
    return value;
  }

  private mapGroupNodes(groupEntry: VpnOpaqueCatalogEntry, nodes: CoreProxyNodeSummary[]): VpnRpcGroupNode[] {
    const context: ActiveRuntimeContext | null = this.activeContext;
    if (context === null) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
    const pools: Map<string, string[]> = this.buildChildIdPools(context.catalog, groupEntry);
    const mapped: VpnRpcGroupNode[] = [];
    for (let index: number = 0; index < nodes.length; index += 1) {
      const node: CoreProxyNodeSummary = nodes[index];
      const nodeId: string = this.takeMappedId(pools, node.name, node.type, node.isGroup ? 'GROUP' : 'TERMINAL');
      mapped.push(createVpnRpcGroupNode(nodeId, node.isGroup ? 'GROUP' : 'TERMINAL', node.type, node.selected));
    }
    return mapped;
  }

  private findSelectedNodeId(groupEntry: VpnOpaqueCatalogEntry, selectedName: string, nodes: CoreProxyNodeSummary[]): string | null {
    const mapped: VpnRpcGroupNode[] = this.mapGroupNodes(groupEntry, nodes);
    for (let index: number = 0; index < mapped.length; index += 1) {
      if (mapped[index].selected && nodes[index].name === selectedName) {
        return mapped[index].nodeId;
      }
    }
    return null;
  }

  private mapRejectedCode(result: ProxyRejectedResult): RpcErrorMapping {
    switch (result.error.code) {
      case 'VPN_SESSION_CHANGED':
        return { code: 'SESSION_CHANGED', retryable: true };
      case 'PROXY_SELECTION_STALE':
        return { code: 'CATALOG_MISMATCH', retryable: true };
      default:
        return { code: 'CORE_OPERATION_FAILED', retryable: false };
    }
  }

  private acceptDelaySnapshot(
    context: ActiveRuntimeContext,
    groupEntry: VpnOpaqueCatalogEntry,
    result: ProxyDelaySnapshotResult
  ): DelaySnapshotAcceptance {
    const previous: DelayJobState | null = this.delayJob;
    if (previous !== null &&
      previous.contextToken === context.token &&
      previous.groupId === groupEntry.id &&
      previous.generation === context.generation &&
      previous.coreJobId !== result.jobId) {
      this.retireDelayJob(previous);
    }
    const stablePrevious: DelayJobState | null = this.delayJob;
    const rpcJobId: string = stablePrevious !== null &&
      stablePrevious.contextToken === context.token &&
      stablePrevious.groupId === groupEntry.id &&
      stablePrevious.generation === context.generation &&
      stablePrevious.coreJobId === result.jobId
      ? stablePrevious.rpcJobId
      : this.allocateRpcJobId();
    const mappedNodes: VpnRpcDelayResult[] = this.mapDelayNodes(context.catalog, groupEntry, result.nodes);
    const fingerprint: string = this.buildDelayFingerprint(rpcJobId, result.state, mappedNodes);
    if (stablePrevious !== null &&
      stablePrevious.contextToken === context.token &&
      stablePrevious.groupId === groupEntry.id &&
      stablePrevious.generation === context.generation &&
      stablePrevious.coreJobId === result.jobId &&
      stablePrevious.fingerprint === fingerprint) {
      return { payload: stablePrevious.payload, changed: false };
    }
    const payload: VpnRpcDelaySnapshotPayload = createVpnRpcDelaySnapshotPayload(
      rpcJobId,
      this.allocateDelayRevision(),
      context.generation,
      groupEntry.id,
      result.state,
      result.totalCount,
      result.completedCount,
      mappedNodes
    );
    const nextJob: DelayJobState = {
      contextToken: context.token,
      profileHash: context.profileHash,
      revisionHash: context.revisionHash,
      catalogDigest: context.catalogDigest,
      sessionId: context.sessionId,
      generation: context.generation,
      groupId: groupEntry.id,
      groupName: groupEntry.localName,
      rpcJobId,
      coreJobId: result.jobId,
      payload,
      fingerprint,
      terminal: result.state === 'COMPLETED' || result.state === 'CANCELLED' || result.state === 'FAILED',
      monitorToken: stablePrevious !== null && stablePrevious.coreJobId === result.jobId
        ? stablePrevious.monitorToken
        : this.allocateMonitorToken(),
      readGate: stablePrevious !== null && stablePrevious.coreJobId === result.jobId
        ? stablePrevious.readGate
        : new SerialGate(),
      pollTask: stablePrevious !== null && stablePrevious.coreJobId === result.jobId
        ? stablePrevious.pollTask
        : null,
      readInFlight: false
    };
    if (nextJob.terminal) {
      this.cancelDelayPoll(nextJob);
    }
    this.delayJob = nextJob;
    return { payload, changed: true };
  }

  private mapDelayNodes(
    catalog: VpnOpaqueCatalog,
    groupEntry: VpnOpaqueCatalogEntry,
    nodes: ProxyDelayNodeResult[]
  ): VpnRpcDelayResult[] {
    const pools: Map<string, string[]> = this.buildChildIdPools(catalog, groupEntry);
    const results: VpnRpcDelayResult[] = [];
    for (let index: number = 0; index < nodes.length; index += 1) {
      const node: ProxyDelayNodeResult = nodes[index];
      const nodeId: string = this.takeMappedId(pools, node.name, node.type, 'TERMINAL');
      results.push(createVpnRpcDelayResult(nodeId, node.state, node.delayMs));
    }
    return results;
  }

  private buildDelayFingerprint(jobId: string, state: string, results: VpnRpcDelayResult[]): string {
    const parts: string[] = [jobId, state];
    for (let index: number = 0; index < results.length; index += 1) {
      parts.push(`${results[index].nodeId}:${results[index].status}:${results[index].delayMs === null ? 'null' : `${results[index].delayMs}`}`);
    }
    return parts.join('|');
  }

  private allocateContextToken(): number {
    if (this.nextContextToken >= Number.MAX_SAFE_INTEGER) {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    this.nextContextToken += 1;
    return this.nextContextToken;
  }

  private allocateDelayRevision(): number {
    if (this.nextDelayRevision >= Number.MAX_SAFE_INTEGER) {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    this.nextDelayRevision += 1;
    return this.nextDelayRevision;
  }

  private allocateMonitorToken(): number {
    if (this.nextMonitorToken >= Number.MAX_SAFE_INTEGER) {
      throw new RpcGuardFailure('CORE_OPERATION_FAILED', false);
    }
    this.nextMonitorToken += 1;
    return this.nextMonitorToken;
  }

  private allocateRpcJobId(): string {
    const sourceBytes: Uint8Array = this.random.bytes(32);
    const ownedBytes: Uint8Array = sourceBytes.slice();
    try {
      return encodeVpnRpcLowercaseHex(ownedBytes);
    } finally {
      zeroBytes(ownedBytes);
    }
  }

  private requireStillCurrent(context: ActiveRuntimeContext): void {
    if (this.closed || this.activeContext === null || this.activeContext.token !== context.token) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
  }

  private requireStillCurrentDelayJob(job: DelayJobState): void {
    if (this.delayJob === null ||
      this.delayJob !== job ||
      this.delayJob.monitorToken !== job.monitorToken ||
      this.delayJob.rpcJobId !== job.rpcJobId ||
      this.delayJob.coreJobId !== job.coreJobId) {
      throw new RpcGuardFailure('SESSION_CHANGED', true);
    }
  }

  private isCurrentDelayJob(context: ActiveRuntimeContext, job: DelayJobState): boolean {
    try {
      this.requireStillCurrent(context);
      this.requireStillCurrentDelayJob(job);
      return true;
    } catch {
      return false;
    }
  }

  private failDelayJobIfCurrent(
    context: ActiveRuntimeContext,
    job: DelayJobState,
    publishEvent: boolean
  ): VpnRpcDelaySnapshotPayload | null {
    if (!this.isCurrentDelayJob(context, job)) {
      return null;
    }
    return this.failDelayJob(context, job, publishEvent);
  }

  private scheduleDelayPollIfNeeded(): boolean {
    const job: DelayJobState | null = this.delayJob;
    if (job === null || job.terminal || this.closed || job.pollTask !== null) {
      return true;
    }
    try {
      job.pollTask = this.scheduler.schedule(DELAY_POLL_INTERVAL_MS, async (): Promise<void> => {
        await this.runScheduledDelayPoll(job.monitorToken);
      });
      return true;
    } catch {
      return false;
    }
  }

  private async runScheduledDelayPoll(token: number): Promise<void> {
    const job: DelayJobState | null = this.delayJob;
    const context: ActiveRuntimeContext | null = this.activeContext;
    if (job === null || context === null || this.closed || job.monitorToken !== token) {
      return;
    }
    job.pollTask = null;
    if (job.readInFlight) {
      this.scheduleDelayPollIfNeeded();
      return;
    }
    let result: ProxyDelayResult;
    try {
      result = await this.executeDelayRead(context, job);
    } catch {
      if (this.isCurrentDelayJob(context, job)) {
        this.failDelayJob(context, job, true);
      }
      return;
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      if (this.isCurrentDelayJob(context, job)) {
        this.failDelayJob(context, job, true);
      }
      return;
    }
    try {
      this.requireStillCurrent(context);
      this.requireStillCurrentDelayJob(job);
    } catch {
      return;
    }
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    const accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    if (accepted.changed) {
      const liveJob: DelayJobState | null = this.delayJob;
      if (liveJob !== null && !this.closed && liveJob.monitorToken === token) {
        await this.session.publishEvent(
          'DELAY_CHANGED',
          liveJob.generation,
          createVpnRpcGuards(liveJob.profileHash, liveJob.revisionHash, liveJob.catalogDigest),
          accepted.payload
        );
      }
    }
    this.scheduleDelayPollIfNeeded();
  }

  private async executeDelayRead(context: ActiveRuntimeContext, job: DelayJobState): Promise<ProxyDelayResult> {
    job.readInFlight = true;
    try {
      return await job.readGate.runExclusive(async (): Promise<ProxyDelayResult> => {
        return await this.runtime.readDelay(
          new ReadDelayCommandValue(this.createRuntimeIdentity(context), context.generation, job.coreJobId)
        );
      });
    } finally {
      job.readInFlight = false;
    }
  }

  private async executeDelayCancel(context: ActiveRuntimeContext, job: DelayJobState): Promise<ProxyDelayResult> {
    job.readInFlight = true;
    try {
      return await job.readGate.runExclusive(async (): Promise<ProxyDelayResult> => {
        return await this.runtime.cancelDelay(
          new CancelDelayCommandValue(this.createRuntimeIdentity(context), context.generation, job.coreJobId)
        );
      });
    } finally {
      job.readInFlight = false;
    }
  }

  private async cancelExistingDelayJobIfNeeded(context: ActiveRuntimeContext): Promise<void> {
    const job: DelayJobState | null = this.delayJob;
    if (job === null || job.terminal) {
      return;
    }
    if (job.sessionId !== context.sessionId || job.generation !== context.generation) {
      this.invalidateDelayJob();
      return;
    }
    this.retireDelayJob(job);
    let result: ProxyDelayResult;
    try {
      result = await this.executeDelayCancel(context, job);
    } catch {
      this.failDelayJob(context, job, false);
      return;
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      this.failDelayJob(context, job, false);
      return;
    }
    this.requireStillCurrent(context);
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    this.acceptDelaySnapshot(context, groupEntry, result);
  }

  private async drainDelayJob(context: ActiveRuntimeContext | null, publishEvent: boolean): Promise<void> {
    if (this.delayDrainPromise !== null) {
      return await this.delayDrainPromise;
    }
    const promise: Promise<void> = this.drainDelayJobInternal(context, publishEvent).finally((): void => {
      if (this.delayDrainPromise === promise) {
        this.delayDrainPromise = null;
      }
    });
    this.delayDrainPromise = promise;
    return await promise;
  }

  private async drainDelayJobInternal(context: ActiveRuntimeContext | null, publishEvent: boolean): Promise<void> {
    const job: DelayJobState | null = this.delayJob;
    if (context === null || job === null || job.terminal) {
      return;
    }
    this.retireDelayJob(job);
    if (job.readInFlight) {
      await this.cancelInFlightDelayJob(context, job, publishEvent);
      return;
    }
    let result: ProxyDelayResult;
    try {
      result = await this.executeDelayCancel(context, job);
    } catch {
      this.failDelayJob(context, job, publishEvent);
      return;
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      this.failDelayJob(context, job, publishEvent);
      return;
    }
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    let accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    let current: DelayJobState | null = this.delayJob;
    if (publishEvent && accepted.changed && current !== null) {
      await this.session.publishEvent(
        'DELAY_CHANGED',
        current.generation,
        createVpnRpcGuards(current.profileHash, current.revisionHash, current.catalogDigest),
        accepted.payload
      );
    }
    for (let readCount: number = 0; current !== null && !current.terminal && readCount < MAX_DELAY_DRAIN_READS; readCount += 1) {
      try {
        result = await this.executeDelayRead(context, current);
      } catch {
        this.failDelayJob(context, current, publishEvent);
        return;
      }
      if (result.kind === 'REJECTED' || result.jobId !== current.coreJobId) {
        this.failDelayJob(context, current, publishEvent);
        return;
      }
      accepted = this.acceptDelaySnapshot(context, groupEntry, result);
      current = this.delayJob;
      if (publishEvent && accepted.changed && current !== null) {
        await this.session.publishEvent(
          'DELAY_CHANGED',
          current.generation,
          createVpnRpcGuards(current.profileHash, current.revisionHash, current.catalogDigest),
          accepted.payload
        );
      }
    }
    if (current !== null && !current.terminal) {
      this.failDelayJob(context, current, publishEvent);
    }
  }

  private async cancelInFlightDelayJob(
    context: ActiveRuntimeContext,
    job: DelayJobState,
    publishEvent: boolean
  ): Promise<void> {
    let result: ProxyDelayResult;
    try {
      result = await this.runtime.cancelDelay(
        new CancelDelayCommandValue(this.createRuntimeIdentity(context), context.generation, job.coreJobId)
      );
    } catch {
      this.failDelayJob(context, job, publishEvent);
      return;
    }
    if (result.kind === 'REJECTED' || result.jobId !== job.coreJobId) {
      this.failDelayJob(context, job, publishEvent);
      return;
    }
    const groupEntry: VpnOpaqueCatalogEntry = this.requireGroupEntry(context.catalog, job.groupId);
    const accepted: DelaySnapshotAcceptance = this.acceptDelaySnapshot(context, groupEntry, result);
    const current: DelayJobState | null = this.delayJob;
    if (publishEvent && accepted.changed && current !== null) {
      await this.session.publishEvent(
        'DELAY_CHANGED',
        current.generation,
        createVpnRpcGuards(current.profileHash, current.revisionHash, current.catalogDigest),
        accepted.payload
      );
    }
    if (current !== null && !current.terminal) {
      this.failDelayJob(context, current, publishEvent);
    }
  }

  private detachActiveContext(): ActiveRuntimeContext | null {
    const current: ActiveRuntimeContext | null = this.activeContext;
    this.activeContext = null;
    return current;
  }

  private detachSpecificContext(context: ActiveRuntimeContext): ActiveRuntimeContext {
    if (this.activeContext !== null && this.activeContext.token === context.token) {
      this.activeContext = null;
    }
    return context;
  }

  private invalidateDelayJob(): void {
    const job: DelayJobState | null = this.delayJob;
    if (job === null) {
      return;
    }
    this.retireDelayJob(job);
    this.delayJob = null;
  }

  private retireDelayJob(job: DelayJobState): void {
    this.cancelDelayPoll(job);
    job.monitorToken = this.allocateMonitorToken();
  }

  private cancelDelayPoll(job: DelayJobState): void {
    if (job.pollTask === null) {
      return;
    }
    const task: VpnRpcCancelableTaskPort = job.pollTask;
    job.pollTask = null;
    task.cancel();
  }

  private failDelayJob(context: ActiveRuntimeContext, job: DelayJobState, publishEvent: boolean): VpnRpcDelaySnapshotPayload {
    this.cancelDelayPoll(job);
    const failedResults: VpnRpcDelayResult[] = [];
    for (let index: number = 0; index < job.payload.results.length; index += 1) {
      const node: VpnRpcDelayResult = job.payload.results[index];
      if (node.status === 'WAITING' || node.status === 'TESTING') {
        failedResults.push(createVpnRpcDelayResult(node.nodeId, 'FAILED', null));
      } else {
        failedResults.push(createVpnRpcDelayResult(node.nodeId, node.status, node.delayMs));
      }
    }
    const failedPayload: VpnRpcDelaySnapshotPayload = createVpnRpcDelaySnapshotPayload(
      job.rpcJobId,
      this.allocateDelayRevision(),
      job.payload.proxyGeneration,
      job.payload.groupId,
      'FAILED',
      job.payload.totalCount,
      job.payload.totalCount,
      failedResults
    );
    const failedJob: DelayJobState = {
      contextToken: context.token,
      profileHash: job.profileHash,
      revisionHash: job.revisionHash,
      catalogDigest: job.catalogDigest,
      sessionId: job.sessionId,
      generation: job.generation,
      groupId: job.groupId,
      groupName: job.groupName,
      rpcJobId: job.rpcJobId,
      coreJobId: job.coreJobId,
      payload: failedPayload,
      fingerprint: this.buildDelayFingerprint(job.rpcJobId, 'FAILED', failedResults),
      terminal: true,
      monitorToken: this.allocateMonitorToken(),
      readGate: job.readGate,
      pollTask: null,
      readInFlight: false
    };
    this.delayJob = failedJob;
    if (publishEvent && !this.closed && this.activeContext !== null && this.activeContext.token === context.token) {
      const pendingPublish: Promise<boolean> = this.session.publishEvent(
        'DELAY_CHANGED',
        failedJob.generation,
        createVpnRpcGuards(failedJob.profileHash, failedJob.revisionHash, failedJob.catalogDigest),
        failedPayload
      );
      pendingPublish.catch((): void => {});
    }
    return failedPayload;
  }

  private beginStopOperation(context: ActiveRuntimeContext): number {
    const token: number = this.nextStopToken + 1;
    this.nextStopToken = token;
    this.currentStopToken = token;
    this.stopInProgress = true;
    this.settledSnapshot = null;
    return token;
  }

  private isCurrentStopOperation(token: number): boolean {
    return this.stopInProgress && this.currentStopToken === token && !this.closed;
  }

  private finishStopOperation(token: number): void {
    if (this.currentStopToken !== token) {
      return;
    }
    this.stopInProgress = false;
  }

  private hasReplacementContextSinceStop(stoppingContext: ActiveRuntimeContext): boolean {
    const snapshot: VpnRuntimeSnapshot = this.runtime.snapshot();
    const activeRequest = snapshot.activeRequest;
    if (activeRequest === null) {
      return false;
    }
    if (activeRequest.profileId !== stoppingContext.profileId ||
      activeRequest.versionId !== stoppingContext.revisionId ||
      activeRequest.sessionId !== stoppingContext.sessionId) {
      return true;
    }
    try {
      const catalog: VpnOpaqueCatalog = this.readCatalog('CATALOG_MISMATCH');
      return catalog.profileHash !== stoppingContext.profileHash ||
        catalog.revisionHash !== stoppingContext.revisionHash ||
        catalog.catalogDigest !== stoppingContext.catalogDigest;
    } catch {
      return true;
    }
  }

  private createSuccessResponse(
    request: VpnRpcBody,
    payload: VpnRpcPayload,
    sessionGeneration: number = request.sessionGeneration,
    guards: VpnRpcGuards = request.guards
  ): VpnRpcBody {
    return createVpnRpcBodySuccessResponse(
      1,
      1,
      request.requestOrdinal!,
      request.requestId!,
      request.method,
      sessionGeneration,
      guards,
      payload
    );
  }

  private createErrorResponse(request: VpnRpcBody, code: VpnRpcTransportErrorCode, retryable: boolean): VpnRpcBody {
    return createVpnRpcBodyErrorResponse(
      1,
      1,
      request.requestOrdinal!,
      request.requestId!,
      request.method,
      request.sessionGeneration,
      request.guards,
      createVpnRpcError(code, retryable)
    );
  }
}
