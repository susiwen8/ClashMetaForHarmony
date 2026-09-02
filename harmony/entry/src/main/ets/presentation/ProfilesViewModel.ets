import {
  ProfileApplication,
  type ProfileApplicationListener,
  type ProfileApplicationSnapshot,
  type RefreshAllSubscriptionsResult,
  type RefreshProfilesItemResult
} from '@cmfa/shared';
import {
  cloneProfilesViewState,
  createProfilesRefreshSummaryState,
  createProfileRowState,
  createProfilesViewState,
  createSafeErrorState,
  type ProfilesRefreshSummaryState,
  type ProfileRowState,
  type SafeErrorState,
  type ProfilesViewState
} from './PresentationModels';

export interface ProfilesNavigationIntent {
  destination: 'PROFILE_DETAIL' | 'ADD_SHEET';
  profileId?: string;
}

export type ProfilesViewListener = (state: ProfilesViewState) => void;
export type ProfilesNavigationListener = (intent: ProfilesNavigationIntent) => void;

class ProfilesNavigationIntentValue implements ProfilesNavigationIntent {
  destination: 'PROFILE_DETAIL' | 'ADD_SHEET' = 'ADD_SHEET';
  profileId?: string;
}

export class ProfilesViewModel {
  private readonly application: ProfileApplication;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, ProfilesViewListener> = new Map();
  private readonly navigationListeners: Map<number, ProfilesNavigationListener> = new Map();
  private state: ProfilesViewState;
  private subscriptionId: number;
  private nextListenerId: number = 0;
  private nextNavigationId: number = 0;
  private refreshAllToken: number = 0;
  private refreshAllPending: boolean = false;
  private refreshAllCompletedCount: number = 0;
  private refreshAllRemainingCount: number = 0;
  private refreshAllTotalCount: number = 0;
  private refreshAllInterrupted: boolean = false;
  private refreshAllError?: SafeErrorState;
  private refreshAllSummary?: ProfilesRefreshSummaryState;
  private disposed: boolean = false;

  constructor(application: ProfileApplication) {
    this.application = application;
    this.state = createState(
      application.current(),
      this.refreshAllPending,
      this.refreshAllCompletedCount,
      this.refreshAllRemainingCount,
      this.refreshAllTotalCount,
      this.refreshAllInterrupted,
      this.refreshAllSummary,
      this.refreshAllError
    );
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      this.publish(this.buildState(snapshot));
    };
    this.subscriptionId = this.application.subscribe(this.applicationListener);
  }

  current(): ProfilesViewState {
    return cloneProfilesViewState(this.state);
  }

  subscribe(listener: ProfilesViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  subscribeNavigation(listener: ProfilesNavigationListener): number {
    this.nextNavigationId += 1;
    this.navigationListeners.set(this.nextNavigationId, listener);
    return this.nextNavigationId;
  }

  unsubscribeNavigation(id: number): void {
    this.navigationListeners.delete(id);
  }

  requestOpenProfile(profileId: string): void {
    this.publishNavigation(createProfileDetailIntent(profileId));
  }

  requestOpenAddSheet(): void {
    this.publishNavigation(createAddSheetIntent());
  }

  async requestRefreshAll(): Promise<void> {
    if (this.disposed || this.refreshAllPending) {
      return;
    }
    const snapshot: ProfileApplicationSnapshot = this.application.current();
    const remoteCount: number = countRemoteProfiles(snapshot.profiles);
    if (remoteCount === 0) {
      return;
    }

    const token: number = this.beginRefreshAll(remoteCount, snapshot);
    try {
      const result: RefreshAllSubscriptionsResult = await this.application.refreshAllSubscriptions();
      if (!this.canPublishRefreshAll(token)) {
        return;
      }

      this.refreshAllPending = false;
      if (result.kind === 'COMPLETED') {
        this.refreshAllCompletedCount = result.result.items.length;
        this.refreshAllRemainingCount = result.result.remainingCount;
        this.refreshAllTotalCount = result.result.items.length + result.result.remainingCount;
        this.refreshAllInterrupted = result.result.deadlineReached ||
          result.result.cancelled ||
          result.result.remainingCount > 0;
        this.refreshAllSummary = summarizeRefreshItems(result.result.items);
        this.refreshAllError = undefined;
      } else {
        this.refreshAllCompletedCount = 0;
        this.refreshAllRemainingCount = this.refreshAllTotalCount;
        this.refreshAllInterrupted = true;
        this.refreshAllSummary = undefined;
        this.refreshAllError = createSafeErrorState(result.error);
      }
      this.publish(this.buildState(this.application.current()));
    } catch (_) {
      if (!this.canPublishRefreshAll(token)) {
        return;
      }
      this.refreshAllPending = false;
      this.refreshAllCompletedCount = 0;
      this.refreshAllRemainingCount = this.refreshAllTotalCount;
      this.refreshAllInterrupted = true;
      this.refreshAllSummary = undefined;
      this.refreshAllError = createRefreshAllRejectedError();
      this.publish(this.buildState(this.application.current()));
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.refreshAllToken += 1;
    this.application.unsubscribe(this.subscriptionId);
    this.listeners.clear();
    this.navigationListeners.clear();
  }

  private beginRefreshAll(remoteCount: number, snapshot: ProfileApplicationSnapshot): number {
    this.refreshAllToken += 1;
    this.refreshAllPending = true;
    this.refreshAllCompletedCount = 0;
    this.refreshAllRemainingCount = remoteCount;
    this.refreshAllTotalCount = remoteCount;
    this.refreshAllInterrupted = false;
    this.refreshAllError = undefined;
    this.refreshAllSummary = undefined;
    this.publish(this.buildState(snapshot));
    return this.refreshAllToken;
  }

  private canPublishRefreshAll(token: number): boolean {
    return !this.disposed && this.refreshAllToken === token;
  }

  private buildState(snapshot: ProfileApplicationSnapshot): ProfilesViewState {
    return createState(
      snapshot,
      this.refreshAllPending,
      this.refreshAllCompletedCount,
      this.refreshAllRemainingCount,
      this.refreshAllTotalCount,
      this.refreshAllInterrupted,
      this.refreshAllSummary,
      this.refreshAllError
    );
  }

  private publish(state: ProfilesViewState): void {
    this.state = cloneProfilesViewState(state);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ProfilesViewListener[] = [];
    this.listeners.forEach((listener: ProfilesViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneProfilesViewState(this.state));
    }
  }

  private publishNavigation(intent: ProfilesNavigationIntent): void {
    if (this.navigationListeners.size === 0) {
      return;
    }
    const listeners: ProfilesNavigationListener[] = [];
    this.navigationListeners.forEach((listener: ProfilesNavigationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneNavigationIntent(intent));
    }
  }
}

function createState(
  snapshot: ProfileApplicationSnapshot,
  refreshAllPending: boolean,
  refreshAllCompletedCount: number,
  refreshAllRemainingCount: number,
  refreshAllTotalCount: number,
  refreshAllInterrupted: boolean,
  refreshAllSummary: ProfilesRefreshSummaryState | undefined,
  refreshAllError: SafeErrorState | undefined
): ProfilesViewState {
  const rows: ProfileRowState[] = [];
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    rows.push(createProfileRowState(snapshot.profiles[index], snapshot.activeProfileId));
  }
  return createProfilesViewState(
    snapshot.status,
    rows,
    snapshot.error === null ? undefined : createSafeErrorState(snapshot.error),
    refreshAllPending,
    refreshAllCompletedCount,
    refreshAllRemainingCount,
    refreshAllTotalCount,
    refreshAllInterrupted,
    refreshAllSummary,
    refreshAllError,
    countRemoteProfiles(snapshot.profiles)
  );
}

