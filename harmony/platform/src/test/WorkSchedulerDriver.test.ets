import { describe, expect, it } from '@ohos/hypium';
import {
  SUBSCRIPTION_REFRESH_REPEAT_MS,
  SUBSCRIPTION_REFRESH_WORK_ID,
  WorkSchedulerDriver,
  type SubscriptionRefreshWorkInfo,
  type WorkSchedulerSystemPort
} from '../main/ets/background/WorkSchedulerDriver';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue?: (value: T) => void;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }
}

function cloneWork(work: SubscriptionRefreshWorkInfo): SubscriptionRefreshWorkInfo {
  return {
    workId: work.workId,
    bundleName: work.bundleName,
    abilityName: work.abilityName,
    isPersisted: work.isPersisted,
    networkType: work.networkType,
    isRepeat: work.isRepeat,
    repeatCycleTime: work.repeatCycleTime,
    isCharging: work.isCharging,
    chargerType: work.chargerType,
    batteryLevel: work.batteryLevel,
    batteryStatus: work.batteryStatus,
    storageRequest: work.storageRequest,
    isDeepIdle: work.isDeepIdle,
    idleWaitTime: work.idleWaitTime,
    parameters: work.parameters,
    earliestStartTime: work.earliestStartTime
  };
}

class RecordingWorkSchedulerSystemPort implements WorkSchedulerSystemPort {
  readonly works: SubscriptionRefreshWorkInfo[] = [];
  readonly started: SubscriptionRefreshWorkInfo[] = [];
  readonly stopped: SubscriptionRefreshWorkInfo[] = [];
  readonly stopCancelFlags: boolean[] = [];
  obtainCalls: number = 0;
  failMethod?: 'obtain' | 'start' | 'stop';
  obtainBarrier?: DeferredValue<void>;

  async obtainAllWorks(): Promise<SubscriptionRefreshWorkInfo[]> {
    this.obtainCalls += 1;
    if (this.obtainBarrier !== undefined) {
      await this.obtainBarrier.promise;
      this.obtainBarrier = undefined;
    }
    if (this.failMethod === 'obtain') {
      this.failMethod = undefined;
      throw new Error('unsafe obtain detail');
    }
    return this.works.map((work) => cloneWork(work));
  }

  startWork(work: SubscriptionRefreshWorkInfo): void {
    if (this.failMethod === 'start') {
      this.failMethod = undefined;
      throw new Error('unsafe start detail');
    }
    const cloned = cloneWork(work);
    this.started.push(cloned);
    this.works.push(cloned);
  }

  stopWork(work: SubscriptionRefreshWorkInfo, needCancel: boolean): void {
    if (this.failMethod === 'stop') {
      this.failMethod = undefined;
      throw new Error('unsafe stop detail');
    }
    this.stopped.push(cloneWork(work));
    this.stopCancelFlags.push(needCancel);
    for (let index: number = this.works.length - 1; index >= 0; index -= 1) {
      if (this.works[index].workId === work.workId) {
        this.works.splice(index, 1);
        break;
      }
    }
  }
}

function desiredWork(): SubscriptionRefreshWorkInfo {
  return {
    workId: SUBSCRIPTION_REFRESH_WORK_ID,
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'SubscriptionRefreshWorkAbility',
    isPersisted: true,
    networkType: 0,
    isRepeat: true,
    repeatCycleTime: SUBSCRIPTION_REFRESH_REPEAT_MS
  };
}

