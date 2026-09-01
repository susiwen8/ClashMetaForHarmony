import common from '@ohos.app.ability.common';
import { Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
const VPN_NOTIFICATION_LOG_DOMAIN: number = 0x0000;
const VPN_NOTIFICATION_LOG_TAG: string = 'CMFAVpn';
const NOTIFICATION_TITLE: string = 'Clash Meta VPN';

export const CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE: number = notificationManager.SlotType.LIVE_VIEW;
export const CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE: number =
  notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW;

class SpeedUnitValue {
  readonly size: number;
  readonly suffix: string;

  constructor(size: number, suffix: string) {
    this.size = size;
    this.suffix = suffix;
  }
}

function reportNotificationStage(stage: string): void {
  hilog.info(VPN_NOTIFICATION_LOG_DOMAIN, VPN_NOTIFICATION_LOG_TAG, '%{public}s', stage);
}

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
  readonly slotType?: number;
  readonly contentType?: number;

  constructor(continuousTaskId?: number, notificationId?: number, slotType?: number, contentType?: number) {
    this.continuousTaskId = continuousTaskId;
    this.notificationId = notificationId;
    this.slotType = slotType;
    this.contentType = contentType;
  }
}

class AbilityKitContinuousTaskDriver implements ContinuousTaskDriver {
  private readonly context: common.Context;
  private readonly cancelBridges: Map<(info: ContinuousTaskCancelInfo) => void, (info: backgroundTaskManager.ContinuousTaskCancelInfo) => void> = new Map();

