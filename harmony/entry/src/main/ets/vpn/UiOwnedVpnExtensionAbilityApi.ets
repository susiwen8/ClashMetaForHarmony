import type { Want } from '@kit.AbilityKit';
import type { ContinuousNotificationPort } from '@cmfa/shared';
import type { VpnExtensionAbilityApi } from './HarmonyVpnController';

export class UiOwnedVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  private readonly delegate: VpnExtensionAbilityApi;
  private readonly notification: ContinuousNotificationPort;
  private readonly cancellationSubscriptionId: number;
  private activeSessionId?: string;
  private startPromise?: Promise<void>;
  private stopPromise?: Promise<void>;
  private onStopped?: () => void;
  private disposed: boolean = false;

  constructor(delegate: VpnExtensionAbilityApi, notification: ContinuousNotificationPort) {
    this.delegate = delegate;
    this.notification = notification;
    this.cancellationSubscriptionId = notification.subscribeCancellation((sessionId: string): void => {
      if (sessionId !== this.activeSessionId) {
        return;
      }
      void this.stopVpnExtensionAbility().catch(() => {
      });
    });
  }

  async startVpnExtensionAbility(want: Want): Promise<void> {
    if (this.activeSessionId !== undefined || this.startPromise !== undefined || this.stopPromise !== undefined) {
      throw new Error('VPN extension lifecycle is already active.');
    }
    const sessionId: string = readSessionId(want);
    const startPromise: Promise<void> = this.startInternal(want, sessionId).finally(() => {
      if (this.startPromise === startPromise) {
        this.startPromise = undefined;
      }
    });
    this.startPromise = startPromise;
    await startPromise;
  }

  async stopVpnExtensionAbility(): Promise<void> {
    if (this.stopPromise !== undefined) {
      await this.stopPromise;
      return;
    }
    const sessionId: string | undefined = this.activeSessionId;
    if (sessionId === undefined) {
      return;
    }
    const stopPromise: Promise<void> = this.stopInternal(sessionId).finally(() => {
      if (this.stopPromise === stopPromise) {
        this.stopPromise = undefined;
      }
    });
    this.stopPromise = stopPromise;
    await stopPromise;
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    if (this.activeSessionId !== sessionId) {
      return;
    }
    await this.notification.updateTraffic(sessionId, uploadBytesPerSecond, downloadBytesPerSecond);
  }

  bindStopHandler(handler: () => void): void {
    this.onStopped = handler;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.notification.unsubscribeCancellation(this.cancellationSubscriptionId);
    this.onStopped = undefined;
  }

  private async startInternal(want: Want, sessionId: string): Promise<void> {
    await this.delegate.stopVpnExtensionAbility();
    await this.delegate.startVpnExtensionAbility(want);
    try {
      await this.notification.start(sessionId);
    } catch (error) {
      try {
        await this.delegate.stopVpnExtensionAbility();
      } catch (_) {
      }
      try {
        await this.notification.stop(sessionId);
      } catch (_) {
      }
      throw error as Error;
    }
    this.activeSessionId = sessionId;
    try {
      await this.notification.updateTraffic(sessionId, 0, 0);
    } catch (_) {
    }
  }

  private async stopInternal(sessionId: string): Promise<void> {
    await this.delegate.stopVpnExtensionAbility();
    await this.notification.stop(sessionId);
    this.activeSessionId = undefined;
    this.onStopped?.();
  }
}

function readSessionId(want: Want): string {
  const parameters: Record<string, Object> | null | undefined =
    want.parameters as Record<string, Object> | null | undefined;
  const sessionId: Object | undefined = parameters?.sessionId;
  if (typeof sessionId !== 'string' || sessionId.trim().length === 0) {
    throw new Error('VPN extension start requires a session id.');
  }
  return sessionId;
}
