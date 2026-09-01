import { workScheduler } from '@kit.BackgroundTasksKit';

export const SUBSCRIPTION_REFRESH_WORK_ID: number = 7301;
export const SUBSCRIPTION_REFRESH_REPEAT_MS: number = 2 * 60 * 60 * 1000;
const SUBSCRIPTION_REFRESH_BUNDLE_NAME: string = 'com.github.kr328.clash.harmony';
const SUBSCRIPTION_REFRESH_ABILITY_NAME: string = 'SubscriptionRefreshWorkAbility';
const WORK_RECONCILE_ERROR_MESSAGE: string = 'Subscription refresh work reconciliation failed.';

export interface SubscriptionRefreshWorkInfo {
  workId: number;
  bundleName: string;
  abilityName: string;
  isPersisted?: boolean;
  networkType?: workScheduler.NetworkType;
  isCharging?: boolean;
  chargerType?: workScheduler.ChargingType;
  batteryLevel?: number;
  batteryStatus?: workScheduler.BatteryStatus;
  storageRequest?: workScheduler.StorageRequest;
  repeatCycleTime?: number;
  isRepeat?: boolean;
  repeatCount?: number;
  isDeepIdle?: boolean;
  idleWaitTime?: number;
  parameters?: Record<string, number | string | boolean>;
  earliestStartTime?: number;
}

export interface WorkSchedulerSystemPort {
  obtainAllWorks(): Promise<SubscriptionRefreshWorkInfo[]>;
  startWork(work: SubscriptionRefreshWorkInfo): void;
  stopWork(work: SubscriptionRefreshWorkInfo, needCancel: boolean): void;
}

export interface WorkSchedulerDriverError extends Error {
  name: 'WorkSchedulerDriverError';
  code: 'SUBSCRIPTION_REFRESH_WORK_RECONCILE_FAILED';
}

class WorkSchedulerDriverErrorValue extends Error implements WorkSchedulerDriverError {
  name: 'WorkSchedulerDriverError' = 'WorkSchedulerDriverError';
  code: 'SUBSCRIPTION_REFRESH_WORK_RECONCILE_FAILED' = 'SUBSCRIPTION_REFRESH_WORK_RECONCILE_FAILED';

  constructor() {
    super(WORK_RECONCILE_ERROR_MESSAGE);
  }
}

class HarmonyWorkSchedulerSystemPort implements WorkSchedulerSystemPort {
  async obtainAllWorks(): Promise<SubscriptionRefreshWorkInfo[]> {
    const works: workScheduler.WorkInfo[] = await workScheduler.obtainAllWorks();
    return works.map((work: workScheduler.WorkInfo): SubscriptionRefreshWorkInfo => fromSdkWorkInfo(work));
  }

  startWork(work: SubscriptionRefreshWorkInfo): void {
    workScheduler.startWork(toSdkWorkInfo(work));
  }

  stopWork(work: SubscriptionRefreshWorkInfo, needCancel: boolean): void {
    workScheduler.stopWork(toSdkWorkInfo(work), needCancel);
  }
}

export function createSubscriptionRefreshWorkInfo(): SubscriptionRefreshWorkInfo {
  return {
    workId: SUBSCRIPTION_REFRESH_WORK_ID,
    bundleName: SUBSCRIPTION_REFRESH_BUNDLE_NAME,
    abilityName: SUBSCRIPTION_REFRESH_ABILITY_NAME,
    isPersisted: true,
    networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
    isRepeat: true,
    repeatCycleTime: SUBSCRIPTION_REFRESH_REPEAT_MS
  };
}

export class WorkSchedulerDriver {
  private readonly system: WorkSchedulerSystemPort;
  private reconcileTail: Promise<void> = Promise.resolve();

  constructor(system?: WorkSchedulerSystemPort) {
    this.system = system ?? new HarmonyWorkSchedulerSystemPort();
  }

  reconcile(enabled: boolean): Promise<void> {
    const previous: Promise<void> = this.reconcileTail;
    const next: Promise<void> = previous.then(
      async (): Promise<void> => await this.reconcileOnceSafely(enabled),
      async (): Promise<void> => await this.reconcileOnceSafely(enabled)
    );
    this.reconcileTail = next.catch((): void => {
    });
    return next;
  }

  private async reconcileOnceSafely(enabled: boolean): Promise<void> {
    try {
      await this.reconcileOnce(enabled);
    } catch (_) {
      throw new WorkSchedulerDriverErrorValue();
    }
  }

  private async reconcileOnce(enabled: boolean): Promise<void> {
    const allWorks: SubscriptionRefreshWorkInfo[] = await this.system.obtainAllWorks();
    const matching: SubscriptionRefreshWorkInfo[] = allWorks.filter(
      (work: SubscriptionRefreshWorkInfo): boolean => work.workId === SUBSCRIPTION_REFRESH_WORK_ID
    );

    if (!enabled) {
      this.stopMatchingWorks(matching);
      return;
    }

    if (matching.length === 1 && isDesiredSubscriptionRefreshWork(matching[0])) {
      return;
    }

    this.stopMatchingWorks(matching);
    this.system.startWork(createSubscriptionRefreshWorkInfo());
  }

