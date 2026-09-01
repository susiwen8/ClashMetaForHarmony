import {
  cancelProxyDelayTest as nativeCancelProxyDelayTest,
  coreVersion as nativeCoreVersion,
  hello as nativeHello,
  loadConfiguration as nativeLoadConfiguration,
  queryProxyGroup as nativeQueryProxyGroup,
  queryProxyGroups as nativeQueryProxyGroups,
  queryRuntimeMode as nativeQueryRuntimeMode,
  readProxyDelayTest as nativeReadProxyDelayTest,
  runtimeSnapshot as nativeRuntimeSnapshot,
  selectProxy as nativeSelectProxy,
  setRuntimeMode as nativeSetRuntimeMode,
  startProxyDelayTest as nativeStartProxyDelayTest,
  startLocal as nativeStartLocal,
  stopRuntime as nativeStopRuntime,
  subscribe as nativeSubscribe,
  unsubscribe as nativeUnsubscribe,
  validateConfiguration as nativeValidateConfiguration
} from 'libentry.so';
import * as nativeEntry from 'libentry.so';

import {
  cloneCoreProxyDelaySnapshot,
  cloneCoreProxyQueryContext,
  normalizeCoreRuntimeMode,
  normalizeCoreError,
  type CoreProxyDelaySnapshot,
  type CoreProxyGroupList,
  type CoreProxyGroupResult,
  type CoreProxyQueryContext,
  type CoreProxySelectionApplied
} from '@cmfa/shared';
import type { CoreError, CoreEvent, CoreRuntimeMode, CoreService, LocalOptions, RuntimeSnapshot } from '@cmfa/shared';
import { decodeProxyGroupList, decodeProxyGroupResult, decodeProxySelectionApplied } from './ProxyNativeCodec';
import {
  decodeCancelProxyDelayTest,
  decodeReadProxyDelayTest,
  decodeStartProxyDelayTest
} from './ProxyDelayNativeCodec';

interface InternalProbeRequest {
  probeRunId: string;
  protocol: string;
  listenerAddress: string;
  originUrl: string;
  caPem: string;
  expectedBodySha256: string;
}

interface InternalProbeTrackerRecord {
  connectionId: string;
  sourceAddress: string;
  destinationAddress: string;
  inboundType: string;
  openedAt: string;
}

interface InternalProbeErrorResult {
  code: string;
  stage: string;
  detail: string;
}

interface InternalProbeResult {
  ok: boolean;
  protocol: string;
  httpStatus: number;
  bodyBytes: number;
  probeRunId: string;
  requestIdEcho: string;
  originId: string;
  responseSha256: string;
  tlsPeerSha256: string;
  startedAt: string;
  completedAt: string;
  clientLocalAddress: string;
  clientRemoteAddress: string;
  tracker: InternalProbeTrackerRecord;
  error: InternalProbeErrorResult;
}

interface InternalProbeNativeModule {
  probeHttps?: (request: InternalProbeRequest) => Promise<InternalProbeResult>;
}

export interface InternalNativeRuntimeEvent {
  type: 'runtime' | 'log';
  state?: string;
  level?: string;
  message: string;
  code?: string;
  sessionId?: string;
  traceId?: string;
  ingress?: string;
  protocol?: string;
}

export interface InternalTunNativeFailure {
  code: string;
  detail: string;
}

