import {
  getInternalNativeModule,
  wrapNativeAsync,
  type InternalNativeRuntimeEvent,
  type InternalTunNativeCaptureConfig,
  type InternalTunNativeModule,
  type InternalTunNativeSnapshot,
  type InternalTunNativeStartOptions,
  type InternalTunNativeTrace
} from './CoreNativeAdapter';
import {
  TunRuntimePortError,
  createTunRuntimeFailure,
  createTunRuntimeSnapshot,
  createVpnCounters,
  createVpnIngressTrace
} from '@cmfa/shared';
import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  TunHandle,
  TunRuntimeEvent,
  TunRuntimeFailure,
  TunRuntimeFailureCode,
  TunRuntimePort,
  TunRuntimeSnapshot,
  TunStartOptions,
  VpnIngressTrace
} from '@cmfa/shared';

const TUN_EVIDENCE_POLL_INTERVAL_MS: number = 250;

class CoreTunPollingTask implements CancelableDelayTask {
  private readonly timerId: number;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    clearTimeout(this.timerId);
  }
}

class CoreTunPollingScheduler implements BoundedDelaySchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const timerId: number = setTimeout(() => {
      void runner();
    }, delayMs);
    return new CoreTunPollingTask(timerId);
  }
}

export interface CoreTunRuntimeConfig {
  configPath: string;
  mixedPort: number;
  platformApiLevel: number;
  processProtected: boolean;
}

function cloneNativeTrace(trace: InternalTunNativeTrace): InternalTunNativeTrace {
  return {
    sequence: trace.sequence,
    sessionId: trace.sessionId,
    traceId: trace.traceId,
    ingress: trace.ingress,
    protocol: trace.protocol,
    sourceAddress: trace.sourceAddress,
    destinationAddress: trace.destinationAddress,
    hashedTuple: trace.hashedTuple,
    correlationHash: trace.correlationHash,
    destinationHash: trace.destinationHash,
    outboundTerminalHash: trace.outboundTerminalHash,
    outboundChainHash: trace.outboundChainHash,
    outboundChainLength: trace.outboundChainLength
  };
}

function cloneNativeTraces(traces: InternalTunNativeTrace[]): InternalTunNativeTrace[] {
  const clones: InternalTunNativeTrace[] = [];
  for (let index = 0; index < traces.length; index += 1) {
    clones.push(cloneNativeTrace(traces[index]));
  }
  return clones;
}

function fallbackTunFailureCode(operation: string): TunRuntimeFailureCode {
  if (operation === 'stopTun') {
    return 'VPN_STOP_FAILED';
  }
  return 'VPN_TUN_START_FAILED';
}

function mapNativeFailureToTunFailure(operation: string, nativeCode: string, detail: string): TunRuntimeFailure {
  const normalizedDetail: string = detail.trim().length > 0 ? detail.trim() : `Tun runtime ${operation} failed.`;
  let code: TunRuntimeFailureCode = fallbackTunFailureCode(operation);
  switch (nativeCode) {
    case 'CMFA_INVALID_ARGUMENT':
    case 'CMFA_OUT_OF_RANGE':
      if (operation === 'startTun') {
        code = 'VPN_TUN_FD_INVALID';
      }
      break;
    case 'CMFA_SOCKET_PROTECT_FAILED':
      code = 'VPN_SOCKET_PROTECT_FAILED';
      break;
    case 'CMFA_BUSY':
      break;
    default:
      break;
  }
  return createTunRuntimeFailure(code, normalizedDetail);
}

function defaultSnapshot(sessionId: string, state: 'IDLE' | 'STOPPED' = 'IDLE'): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId,
    state,
    counters: createVpnCounters(0, 0, 0, 0),
    ingressTraces: [],
    failure: null
  });
}

function traceToIngressTrace(trace: InternalTunNativeTrace): VpnIngressTrace {
  return createVpnIngressTrace({
    sequence: trace.sequence,
    sessionId: trace.sessionId,
    stage: `${trace.ingress}/${trace.protocol}`,
    detail: `${trace.protocol}:${trace.traceId}`,
    atMs: trace.sequence,
    traceId: trace.traceId,
    ingress: trace.ingress,
    protocol: trace.protocol,
    hashedTuple: trace.hashedTuple,
    correlationHash: trace.correlationHash,
    destinationHash: trace.destinationHash,
    outboundTerminalHash: trace.outboundTerminalHash,
    outboundChainHash: trace.outboundChainHash,
    outboundChainLength: trace.outboundChainLength
  });
}

