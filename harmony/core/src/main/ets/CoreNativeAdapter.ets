import {
  coreVersion as nativeCoreVersion,
  hello as nativeHello,
  loadConfiguration as nativeLoadConfiguration,
  runtimeSnapshot as nativeRuntimeSnapshot,
  startLocal as nativeStartLocal,
  stopRuntime as nativeStopRuntime,
  subscribe as nativeSubscribe,
  unsubscribe as nativeUnsubscribe,
  validateConfiguration as nativeValidateConfiguration
} from 'libentry.so';
import * as nativeEntry from 'libentry.so';

import { normalizeCoreError } from '@cmfa/shared';
import type { CoreError, CoreEvent, CoreService, LocalOptions, RuntimeSnapshot } from '@cmfa/shared';

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

class CoreNativeAdapter implements CoreService {
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
