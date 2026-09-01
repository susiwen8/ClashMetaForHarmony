import { describe, expect, it } from '@ohos/hypium';
import {
  CoreTunRuntime,
  type CoreTunRuntimeConfig
} from '../../Index';
import type { InternalNativeRuntimeEvent, InternalTunNativeModule } from '../main/ets/CoreNativeAdapter';
import {
  TunRuntimePortError,
  createTunHandle,
  createTunStartOptions,
  createVpnCaptureConfig,
  type CreateVpnCaptureConfigInput
} from '@cmfa/shared';
import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  TunHandle,
  TunRuntimeEvent,
  TunRuntimeSnapshot,
  TunStartOptions,
  VpnCaptureConfig
} from '@cmfa/shared';

const DESTINATION_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const OUTBOUND_TERMINAL_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const OUTBOUND_CHAIN_HASH: string = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

interface NativeTunCountersShape {
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

interface NativeTunFailureShape {
  code: string;
  detail: string;
}

interface NativeTunSnapshotShape {
  sessionId: string;
  state: 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR';
  counters: NativeTunCountersShape;
  failure: NativeTunFailureShape | null;
}

interface NativeTunTraceShape {
  sequence: number;
  sessionId: string;
  traceId: string;
  ingress: string;
  protocol: string;
  sourceAddress: string;
  destinationAddress: string;
  hashedTuple: string;
  correlationHash: string;
  destinationHash: string;
  outboundTerminalHash: string;
  outboundChainHash: string;
  outboundChainLength: number;
}

interface NativeRuntimeEventShape {
  type: 'runtime' | 'log';
  state?: string;
  message: string;
  code?: string;
  sessionId?: string;
  traceId?: string;
  ingress?: string;
  protocol?: string;
  level?: string;
}

interface NativeTunStartShape {
  fd: number;
  vpnId: string;
  sessionId: string;
  configPath: string;
  mixedPort: number;
  platformApiLevel: number;
  processProtected: boolean;
  captureConfig: VpnCaptureConfig;
  dnsServers: string[];
}

class NativeBridgeFailure extends Error {
  code: string;
  detail: string;

  constructor(code: string, detail: string) {
    super(detail);
    this.code = code;
    this.detail = detail;
  }
}

class NativeBridgeErrorWithGenericMessage extends NativeBridgeFailure {
  constructor(code: string, message: string, detail: string) {
    super(code, detail);
    this.message = message;
  }
}

class ManualDelayTask implements CancelableDelayTask {
  readonly delayMs: number;
  readonly runner: () => Promise<void>;
  canceled: boolean = false;

  constructor(delayMs: number, runner: () => Promise<void>) {
    this.delayMs = delayMs;
    this.runner = runner;
  }

  cancel(): void {
    this.canceled = true;
  }

  async run(): Promise<void> {
    if (!this.canceled) {
      await this.runner();
    }
  }
}

class ManualDelayScheduler implements BoundedDelaySchedulerPort {
  readonly tasks: ManualDelayTask[] = [];

  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const task = new ManualDelayTask(delayMs, runner);
    this.tasks.push(task);
    return task;
  }
}

const CONFIG: CoreTunRuntimeConfig = {
  configPath: '/data/storage/el2/base/files/profiles/current.yaml',
  mixedPort: 7890,
  platformApiLevel: 12,
  processProtected: true
};
const SELF_PACKAGE_NAME: string = 'com.github.kr328.clash.harmony';

function buildCaptureConfig(): VpnCaptureConfig {
  const input: CreateVpnCaptureConfigInput = {
    addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
    routes: ['0.0.0.0/0', '::/0'],
    dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
    mtu: 1500,
    ipv4: true,
    ipv6: true,
    isBlocking: false,
    blockedApplications: [SELF_PACKAGE_NAME],
    trustedApplications: []
  };
  return createVpnCaptureConfig(input);
}

function buildStartOptions(): TunStartOptions {
  const captureConfig: VpnCaptureConfig = buildCaptureConfig();
  return createTunStartOptions(captureConfig, captureConfig.dnsServers);
}

function buildHandle(sessionId: string, fd: number = 41): TunHandle {
  return createTunHandle(fd, `vpn-${sessionId}`, sessionId);
}

function buildNativeSnapshot(sessionId: string, state: 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR'): NativeTunSnapshotShape {
  return {
    sessionId,
    state,
    counters: {
      txPackets: 1,
      txBytes: 2,
      rxPackets: 3,
      rxBytes: 4
    },
    failure: null
  };
}

function buildNativeTrace(sequence: number, sessionId: string, protocol: string = 'tcp'): NativeTunTraceShape {
  return {
    sequence,
    sessionId,
    traceId: `trace-${sequence}`,
    ingress: 'tun',
    protocol,
    sourceAddress: '10.111.222.1:12345',
    destinationAddress: '1.1.1.1:443',
    hashedTuple: `hash-${sequence}`,
    correlationHash: `corr-${sequence}`,
    destinationHash: DESTINATION_HASH,
    outboundTerminalHash: OUTBOUND_TERMINAL_HASH,
    outboundChainHash: OUTBOUND_CHAIN_HASH,
    outboundChainLength: sequence
  };
}

