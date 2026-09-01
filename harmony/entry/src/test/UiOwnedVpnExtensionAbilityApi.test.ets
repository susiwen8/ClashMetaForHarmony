import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import type { ContinuousNotificationPort } from '@cmfa/shared';
import type { VpnExtensionAbilityApi } from '../main/ets/vpn/HarmonyVpnController';
import { UiOwnedVpnExtensionAbilityApi } from '../main/ets/vpn/UiOwnedVpnExtensionAbilityApi';

class RecordingVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  readonly events: string[];
  startError?: Error;
  stopError?: Error;
  updateError?: Error;

  constructor(events: string[]) {
    this.events = events;
  }

  async startVpnExtensionAbility(_want: Want): Promise<void> {
    this.events.push('extension.start');
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stopVpnExtensionAbility(): Promise<void> {
    this.events.push('extension.stop');
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    this.events.push(`extension.update:${sessionId}:${uploadBytesPerSecond}:${downloadBytesPerSecond}`);
    if (this.updateError !== undefined) {
      throw this.updateError;
    }
  }
}

class RecordingNotification implements ContinuousNotificationPort {
  readonly events: string[];
  startError?: Error;
  stopError?: Error;
  updateError?: Error;
  subscribeCount: number = 0;
  unsubscribeCount: number = 0;
  private listener?: (sessionId: string) => void;

  constructor(events: string[]) {
    this.events = events;
  }

  async start(sessionId: string): Promise<void> {
    this.events.push(`notification.start:${sessionId}`);
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stop(sessionId: string): Promise<void> {
    this.events.push(`notification.stop:${sessionId}`);
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    this.events.push(`notification.update:${sessionId}:${uploadBytesPerSecond}:${downloadBytesPerSecond}`);
    if (this.updateError !== undefined) {
      throw this.updateError;
    }
  }

  subscribeCancellation(listener: (sessionId: string) => void): number {
    this.subscribeCount += 1;
    this.listener = listener;
    return 1;
  }

  unsubscribeCancellation(_subscriptionId: number): void {
    this.unsubscribeCount += 1;
    this.listener = undefined;
  }

  cancel(sessionId: string): void {
    this.listener?.(sessionId);
  }
}

function startWant(sessionId: string): Want {
  return {
    bundleName: 'com.github.kr328.clash.harmony',
    abilityName: 'CmfaVpnExtensionAbility',
    parameters: {
      profileId: 'profile-1',
      versionId: 'version-1',
      sessionId
    }
  };
}

async function settleMicrotasks(turns: number = 8): Promise<void> {
  for (let turn: number = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

export default function uiOwnedVpnExtensionAbilityApiTestsuite() {
  describe('UiOwnedVpnExtensionAbilityApiTest', () => {
    it('clearsAnyStaleExtensionBeforeStartingNotificationAndStopsInReverseOrder', 0, async () => {
      const events: string[] = [];
      const delegate = new RecordingVpnExtensionAbilityApi(events);
      const notification = new RecordingNotification(events);
      const api = new UiOwnedVpnExtensionAbilityApi(delegate, notification);
      api.bindStopHandler(() => {
        events.push('extension.stopped');
      });

      await api.startVpnExtensionAbility(startWant('session-1'));
      await api.stopVpnExtensionAbility();

      expect(events.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-1>notification.update:session-1:0:0>extension.stop>notification.stop:session-1>extension.stopped'
      );
    });

    it('rollsBackVpnWhenNotificationFailsAndSkipsNotificationWhenVpnAuthorizationFails', 0, async () => {
      const notificationFailureEvents: string[] = [];
      const notificationFailureDelegate = new RecordingVpnExtensionAbilityApi(notificationFailureEvents);
      const notificationFailure = new RecordingNotification(notificationFailureEvents);
      notificationFailure.startError = new Error('notification failed');
      const notificationFailureApi = new UiOwnedVpnExtensionAbilityApi(notificationFailureDelegate, notificationFailure);

      try {
        await notificationFailureApi.startVpnExtensionAbility(startWant('session-a'));
      } catch (_) {
      }
      expect(notificationFailureEvents.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-a>extension.stop>notification.stop:session-a'
      );

      const vpnFailureEvents: string[] = [];
      const vpnFailureDelegate = new RecordingVpnExtensionAbilityApi(vpnFailureEvents);
      vpnFailureDelegate.startError = new Error('vpn failed');
      const vpnFailureNotification = new RecordingNotification(vpnFailureEvents);
      const vpnFailureApi = new UiOwnedVpnExtensionAbilityApi(vpnFailureDelegate, vpnFailureNotification);

      try {
        await vpnFailureApi.startVpnExtensionAbility(startWant('session-b'));
      } catch (_) {
      }
      expect(vpnFailureEvents.join('>')).assertEqual('extension.stop>extension.start');
    });

    it('stopsVpnWhenHarmonyCancelsTheOwnedContinuousTask', 0, async () => {
      const events: string[] = [];
      const delegate = new RecordingVpnExtensionAbilityApi(events);
      const notification = new RecordingNotification(events);
      const api = new UiOwnedVpnExtensionAbilityApi(delegate, notification);
      api.bindStopHandler(() => {
        events.push('extension.stopped');
      });

      await api.startVpnExtensionAbility(startWant('session-1'));
      notification.cancel('other-session');
      notification.cancel('session-1');
      await settleMicrotasks();

      expect(events.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-1>notification.update:session-1:0:0>extension.stop>notification.stop:session-1>extension.stopped'
      );
    });

    it('disposeUnsubscribesCancellationIdempotentlyAndIgnoresLaterCancels', 0, async () => {
      const events: string[] = [];
      const delegate = new RecordingVpnExtensionAbilityApi(events);
      const notification = new RecordingNotification(events);
      const api = new UiOwnedVpnExtensionAbilityApi(delegate, notification);

      await api.startVpnExtensionAbility(startWant('session-1'));
      api.dispose();
      api.dispose();
      notification.cancel('session-1');
      await settleMicrotasks();

      expect(notification.subscribeCount).assertEqual(1);
      expect(notification.unsubscribeCount).assertEqual(1);
      expect(events.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-1>notification.update:session-1:0:0'
      );
    });

    it('seedUpdateFailureDoesNotRollbackSuccessfulStart', 0, async () => {
      const events: string[] = [];
      const delegate = new RecordingVpnExtensionAbilityApi(events);
      const notification = new RecordingNotification(events);
      notification.updateError = new Error('seed failed');
      const api = new UiOwnedVpnExtensionAbilityApi(delegate, notification);

      await api.startVpnExtensionAbility(startWant('session-1'));

      expect(events.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-1>notification.update:session-1:0:0'
      );
    });

    it('forwardsTrafficOnlyForTheActiveSessionAndStopsForwardingAfterStop', 0, async () => {
      const events: string[] = [];
      const delegate = new RecordingVpnExtensionAbilityApi(events);
      const notification = new RecordingNotification(events);
      const api = new UiOwnedVpnExtensionAbilityApi(delegate, notification);

      await api.startVpnExtensionAbility(startWant('session-1'));
      await api.updateTraffic('other-session', 10, 20);
      await api.updateTraffic('session-1', 10, 20);
      await api.stopVpnExtensionAbility();
      await api.updateTraffic('session-1', 30, 40);

      expect(events.join('>')).assertEqual(
        'extension.stop>extension.start>notification.start:session-1>notification.update:session-1:0:0>' +
        'notification.update:session-1:10:20>extension.stop>notification.stop:session-1'
      );
    });
  });
}
