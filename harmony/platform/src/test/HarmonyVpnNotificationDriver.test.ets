import { describe, expect, it } from '@ohos/hypium';
import {
  CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
  CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE,
  decodeContinuousTaskNotificationInfo,
  decodeContinuousTaskCancelInfo,
  HarmonyVpnNotificationDriver
} from '../main/ets/background/HarmonyVpnNotificationDriver';
import type {
  ContinuousTaskCancelInfo,
  ContinuousTaskDriver,
  ContinuousTaskNotificationInfo,
  ContinuousTaskWantRequest,
  PlatformContinuousTaskContext
} from '../main/ets/background/ContinuousTaskDriver';

class FakeAbilityIdentity {
  readonly bundleName: string;
  readonly moduleName: string;
  readonly name: string;

  constructor(bundleName: string, moduleName: string, name: string) {
    this.bundleName = bundleName;
    this.moduleName = moduleName;
    this.name = name;
  }
}

class ContinuousTaskWantRequestRecord implements ContinuousTaskWantRequest {
  readonly bundleName: string;
  readonly moduleName: string;
  readonly abilityName: string;
  readonly parameters: Record<string, Object>;

  constructor(bundleName: string, moduleName: string, abilityName: string, parameters?: Record<string, Object>) {
    this.bundleName = bundleName;
    this.moduleName = moduleName;
    this.abilityName = abilityName;
    this.parameters = parameters ?? {};
  }
}

class ContinuousTaskNotificationInfoValue implements ContinuousTaskNotificationInfo {
  readonly continuousTaskId?: number;
  readonly notificationId?: number;
  readonly slotType?: number;
  readonly contentType?: number;

  constructor(continuousTaskId?: number, notificationId?: number, slotType?: number, contentType?: number) {
    this.continuousTaskId = continuousTaskId;
    this.notificationId = notificationId;
    this.slotType = slotType;
    this.contentType = contentType;
  }
}

class ContinuousTaskCancelInfoValue implements ContinuousTaskCancelInfo {
  readonly continuousTaskId?: number;
  readonly notificationId?: number;

  constructor(continuousTaskId?: number, notificationId?: number) {
    this.continuousTaskId = continuousTaskId;
    this.notificationId = notificationId;
  }
}

class PlatformContinuousTaskCancelInfoValue {
  readonly id: number;

  constructor(id: number) {
    this.id = id;
  }
}

class PlatformContinuousTaskNotificationInfoValue {
  readonly continuousTaskId?: number;
  readonly notificationId?: number;
  readonly slotType?: number;
  readonly contentType?: number;

  constructor(continuousTaskId?: number, notificationId?: number, slotType?: number, contentType?: number) {
    this.continuousTaskId = continuousTaskId;
    this.notificationId = notificationId;
    this.slotType = slotType;
    this.contentType = contentType;
  }
}

class NotificationUpdateRecordValue {
  readonly notificationId: number;
  readonly title: string;
  readonly text: string;

  constructor(notificationId: number, title: string, text: string) {
    this.notificationId = notificationId;
    this.title = title;
    this.text = text;
  }
}

class FakeContinuousTaskContext implements PlatformContinuousTaskContext {
  readonly abilityInfo: FakeAbilityIdentity;

  constructor(bundleName: string, moduleName: string, abilityName: string) {
    this.abilityInfo = new FakeAbilityIdentity(bundleName, moduleName, abilityName);
  }
}

class FakeContinuousTaskDriver implements ContinuousTaskDriver {
  readonly wants: ContinuousTaskWantRequest[] = [];
  readonly startModes: string[][] = [];
  readonly stopIds: Array<number | undefined> = [];
  readonly onCallbacks: Array<(info: ContinuousTaskCancelInfo) => void> = [];
  readonly offCallbacks: Array<(info: ContinuousTaskCancelInfo) => void> = [];
  readonly wantAgents: Object[] = [];
  readonly updateRecords: NotificationUpdateRecordValue[] = [];
  createWantAgentError?: Error;
  startError?: Error;
  stopError?: Error;
  onCancelError?: Error;
  offCancelError?: Error;
  updateError?: Error;
  nextNotificationInfo: ContinuousTaskNotificationInfo | null = null;