function snapshotFromNative(snapshot: InternalTunNativeSnapshot, traces: InternalTunNativeTrace[]): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId: snapshot.sessionId,
    state: snapshot.state,
    counters: createVpnCounters(
      snapshot.counters.txPackets,
      snapshot.counters.txBytes,
      snapshot.counters.rxPackets,
      snapshot.counters.rxBytes
    ),
    ingressTraces: traces.map((trace: InternalTunNativeTrace) => traceToIngressTrace(trace)),
    failure: snapshot.failure === null
      ? null
      : createTunRuntimeFailure(snapshot.failure.code, snapshot.failure.detail)
  });
}

function cloneSnapshot(snapshot: TunRuntimeSnapshot): TunRuntimeSnapshot {
  return createTunRuntimeSnapshot({
    sessionId: snapshot.sessionId,
    state: snapshot.state,
    counters: snapshot.counters,
    ingressTraces: snapshot.ingressTraces,
    failure: snapshot.failure
  });
}

function cloneEventSnapshot(snapshot: TunRuntimeSnapshot): TunRuntimeSnapshot {
  return cloneSnapshot(snapshot);
}

function isSameTunEvidence(left: TunRuntimeSnapshot, right: TunRuntimeSnapshot): boolean {
  if (left.sessionId !== right.sessionId || left.state !== right.state ||
    left.counters.txPackets !== right.counters.txPackets || left.counters.txBytes !== right.counters.txBytes ||
    left.counters.rxPackets !== right.counters.rxPackets || left.counters.rxBytes !== right.counters.rxBytes ||
    left.failure?.code !== right.failure?.code || left.failure?.detail !== right.failure?.detail ||
    left.ingressTraces.length !== right.ingressTraces.length) {
    return false;
  }
  for (let index: number = 0; index < left.ingressTraces.length; index += 1) {
    const leftTrace: VpnIngressTrace = left.ingressTraces[index];
    const rightTrace: VpnIngressTrace = right.ingressTraces[index];
    if (leftTrace.sequence !== rightTrace.sequence || leftTrace.traceId !== rightTrace.traceId ||
      leftTrace.ingress !== rightTrace.ingress || leftTrace.protocol !== rightTrace.protocol ||
      leftTrace.correlationHash !== rightTrace.correlationHash || leftTrace.destinationHash !== rightTrace.destinationHash ||
      leftTrace.outboundTerminalHash !== rightTrace.outboundTerminalHash ||
      leftTrace.outboundChainHash !== rightTrace.outboundChainHash ||
      leftTrace.outboundChainLength !== rightTrace.outboundChainLength) {
      return false;
    }
  }
  return true;
}

function resolveTunPacketDiagnosticStage(event: InternalNativeRuntimeEvent): string | undefined {
  if (event.ingress !== 'diagnostic' || event.message !== event.protocol) {
    return undefined;
  }
  switch (event.protocol) {
    case 'tun.packet.read-loop-enter':
    case 'tun.packet.read-would-block':
    case 'tun.packet.read-failed':
    case 'tun.packet.raw-read':
    case 'tun.packet.gvisor-inject':
      return event.protocol;
    default:
      return undefined;
  }
}

export class CoreTunRuntime implements TunRuntimePort {
  private readonly nativeModule: InternalTunNativeModule;
  private readonly config: CoreTunRuntimeConfig;
  private readonly pollingScheduler: BoundedDelaySchedulerPort;
  private readonly consumedSessions: Set<string> = new Set();
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private nativeSubscriptionId: number = 0;
  private activeSessionId: string = 'tun-runtime';
  private snapshotValue: TunRuntimeSnapshot = defaultSnapshot('tun-runtime');
  private traceValue: InternalTunNativeTrace[] = [];
  private disposed: boolean = false;
  private acceptingNativeEvents: boolean = false;
  private generation: number = 0;
  private pollingEpoch: number = 0;
  private pollingTask?: CancelableDelayTask;

  private static buildCaptureConfig(options: TunStartOptions): InternalTunNativeCaptureConfig {
    return {
      addresses: options.captureConfig.addresses.slice(),
      routes: options.captureConfig.routes.slice(),
      dnsServers: options.captureConfig.dnsServers.slice(),
      mtu: options.captureConfig.mtu,
      ipv4: options.captureConfig.ipv4,
      ipv6: options.captureConfig.ipv6,
      isBlocking: options.captureConfig.isBlocking,
      blockedApplications: options.captureConfig.blockedApplications.slice(),
      trustedApplications: options.captureConfig.trustedApplications.slice()
    };
  }