export default function workSchedulerDriverTestsuite() {
  describe('WorkSchedulerDriverTest', () => {
    it('createsOnePersistedTwoHourAnyNetworkRepeatWork', 0, () => {
      const work = desiredWork();
      expect(work.workId).assertEqual(7301);
      expect(work.isPersisted).assertTrue();
      expect(work.networkType).assertEqual(0);
      expect(work.isRepeat).assertTrue();
      expect(work.repeatCycleTime).assertEqual(2 * 60 * 60 * 1000);
      expect(work.isCharging).assertUndefined();
      expect(work.parameters).assertUndefined();
    });

    it('startsWhenMissingAndDoesNothingWhenTheExactWorkAlreadyExists', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      const driver = new WorkSchedulerDriver(system);

      await driver.reconcile(true);
      await driver.reconcile(true);

      expect(system.started.length).assertEqual(1);
      expect(system.stopped.length).assertEqual(0);
      expect(system.obtainCalls).assertEqual(2);
    });

    it('treatsSdkMaterializedFalseZeroAndEmptyDefaultsAsNoConstraints', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      const materialized = desiredWork();
      materialized.isCharging = false;
      materialized.chargerType = 0;
      materialized.batteryLevel = 0;
      materialized.batteryStatus = 0;
      materialized.storageRequest = 0;
      materialized.repeatCount = 0;
      materialized.isDeepIdle = false;
      materialized.idleWaitTime = 0;
      materialized.parameters = {};
      materialized.earliestStartTime = 0;
      system.works.push(materialized);
      const driver = new WorkSchedulerDriver(system);

      await driver.reconcile(true);

      expect(system.started.length).assertEqual(0);
      expect(system.stopped.length).assertEqual(0);
    });

    it('replacesAWorkWithAnActuallyEnabledChargingConstraint', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      const constrained = desiredWork();
      constrained.isCharging = true;
      constrained.chargerType = 0;
      system.works.push(constrained);
      const driver = new WorkSchedulerDriver(system);

      await driver.reconcile(true);

      expect(system.stopped.length).assertEqual(1);
      expect(system.started.length).assertEqual(1);
    });

    it('replacesDriftAndDuplicatesWithoutTouchingUnrelatedWorks', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      const drift = desiredWork();
      drift.repeatCycleTime = 3 * 60 * 60 * 1000;
      system.works.push(drift, desiredWork(), {
        workId: 9001,
        bundleName: 'com.example.other',
        abilityName: 'OtherWork'
      });
      const driver = new WorkSchedulerDriver(system);

      await driver.reconcile(true);

      expect(system.stopped.length).assertEqual(2);
      expect(system.stopCancelFlags).assertDeepEquals([true, true]);
      expect(system.started.length).assertEqual(1);
      expect(system.works.some((work) => work.workId === 9001)).assertTrue();
    });

    it('disablesOnlyTheMatchingSubscriptionWorks', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      system.works.push(desiredWork(), desiredWork(), {
        workId: 9001,
        bundleName: 'com.example.other',
        abilityName: 'OtherWork'
      });
      const driver = new WorkSchedulerDriver(system);

      await driver.reconcile(false);

      expect(system.stopped.length).assertEqual(2);
      expect(system.started.length).assertEqual(0);
      expect(system.works.length).assertEqual(1);
      expect(system.works[0].workId).assertEqual(9001);
    });

    it('serializesConcurrentReconcileCallsSoOnlyOneWorkStarts', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      const barrier = new DeferredValue<void>();
      system.obtainBarrier = barrier;
      const driver = new WorkSchedulerDriver(system);

      const first = driver.reconcile(true);
      const second = driver.reconcile(true);
      await Promise.resolve();
      expect(system.obtainCalls).assertEqual(1);
      barrier.resolve(undefined);
      await first;
      await second;

      expect(system.started.length).assertEqual(1);
    });

    it('mapsSystemFailuresToFixedErrorsAndAllowsRetry', 0, async () => {
      const system = new RecordingWorkSchedulerSystemPort();
      system.failMethod = 'start';
      const driver = new WorkSchedulerDriver(system);
      let firstError = '';
      try {
        await driver.reconcile(true);
      } catch (error) {
        firstError = `${error}`;
      }
      expect(firstError).assertContain('Subscription refresh work reconciliation failed.');
      expect(firstError.includes('unsafe start detail')).assertFalse();

      await driver.reconcile(true);
      expect(system.started.length).assertEqual(1);
    });
  });
}
