import {
  ProfileApplication,
  type ManageDeleteResult,
  type ManageEnableResult,
  type ManageReplaceResult,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type RefreshProfileResult
} from '@cmfa/shared';
import {
  areProfileActionsLocked,
  cloneProfileDetailViewState,
  createProfileDetailProfileState,
  createProfileDetailViewState,
  createSafeErrorState,
  isProfileStartEligible,
  parseRemoteSourceInput,
  resolveRemoteUrlIssue,
  type ParsedRemoteSourceInput,
  type ProfileDetailProfileState,
  type ProfileDetailViewState,
  type SafeErrorState
} from './PresentationModels';

export interface ProfileDetailNavigationIntent {
  destination: 'BACK';
}

export interface ProfileDetailEffect {
  kind: 'COPY_TECHNICAL_DETAIL';
  value: string;
}

export type ProfileDetailViewListener = (state: ProfileDetailViewState) => void;
export type ProfileDetailNavigationListener = (intent: ProfileDetailNavigationIntent) => void;
export type ProfileDetailEffectListener = (effect: ProfileDetailEffect) => void;

class ProfileDetailNavigationIntentValue implements ProfileDetailNavigationIntent {
  destination: 'BACK' = 'BACK';
}

class ProfileDetailEffectValue implements ProfileDetailEffect {
  kind: 'COPY_TECHNICAL_DETAIL' = 'COPY_TECHNICAL_DETAIL';
  value: string = '';
}

export class ProfileDetailViewModel {
  private readonly application: ProfileApplication;
  private readonly profileId: string;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, ProfileDetailViewListener> = new Map();
  private readonly navigationListeners: Map<number, ProfileDetailNavigationListener> = new Map();
  private readonly effectListeners: Map<number, ProfileDetailEffectListener> = new Map();
  private state: ProfileDetailViewState;
  private subscriptionId: number;
  private nextListenerId: number = 0;
  private nextNavigationId: number = 0;
  private nextEffectId: number = 0;
  private commandToken: number = 0;
  private disposed: boolean = false;
  private status: 'IDLE' | 'CONFIRMING_HTTP' | 'CONFIRMING_DELETE' | 'SUBMITTING' | 'COMPLETED' | 'ERROR' = 'IDLE';
  private confirmingDelete: boolean = false;
  private httpConfirmationHost?: string;
  private pendingPlainHttpRefresh: boolean = false;
  private replacementUrlDraft: string = '';

  constructor(application: ProfileApplication, profileId: string) {
    this.application = application;
    this.profileId = profileId;
    this.state = this.buildState();
    this.applicationListener = (_snapshot: ProfileApplicationSnapshot): void => {
      if (this.status === 'SUBMITTING') {
        return;
      }
      this.publish(this.buildState());
    };
    this.subscriptionId = this.application.subscribe(this.applicationListener);
  }

  current(): ProfileDetailViewState {
    return cloneProfileDetailViewState(this.state);
  }

