import type { CoreEvent, CoreRuntimeMode, LocalOptions, RuntimeSnapshot } from './CoreModels';
import type {
  CoreProxyGroupList,
  CoreProxyGroupResult,
  CoreProxyQueryContext,
  CoreProxySelectionApplied
} from './CoreProxyModels';
import type { CoreProxyDelaySnapshot } from './CoreProxyDelayModels';

export interface CoreService {
  hello(): string;
  coreVersion(): Promise<string>;
  validateConfiguration(path: string): Promise<void>;
  loadConfiguration(path: string): Promise<void>;
  startLocal(options: LocalOptions): Promise<RuntimeSnapshot>;
  stopRuntime(): Promise<RuntimeSnapshot>;
  runtimeSnapshot(): RuntimeSnapshot;
  queryRuntimeMode?(): CoreRuntimeMode;
  setRuntimeMode?(mode: CoreRuntimeMode): CoreRuntimeMode;
  queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<CoreProxyGroupList>;
  queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyGroupResult>;
  selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<CoreProxySelectionApplied>;
  startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<CoreProxyDelaySnapshot>;
  readProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
  cancelProxyDelayTest(jobId: string): Promise<CoreProxyDelaySnapshot>;
  subscribe(callback: (event: CoreEvent) => void): number;
  unsubscribe(subscriptionId: number): void;
}