  async createWantAgent(want: ContinuousTaskWantRequest): Promise<Object> {
    this.wants.push(new ContinuousTaskWantRequestRecord(
      want.bundleName,
      want.moduleName,
      want.abilityName,
      want.parameters
    ));
    if (this.createWantAgentError !== undefined) {
      throw this.createWantAgentError;
    }
    const agent: Object = new FakeAbilityIdentity(`agent-${this.wants.length}`, '', '');
    this.wantAgents.push(agent);
    return agent;
  }

  async startBackgroundTask(_wantAgent: Object, backgroundModes: string[]): Promise<ContinuousTaskNotificationInfo | null> {
    this.startModes.push(backgroundModes.slice());
    if (this.startError !== undefined) {
      throw this.startError;
    }
    if (this.nextNotificationInfo === null) {
      return null;
    }
    return new ContinuousTaskNotificationInfoValue(
      this.nextNotificationInfo.continuousTaskId,
      this.nextNotificationInfo.notificationId,
      this.nextNotificationInfo.slotType,
      this.nextNotificationInfo.contentType
    );
  }

  async stopBackgroundTask(continuousTaskId?: number): Promise<void> {
    this.stopIds.push(continuousTaskId);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  onCancel(callback: (info: ContinuousTaskCancelInfo) => void): void {
    if (this.onCancelError !== undefined) {
      throw this.onCancelError;
    }
    this.onCallbacks.push(callback);
  }

  offCancel(callback: (info: ContinuousTaskCancelInfo) => void): void {
    this.offCallbacks.push(callback);
    if (this.offCancelError !== undefined) {
      throw this.offCancelError;
    }
  }

  async updateNotification(notificationId: number, title: string, text: string): Promise<void> {
    this.updateRecords.push(new NotificationUpdateRecordValue(notificationId, title, text));
    if (this.updateError !== undefined) {
      throw this.updateError;
    }
  }

  emitCancellation(info: ContinuousTaskCancelInfo): void {
    const callbacks = this.onCallbacks.slice();
    for (let index = 0; index < callbacks.length; index += 1) {
      callbacks[index](new ContinuousTaskCancelInfoValue(info.continuousTaskId, info.notificationId));
    }
  }
}

export default function harmonyVpnNotificationDriverTestsuite() {
  describe('HarmonyVpnNotificationDriverTest', () => {
    it('startsOneSessionWithEntryAbilityWantAndEmitsCancellationOnlyForTheCurrentSession', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      const cancellations: string[] = [];
      notification.subscribeCancellation((sessionId: string) => {
        cancellations.push(sessionId);
      });

      await notification.start('session-a');

      expect(driver.wants.length).assertEqual(1);
      expect(driver.wants[0].bundleName).assertEqual('com.github.kr328.clash.harmony');
      expect(driver.wants[0].moduleName).assertEqual('entry');
      expect(driver.wants[0].abilityName).assertEqual('EntryAbility');
      expect(Object.keys(driver.wants[0].parameters).length).assertEqual(0);
      expect(driver.startModes.length).assertEqual(1);
      expect(driver.startModes[0].join(',')).assertEqual('dataTransfer');
      expect(driver.onCallbacks.length).assertEqual(1);

      driver.emitCancellation(new ContinuousTaskCancelInfoValue(99, 99));
      driver.emitCancellation(new ContinuousTaskCancelInfoValue(42, 99));
      driver.emitCancellation(new ContinuousTaskCancelInfoValue(99, 7));

      expect(cancellations.length).assertEqual(1);
      expect(cancellations[0]).assertEqual('session-a');

      await notification.stop('session-a');
      expect(driver.stopIds.length).assertEqual(1);
      expect(driver.stopIds[0]).assertEqual(42);
      expect(driver.offCallbacks.length).assertEqual(1);
      expect(driver.offCallbacks[0] === driver.onCallbacks[0]).assertTrue();
    });

    it('decodesNotificationOwnershipMetadataFromThePlatformObject', 0, () => {
      const decoded: ContinuousTaskNotificationInfo | null = decodeContinuousTaskNotificationInfo(
        new PlatformContinuousTaskNotificationInfoValue(
          42,
          7,
          CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
          CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
        )
      );

      expect(decoded?.continuousTaskId).assertEqual(42);
      expect(decoded?.notificationId).assertEqual(7);
      expect(decoded?.slotType).assertEqual(CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE);
      expect(decoded?.contentType).assertEqual(CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE);
    });

    it('rejectsDuplicateStartCleansUpPartialStartAndKeepsRepeatedStopIdempotent', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const duplicateDriver = new FakeContinuousTaskDriver();
      duplicateDriver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(88, 9);
      const duplicateNotification = new HarmonyVpnNotificationDriver(context, duplicateDriver);

      await duplicateNotification.start('session-dup');
      let duplicateRejected: boolean = false;
      try {
        await duplicateNotification.start('session-next');
        expect(false).assertTrue();
      } catch (_) {
        duplicateRejected = true;
      }
      expect(duplicateRejected).assertTrue();

      const failureDriver = new FakeContinuousTaskDriver();
      failureDriver.startError = new Error('start failed');
      const failureNotification = new HarmonyVpnNotificationDriver(context, failureDriver);
      let failedStartRejected: boolean = false;
      try {
        await failureNotification.start('session-fail');
        expect(false).assertTrue();
      } catch (_) {
        failedStartRejected = true;
      }
      expect(failedStartRejected).assertTrue();
      expect(failureDriver.onCallbacks.length).assertEqual(1);
      expect(failureDriver.offCallbacks.length).assertEqual(1);
      expect(failureDriver.offCallbacks[0] === failureDriver.onCallbacks[0]).assertTrue();
      expect(failureDriver.stopIds.length).assertEqual(0);

      const repeatedDriver = new FakeContinuousTaskDriver();
      repeatedDriver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(11, 12);
      const repeatedNotification = new HarmonyVpnNotificationDriver(context, repeatedDriver);
      await repeatedNotification.start('session-stop');
      await repeatedNotification.stop('wrong-session');
      await repeatedNotification.stop('session-stop');
      await repeatedNotification.stop('session-stop');

      expect(repeatedDriver.stopIds.length).assertEqual(1);
      expect(repeatedDriver.stopIds[0]).assertEqual(11);
      expect(repeatedDriver.offCallbacks.length).assertEqual(1);
    });

    it('toleratesMissingNotificationIdsAndDoesNotLeakProfileOrSecretParameters', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = null;
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      const cancellations: string[] = [];
      notification.subscribeCancellation((sessionId: string) => {
        cancellations.push(sessionId);
      });

      await notification.start('session-open');

      expect(driver.wants.length).assertEqual(1);
      expect(Object.keys(driver.wants[0].parameters).join(',')).assertEqual('');
      driver.emitCancellation(new ContinuousTaskCancelInfoValue());
      expect(cancellations.length).assertEqual(1);
      expect(cancellations[0]).assertEqual('session-open');

      await notification.stop('session-open');
      await notification.stop('session-open');
      expect(driver.stopIds.length).assertEqual(1);
      expect(driver.stopIds[0]).assertUndefined();
    });