  subscribe(listener: ProfileDetailViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  subscribeNavigation(listener: ProfileDetailNavigationListener): number {
    this.nextNavigationId += 1;
    this.navigationListeners.set(this.nextNavigationId, listener);
    return this.nextNavigationId;
  }

  unsubscribeNavigation(id: number): void {
    this.navigationListeners.delete(id);
  }

  subscribeEffect(listener: ProfileDetailEffectListener): number {
    this.nextEffectId += 1;
    this.effectListeners.set(this.nextEffectId, listener);
    return this.nextEffectId;
  }

  unsubscribeEffect(id: number): void {
    this.effectListeners.delete(id);
  }

  async requestEnable(): Promise<void> {
    if (this.status === 'SUBMITTING' || !this.state.canEnable) {
      return;
    }
    const token: number = this.beginCommand();
    const result: ManageEnableResult = await this.application.enable(this.profileId);
    this.completeCommand(token, result.kind === 'FAILED' ? 'ERROR' : 'COMPLETED');
  }

  async requestRefresh(): Promise<void> {
    if (this.status === 'SUBMITTING' || !this.state.canRefresh) {
      return;
    }
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(this.application.current());
    if (profile === undefined) {
      return;
    }
    if (profile.sourceKind === 'REMOTE_URL' && profile.sourceDisplay.startsWith('http://')) {
      this.pendingPlainHttpRefresh = true;
      this.httpConfirmationHost = sanitizeRefreshHost(profile.sourceDisplay);
      this.status = 'CONFIRMING_HTTP';
      this.publish(this.buildState());
      return;
    }
    const token: number = this.beginCommand();
    const result: RefreshProfileResult = await this.application.refresh(this.profileId);
    this.completeCommand(token, resolveRefreshStatus(result));
  }

  cancelPlainHttpConfirmation(): void {
    if (!this.pendingPlainHttpRefresh) {
      return;
    }
    this.pendingPlainHttpRefresh = false;
    this.httpConfirmationHost = undefined;
    this.status = 'IDLE';
    this.publish(this.buildState());
  }

  async confirmPlainHttpRefresh(): Promise<void> {
    if (!this.pendingPlainHttpRefresh) {
      return;
    }
    this.pendingPlainHttpRefresh = false;
    this.httpConfirmationHost = undefined;
    const token: number = this.beginCommand();
    const result: RefreshProfileResult = await this.application.refresh(this.profileId, true);
    this.completeCommand(token, resolveRefreshStatus(result));
  }

  updateReplacementUrlDraft(value: string): void {
    this.replacementUrlDraft = value;
  }

  async requestReplaceSubscriptionUrl(): Promise<void> {
    if (this.status === 'SUBMITTING' || !this.state.canReplaceSubscriptionUrl) {
      return;
    }
    const issue = resolveRemoteUrlIssue(this.replacementUrlDraft);
    if (issue !== undefined) {
      return;
    }
    const parsed: ParsedRemoteSourceInput | undefined = parseRemoteSourceInput(this.replacementUrlDraft);
    if (parsed === undefined) {
      return;
    }
    this.replacementUrlDraft = '';
    const token: number = this.beginCommand();
    const result: ManageReplaceResult = await this.application.replaceSubscriptionUrl(this.profileId, parsed.sourceUrl);
    this.completeCommand(token, result.kind === 'FAILED' ? 'ERROR' : 'COMPLETED');
  }

  requestDelete(): void {
    if (this.status === 'SUBMITTING' || !this.state.canDelete) {
      return;
    }
    this.confirmingDelete = true;
    this.status = 'CONFIRMING_DELETE';
    this.publish(this.buildState());
  }

  async confirmDelete(): Promise<void> {
    if (!this.confirmingDelete || this.status === 'SUBMITTING') {
      return;
    }
    this.confirmingDelete = false;
    const token: number = this.beginCommand();
    const result: ManageDeleteResult = await this.application.delete(this.profileId);
    if (token !== this.commandToken) {
      return;
    }
    if (result.kind === 'DELETED') {
      this.status = 'COMPLETED';
      this.publish(this.buildState());
      this.publishNavigation(new ProfileDetailNavigationIntentValue());
      return;
    }
    this.status = 'ERROR';
    this.publish(this.buildState());
  }

  cancelDelete(): void {
    if (!this.confirmingDelete) {
      return;
    }
    this.confirmingDelete = false;
    this.status = 'IDLE';
    this.publish(this.buildState());
  }

  requestCopyTechnicalDetail(): void {
    const detail: string | undefined = this.state.error?.technicalDetail;
    if (detail === undefined || detail.trim().length === 0) {
      return;
    }
    this.publishEffect(createCopyEffect(detail));
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.application.unsubscribe(this.subscriptionId);
    this.listeners.clear();
    this.navigationListeners.clear();
    this.effectListeners.clear();
  }

  private beginCommand(): number {
    this.commandToken += 1;
    this.confirmingDelete = false;
    this.pendingPlainHttpRefresh = false;
    this.httpConfirmationHost = undefined;
    this.status = 'SUBMITTING';
    this.publish(this.buildState());
    return this.commandToken;
  }

  private completeCommand(
    token: number,
    status: 'IDLE' | 'COMPLETED' | 'ERROR'
  ): void {
    if (token !== this.commandToken) {
      return;
    }
    this.status = status;
    this.publish(this.buildState());
  }

  private buildState(): ProfileDetailViewState {
    const snapshot: ProfileApplicationSnapshot = this.application.current();
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(snapshot);
    const profileState: ProfileDetailProfileState | undefined = profile === undefined
      ? undefined
      : createProfileDetailProfileState(profile);
    const actionsLocked: boolean = areProfileActionsLocked(snapshot.runtime.state);
    const sourceRepairRequired: boolean = profile?.sourceRepairRequired === true;
    const canEnable: boolean = !actionsLocked && isProfileStartEligible(profile);
    const canRefresh: boolean = !actionsLocked && profile !== undefined && !sourceRepairRequired;
    const canDelete: boolean = !actionsLocked && profile !== undefined;
    const canReplaceSubscriptionUrl: boolean = !actionsLocked && sourceRepairRequired;
    const error: SafeErrorState | undefined = resolveDetailError(snapshot, profile);
    return createProfileDetailViewState(
      this.status,
      profileState,
      canEnable,
      canRefresh,
      canDelete,
      canReplaceSubscriptionUrl,
      sourceRepairRequired,
      this.confirmingDelete,
      this.httpConfirmationHost,
      error
    );
  }

  private findProfile(snapshot: ProfileApplicationSnapshot): ProfileApplicationProfileSnapshot | undefined {
    for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
      if (snapshot.profiles[index].id === this.profileId) {
        return snapshot.profiles[index];
      }
    }
    return undefined;
  }

