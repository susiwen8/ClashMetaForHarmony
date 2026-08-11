import {
  ProfileApplication,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot
} from '@cmfa/shared';
import {
  cloneHomeViewState,
  createHomeViewState,
  createProfileSummaryState,
  createSafeErrorState,
  isProfileStartEligible,
  type HomeViewState
} from './PresentationModels';

export type HomeViewListener = (state: HomeViewState) => void;

export class HomeViewModel {
  private readonly application: ProfileApplication;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, HomeViewListener> = new Map();
  private readonly snapshotById: Map<string, ProfileApplicationProfileSnapshot> = new Map();
  private state: HomeViewState;
  private subscriptionId: number;
  private nextListenerId: number = 0;
  private commandPending: boolean = false;
  private disposed: boolean = false;

  constructor(application: ProfileApplication) {
    this.application = application;
    const initialSnapshot: ProfileApplicationSnapshot = application.current();
    this.state = createState(initialSnapshot, false, this.snapshotById);
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      this.publish(createState(snapshot, this.commandPending, this.snapshotById));
    };
    this.subscriptionId = this.application.subscribe(this.applicationListener);
  }

  current(): HomeViewState {
    return cloneHomeViewState(this.state);
  }

  subscribe(listener: HomeViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  async requestPrimaryAction(): Promise<void> {
    if (this.commandPending) {
      return;
    }
    const snapshot: ProfileApplicationSnapshot = this.application.current();
    const primaryAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = resolvePrimaryAction(snapshot, false, this.snapshotById);
    if (primaryAction !== 'START' && primaryAction !== 'STOP') {
      return;
    }
    this.commandPending = true;
    this.publish(createState(snapshot, true, this.snapshotById));
    try {
      if (primaryAction === 'START') {
        await this.application.startLocal();
      } else {
        await this.application.stopLocal();
      }
    } finally {
      this.commandPending = false;
      this.publish(createState(this.application.current(), false, this.snapshotById));
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.application.unsubscribe(this.subscriptionId);
    this.listeners.clear();
    this.snapshotById.clear();
  }

  private publish(state: HomeViewState): void {
    this.state = cloneHomeViewState(state);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: HomeViewListener[] = [];
    this.listeners.forEach((listener: HomeViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneHomeViewState(this.state));
    }
  }
}

function createState(
  snapshot: ProfileApplicationSnapshot,
  pending: boolean,
  cache: Map<string, ProfileApplicationProfileSnapshot>
): HomeViewState {
  updateProfileCache(cache, snapshot.profiles);
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  const error = snapshot.error !== null
    ? createSafeErrorState(snapshot.error)
    : createSafeErrorState(snapshot.runtime.lastError);
  const httpAddress: string | undefined = snapshot.runtime.latest.httpAddress.trim().length > 0
    ? snapshot.runtime.latest.httpAddress
    : undefined;
  const socksAddress: string | undefined = snapshot.runtime.latest.socksAddress.trim().length > 0
    ? snapshot.runtime.latest.socksAddress
    : undefined;
  return createHomeViewState(
    snapshot.status,
    activeProfile === undefined ? undefined : createProfileSummaryState(activeProfile),
    snapshot.runtime.state,
    resolvePrimaryAction(snapshot, pending, cache),
    httpAddress,
    socksAddress,
    error
  );
}

function resolvePrimaryAction(
  snapshot: ProfileApplicationSnapshot,
  pending: boolean,
  cache: Map<string, ProfileApplicationProfileSnapshot>
): 'DISABLED' | 'START' | 'STOP' | 'BUSY' {
  if (snapshot.status !== 'READY') {
    return 'DISABLED';
  }
  if (pending || snapshot.runtime.state === 'STARTING' || snapshot.runtime.state === 'STOPPING') {
    return 'BUSY';
  }
  if (snapshot.runtime.state === 'RUNNING') {
    return 'STOP';
  }
  const activeProfile: ProfileApplicationProfileSnapshot | undefined = snapshot.activeProfileId === undefined
    ? undefined
    : cache.get(snapshot.activeProfileId);
  if (!isProfileStartEligible(activeProfile)) {
    return 'DISABLED';
  }
  return 'START';
}

function updateProfileCache(
  cache: Map<string, ProfileApplicationProfileSnapshot>,
  profiles: ProfileApplicationProfileSnapshot[]
): void {
  cache.clear();
  for (let index: number = 0; index < profiles.length; index += 1) {
    cache.set(profiles[index].id, profiles[index]);
  }
}
