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

export const CORE_BRIDGE_VERSION: string = '1.0.0';

export class CoreNativeAdapter implements CoreService {
  hello(): string {
    try {
      return nativeHello();
    } catch (error) {
      throw normalizeCoreError('hello', error as Object | Error | undefined);
    }
  }

  coreVersion(): Promise<string> {
    return this.wrapAsync<string>('coreVersion', (): Promise<string> => nativeCoreVersion());
  }

  validateConfiguration(configPath: string): Promise<void> {
    return this.wrapAsync<void>('validateConfiguration', (): Promise<void> => nativeValidateConfiguration(configPath));
  }

  loadConfiguration(configPath: string): Promise<void> {
    return this.wrapAsync<void>('loadConfiguration', (): Promise<void> => nativeLoadConfiguration(configPath));
  }

  startLocal(options: LocalOptions): Promise<RuntimeSnapshot> {
    return this.wrapAsync<RuntimeSnapshot>('startLocal', (): Promise<RuntimeSnapshot> => nativeStartLocal(options));
  }

  stopRuntime(): Promise<RuntimeSnapshot> {
    return this.wrapAsync<RuntimeSnapshot>('stopRuntime', (): Promise<RuntimeSnapshot> => nativeStopRuntime());
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
    const probeModule: InternalProbeNativeModule = nativeEntry as InternalProbeNativeModule;
    if (typeof probeModule.probeHttps !== 'function') {
      return Promise.reject(normalizeCoreError('probeHttps', new Error('Self-test probe surface is disabled in this build.')));
    }
    return this.wrapAsync<InternalProbeResult>('probeHttps', (): Promise<InternalProbeResult> => probeModule.probeHttps!(request));
  }

  private wrapAsync<T>(operation: string, invoke: () => Promise<T>): Promise<T> {
    try {
      return invoke().catch((error: CoreError | Error | Object | undefined) => {
        return Promise.reject(normalizeCoreError(operation, error));
      });
    } catch (error) {
      return Promise.reject(normalizeCoreError(operation, error as Object | Error | undefined));
    }
  }
}