  private publish(state: ProfileDetailViewState): void {
    this.state = cloneProfileDetailViewState(state);
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ProfileDetailViewListener[] = [];
    this.listeners.forEach((listener: ProfileDetailViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneProfileDetailViewState(this.state));
    }
  }

  private publishNavigation(intent: ProfileDetailNavigationIntent): void {
    if (this.navigationListeners.size === 0) {
      return;
    }
    const listeners: ProfileDetailNavigationListener[] = [];
    this.navigationListeners.forEach((listener: ProfileDetailNavigationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneNavigationIntent(intent));
    }
  }

  private publishEffect(effect: ProfileDetailEffect): void {
    if (this.effectListeners.size === 0) {
      return;
    }
    const listeners: ProfileDetailEffectListener[] = [];
    this.effectListeners.forEach((listener: ProfileDetailEffectListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneEffect(effect));
    }
  }
}

function resolveDetailError(
  snapshot: ProfileApplicationSnapshot,
  profile: ProfileApplicationProfileSnapshot | undefined
): SafeErrorState | undefined {
  if (snapshot.error !== null) {
    return createSafeErrorState(snapshot.error);
  }
  if (profile?.lastError !== null && profile?.lastError !== undefined) {
    return createSafeErrorState(profile.lastError);
  }
  return undefined;
}

function sanitizeRefreshHost(sourceDisplay: string): string {
  const schemeSeparator: number = sourceDisplay.indexOf('://');
  return schemeSeparator >= 0 ? sourceDisplay.substring(schemeSeparator + 3) : sourceDisplay;
}

function createCopyEffect(value: string): ProfileDetailEffect {
  const effect: ProfileDetailEffectValue = new ProfileDetailEffectValue();
  effect.value = value;
  return effect;
}

function cloneNavigationIntent(intent: ProfileDetailNavigationIntent): ProfileDetailNavigationIntent {
  const cloned: ProfileDetailNavigationIntentValue = new ProfileDetailNavigationIntentValue();
  cloned.destination = intent.destination;
  return cloned;
}

function cloneEffect(effect: ProfileDetailEffect): ProfileDetailEffect {
  const cloned: ProfileDetailEffectValue = new ProfileDetailEffectValue();
  cloned.kind = effect.kind;
  cloned.value = effect.value;
  return cloned;
}

function resolveRefreshStatus(result: RefreshProfileResult): 'IDLE' | 'COMPLETED' | 'ERROR' {
  if (result.kind === 'CANCELLED') {
    return 'IDLE';
  }
  return result.kind === 'FAILED' ? 'ERROR' : 'COMPLETED';
}