async function flushTasks(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}

interface DeferredPromise<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
}

function createDeferredPromise<T>(): DeferredPromise<T> {
  let resolveRef: ((value: T) => void) | undefined = undefined;
  const promise: Promise<T> = new Promise<T>((resolve: (value: T) => void): void => {
    resolveRef = resolve;
  });
  return {
    promise,
    resolve: (value: T): void => {
      resolveRef!(value);
    }
  };
}

async function expectTunFailure(
  operation: () => Promise<void | Object>,
  expectedCode: string,
  expectedDetailFragment: string
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    expect(error instanceof TunRuntimePortError).assertTrue();
    const portError: TunRuntimePortError = error as TunRuntimePortError;
    expect(portError.failure.code).assertEqual(expectedCode);
    expect(portError.failure.detail.includes(expectedDetailFragment)).assertTrue();
  }
}

async function captureTunFailure(operation: () => Promise<void | Object>): Promise<TunRuntimePortError> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    expect(error instanceof TunRuntimePortError).assertTrue();
    return error as TunRuntimePortError;
  }
  throw new TunRuntimePortError('VPN_TUN_START_FAILED', 'unreachable');
}

class FakeNativeTunModule implements InternalTunNativeModule {
  readonly startCalls: NativeTunStartShape[] = [];
  readonly stopCalls: number[] = [];
  readonly closeStaleCalls: string[] = [];
  readonly readTraceCalls: number[] = [];
  readonly unsubscribeCalls: number[] = [];
  private readonly listeners: Map<number, (event: InternalNativeRuntimeEvent) => void> = new Map();
  private nextSubscriptionId: number = 1;
  snapshotValue: NativeTunSnapshotShape = buildNativeSnapshot('session-1', 'IDLE');
  traceValues: NativeTunTraceShape[] = [];
  startError?: NativeBridgeFailure;
  stopError?: NativeBridgeFailure;
  closeStaleError?: NativeBridgeFailure;
  snapshotError?: NativeBridgeFailure;
  traceError?: NativeBridgeFailure;

  private cloneCaptureConfig(config: VpnCaptureConfig): VpnCaptureConfig {
    const input: CreateVpnCaptureConfigInput = {
      addresses: config.addresses.slice(),
      routes: config.routes.slice(),
      dnsServers: config.dnsServers.slice(),
      mtu: config.mtu,
      ipv4: config.ipv4,
      ipv6: config.ipv6,
      isBlocking: config.isBlocking,
      blockedApplications: config.blockedApplications.slice(),
      trustedApplications: config.trustedApplications.slice()
    };
    return createVpnCaptureConfig(input);
  }

  private cloneFailure(failure: NativeTunFailureShape | null): NativeTunFailureShape | null {
    if (failure === null) {
      return null;
    }
    return {
      code: failure.code,
      detail: failure.detail
    };
  }

  private cloneSnapshot(snapshot: NativeTunSnapshotShape): NativeTunSnapshotShape {
    return {
      sessionId: snapshot.sessionId,
      state: snapshot.state,
      counters: {
        txPackets: snapshot.counters.txPackets,
        txBytes: snapshot.counters.txBytes,
        rxPackets: snapshot.counters.rxPackets,
        rxBytes: snapshot.counters.rxBytes
      },
      failure: this.cloneFailure(snapshot.failure)
    };
  }

