import { ProfileApplication, type ProfileApplicationListener, type ProfileApplicationSnapshot } from '@cmfa/shared';
import {
  areProfileActionsLocked,
  cloneProfilesViewState,
  createProfileRowState,
  createProfilesViewState,
  createSafeErrorState,
  type ProfileRowState,
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
  private disposed: boolean = false;

  constructor(application: ProfileApplication) {
    this.application = application;
    this.state = createState(application.current());
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      this.publish(createState(snapshot));
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

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.application.unsubscribe(this.subscriptionId);
    this.listeners.clear();
    this.navigationListeners.clear();
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

function createState(snapshot: ProfileApplicationSnapshot): ProfilesViewState {
  const rows: ProfileRowState[] = [];
  const actionsLockedByRuntime: boolean = areProfileActionsLocked(snapshot.runtime.state);
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    rows.push(createProfileRowState(snapshot.profiles[index], snapshot.activeProfileId, actionsLockedByRuntime));
  }
  return createProfilesViewState(
    snapshot.status,
    rows,
    snapshot.error === null ? undefined : createSafeErrorState(snapshot.error)
  );
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