  constructor(
    config: CoreTunRuntimeConfig,
    nativeModule?: InternalTunNativeModule,
    pollingScheduler?: BoundedDelaySchedulerPort
  ) {
    this.config = {
      configPath: config.configPath,
      mixedPort: config.mixedPort,
      platformApiLevel: config.platformApiLevel,
      processProtected: config.processProtected
    };
    this.nativeModule = nativeModule ?? getInternalNativeModule();
    this.pollingScheduler = pollingScheduler ?? new CoreTunPollingScheduler();
  }

  async start(handle: TunHandle, options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    this.ensureNotDisposed('startTun');
    if (this.consumedSessions.has(handle.sessionId)) {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', `Tun handle for session ${handle.sessionId} was already transferred.`);
    }
    this.ensureNativeSubscription();
    const startTunRef = this.nativeModule.startTun;
    if (typeof startTunRef !== 'function') {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', 'Tun start surface is unavailable.');
    }
    const invokeStartTun = (startOptions: InternalTunNativeStartOptions): Promise<InternalTunNativeSnapshot> => {
      return this.nativeModule.startTun!(startOptions);
    };

    const nativeStartOptions: InternalTunNativeStartOptions = {
      fd: handle.fd,
      vpnId: handle.vpnId,
      sessionId: handle.sessionId,
      configPath: this.config.configPath,
      mixedPort: this.config.mixedPort,
      platformApiLevel: this.config.platformApiLevel,
      processProtected: this.config.processProtected,
      captureConfig: CoreTunRuntime.buildCaptureConfig(options),
      dnsServers: options.dnsServers.slice()
    };

    try {
      this.consumedSessions.add(handle.sessionId);
      const snapshot: InternalTunNativeSnapshot = await this.invokeNativeSnapshot('startTun', (): Promise<InternalTunNativeSnapshot> => {
        return invokeStartTun(nativeStartOptions);
      });
      if (snapshot.sessionId !== handle.sessionId) {
        throw new TunRuntimePortError(
          'VPN_TUN_START_FAILED',
          `Tun runtime returned a stale session snapshot for ${snapshot.sessionId}.`
        );
      }
      this.activeSessionId = handle.sessionId;
      const traces: InternalTunNativeTrace[] = await this.readTunTraces(0);
      this.snapshotValue = snapshotFromNative(snapshot, traces);
      this.acceptingNativeEvents = true;
      this.startEvidencePolling();
      return cloneSnapshot(this.snapshotValue);
    } catch (error) {
      if (error instanceof TunRuntimePortError) {
        throw error;
      }
      throw this.normalizeTunError('startTun', error as Object | Error | undefined);
    }
  }

