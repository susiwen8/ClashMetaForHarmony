import {
  ProfileApplication,
  type ProfileApplicationListener,
  type ProfileApplicationSnapshot,
  type RefreshAllSubscriptionsResult,
  type RefreshProfilesItemResult
} from '@cmfa/shared';
import {
  cloneProfilesViewState,
  createProfilesSummaryState,
  createProfileRowState,
  createProfilesViewState,
  createSafeErrorState,
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
  private refreshAllTotalCount: number = 0;
  private refreshAllError?: SafeErrorState;
  private disposed: boolean = false;

  constructor(application: ProfileApplication) {
    this.application = application;
    this.state = createState(
      application.current(),
      this.refreshAllPending,
      this.refreshAllCompletedCount,
      this.refreshAllTotalCount,
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
    const remoteCount: number = countRemoteProfiles(snapshot);
    if (remoteCount === 0) {
      return;
    }

    const token: number = this.beginRefreshAll(remoteCount, snapshot);
    const result: RefreshAllSubscriptionsResult = await this.application.refreshAllSubscriptions();
    if (!this.canPublishRefreshAll(token)) {
      return;
    }

    this.refreshAllPending = false;
    if (result.kind === 'COMPLETED') {
      this.refreshAllCompletedCount = countCompletedRefreshItems(result.result.items);
      this.refreshAllTotalCount = result.result.items.length;
      this.refreshAllError = undefined;
    } else {
      this.refreshAllCompletedCount = 0;
      this.refreshAllError = createSafeErrorState(result.error);
    }
    this.publish(this.buildState(this.application.current()));
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
    this.refreshAllTotalCount = remoteCount;
    this.refreshAllError = undefined;
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
      this.refreshAllTotalCount,
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
  refreshAllTotalCount: number,
  refreshAllError: SafeErrorState | undefined
): ProfilesViewState {
  const rows: ProfileRowState[] = [];
  const remoteCount: number = countRemoteProfiles(snapshot);
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    rows.push(createProfileRowState(snapshot.profiles[index], snapshot.activeProfileId));
  }
  return createProfilesViewState(
    snapshot.status,
    rows,
    snapshot.error === null ? undefined : createSafeErrorState(snapshot.error),
    refreshAllPending ? 1 : 0,
    refreshAllCompletedCount,
    refreshAllTotalCount,
    createProfilesSummaryState(
      snapshot.profiles.length,
      remoteCount,
      snapshot.profiles.length - remoteCount,
      countProfilesByAvailability(snapshot, 'VALID'),
      countProfilesByAvailability(snapshot, 'INVALID'),
      countProfilesByAvailability(snapshot, 'UPDATE_FAILED_USING_VALID')
    ),
    refreshAllError
  );
}

function countRemoteProfiles(snapshot: ProfileApplicationSnapshot): number {
  let count: number = 0;
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    if (snapshot.profiles[index].sourceKind === 'REMOTE_URL') {
      count += 1;
    }
  }
  return count;
}

function countProfilesByAvailability(
  snapshot: ProfileApplicationSnapshot,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID'
): number {
  let count: number = 0;
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    if (snapshot.profiles[index].availability === availability) {
      count += 1;
    }
  }
  return count;
}

function countCompletedRefreshItems(items: RefreshProfilesItemResult[]): number {
  return items.length;
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