  private stopMatchingWorks(works: SubscriptionRefreshWorkInfo[]): void {
    for (let index: number = 0; index < works.length; index += 1) {
      this.system.stopWork(cloneWorkInfo(works[index]), true);
    }
  }
}

function isDesiredSubscriptionRefreshWork(work: SubscriptionRefreshWorkInfo): boolean {
  return work.workId === SUBSCRIPTION_REFRESH_WORK_ID &&
    work.bundleName === SUBSCRIPTION_REFRESH_BUNDLE_NAME &&
    work.abilityName === SUBSCRIPTION_REFRESH_ABILITY_NAME &&
    work.isPersisted === true &&
    work.networkType === workScheduler.NetworkType.NETWORK_TYPE_ANY &&
    work.isRepeat === true &&
    work.repeatCycleTime === SUBSCRIPTION_REFRESH_REPEAT_MS &&
    work.isCharging === undefined &&
    isUnsetSdkNumber(work.batteryLevel) &&
    isAnyBatteryStatus(work.batteryStatus) &&
    isAnyStorageRequest(work.storageRequest) &&
    isUnsetSdkNumber(work.repeatCount) &&
    work.isDeepIdle === undefined &&
    isEmptyParameters(work.parameters) &&
    isUnsetSdkNumber(work.earliestStartTime);
}

function isAnyBatteryStatus(value: workScheduler.BatteryStatus | undefined): boolean {
  return value === undefined || value === workScheduler.BatteryStatus.BATTERY_STATUS_LOW_OR_OKAY;
}

function isAnyStorageRequest(value: workScheduler.StorageRequest | undefined): boolean {
  return value === undefined || value === workScheduler.StorageRequest.STORAGE_LEVEL_LOW_OR_OKAY;
}

function isUnsetSdkNumber(value: number | undefined): boolean {
  return value === undefined || value === 0;
}

function isEmptyParameters(parameters: Record<string, number | string | boolean> | undefined): boolean {
  return parameters === undefined || Object.keys(parameters).length === 0;
}

function cloneParameters(
  parameters: Record<string, number | string | boolean> | undefined
): Record<string, number | string | boolean> | undefined {
  if (parameters === undefined) {
    return undefined;
  }
  const cloned: Record<string, number | string | boolean> = {};
  for (const key of Object.keys(parameters)) {
    cloned[key] = parameters[key];
  }
  return cloned;
}

function cloneWorkInfo(work: SubscriptionRefreshWorkInfo): SubscriptionRefreshWorkInfo {
  return {
    workId: work.workId,
    bundleName: work.bundleName,
    abilityName: work.abilityName,
    isPersisted: work.isPersisted,
    networkType: work.networkType,
    isCharging: work.isCharging,
    chargerType: work.chargerType,
    batteryLevel: work.batteryLevel,
    batteryStatus: work.batteryStatus,
    storageRequest: work.storageRequest,
    repeatCycleTime: work.repeatCycleTime,
    isRepeat: work.isRepeat,
    repeatCount: work.repeatCount,
    isDeepIdle: work.isDeepIdle,
    idleWaitTime: work.idleWaitTime,
    parameters: cloneParameters(work.parameters),
    earliestStartTime: work.earliestStartTime
  };
}

function fromSdkWorkInfo(work: workScheduler.WorkInfo): SubscriptionRefreshWorkInfo {
  return cloneWorkInfo({
    workId: work.workId,
    bundleName: work.bundleName,
    abilityName: work.abilityName,
    isPersisted: work.isPersisted,
    networkType: work.networkType,
    isCharging: work.isCharging,
    chargerType: work.chargerType,
    batteryLevel: work.batteryLevel,
    batteryStatus: work.batteryStatus,
    storageRequest: work.storageRequest,
    repeatCycleTime: work.repeatCycleTime,
    isRepeat: work.isRepeat,
    repeatCount: work.repeatCount,
    isDeepIdle: work.isDeepIdle,
    idleWaitTime: work.idleWaitTime,
    parameters: work.parameters,
    earliestStartTime: work.earliestStartTime
  });
}

function toSdkWorkInfo(work: SubscriptionRefreshWorkInfo): workScheduler.WorkInfo {
  return {
    workId: work.workId,
    bundleName: work.bundleName,
    abilityName: work.abilityName,
    isPersisted: work.isPersisted,
    networkType: work.networkType,
    isCharging: work.isCharging,
    chargerType: work.chargerType,
    batteryLevel: work.batteryLevel,
    batteryStatus: work.batteryStatus,
    storageRequest: work.storageRequest,
    repeatCycleTime: work.repeatCycleTime,
    isRepeat: work.isRepeat,
    repeatCount: work.repeatCount,
    isDeepIdle: work.isDeepIdle,
    idleWaitTime: work.idleWaitTime,
    parameters: cloneParameters(work.parameters),
    earliestStartTime: work.earliestStartTime
  };
}