  async stop(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.snapshotValue.state === 'STOPPED' || this.snapshotValue.state === 'IDLE') {
      return;
    }
    this.acceptingNativeEvents = false;
    this.stopEvidencePolling();
    try {
      const snapshot: InternalTunNativeSnapshot = await this.invokeNativeSnapshot('stopTun', (): Promise<InternalTunNativeSnapshot> => {
        if (typeof this.nativeModule.stopTun !== 'function') {
          return Promise.reject(new Error('Tun stop surface is unavailable.'));
        }
        return this.nativeModule.stopTun();
      });
      this.traceValue = [];
      this.snapshotValue = snapshotFromNative(snapshot, []);
      this.activeSessionId = snapshot.sessionId;
    } catch (error) {
      this.acceptingNativeEvents = this.snapshotValue.state !== 'STOPPED' && this.snapshotValue.state !== 'IDLE';
      if (this.acceptingNativeEvents) {
        this.startEvidencePolling();
      }
      throw this.normalizeTunError('stopTun', error as Object | Error | undefined);
    }
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    this.ensureNotDisposed('closeStaleOutboundConnections');
    if (this.snapshotValue.state === 'IDLE' || this.snapshotValue.state === 'STOPPED' || this.activeSessionId !== sessionId) {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', `Tun runtime requires an active session matching ${sessionId}.`);
    }
    if (typeof this.nativeModule.closeStaleOutboundConnections !== 'function') {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', 'Tun close-stale surface is unavailable.');
    }
    try {
      await wrapNativeAsync<void>('closeStaleOutboundConnections', (): Promise<void> => {
        return this.nativeModule.closeStaleOutboundConnections!(sessionId);
      });
    } catch (error) {
      throw this.normalizeTunError('closeStaleOutboundConnections', error as Object | Error | undefined);
    }
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    this.ensureNotDisposed('tunSnapshot');
    const snapshot: InternalTunNativeSnapshot = await this.invokeNativeSnapshot('tunSnapshot', (): Promise<InternalTunNativeSnapshot> => {
      if (typeof this.nativeModule.tunSnapshot !== 'function') {
        return Promise.reject(new Error('Tun snapshot surface is unavailable.'));
      }
      return this.nativeModule.tunSnapshot();
    });
    if (snapshot.sessionId !== sessionId) {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', `Tun runtime returned a stale session snapshot for ${snapshot.sessionId}.`);
    }
    this.activeSessionId = sessionId;
    const traces: InternalTunNativeTrace[] = await this.readTunTraces(0);
    this.snapshotValue = snapshotFromNative(snapshot, traces);
    this.acceptingNativeEvents = true;
    this.startEvidencePolling();
    return cloneSnapshot(this.snapshotValue);
  }

  snapshot(): TunRuntimeSnapshot {
    return cloneSnapshot(this.snapshotValue);
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    this.ensureNotDisposed('subscribe');
    this.ensureNativeSubscription();
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  async readTunTraces(afterSequence: number): Promise<InternalTunNativeTrace[]> {
    this.ensureNotDisposed('readTunTraces');
    const traces: InternalTunNativeTrace[] = await wrapNativeAsync<InternalTunNativeTrace[]>('readTunTraces', (): Promise<InternalTunNativeTrace[]> => {
      if (typeof this.nativeModule.readTunTraces !== 'function') {
        return Promise.reject(new Error('Tun trace surface is unavailable.'));
      }
      return this.nativeModule.readTunTraces(afterSequence);
    });

    const filtered: InternalTunNativeTrace[] = [];
    for (let index = 0; index < traces.length; index += 1) {
      if (this.activeSessionId === 'tun-runtime' || traces[index].sessionId === this.activeSessionId) {
        filtered.push(cloneNativeTrace(traces[index]));
      }
    }
    this.traceValue = cloneNativeTraces(filtered);
    return cloneNativeTraces(filtered);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.acceptingNativeEvents = false;
    this.generation += 1;
    this.stopEvidencePolling();
    this.listeners.clear();
    if (this.nativeSubscriptionId !== 0) {
      try {
        if (typeof this.nativeModule.unsubscribe === 'function') {
          this.nativeModule.unsubscribe(this.nativeSubscriptionId);
        }
      } catch (_error) {
      }
      this.nativeSubscriptionId = 0;
    }
  }

  private ensureNativeSubscription(): void {
    if (this.nativeSubscriptionId !== 0) {
      return;
    }
    if (typeof this.nativeModule.subscribe !== 'function') {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', 'Tun event subscription surface is unavailable.');
    }
    this.nativeSubscriptionId = this.nativeModule.subscribe((event: InternalNativeRuntimeEvent): void => {
      void this.handleNativeEvent(event);
    });
  }

  private startEvidencePolling(): void {
    this.stopEvidencePolling();
    this.scheduleEvidencePoll(this.pollingEpoch);
  }

  private stopEvidencePolling(): void {
    this.pollingEpoch += 1;
    this.pollingTask?.cancel();
    this.pollingTask = undefined;
  }

  private scheduleEvidencePoll(epoch: number): void {
    if (this.disposed || epoch !== this.pollingEpoch || this.activeSessionId === 'tun-runtime' ||
      this.snapshotValue.state === 'IDLE' || this.snapshotValue.state === 'STOPPED') {
      return;
    }
    this.pollingTask = this.pollingScheduler.schedule(TUN_EVIDENCE_POLL_INTERVAL_MS, async (): Promise<void> => {
      this.pollingTask = undefined;
      await this.pollNativeEvidence(epoch);
    });
  }

  private async pollNativeEvidence(epoch: number): Promise<void> {
    if (this.disposed || epoch !== this.pollingEpoch || this.activeSessionId === 'tun-runtime') {
      return;
    }
    const sessionId: string = this.activeSessionId;
    try {
      const snapshot: InternalTunNativeSnapshot = await this.invokeNativeSnapshot('tunSnapshot', (): Promise<InternalTunNativeSnapshot> => {
        if (typeof this.nativeModule.tunSnapshot !== 'function') {
          return Promise.reject(new Error('Tun snapshot surface is unavailable.'));
        }
        return this.nativeModule.tunSnapshot();
      });
      if (this.disposed || epoch !== this.pollingEpoch || snapshot.sessionId !== sessionId) {
        return;
      }
      const traces: InternalTunNativeTrace[] = await this.readTunTraces(0);
      if (this.disposed || epoch !== this.pollingEpoch) {
        return;
      }
      const nextSnapshot: TunRuntimeSnapshot = snapshotFromNative(snapshot, traces);
      const changed: boolean = !isSameTunEvidence(this.snapshotValue, nextSnapshot);
      this.snapshotValue = nextSnapshot;
      if (changed) {
        this.emitSnapshotEvent();
      }
    } catch (_error) {
    } finally {
      this.scheduleEvidencePoll(epoch);
    }
  }

  private async handleNativeEvent(event: InternalNativeRuntimeEvent): Promise<void> {
    if (this.disposed || !this.acceptingNativeEvents || event.type !== 'runtime') {
      return;
    }
    const sessionId: string = typeof event.sessionId === 'string' && event.sessionId.trim().length > 0
      ? event.sessionId.trim()
      : '';
    if (sessionId.length === 0) {
      return;
    }
    if (this.activeSessionId !== 'tun-runtime' && this.activeSessionId !== sessionId) {
      return;
    }
    const diagnosticStage: string | undefined = resolveTunPacketDiagnosticStage(event);
    if (diagnosticStage !== undefined) {
      this.emitSnapshotEvent(diagnosticStage, sessionId);
      return;
    }
    const generation: number = this.generation;
    try {
      const snapshot: InternalTunNativeSnapshot = await this.invokeNativeSnapshot('tunSnapshot', (): Promise<InternalTunNativeSnapshot> => {
        if (typeof this.nativeModule.tunSnapshot !== 'function') {
          return Promise.reject(new Error('Tun snapshot surface is unavailable.'));
        }
        return this.nativeModule.tunSnapshot();
      });
      if (this.disposed || !this.acceptingNativeEvents || generation !== this.generation || snapshot.sessionId !== sessionId) {
        return;
      }
      const traces: InternalTunNativeTrace[] = await this.readTunTraces(0);
      if (this.disposed || !this.acceptingNativeEvents || generation !== this.generation) {
        return;
      }
      this.snapshotValue = snapshotFromNative(snapshot, traces);
      this.emitSnapshotEvent();
    } catch (_error) {
    }
  }

  private emitSnapshotEvent(diagnosticStage?: string, sessionId?: string): void {
    const listeners: Array<(event: TunRuntimeEvent) => void> = [];
    this.listeners.forEach((listener: (event: TunRuntimeEvent) => void): void => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index]({
        sessionId: sessionId ?? this.snapshotValue.sessionId,
        snapshot: cloneEventSnapshot(this.snapshotValue),
        diagnosticStage: diagnosticStage
      });
    }
  }

  private async invokeNativeSnapshot(
    operation: string,
    invoke: () => Promise<InternalTunNativeSnapshot>
  ): Promise<InternalTunNativeSnapshot> {
    return await wrapNativeAsync<InternalTunNativeSnapshot>(operation, invoke);
  }

  private normalizeTunError(operation: string, error: Object | Error | undefined): TunRuntimePortError {
    const nativeCode: string = this.extractErrorCode(error);
    const detailSource: string = this.extractErrorDetail(error);
    const failure: TunRuntimeFailure = mapNativeFailureToTunFailure(operation, nativeCode, detailSource);
    return new TunRuntimePortError(failure.code, failure.detail, nativeCode);
  }

  private extractErrorDetail(error: Object | Error | undefined): string {
    if (error === undefined) {
      return '';
    }
    const record = error as Record<string, string | undefined>;
    if (typeof record['detail'] === 'string' && record['detail']!.trim().length > 0) {
      return record['detail'] as string;
    }
    if (error instanceof Error) {
      return error.message;
    }
    return '';
  }

  private extractErrorCode(error: Object | Error | undefined): string {
    if (error === undefined) {
      return fallbackTunFailureCode('startTun');
    }
    const record = error as Record<string, string | undefined>;
    if (typeof record['code'] === 'string' && record['code']!.trim().length > 0) {
      return record['code'] as string;
    }
    return 'CMFA_BACKEND_ERROR';
  }

  private ensureNotDisposed(operation: string): void {
    if (this.disposed) {
      throw new TunRuntimePortError('VPN_TUN_START_FAILED', `Tun runtime ${operation} is unavailable after dispose.`);
    }
  }
}
