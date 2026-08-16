import common from '@ohos.app.ability.common';
import { Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import type { ContinuousNotificationPort } from '@cmfa/shared';
import type {
  ContinuousTaskCancelInfo,
  ContinuousTaskDriver,
  ContinuousTaskNotificationInfo,
  ContinuousTaskWantRequest,
  PlatformContinuousTaskContext
} from './ContinuousTaskDriver';

const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const DATA_TRANSFER_MODE: string = 'dataTransfer';

class ContinuousTaskWantRequestValue implements ContinuousTaskWantRequest {
  readonly bundleName: string;
  readonly moduleName: string;
  readonly abilityName: string;
  readonly parameters: Record<string, Object>;

  constructor(bundleName: string, moduleName: string, abilityName: string) {
    this.bundleName = bundleName;
    this.moduleName = moduleName;
    this.abilityName = abilityName;
    this.parameters = {};
  }
}

class ContinuousTaskNotificationInfoValue implements ContinuousTaskNotificationInfo {
  readonly continuousTaskId?: number;
  readonly notificationId?: number;

  constructor(continuousTaskId?: number, notificationId?: number) {
    this.continuousTaskId = continuousTaskId;
    this.notificationId = notificationId;
  }
}

class AbilityKitContinuousTaskDriver implements ContinuousTaskDriver {
  private readonly context: common.UIAbilityContext;
  private readonly cancelBridges: Map<(info: ContinuousTaskCancelInfo) => void, (info: backgroundTaskManager.ContinuousTaskCancelInfo) => void> = new Map();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async createWantAgent(request: ContinuousTaskWantRequest): Promise<Object> {
    const wantValue: Want = {
      bundleName: request.bundleName,
      moduleName: request.moduleName,
      abilityName: request.abilityName,
      parameters: request.parameters
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [wantValue],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  async startBackgroundTask(wantAgentValue: Object, backgroundModes: string[]): Promise<ContinuousTaskNotificationInfo | null> {
    const notification = await backgroundTaskManager.startBackgroundRunning(this.context, backgroundModes, wantAgentValue);
    return readNotificationInfo(notification as Object);
  }

  async stopBackgroundTask(_continuousTaskId?: number): Promise<void> {
    await backgroundTaskManager.stopBackgroundRunning(this.context);
  }

  onCancel(callback: (info: ContinuousTaskCancelInfo) => void): void {
    const bridge = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      callback(decodeContinuousTaskCancelInfo(info as Object));
    };
    backgroundTaskManager.on('continuousTaskCancel', bridge);
    this.cancelBridges.set(callback, bridge);
  }

  offCancel(callback: (info: ContinuousTaskCancelInfo) => void): void {
    const bridge = this.cancelBridges.get(callback);
    if (bridge === undefined) {
      return;
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', bridge);
    } catch (error) {
      try {
        backgroundTaskManager.off('continuousTaskCancel');
      } catch (_) {
        throw error as Error;
      }
    }
    this.cancelBridges.delete(callback);
  }
}

export class HarmonyVpnNotificationDriver implements ContinuousNotificationPort {
  private readonly context: PlatformContinuousTaskContext;
  private readonly driver: ContinuousTaskDriver;
  private readonly listeners: Map<number, (sessionId: string) => void> = new Map();
  private readonly cancelCallback: (info: ContinuousTaskCancelInfo) => void;
  private nextSubscriptionId: number = 1;
  private activeSessionId?: string;
  private activeContinuousTaskId?: number;
  private activeNotificationId?: number;
  private cancellationSubscribed: boolean = false;
  private startInFlight: boolean = false;

  constructor(
    context: PlatformContinuousTaskContext,
    driver?: ContinuousTaskDriver
  ) {
    this.context = context;
    this.driver = driver ?? new AbilityKitContinuousTaskDriver(context as common.UIAbilityContext);
    this.cancelCallback = (info: ContinuousTaskCancelInfo): void => {
      this.handleCancellation(info);
    };
  }

  async start(sessionId: string): Promise<void> {
    if (this.activeSessionId !== undefined || this.startInFlight) {
      throw new Error('Continuous notification is already active.');
    }
    this.startInFlight = true;
    try {
      if (this.cancellationSubscribed) {
        this.detachCancellationListener();
      }
      const wantRequest: ContinuousTaskWantRequest = new ContinuousTaskWantRequestValue(
        this.context.abilityInfo.bundleName,
        this.context.abilityInfo.moduleName,
        ENTRY_ABILITY_NAME
      );
      const wantAgentValue: Object = await this.driver.createWantAgent(wantRequest);
      this.driver.onCancel(this.cancelCallback);
      this.cancellationSubscribed = true;
      try {
        const notificationInfo: ContinuousTaskNotificationInfo | null = await this.driver.startBackgroundTask(
          wantAgentValue,
          [DATA_TRANSFER_MODE]
        );
        this.activeSessionId = sessionId;
        this.activeContinuousTaskId = notificationInfo?.continuousTaskId;
        this.activeNotificationId = notificationInfo?.notificationId;
      } catch (error) {
        this.detachCancellationListenerIgnoringErrors();
        throw error as Error;
      }
    } finally {
      this.startInFlight = false;
    }
  }

  async stop(sessionId: string): Promise<void> {
    if (this.activeSessionId === undefined) {
      if (this.cancellationSubscribed) {
        this.detachCancellationListener();
      }
      return;
    }
    if (this.activeSessionId !== sessionId) {
      return;
    }
    const stopId: number | undefined = this.activeContinuousTaskId;
    let detachError: Error | undefined = undefined;
    try {
      this.detachCancellationListener();
    } catch (error) {
      detachError = error instanceof Error ? error : new Error('Continuous notification listener cleanup failed.');
    }
    await this.driver.stopBackgroundTask(stopId);
    this.activeSessionId = undefined;
    this.activeContinuousTaskId = undefined;
    this.activeNotificationId = undefined;
    if (detachError !== undefined) {
      throw detachError;
    }
  }

  subscribeCancellation(listener: (sessionId: string) => void): number {
    const subscriptionId: number = this.nextSubscriptionId;
    this.nextSubscriptionId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribeCancellation(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  private handleCancellation(info: ContinuousTaskCancelInfo): void {
    const sessionId: string | undefined = this.activeSessionId;
    if (sessionId === undefined) {
      return;
    }
    if (!matchesCancellation(info, this.activeContinuousTaskId, this.activeNotificationId)) {
      return;
    }
    const snapshotListeners: Array<(sessionId: string) => void> = [];
    this.listeners.forEach((listener: (sessionId: string) => void) => {
      snapshotListeners.push(listener);
    });
    for (let index: number = 0; index < snapshotListeners.length; index += 1) {
      snapshotListeners[index](sessionId);
    }
  }

  private detachCancellationListener(): void {
    if (!this.cancellationSubscribed) {
      return;
    }
    this.driver.offCancel(this.cancelCallback);
    this.cancellationSubscribed = false;
  }

  private detachCancellationListenerIgnoringErrors(): void {
    try {
      this.detachCancellationListener();
    } catch (_) {
    }
  }
}

function matchesCancellation(
  info: ContinuousTaskCancelInfo,
  activeContinuousTaskId?: number,
  activeNotificationId?: number
): boolean {
  if (activeContinuousTaskId === undefined && activeNotificationId === undefined) {
    return true;
  }
  if (activeContinuousTaskId !== undefined) {
    return info.continuousTaskId === activeContinuousTaskId;
  }
  if (info.notificationId !== undefined) {
    return info.notificationId === activeNotificationId;
  }
  return true;
}

export function decodeContinuousTaskCancelInfo(info: Object): ContinuousTaskCancelInfo {
  return new ContinuousTaskNotificationInfoValue(
    toOptionalInteger(Reflect.get(info, 'id')) ?? toOptionalInteger(Reflect.get(info, 'continuousTaskId')),
    toOptionalInteger(Reflect.get(info, 'notificationId'))
  );
}

function readNotificationInfo(notification: Object | undefined): ContinuousTaskNotificationInfo | null {
  if (notification === undefined) {
    return null;
  }
  const continuousTaskId: number | undefined = toOptionalInteger(Reflect.get(notification, 'continuousTaskId'));
  const notificationId: number | undefined = toOptionalInteger(Reflect.get(notification, 'notificationId'));
  if (continuousTaskId === undefined && notificationId === undefined) {
    return null;
  }
  return new ContinuousTaskNotificationInfoValue(continuousTaskId, notificationId);
}

function toOptionalInteger(value: Object | undefined): number | undefined {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    return undefined;
  }
  return value;
}
