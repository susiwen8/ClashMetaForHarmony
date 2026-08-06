import {
  coreVersion as nativeCoreVersion,
  hello as nativeHello,
  loadConfiguration as nativeLoadConfiguration,
  probeHttps as nativeProbeHttps,
  runtimeSnapshot as nativeRuntimeSnapshot,
  startLocal as nativeStartLocal,
  stopRuntime as nativeStopRuntime,
  subscribe as nativeSubscribe,
  unsubscribe as nativeUnsubscribe,
  validateConfiguration as nativeValidateConfiguration
} from 'libentry.so';

import { normalizeCoreError } from '@cmfa/shared';
import type { CoreError, CoreEvent, CoreService, LocalOptions, ProbeRequest, ProbeResult, RuntimeSnapshot } from '@cmfa/shared';

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

  probeHttps(request: ProbeRequest): Promise<ProbeResult> {
    return this.wrapAsync<ProbeResult>('probeHttps', (): Promise<ProbeResult> => nativeProbeHttps(request));
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