  constructor(context: common.Context) {
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

  async updateNotification(notificationId: number, title: string, text: string): Promise<void> {
    const request: notificationManager.NotificationRequest = createLiveViewNotificationRequest(notificationId, title, text);
    reportNotificationStage('notification.traffic.publish.begin');
    try {
      await notificationManager.publish(request);
      reportNotificationStage('notification.traffic.publish.ok');
    } catch (error) {
      reportNotificationStage('notification.traffic.publish.failed');
      throw error as Error;
    }
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
  private activeSlotType?: number;
  private activeContentType?: number;
  private cancellationSubscribed: boolean = false;
  private startInFlight: boolean = false;

  constructor(
    context: PlatformContinuousTaskContext,
    driver?: ContinuousTaskDriver,
    sdkContext?: common.Context
  ) {
    this.context = context;
    if (driver !== undefined) {
      this.driver = driver;
    } else {
      if (sdkContext === undefined) {
        throw new Error('HarmonyOS continuous task context is required.');
      }
      this.driver = new AbilityKitContinuousTaskDriver(sdkContext);
    }
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
      let wantAgentValue: Object;
      reportNotificationStage('notification.want-agent.begin');
      try {
        wantAgentValue = await this.driver.createWantAgent(wantRequest);
        reportNotificationStage('notification.want-agent.ok');
      } catch (error) {
        reportNotificationStage('notification.want-agent.failed');
        throw error as Error;
      }
      reportNotificationStage('notification.cancel-subscribe.begin');
      try {
        this.driver.onCancel(this.cancelCallback);
        reportNotificationStage('notification.cancel-subscribe.ok');
      } catch (error) {
        reportNotificationStage('notification.cancel-subscribe.failed');
        throw error as Error;
      }
      this.cancellationSubscribed = true;
      reportNotificationStage('notification.background.begin');
      try {
        const notificationInfo: ContinuousTaskNotificationInfo | null = await this.driver.startBackgroundTask(
          wantAgentValue,
          [DATA_TRANSFER_MODE]
        );
        reportNotificationStage('notification.background.ok');
        this.activeSessionId = sessionId;
        this.activeContinuousTaskId = notificationInfo?.continuousTaskId;
        this.activeNotificationId = notificationInfo?.notificationId;
        this.activeSlotType = notificationInfo?.slotType;
        this.activeContentType = notificationInfo?.contentType;
        reportNotificationStage(
          this.activeNotificationId === undefined
            ? 'notification.traffic.id-missing'
            : 'notification.traffic.id-ready'
        );
        reportNotificationStage(
          this.activeNotificationIsLiveView()
            ? 'notification.traffic.metadata-live-view'
            : 'notification.traffic.metadata-non-live-view'
        );
      } catch (error) {
        reportNotificationStage('notification.background.failed');
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
    this.activeSlotType = undefined;
    this.activeContentType = undefined;
    if (detachError !== undefined) {
      throw detachError;
    }
  }

  async updateTraffic(
    sessionId: string,
    uploadBytesPerSecond: number,
    downloadBytesPerSecond: number
  ): Promise<void> {
    if (this.activeSessionId !== sessionId || this.activeNotificationId === undefined) {
      return;
    }
    const speedText: string = formatSpeedText(uploadBytesPerSecond, downloadBytesPerSecond);
    await this.driver.updateNotification(this.activeNotificationId, NOTIFICATION_TITLE, speedText);
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

  private activeNotificationIsLiveView(): boolean {
    return this.activeSlotType === CONTINUOUS_TASK_LIVE_VIEW_SLOT_TYPE &&
      this.activeContentType === CONTINUOUS_TASK_SYSTEM_LIVE_VIEW_CONTENT_TYPE;
  }
}

export class UiAbilityOwnedContinuousNotificationPort implements ContinuousNotificationPort {
  private readonly listeners: Map<number, (sessionId: string) => void> = new Map();
  private nextSubscriptionId: number = 1;
  private activeSessionId?: string;

  async start(sessionId: string): Promise<void> {
    if (this.activeSessionId !== undefined) {
      throw new Error('UIAbility-owned continuous notification is already leased.');
    }
    this.activeSessionId = sessionId;
  }

  async stop(sessionId: string): Promise<void> {
    if (sessionId === this.activeSessionId) {
      this.activeSessionId = undefined;
    }
  }

  async updateTraffic(
    _sessionId: string,
    _uploadBytesPerSecond: number,
    _downloadBytesPerSecond: number
  ): Promise<void> {
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

export function decodeContinuousTaskNotificationInfo(notification: Object | undefined): ContinuousTaskNotificationInfo | null {
  if (notification === undefined) {
    return null;
  }
  const continuousTaskId: number | undefined = toOptionalInteger(Reflect.get(notification, 'continuousTaskId'));
  const notificationId: number | undefined = toOptionalInteger(Reflect.get(notification, 'notificationId'));
  const slotType: number | undefined = toOptionalInteger(Reflect.get(notification, 'slotType'));
  const contentType: number | undefined = toOptionalInteger(Reflect.get(notification, 'contentType'));
  if (continuousTaskId === undefined && notificationId === undefined && slotType === undefined && contentType === undefined) {
    return null;
  }
  return new ContinuousTaskNotificationInfoValue(continuousTaskId, notificationId, slotType, contentType);
}

function readNotificationInfo(notification: Object | undefined): ContinuousTaskNotificationInfo | null {
  return decodeContinuousTaskNotificationInfo(notification);
}

function toOptionalInteger(value: Object | undefined): number | undefined {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    return undefined;
  }
  return value;
}

function createLiveViewNotificationRequest(
  notificationId: number,
  _title: string,
  speedText: string
): notificationManager.NotificationRequest {
  return {
    id: notificationId,
    updateOnly: true,
    notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
    content: {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
      systemLiveView: {
        typeCode: 8,
        title: 'Clash Meta VPN',
        text: speedText,
        capsule: {
          title: speedText
        }
      }
    },
    template: {
      name: 'downloadTemplate',
      data: {
        title: 'Clash Meta VPN',
        fileName: speedText,
        progressValue: 0
      }
    }
  };
}

function formatSpeedText(uploadBytesPerSecond: number, downloadBytesPerSecond: number): string {
  return `↑ ${formatSpeed(uploadBytesPerSecond)}  ↓ ${formatSpeed(downloadBytesPerSecond)}`;
}

function formatSpeed(value: number): string {
  const normalized: number = normalizeSpeedValue(value);
  if (normalized < 1024) {
    return `${normalized} B/s`;
  }
  const units: SpeedUnitValue[] = [
    new SpeedUnitValue(1024 * 1024 * 1024, 'GiB'),
    new SpeedUnitValue(1024 * 1024, 'MiB'),
    new SpeedUnitValue(1024, 'KiB')
  ];
  for (let index: number = 0; index < units.length; index += 1) {
    const unit = units[index];
    if (normalized >= unit.size) {
      return `${(normalized / unit.size).toFixed(1)} ${unit.suffix}/s`;
    }
  }
  return `${normalized} B/s`;
}

function normalizeSpeedValue(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    return 0;
  }
  return value;
}