    it('updatesOnlyTheLiveViewNotificationOwnedByTheActiveSession', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);

      await notification.start('session-live');
      await notification.updateTraffic('wrong-session', 10, 20);
      expect(driver.updateRecords.length).assertEqual(0);

      await notification.updateTraffic('session-live', 0, 0);
      await notification.updateTraffic('session-live', 512, 1023);
      await notification.updateTraffic('session-live', 1024, 1536);
      await notification.updateTraffic('session-live', 1048576, 1572864);
      await notification.updateTraffic('session-live', 1073741824, 2147483648);

      expect(driver.updateRecords.length).assertEqual(5);
      expect(driver.updateRecords[0].notificationId).assertEqual(7);
      expect(driver.updateRecords[0].title).assertEqual('Clash Meta VPN');
      expect(driver.updateRecords[0].text).assertEqual('↑ 0 B/s  ↓ 0 B/s');
      expect(driver.updateRecords[1].text).assertEqual('↑ 512 B/s  ↓ 1023 B/s');
      expect(driver.updateRecords[2].text).assertEqual('↑ 1.0 KiB/s  ↓ 1.5 KiB/s');
      expect(driver.updateRecords[3].text).assertEqual('↑ 1.0 MiB/s  ↓ 1.5 MiB/s');
      expect(driver.updateRecords[4].text).assertEqual('↑ 1.0 GiB/s  ↓ 2.0 GiB/s');
    });

    it('formatsInvalidOrUnsafeTrafficInputsAsZeroWithoutLeakingOtherState', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);

      await notification.start('session-live');
      await notification.updateTraffic('session-live', -1, 1.5);
      await notification.updateTraffic('session-live', Number.NaN, Number.MAX_SAFE_INTEGER + 1);

      expect(driver.updateRecords.length).assertEqual(2);
      expect(driver.updateRecords[0].text).assertEqual('↑ 0 B/s  ↓ 0 B/s');
      expect(driver.updateRecords[1].text).assertEqual('↑ 0 B/s  ↓ 0 B/s');
    });

    it('ignoresTrafficUpdatesWhenNotificationOwnershipIsMissingWrongSessionOrStoppedAndStillUpdatesNonLiveMetadataWhenIdExists', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );

      const missingIdDriver = new FakeContinuousTaskDriver();
      missingIdDriver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        undefined,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const missingIdNotification = new HarmonyVpnNotificationDriver(context, missingIdDriver);
      await missingIdNotification.start('session-missing');
      await missingIdNotification.updateTraffic('session-missing', 100, 200);
      expect(missingIdDriver.updateRecords.length).assertEqual(0);

      const nonLiveDriver = new FakeContinuousTaskDriver();
      nonLiveDriver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(42, 7, 99, 88);
      const nonLiveNotification = new HarmonyVpnNotificationDriver(context, nonLiveDriver);
      await nonLiveNotification.start('session-nonlive');
      await nonLiveNotification.updateTraffic('session-nonlive', 100, 200);
      expect(nonLiveDriver.updateRecords.length).assertEqual(1);
      expect(nonLiveDriver.updateRecords[0].notificationId).assertEqual(7);
      expect(nonLiveDriver.updateRecords[0].title).assertEqual('Clash Meta VPN');
      expect(nonLiveDriver.updateRecords[0].text).assertEqual('↑ 100 B/s  ↓ 200 B/s');

      const stoppedDriver = new FakeContinuousTaskDriver();
      stoppedDriver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const stoppedNotification = new HarmonyVpnNotificationDriver(context, stoppedDriver);
      await stoppedNotification.start('session-stopped');
      await stoppedNotification.stop('session-stopped');
      await stoppedNotification.updateTraffic('session-stopped', 100, 200);
      expect(stoppedDriver.updateRecords.length).assertEqual(0);
    });

    it('decodesThePlatformCancellationIdAsTheContinuousTaskId', 0, () => {
      const decoded: ContinuousTaskCancelInfo = decodeContinuousTaskCancelInfo(
        new PlatformContinuousTaskCancelInfoValue(42)
      );

      expect(decoded.continuousTaskId).assertEqual(42);
      expect(decoded.notificationId).assertUndefined();
    });

    it('mapsPlatformCancellationToTheOnlyActiveSessionWhenStartReturnedOnlyNotificationId', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(undefined, 7);
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      const cancellations: string[] = [];
      notification.subscribeCancellation((sessionId: string) => {
        cancellations.push(sessionId);
      });

      await notification.start('session-notification-only');
      driver.emitCancellation(decodeContinuousTaskCancelInfo(new PlatformContinuousTaskCancelInfoValue(42)));

      expect(cancellations.join(',')).assertEqual('session-notification-only');
    });

    it('rejectsOnCancelFailureBeforeStartingAndAllowsARetry', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.onCancelError = new Error('subscribe failed');
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      let rejected: boolean = false;

      try {
        await notification.start('session-first');
      } catch (_) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(driver.startModes.length).assertEqual(0);
      driver.onCancelError = undefined;
      await notification.start('session-retry');
      expect(driver.startModes.length).assertEqual(1);
    });

    it('preservesTheStartFailureWhenCancellationDetachAlsoFails', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.startError = new Error('primary start failed');
      driver.offCancelError = new Error('detach failed');
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      let detail: string = '';

      try {
        await notification.start('session-failure');
      } catch (error) {
        detail = (error as Error).message;
      }

      expect(detail).assertEqual('primary start failed');
      expect(driver.offCallbacks.length).assertEqual(1);
      driver.startError = undefined;
      driver.offCancelError = undefined;
      await notification.start('session-retry');
      expect(driver.offCallbacks.length).assertEqual(2);
    });

    it('stillStopsTheBackgroundTaskWhenCancellationDetachFails', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);

      await notification.start('session-stop');
      driver.offCancelError = new Error('detach failed');
      let rejected: boolean = false;
      try {
        await notification.stop('session-stop');
      } catch (_) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      expect(driver.stopIds.join(',')).assertEqual('42');
      driver.offCancelError = undefined;
      await notification.stop('session-stop');
      expect(driver.offCallbacks.length).assertEqual(2);
      expect(driver.stopIds.join(',')).assertEqual('42');
    });

    it('keepsSessionOwnershipUntilBackgroundStopSucceedsSoStopCanRetry', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);

      await notification.start('session-retry-stop');
      await notification.updateTraffic('session-retry-stop', 1024, 2048);
      driver.stopError = new Error('stop failed');
      let rejected: boolean = false;
      try {
        await notification.stop('session-retry-stop');
      } catch (_) {
        rejected = true;
      }

      expect(rejected).assertTrue();
      await notification.updateTraffic('session-retry-stop', 2048, 3072);
      driver.stopError = undefined;
      await notification.stop('session-retry-stop');
      expect(driver.stopIds.join(',')).assertEqual('42,42');
      expect(driver.updateRecords.length).assertEqual(2);
    });

    it('surfacesPublishFailuresButKeepsOwnershipAndCancellationStateForRetry', 0, async () => {
      const context = new FakeContinuousTaskContext(
        'com.github.kr328.clash.harmony',
        'entry',
        'CmfaVpnExtensionAbility'
      );
      const driver = new FakeContinuousTaskDriver();
      driver.nextNotificationInfo = new ContinuousTaskNotificationInfoValue(
        42,
        7,
        CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE,
        CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE
      );
      const notification = new HarmonyVpnNotificationDriver(context, driver);
      const cancellations: string[] = [];
      notification.subscribeCancellation((sessionId: string) => {
        cancellations.push(sessionId);
      });

      await notification.start('session-retry');
      driver.updateError = new Error('publish failed');

      let rejected: boolean = false;
      try {
        await notification.updateTraffic('session-retry', 1024, 2048);
      } catch (error) {
        rejected = (error as Error).message === 'publish failed';
      }

      expect(rejected).assertTrue();
      expect(driver.stopIds.length).assertEqual(0);
      expect(cancellations.length).assertEqual(0);

      driver.updateError = undefined;
      await notification.updateTraffic('session-retry', 2048, 4096);
      driver.emitCancellation(new ContinuousTaskCancelInfoValue(42, 999));

      expect(driver.updateRecords.length).assertEqual(2);
      expect(driver.updateRecords[1].text).assertEqual('↑ 2.0 KiB/s  ↓ 4.0 KiB/s');
      expect(cancellations.join(',')).assertEqual('session-retry');
    });
  });
}