export interface InternalTunNativeCounters {
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

export interface InternalTunNativeSnapshot {
  sessionId: string;
  state: 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR';
  counters: InternalTunNativeCounters;
  failure: InternalTunNativeFailure | null;
}

export interface InternalTunNativeTrace {
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

export interface InternalTunNativeCaptureConfig {
  addresses: string[];
  routes: string[];
  dnsServers: string[];
  mtu: number;
  ipv4: boolean;
  ipv6: boolean;
  isBlocking: boolean;
  blockedApplications: string[];
  trustedApplications: string[];
}

export interface InternalTunNativeStartOptions {
  fd: number;
  vpnId: string;
  sessionId: string;
  configPath: string;
  mixedPort: number;
  platformApiLevel: number;
  processProtected: boolean;
  captureConfig: InternalTunNativeCaptureConfig;
  dnsServers: string[];
}

export interface InternalTunNativeModule extends InternalProbeNativeModule {
  queryRuntimeMode?: () => string;
  setRuntimeMode?: (mode: CoreRuntimeMode) => string;
  queryProxyGroups?: (context: CoreProxyQueryContext, selectableOnly: boolean) => Promise<string>;
  queryProxyGroup?: (context: CoreProxyQueryContext, groupName: string) => Promise<string>;
  selectProxy?: (context: CoreProxyQueryContext, groupName: string, memberName: string) => Promise<string>;
  startProxyDelayTest?: (context: CoreProxyQueryContext, groupName: string) => Promise<string>;
  readProxyDelayTest?: (jobId: string) => Promise<string>;
  cancelProxyDelayTest?: (jobId: string) => Promise<string>;
  subscribe?: (callback: (event: InternalNativeRuntimeEvent) => void) => number;
  unsubscribe?: (subscriptionId: number) => void;
  startTun?: (options: InternalTunNativeStartOptions) => Promise<InternalTunNativeSnapshot>;
  stopTun?: () => Promise<InternalTunNativeSnapshot>;
  closeStaleOutboundConnections?: (sessionId: string) => Promise<void>;
  tunSnapshot?: () => Promise<InternalTunNativeSnapshot>;
  readTunTraces?: (afterSequence: number) => Promise<InternalTunNativeTrace[]>;
}

export const CORE_BRIDGE_VERSION: string = '1.0.0';

export function getInternalNativeModule(): InternalTunNativeModule {
  return nativeEntry as InternalTunNativeModule;
}

export function wrapNativeAsync<T>(operation: string, invoke: () => Promise<T>): Promise<T> {
  try {
    return invoke().catch((error: CoreError | Error | Object | undefined) => {
      return Promise.reject(normalizeCoreError(operation, error));
    });
  } catch (error) {
    return Promise.reject(normalizeCoreError(operation, error as Object | Error | undefined));
  }
}

export class CoreNativeAdapter implements CoreService {
  private readonly proxyModule: InternalTunNativeModule;

  constructor(proxyModule: InternalTunNativeModule = getInternalNativeModule()) {
    this.proxyModule = proxyModule;
  }

  hello(): string {
    try {
      return nativeHello();
    } catch (error) {
      throw normalizeCoreError('hello', error as Object | Error | undefined);
    }
  }

  coreVersion(): Promise<string> {
    return wrapNativeAsync<string>('coreVersion', (): Promise<string> => nativeCoreVersion());
  }

  validateConfiguration(configPath: string): Promise<void> {
    return wrapNativeAsync<void>('validateConfiguration', (): Promise<void> => nativeValidateConfiguration(configPath));
  }

  loadConfiguration(configPath: string): Promise<void> {
    return wrapNativeAsync<void>('loadConfiguration', (): Promise<void> => nativeLoadConfiguration(configPath));
  }

  startLocal(options: LocalOptions): Promise<RuntimeSnapshot> {
    return wrapNativeAsync<RuntimeSnapshot>('startLocal', (): Promise<RuntimeSnapshot> => nativeStartLocal(options));
  }

  stopRuntime(): Promise<RuntimeSnapshot> {
    return wrapNativeAsync<RuntimeSnapshot>('stopRuntime', (): Promise<RuntimeSnapshot> => nativeStopRuntime());
  }

  runtimeSnapshot(): RuntimeSnapshot {
    try {
      return nativeRuntimeSnapshot();
    } catch (error) {
      throw normalizeCoreError('runtimeSnapshot', error as Object | Error | undefined);
    }
  }

  queryRuntimeMode(): CoreRuntimeMode {
    try {
      const rawMode: string = this.proxyModule.queryRuntimeMode !== undefined
        ? this.proxyModule.queryRuntimeMode()
        : nativeQueryRuntimeMode();
      return normalizeCoreRuntimeMode(rawMode);
    } catch (error) {
      throw normalizeCoreError('queryRuntimeMode', error as Object | Error | undefined);
    }
  }

  setRuntimeMode(mode: CoreRuntimeMode): CoreRuntimeMode {
    const normalizedMode: CoreRuntimeMode = normalizeCoreRuntimeMode(mode);
    try {
      const rawMode: string = this.proxyModule.setRuntimeMode !== undefined
        ? this.proxyModule.setRuntimeMode(normalizedMode)
        : nativeSetRuntimeMode(normalizedMode);
      return normalizeCoreRuntimeMode(rawMode);
    } catch (error) {
      throw normalizeCoreError('setRuntimeMode', error as Object | Error | undefined);
    }
  }

  queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList> {
    const expectedContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    const nativeContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    return wrapNativeAsync<string>('queryProxyGroups', (): Promise<string> =>
      this.proxyModule.queryProxyGroups !== undefined
        ? this.proxyModule.queryProxyGroups(nativeContext, selectableOnly)
        : nativeQueryProxyGroups(nativeContext, selectableOnly)
    )
      .then((raw: string): CoreProxyGroupList => decodeProxyGroupList(raw, expectedContext));
  }

  queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult> {
    const expectedContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    const nativeContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    return wrapNativeAsync<string>('queryProxyGroup', (): Promise<string> =>
      this.proxyModule.queryProxyGroup !== undefined
        ? this.proxyModule.queryProxyGroup(nativeContext, groupName)
        : nativeQueryProxyGroup(nativeContext, groupName)
    )
      .then((raw: string): CoreProxyGroupResult => decodeProxyGroupResult(raw, expectedContext));
  }

  selectProxy(
    context: CoreProxyQueryContext,
    groupName: string,
    memberName: string
  ): Promise<CoreProxySelectionApplied> {
    const expectedContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    const nativeContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    return wrapNativeAsync<string>('selectProxy', (): Promise<string> =>
      this.proxyModule.selectProxy !== undefined
        ? this.proxyModule.selectProxy(nativeContext, groupName, memberName)
        : nativeSelectProxy(nativeContext, groupName, memberName)
    )
      .then((raw: string): CoreProxySelectionApplied => decodeProxySelectionApplied(raw, expectedContext));
  }

  startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot> {
    const expectedContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    const nativeContext: CoreProxyQueryContext = cloneCoreProxyQueryContext(context);
    return wrapNativeAsync<string>('startProxyDelayTest', (): Promise<string> =>
      this.proxyModule.startProxyDelayTest !== undefined
        ? this.proxyModule.startProxyDelayTest(nativeContext, groupName)
        : nativeStartProxyDelayTest(nativeContext, groupName)
    )
      .then((raw: string): CoreProxyDelaySnapshot =>
        cloneCoreProxyDelaySnapshot(decodeStartProxyDelayTest(raw, expectedContext, groupName))
      );
  }

  readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return wrapNativeAsync<string>('readProxyDelayTest', (): Promise<string> =>
      this.proxyModule.readProxyDelayTest !== undefined
        ? this.proxyModule.readProxyDelayTest(jobId)
        : nativeReadProxyDelayTest(jobId)
    )
      .then((raw: string): CoreProxyDelaySnapshot =>
        cloneCoreProxyDelaySnapshot(decodeReadProxyDelayTest(raw, jobId))
      );
  }

  cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot> {
    return wrapNativeAsync<string>('cancelProxyDelayTest', (): Promise<string> =>
      this.proxyModule.cancelProxyDelayTest !== undefined
        ? this.proxyModule.cancelProxyDelayTest(jobId)
        : nativeCancelProxyDelayTest(jobId)
    )
      .then((raw: string): CoreProxyDelaySnapshot =>
        cloneCoreProxyDelaySnapshot(decodeCancelProxyDelayTest(raw, jobId))
      );
  }

  subscribe(callback: (event: CoreEvent) => void): number {
    try {
      return nativeSubscribe(callback);
    } catch (error) {
      throw normalizeCoreError('subscribe', error as Object | Error | undefined);
    }
  }

  unsubscribe(subscriptionId: number): void {
    try {
      nativeUnsubscribe(subscriptionId);
    } catch (error) {
      throw normalizeCoreError('unsubscribe', error as Object | Error | undefined);
    }
  }

  probeHttpsForSelfTest(request: InternalProbeRequest): Promise<InternalProbeResult> {
    const probeModule: InternalProbeNativeModule = getInternalNativeModule();
    if (typeof probeModule.probeHttps !== 'function') {
      return Promise.reject(normalizeCoreError('probeHttps', new Error('Self-test probe surface is disabled in this build.')));
    }
    return wrapNativeAsync<InternalProbeResult>('probeHttps', (): Promise<InternalProbeResult> => probeModule.probeHttps!(request));
  }
}

export function createCoreService(): CoreService {
  return new CoreNativeAdapter();
}
