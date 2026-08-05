import type { CoreEvent, LocalOptions, RuntimeSnapshot } from './CoreModels';

export interface CoreService {
  hello(): string;
  coreVersion(): Promise<string>;
  validateConfiguration(path: string): Promise<void>;
  loadConfiguration(path: string): Promise<void>;
  startLocal(options: LocalOptions): Promise<RuntimeSnapshot>;
  stopRuntime(): Promise<RuntimeSnapshot>;
  runtimeSnapshot(): RuntimeSnapshot;
  subscribe(callback: (event: CoreEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
}
