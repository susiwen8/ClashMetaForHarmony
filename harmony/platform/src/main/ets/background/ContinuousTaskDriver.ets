export interface PlatformAbilityIdentity {
  readonly bundleName: string;
  readonly moduleName: string;
  readonly name: string;
}

export interface PlatformContinuousTaskContext {
  readonly abilityInfo: PlatformAbilityIdentity;
}

export interface ContinuousTaskWantRequest {
  bundleName: string;
  moduleName: string;
  abilityName: string;
  parameters: Record<string, Object>;
}

export interface ContinuousTaskNotificationInfo {
  continuousTaskId?: number;
  notificationId?: number;
  slotType?: number;
  contentType?: number;
}

export interface ContinuousTaskCancelInfo {
  continuousTaskId?: number;
  notificationId?: number;
}

export interface ContinuousTaskDriver {
  createWantAgent(want: ContinuousTaskWantRequest): Promise<Object>;
  startBackgroundTask(wantAgentValue: Object, backgroundModes: string[]): Promise<ContinuousTaskNotificationInfo | null>;
  stopBackgroundTask(continuousTaskId?: number): Promise<void>;
  updateNotification(notificationId: number, title: string, text: string): Promise<void>;
  onCancel(callback: (info: ContinuousTaskCancelInfo) => void): void;
  offCancel(callback: (info: ContinuousTaskCancelInfo) => void): void;
}