  private cloneTrace(trace: NativeTunTraceShape): NativeTunTraceShape {
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

  async startTun(options: NativeTunStartShape): Promise<NativeTunSnapshotShape> {
    this.startCalls.push({
      fd: options.fd,
      vpnId: options.vpnId,
      sessionId: options.sessionId,
      configPath: options.configPath,
      mixedPort: options.mixedPort,
      platformApiLevel: options.platformApiLevel,
      processProtected: options.processProtected,
      captureConfig: this.cloneCaptureConfig(options.captureConfig),
      dnsServers: options.dnsServers.slice()
    });
    if (this.startError !== undefined) {
      throw this.startError;
    }
    return this.cloneSnapshot(this.snapshotValue);
  }

  async stopTun(): Promise<NativeTunSnapshotShape> {
    this.stopCalls.push(this.stopCalls.length + 1);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
    return this.cloneSnapshot(this.snapshotValue);
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    this.closeStaleCalls.push(sessionId);
    if (this.closeStaleError !== undefined) {
      throw this.closeStaleError;
    }
  }

  async tunSnapshot(): Promise<NativeTunSnapshotShape> {
    if (this.snapshotError !== undefined) {
      throw this.snapshotError;
    }
    return this.cloneSnapshot(this.snapshotValue);
  }

  async readTunTraces(afterSequence: number): Promise<NativeTunTraceShape[]> {
    this.readTraceCalls.push(afterSequence);
    if (this.traceError !== undefined) {
      throw this.traceError;
    }
    const filtered: NativeTunTraceShape[] = [];
    for (let index = 0; index < this.traceValues.length; index += 1) {
      if (this.traceValues[index].sequence > afterSequence) {
        filtered.push(this.cloneTrace(this.traceValues[index]));
      }
    }
    return filtered;
  }

  subscribe(listener: (event: InternalNativeRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.unsubscribeCalls.push(subscriptionId);
    this.listeners.delete(subscriptionId);
  }

  emitRuntime(event: InternalNativeRuntimeEvent): void {
    const listeners: Array<(event: InternalNativeRuntimeEvent) => void> = [];
    this.listeners.forEach((listener: (event: InternalNativeRuntimeEvent) => void): void => {
      listeners.push(listener);
    });
    for (let index = 0; index < listeners.length; index += 1) {
      listeners[index](event);
    }
  }
}

class MutableSurfaceNativeModule implements InternalTunNativeModule {
  readonly delegate: FakeNativeTunModule;
  subscribe?: (listener: (event: InternalNativeRuntimeEvent) => void) => number;
  unsubscribe?: (subscriptionId: number) => void;
  startTun?: (options: NativeTunStartShape) => Promise<NativeTunSnapshotShape>;
  stopTun?: () => Promise<NativeTunSnapshotShape>;
  tunSnapshot?: () => Promise<NativeTunSnapshotShape>;
  readTunTraces?: (afterSequence: number) => Promise<NativeTunTraceShape[]>;

  constructor(delegate: FakeNativeTunModule) {
    this.delegate = delegate;
    this.unsubscribe = (subscriptionId: number): void => {
      this.delegate.unsubscribe(subscriptionId);
    };
    this.stopTun = (): Promise<NativeTunSnapshotShape> => {
      return this.delegate.stopTun();
    };
    this.tunSnapshot = (): Promise<NativeTunSnapshotShape> => {
      return this.delegate.tunSnapshot();
    };
    this.readTunTraces = (afterSequence: number): Promise<NativeTunTraceShape[]> => {
      return this.delegate.readTunTraces(afterSequence);
    };
  }

  enableSubscribe(): void {
    this.subscribe = (listener: (event: InternalNativeRuntimeEvent) => void): number => {
      return this.delegate.subscribe(listener);
    };
  }

  disableSubscribe(): void {
    this.subscribe = undefined;
  }

  enableStartTun(): void {
    this.startTun = (options: NativeTunStartShape): Promise<NativeTunSnapshotShape> => {
      return this.delegate.startTun(options);
    };
  }

  disableStartTun(): void {
    this.startTun = undefined;
  }
}

class DeferredSnapshotNativeTunModule extends FakeNativeTunModule {
  snapshotPromise?: Promise<NativeTunSnapshotShape>;
  stopSnapshot?: NativeTunSnapshotShape;

  async tunSnapshot(): Promise<NativeTunSnapshotShape> {
    if (this.snapshotPromise !== undefined) {
      return await this.snapshotPromise;
    }
    return await super.tunSnapshot();
  }

  async stopTun(): Promise<NativeTunSnapshotShape> {
    if (this.stopSnapshot !== undefined) {
      return {
        sessionId: this.stopSnapshot.sessionId,
        state: this.stopSnapshot.state,
        counters: {
          txPackets: this.stopSnapshot.counters.txPackets,
          txBytes: this.stopSnapshot.counters.txBytes,
          rxPackets: this.stopSnapshot.counters.rxPackets,
          rxBytes: this.stopSnapshot.counters.rxBytes
        },
        failure: this.stopSnapshot.failure === null
          ? null
          : {
            code: this.stopSnapshot.failure.code,
            detail: this.stopSnapshot.failure.detail
          }
      };
    }
    return await super.stopTun();
  }
}

export default function coreTunRuntimeTestsuite() {
  describe('CoreTunRuntimeTest', () => {
    it('startTransfersEachSessionFdExactlyOnceAndKeepsExactTunPolicy', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-1', 'READY');
      nativeModule.traceValues = [buildNativeTrace(1, 'session-1')];
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const handle: TunHandle = buildHandle('session-1', 42);
      const result: TunRuntimeSnapshot = await runtime.start(handle, buildStartOptions());

      expect(result.sessionId).assertEqual('session-1');
      expect(result.state).assertEqual('READY');
      expect(nativeModule.startCalls.length).assertEqual(1);
      expect(nativeModule.startCalls[0].fd).assertEqual(42);
      expect(nativeModule.startCalls[0].configPath).assertEqual(CONFIG.configPath);
      expect(nativeModule.startCalls[0].mixedPort).assertEqual(7890);
      expect(nativeModule.startCalls[0].platformApiLevel).assertEqual(12);
      expect(nativeModule.startCalls[0].processProtected).assertTrue();
      expect(nativeModule.startCalls[0].captureConfig.routes[0]).assertEqual('0.0.0.0/0');
      expect(nativeModule.startCalls[0].captureConfig.routes[1]).assertEqual('::/0');
      expect(nativeModule.startCalls[0].dnsServers[0]).assertEqual('10.111.222.2');
      expect(nativeModule.startCalls[0].dnsServers[1]).assertEqual('fd00:111:222::2');
      expect(nativeModule.startCalls[0].captureConfig.mtu).assertEqual(1500);

      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'already'
      );
      expect(nativeModule.startCalls.length).assertEqual(1);
      runtime.dispose();
    });

    it('rejectsNativeSessionMismatchWithoutRetryingTheBorrowedFd', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('unexpected-session', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const handle: TunHandle = buildHandle('session-1');

      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'stale session'
      );
      expect(nativeModule.startCalls.length).assertEqual(1);
      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'already'
      );
      expect(nativeModule.startCalls.length).assertEqual(1);
      runtime.dispose();
    });