interface RemoteProfileLike {
  sourceKind: string;
}

function countRemoteProfiles(profiles: RemoteProfileLike[]): number {
  let count: number = 0;
  for (let index: number = 0; index < profiles.length; index += 1) {
    if (profiles[index].sourceKind === 'REMOTE_URL') {
      count += 1;
    }
  }
  return count;
}

function summarizeRefreshItems(items: RefreshProfilesItemResult[]): ProfilesRefreshSummaryState {
  let success: number = 0;
  let failedUsingCurrent: number = 0;
  let failed: number = 0;
  let skippedHttp: number = 0;
  let skippedNotDue: number = 0;
  let busy: number = 0;
  for (let index: number = 0; index < items.length; index += 1) {
    switch (items[index].status) {
      case 'SUCCESS':
        success += 1;
        break;
      case 'FAILED_USING_CURRENT':
        failedUsingCurrent += 1;
        break;
      case 'FAILED':
        failed += 1;
        break;
      case 'SKIPPED_HTTP':
        skippedHttp += 1;
        break;
      case 'SKIPPED_NOT_DUE':
        skippedNotDue += 1;
        break;
      case 'BUSY':
        busy += 1;
        break;
      default:
        break;
    }
  }
  return createProfilesRefreshSummaryState(
    success,
    failedUsingCurrent,
    failed,
    skippedHttp,
    skippedNotDue,
    busy
  );
}

function createRefreshAllRejectedError(): SafeErrorState {
  return createSafeErrorState({
    code: 'SUBSCRIPTION_REFRESH_ALL_FAILED',
    stage: 'DOWNLOAD',
    userMessageResource: 'error.download',
    technicalDetail: 'Subscription refresh failed before completion.',
    timestamp: '2026-09-02T00:00:00.000Z',
    retryable: true
  })!;
}

function createProfileDetailIntent(profileId: string): ProfilesNavigationIntent {
  const intent: ProfilesNavigationIntentValue = new ProfilesNavigationIntentValue();
  intent.destination = 'PROFILE_DETAIL';
  intent.profileId = profileId;
  return intent;
}

function createAddSheetIntent(): ProfilesNavigationIntent {
  return new ProfilesNavigationIntentValue();
}

function cloneNavigationIntent(intent: ProfilesNavigationIntent): ProfilesNavigationIntent {
  const cloned: ProfilesNavigationIntentValue = new ProfilesNavigationIntentValue();
  cloned.destination = intent.destination;
  cloned.profileId = intent.profileId;
  return cloned;
}