    it('clonesSnapshotsAndTraceReadsBeforeReturningThem', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-7', 'READY');
      nativeModule.traceValues = [buildNativeTrace(1, 'session-7', 'udp')];
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const snapshot: TunRuntimeSnapshot = await runtime.start(buildHandle('session-7'), buildStartOptions());
      const traces = await runtime.readTunTraces(0);

      snapshot.counters.rxPackets = 999;
      snapshot.ingressTraces[0].detail = 'tampered';
      traces[0].protocol = 'icmp';

      const latestSnapshot: TunRuntimeSnapshot = runtime.snapshot();
      const latestTraces = await runtime.readTunTraces(0);
      expect(latestSnapshot.counters.rxPackets).assertEqual(3);
      expect(latestSnapshot.ingressTraces[0].detail.includes('1.1.1.1:443')).assertFalse();
      expect(latestSnapshot.ingressTraces[0].traceId).assertEqual('trace-1');
      expect(latestSnapshot.ingressTraces[0].ingress).assertEqual('tun');
      expect(latestSnapshot.ingressTraces[0].protocol).assertEqual('udp');
      expect(latestSnapshot.ingressTraces[0].hashedTuple).assertEqual('hash-1');
      expect(latestSnapshot.ingressTraces[0].correlationHash).assertEqual('corr-1');
      expect(latestSnapshot.ingressTraces[0].destinationHash).assertEqual(DESTINATION_HASH);
      expect(latestSnapshot.ingressTraces[0].outboundTerminalHash).assertEqual(OUTBOUND_TERMINAL_HASH);
      expect(latestSnapshot.ingressTraces[0].outboundChainHash).assertEqual(OUTBOUND_CHAIN_HASH);
      expect(latestSnapshot.ingressTraces[0].outboundChainLength).assertEqual(1);
      expect(latestTraces[0].protocol).assertEqual('udp');
      runtime.dispose();
    });

    it('mapsNativeFailuresToStableTunRuntimeFailures', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.startError = new NativeBridgeFailure('CMFA_INVALID_ARGUMENT', 'tun fd must be positive');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      await expectTunFailure(
        async () => {
          await runtime.start(buildHandle('session-3'), buildStartOptions());
        },
        'VPN_TUN_FD_INVALID',
        'fd'
      );

      nativeModule.startError = undefined;
      nativeModule.snapshotValue = buildNativeSnapshot('session-4', 'READY');
      await runtime.start(buildHandle('session-4'), buildStartOptions());
      nativeModule.stopError = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'stop failed');
      await expectTunFailure(
        async () => {
          await runtime.stop();
        },
        'VPN_STOP_FAILED',
        'stop failed'
      );
      runtime.dispose();
    });

    it('mapsBusyStopFailuresToVpnStopFailedWhilePreservingNativeCode', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-busy', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      await runtime.start(buildHandle('session-stop-busy'), buildStartOptions());
      nativeModule.stopError = new NativeBridgeFailure('CMFA_BUSY', 'stop busy detail');

      const stopError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtime.stop();
      });

      expect(stopError.failure.code).assertEqual('VPN_STOP_FAILED');
      expect(stopError.failure.detail).assertContain('stop busy detail');
      expect(stopError.nativeCode).assertEqual('CMFA_BUSY');
      runtime.dispose();
    });

    it('keepsBusyStartFailuresMappedToVpnTunStartFailedWhilePreservingNativeCode', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.startError = new NativeBridgeFailure('CMFA_BUSY', 'start busy detail');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      const startError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtime.start(buildHandle('session-start-busy'), buildStartOptions());
      });

      expect(startError.failure.code).assertEqual('VPN_TUN_START_FAILED');
      expect(startError.failure.detail).assertContain('start busy detail');
      expect(startError.nativeCode).assertEqual('CMFA_BUSY');
      runtime.dispose();
    });

    it('keepsAcceptingNativeEventsWhenStopFailsAndTheSessionRemainsActive', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-error', 'READY');
      nativeModule.traceValues = [buildNativeTrace(1, 'session-stop-error')];
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const received: TunRuntimeSnapshot[] = [];
      runtime.subscribe((event: TunRuntimeEvent): void => {
        received.push(event.snapshot);
      });

      await runtime.start(buildHandle('session-stop-error'), buildStartOptions());
      nativeModule.stopError = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'stop failed');
      await expectTunFailure(
        async () => {
          await runtime.stop();
        },
        'VPN_STOP_FAILED',
        'stop failed'
      );

      nativeModule.stopError = undefined;
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-error', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 29;
      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'retry-event',
        code: 'CMFA_OK',
        sessionId: 'session-stop-error',
        traceId: 'trace-stop-error',
        ingress: 'tun',
        protocol: 'tcp'
      });
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].counters.rxPackets).assertEqual(29);
      runtime.dispose();
    });

    it('forwardsMatchingNativeRuntimeEventsAndIgnoresLateCallbacksAfterDispose', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-events', 'READY');
      nativeModule.traceValues = [buildNativeTrace(1, 'session-events')];
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const received: TunRuntimeSnapshot[] = [];

      const subscriptionId: number = runtime.subscribe((event) => {
        received.push(event.snapshot);
      });
      expect(subscriptionId > 0).assertTrue();

      await runtime.start(buildHandle('session-events'), buildStartOptions());
      nativeModule.snapshotValue = buildNativeSnapshot('session-events', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 17;
      nativeModule.traceValues = [buildNativeTrace(1, 'session-events'), buildNativeTrace(2, 'session-events', 'dns')];
      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'dns',
        code: 'CMFA_OK',
        sessionId: 'session-events',
        traceId: 'trace-2',
        ingress: 'tun',
        protocol: 'dns'
      });
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].counters.rxPackets).assertEqual(17);
      expect(received[0].ingressTraces.length).assertEqual(2);
      expect(received[0].ingressTraces[1].traceId).assertEqual('trace-2');
      expect(received[0].ingressTraces[1].protocol).assertEqual('dns');
      expect(received[0].ingressTraces[1].correlationHash).assertEqual('corr-2');
      expect(received[0].ingressTraces[1].destinationHash).assertEqual(DESTINATION_HASH);
      expect(received[0].ingressTraces[1].outboundTerminalHash).assertEqual(OUTBOUND_TERMINAL_HASH);
      expect(received[0].ingressTraces[1].outboundChainHash).assertEqual(OUTBOUND_CHAIN_HASH);
      expect(received[0].ingressTraces[1].outboundChainLength).assertEqual(2);
      received[0].counters.rxPackets = 0;
      expect(runtime.snapshot().counters.rxPackets).assertEqual(17);

      runtime.dispose();
      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'late',
        code: 'CMFA_OK',
        sessionId: 'session-events',
        traceId: 'trace-3',
        ingress: 'tun',
        protocol: 'tcp'
      });
      await flushTasks();
      expect(received.length).assertEqual(1);
      expect(nativeModule.unsubscribeCalls.length).assertEqual(1);
    });

    it('forwardsOnlyFixedTunPacketDiagnosticsWithoutNativePayloads', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-diagnostic', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const received: TunRuntimeEvent[] = [];
      runtime.subscribe((event: TunRuntimeEvent): void => {
        received.push(event);
      });
      await runtime.start(buildHandle('session-diagnostic'), buildStartOptions());
      nativeModule.snapshotError = new NativeBridgeFailure('CMFA_BUSY', 'snapshot unavailable during start');

      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'tun.packet.read-loop-enter',
        code: 'CMFA_OK',
        sessionId: 'session-diagnostic',
        traceId: 'private-trace',
        ingress: 'diagnostic',
        protocol: 'tun.packet.read-loop-enter'
      });
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].diagnosticStage).assertEqual('tun.packet.read-loop-enter');
      nativeModule.snapshotError = undefined;

      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'private-payload',
        code: 'CMFA_OK',
        sessionId: 'session-diagnostic',
        traceId: 'private-trace',
        ingress: 'diagnostic',
        protocol: 'private-payload'
      });
      await flushTasks();

      expect(received.length).assertEqual(2);
      expect(received[1].diagnosticStage === undefined).assertTrue();
      runtime.dispose();
    });

    it('pollsLiveNativeTunEvidenceWithoutDependingOnRuntimeEventDeliveryAndCancelsOnStop', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-poll', 'READY');
      const scheduler = new ManualDelayScheduler();
      const runtime = new CoreTunRuntime(CONFIG, nativeModule, scheduler);
      const received: TunRuntimeEvent[] = [];
      runtime.subscribe((event: TunRuntimeEvent): void => {
        received.push(event);
      });

      await runtime.start(buildHandle('session-poll'), buildStartOptions());
      expect(scheduler.tasks.length).assertEqual(1);
      expect(scheduler.tasks[0].delayMs).assertEqual(250);

      nativeModule.snapshotValue = buildNativeSnapshot('session-poll', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 29;
      nativeModule.traceValues = [buildNativeTrace(1, 'session-poll', 'udp')];
      await scheduler.tasks[0].run();
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].snapshot.counters.rxPackets).assertEqual(29);
      expect(received[0].snapshot.ingressTraces.length).assertEqual(1);
      expect(scheduler.tasks.length).assertEqual(2);

      nativeModule.snapshotValue = buildNativeSnapshot('session-poll', 'STOPPED');
      await runtime.stop();
      expect(scheduler.tasks[1].canceled).assertTrue();
      runtime.dispose();
    });

    it('restartsPollingAfterStopFailsAndContinuesPublishingEvidence', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-failed-poll', 'READY');
      const scheduler = new ManualDelayScheduler();
      const runtime = new CoreTunRuntime(CONFIG, nativeModule, scheduler);
      const received: TunRuntimeEvent[] = [];
      runtime.subscribe((event: TunRuntimeEvent): void => {
        received.push(event);
      });

      await runtime.start(buildHandle('session-stop-failed-poll'), buildStartOptions());
      expect(scheduler.tasks.length).assertEqual(1);
      expect(scheduler.tasks[0].canceled).assertFalse();

      nativeModule.stopError = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'stop failed');
      await expectTunFailure(
        async () => {
          await runtime.stop();
        },
        'VPN_STOP_FAILED',
        'stop failed'
      );

      expect(scheduler.tasks[0].canceled).assertTrue();
      expect(scheduler.tasks.length).assertEqual(2);
      expect(scheduler.tasks[1].canceled).assertFalse();
      expect(scheduler.tasks[1].delayMs).assertEqual(250);

      nativeModule.stopError = undefined;
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-failed-poll', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 43;
      nativeModule.traceValues = [buildNativeTrace(1, 'session-stop-failed-poll', 'udp')];
      await scheduler.tasks[1].run();
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].snapshot.counters.rxPackets).assertEqual(43);
      runtime.dispose();
    });

    it('stopsSafelyMoreThanOnce', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-stop'), buildStartOptions());

      nativeModule.snapshotValue = buildNativeSnapshot('session-stop', 'STOPPED');
      await runtime.stop();
      await runtime.stop();

      expect(nativeModule.stopCalls.length).assertEqual(1);
      expect(runtime.snapshot().state).assertEqual('STOPPED');
      runtime.unsubscribe(9999);
      runtime.dispose();
    });

    it('ignoresLateNativeRuntimeEventsAfterStopBeginsForTheSameSession', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-late', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-stop-late'), buildStartOptions());

      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-late', 'STOPPED');
      const stopPromise: Promise<void> = runtime.stop();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-late', 'READY');
      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'late-after-stop',
        code: 'CMFA_OK',
        sessionId: 'session-stop-late',
        traceId: 'trace-late-stop',
        ingress: 'tun',
        protocol: 'tcp'
      });
      await stopPromise;
      await flushTasks();

      expect(runtime.snapshot().state).assertEqual('STOPPED');
      runtime.dispose();
    });

    it('ignoresInFlightNativeRuntimeSnapshotsThatResolveAfterStopFinishes', 0, async () => {
      const nativeModule = new DeferredSnapshotNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-inflight', 'READY');
      const deferredSnapshot: DeferredPromise<NativeTunSnapshotShape> = createDeferredPromise<NativeTunSnapshotShape>();
      nativeModule.snapshotPromise = deferredSnapshot.promise;
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-stop-inflight'), buildStartOptions());

      nativeModule.emitRuntime({
        type: 'runtime',
        state: 'RUNNING',
        message: 'inflight-before-stop',
        code: 'CMFA_OK',
        sessionId: 'session-stop-inflight',
        traceId: 'trace-stop-inflight',
        ingress: 'tun',
        protocol: 'tcp'
      });
      await flushTasks();

      nativeModule.stopSnapshot = buildNativeSnapshot('session-stop-inflight', 'STOPPED');
      await runtime.stop();

      deferredSnapshot.resolve(buildNativeSnapshot('session-stop-inflight', 'READY'));
      await flushTasks();

      expect(runtime.snapshot().state).assertEqual('STOPPED');
      runtime.dispose();
    });

    it('restartsPollingAfterRecoverAndCancelsThePreviousPendingTask', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-recover-poll', 'READY');
      const scheduler = new ManualDelayScheduler();
      const runtime = new CoreTunRuntime(CONFIG, nativeModule, scheduler);
      const received: TunRuntimeEvent[] = [];
      runtime.subscribe((event: TunRuntimeEvent): void => {
        received.push(event);
      });

      await runtime.start(buildHandle('session-recover-poll'), buildStartOptions());
      expect(scheduler.tasks.length).assertEqual(1);
      await scheduler.tasks[0].run();
      await flushTasks();
      expect(scheduler.tasks.length).assertEqual(2);
      expect(scheduler.tasks[1].canceled).assertFalse();

      nativeModule.snapshotValue = buildNativeSnapshot('session-recover-poll', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 61;
      await runtime.recover('session-recover-poll');

      expect(scheduler.tasks[1].canceled).assertTrue();
      expect(scheduler.tasks.length).assertEqual(3);
      expect(scheduler.tasks[2].canceled).assertFalse();
      expect(scheduler.tasks[2].delayMs).assertEqual(250);

      nativeModule.snapshotValue = buildNativeSnapshot('session-recover-poll', 'READY');
      nativeModule.snapshotValue.counters.rxPackets = 77;
      nativeModule.traceValues = [buildNativeTrace(1, 'session-recover-poll', 'udp')];
      await scheduler.tasks[2].run();
      await flushTasks();

      expect(received.length).assertEqual(1);
      expect(received[0].snapshot.counters.rxPackets).assertEqual(77);
      runtime.dispose();
    });

    it('rejectsRecoverWhenNativeSnapshotBelongsToAnotherSession', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('other-session', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      await expectTunFailure(
        async () => {
          await runtime.recover('session-recover');
        },
        'VPN_TUN_START_FAILED',
        'stale session'
      );
      runtime.dispose();
    });

    it('doesNotConsumeFdWhenSubscribeSurfaceIsUnavailableBeforeNativeStart', 0, async () => {
      const delegate = new FakeNativeTunModule();
      delegate.snapshotValue = buildNativeSnapshot('session-preflight', 'READY');
      const mutableModule = new MutableSurfaceNativeModule(delegate);
      mutableModule.disableSubscribe();
      mutableModule.enableStartTun();
      const runtime = new CoreTunRuntime(CONFIG, mutableModule);
      const handle: TunHandle = buildHandle('session-preflight', 77);

      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'subscription'
      );
      expect(delegate.startCalls.length).assertEqual(0);

      mutableModule.enableSubscribe();
      const snapshot: TunRuntimeSnapshot = await runtime.start(handle, buildStartOptions());
      expect(snapshot.sessionId).assertEqual('session-preflight');
      expect(delegate.startCalls.length).assertEqual(1);
      runtime.dispose();
    });

    it('doesNotConsumeFdWhenStartSurfaceIsUnavailableBeforeNativeCall', 0, async () => {
      const delegate = new FakeNativeTunModule();
      delegate.snapshotValue = buildNativeSnapshot('session-start-surface', 'READY');
      const mutableModule = new MutableSurfaceNativeModule(delegate);
      mutableModule.enableSubscribe();
      mutableModule.disableStartTun();
      const runtime = new CoreTunRuntime(CONFIG, mutableModule);
      const handle: TunHandle = buildHandle('session-start-surface', 78);

      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'surface'
      );
      expect(delegate.startCalls.length).assertEqual(0);

      mutableModule.enableStartTun();
      const snapshot: TunRuntimeSnapshot = await runtime.start(handle, buildStartOptions());
      expect(snapshot.sessionId).assertEqual('session-start-surface');
      expect(delegate.startCalls.length).assertEqual(1);
      runtime.dispose();
    });

    it('consumesFdOnceNativeStartWasAttemptedEvenIfNativeRejects', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.startError = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'native start rejected');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      const handle: TunHandle = buildHandle('session-native-reject', 79);

      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'native start rejected'
      );
      expect(nativeModule.startCalls.length).assertEqual(1);

      nativeModule.startError = undefined;
      nativeModule.snapshotValue = buildNativeSnapshot('session-native-reject', 'READY');
      await expectTunFailure(
        async () => {
          await runtime.start(handle, buildStartOptions());
        },
        'VPN_TUN_START_FAILED',
        'already'
      );
      expect(nativeModule.startCalls.length).assertEqual(1);
      runtime.dispose();
    });

    it('mapsNativeFailuresByCodeInsteadOfMessageTextAndPreservesNativeCode', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      nativeModule.startError = new NativeBridgeFailure('CMFA_INVALID_ARGUMENT', 'fd wording one');
      const firstError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtime.start(buildHandle('session-map-a', 90), buildStartOptions());
      });
      expect(firstError.failure.code).assertEqual('VPN_TUN_FD_INVALID');
      expect(firstError.nativeCode).assertEqual('CMFA_INVALID_ARGUMENT');

      const runtimeSecond = new CoreTunRuntime(CONFIG, nativeModule);
      nativeModule.startError = new NativeBridgeFailure('CMFA_INVALID_ARGUMENT', 'totally different wording');
      const secondError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtimeSecond.start(buildHandle('session-map-b', 91), buildStartOptions());
      });
      expect(secondError.failure.code).assertEqual('VPN_TUN_FD_INVALID');
      expect(secondError.nativeCode).assertEqual('CMFA_INVALID_ARGUMENT');

      const runtimeUnknown = new CoreTunRuntime(CONFIG, nativeModule);
      nativeModule.startError = new NativeBridgeFailure('CMFA_SOMETHING_NEW', 'new backend wording');
      const unknownStartError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtimeUnknown.start(buildHandle('session-map-c', 92), buildStartOptions());
      });
      expect(unknownStartError.failure.code).assertEqual('VPN_TUN_START_FAILED');
      expect(unknownStartError.nativeCode).assertEqual('CMFA_SOMETHING_NEW');

      const runtimeStop = new CoreTunRuntime(CONFIG, nativeModule);
      nativeModule.startError = undefined;
      nativeModule.snapshotValue = buildNativeSnapshot('session-map-stop', 'READY');
      await runtimeStop.start(buildHandle('session-map-stop', 93), buildStartOptions());
      nativeModule.stopError = new NativeBridgeFailure('CMFA_NEW_STOP', 'stop wording changed');
      const stopError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtimeStop.stop();
      });
      expect(stopError.failure.code).assertEqual('VPN_STOP_FAILED');
      expect(stopError.nativeCode).assertEqual('CMFA_NEW_STOP');

      runtime.dispose();
      runtimeSecond.dispose();
      runtimeUnknown.dispose();
      runtimeStop.dispose();
    });

    it('prefersStructuredDetailOverGenericErrorMessageWhenNormalizingTunFailures', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stop-structured-detail', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      await runtime.start(buildHandle('session-stop-structured-detail', 94), buildStartOptions());
      nativeModule.stopError = new NativeBridgeErrorWithGenericMessage(
        'CMFA_BACKEND_ERROR',
        'Native core operation failed',
        'TUN_STOP_EXECUTOR_FAILED_ERROR'
      );

      const stopError: TunRuntimePortError = await captureTunFailure(async () => {
        await runtime.stop();
      });

      expect(stopError.failure.code).assertEqual('VPN_STOP_FAILED');
      expect(stopError.failure.detail).assertEqual('TUN_STOP_EXECUTOR_FAILED_ERROR');
      expect(stopError.nativeCode).assertEqual('CMFA_BACKEND_ERROR');
      runtime.dispose();
    });

    it('closeStaleOutboundConnectionsForwardsThroughNativeWithoutStoppingTun', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-close-stale', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-close-stale', 80), buildStartOptions());

      await runtime.closeStaleOutboundConnections('session-close-stale');

      expect(nativeModule.closeStaleCalls.length).assertEqual(1);
      expect(nativeModule.closeStaleCalls[0]).assertEqual('session-close-stale');
      expect(nativeModule.stopCalls.length).assertEqual(0);
      expect(runtime.snapshot().state).assertEqual('READY');
      runtime.dispose();
    });

    it('closeStaleOutboundConnectionsRejectsInitialIdleStateWithoutNativeCall', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);

      await expectTunFailure(
        async () => {
          await runtime.closeStaleOutboundConnections('session-idle');
        },
        'VPN_TUN_START_FAILED',
        'active session'
      );
      expect(nativeModule.closeStaleCalls.length).assertEqual(0);
      runtime.dispose();
    });

    it('closeStaleOutboundConnectionsRejectsStoppedStateWithoutNativeCall', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-stopped', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-stopped', 82), buildStartOptions());
      nativeModule.snapshotValue = buildNativeSnapshot('session-stopped', 'STOPPED');
      await runtime.stop();

      await expectTunFailure(
        async () => {
          await runtime.closeStaleOutboundConnections('session-stopped');
        },
        'VPN_TUN_START_FAILED',
        'active session'
      );
      expect(nativeModule.closeStaleCalls.length).assertEqual(0);
      runtime.dispose();
    });

    it('closeStaleOutboundConnectionsRejectsStaleSessionWithoutNativeCall', 0, async () => {
      const nativeModule = new FakeNativeTunModule();
      nativeModule.snapshotValue = buildNativeSnapshot('session-close-stale', 'READY');
      const runtime = new CoreTunRuntime(CONFIG, nativeModule);
      await runtime.start(buildHandle('session-close-stale', 81), buildStartOptions());

      await expectTunFailure(
        async () => {
          await runtime.closeStaleOutboundConnections('other-session');
        },
        'VPN_TUN_START_FAILED',
        'session'
      );
      expect(nativeModule.closeStaleCalls.length).assertEqual(0);
      expect(nativeModule.stopCalls.length).assertEqual(0);
      runtime.dispose();
    });
  });
}
