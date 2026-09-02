import {
  ProfileApplication,
  type ManageDeleteResult,
  type ManageEnableResult,
  type ProfileApplicationListener,
  type ProfileApplicationProfileSnapshot,
  type ProfileApplicationSnapshot,
  type RefreshProfileResult,
  type UpdateProfileResult
} from '@cmfa/shared';
import {
  cloneProfileDetailViewState,
  createProfileDetailProfileState,
  createProfileDetailViewState,
  createSafeErrorState,
  isProfileStartEligible,
  parseRemoteSourceInput,
  resolveNameIssue,
  resolveRemoteUrlIssue,
  safeRemoteHostFromUrl,
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
  private pendingPlainHttpEdit?: ParsedRemoteSourceInput;
  private pendingPlainHttpEditName?: string;
  private fallbackError?: SafeErrorState;
  private editing: boolean = false;
  private editNameDraft: string = '';
  private editUrlDraft: string = '';
  private editNameIssue?: 'REQUIRED' | 'TOO_LONG';
  private editUrlIssue?: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME';

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

  currentEditNameDraft(): string {
    return this.editNameDraft;
  }

  currentEditUrlDraft(): string {
    return this.editUrlDraft;
  }

  currentReplacementUrlDraft(): string {
    return this.currentEditUrlDraft();
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

  requestEdit(): void {
    if (this.status === 'SUBMITTING') {
      return;
    }
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(this.application.current());
    if (profile === undefined) {
      return;
    }
    this.editing = true;
    this.editNameDraft = profile.name;
    this.editUrlDraft = '';
    this.editNameIssue = undefined;
    this.editUrlIssue = undefined;
    this.confirmingDelete = false;
    this.pendingPlainHttpRefresh = false;
    this.clearPendingPlainHttpEdit();
    this.httpConfirmationHost = undefined;
    this.fallbackError = undefined;
    this.status = 'IDLE';
    this.publish(this.buildState());
  }

  cancelEdit(): void {
    if (!this.editing && this.pendingPlainHttpEdit === undefined) {
      return;
    }
    this.editing = false;
    this.clearEditDrafts();
    this.confirmingDelete = false;
    this.pendingPlainHttpRefresh = false;
    this.clearPendingPlainHttpEdit();
    this.httpConfirmationHost = undefined;
    this.fallbackError = undefined;
    this.status = 'IDLE';
    this.publish(this.buildState());
  }

  updateEditNameDraft(value: string): void {
    this.editNameDraft = value;
    this.editNameIssue = undefined;
    this.clearStaleEditCommandError();
    if (this.pendingPlainHttpEdit !== undefined) {
      this.clearPendingPlainHttpEdit();
      this.httpConfirmationHost = undefined;
      this.status = 'IDLE';
    }
    if (this.status !== 'SUBMITTING') {
      this.publish(this.buildState());
    }
  }

  updateEditUrlDraft(value: string): void {
    this.editUrlDraft = value;
    this.editUrlIssue = undefined;
    this.clearStaleEditCommandError();
    if (this.pendingPlainHttpEdit !== undefined) {
      this.clearPendingPlainHttpEdit();
      this.httpConfirmationHost = undefined;
      this.status = 'IDLE';
    }
    if (this.status !== 'SUBMITTING') {
      this.publish(this.buildState());
    }
  }

  updateReplacementUrlDraft(value: string): void {
    if (!this.editing) {
      this.requestEdit();
    }
    this.updateEditUrlDraft(value);
  }

  async requestSaveEdits(): Promise<void> {
    if (this.status === 'SUBMITTING' || !this.editing) {
      return;
    }
    this.editNameIssue = resolveNameIssue(this.editNameDraft, true);
    this.editUrlIssue = undefined;

    let parsedSource: ParsedRemoteSourceInput | undefined = undefined;
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(this.application.current());
    const sourceRepairRequired: boolean = profile?.sourceRepairRequired === true;
    const trimmedUrl: string = this.editUrlDraft.trim();
    if (trimmedUrl.length === 0) {
      if (sourceRepairRequired) {
        this.editUrlIssue = 'REQUIRED';
      }
    } else {
      this.editUrlIssue = resolveRemoteUrlIssue(this.editUrlDraft);
      if (this.editUrlIssue === undefined) {
        parsedSource = parseRemoteSourceInput(this.editUrlDraft);
        if (parsedSource === undefined) {
          this.editUrlIssue = 'INVALID_URL';
        }
      }
    }

    if (this.editNameIssue !== undefined || this.editUrlIssue !== undefined) {
      this.clearPendingPlainHttpEdit();
      this.httpConfirmationHost = undefined;
      this.fallbackError = undefined;
      this.status = 'IDLE';
      this.publish(this.buildState());
      return;
    }

    const normalizedName: string = normalizeRequiredName(this.editNameDraft);
    if (parsedSource?.plainHttp === true) {
      this.pendingPlainHttpEdit = parsedSource;
      this.pendingPlainHttpEditName = normalizedName;
      this.pendingPlainHttpRefresh = false;
      this.httpConfirmationHost = parsedSource.host;
      this.fallbackError = undefined;
      this.status = 'CONFIRMING_HTTP';
      this.publish(this.buildState());
      return;
    }

    await this.executeUpdate(normalizedName, parsedSource?.sourceUrl, false);
  }

  async requestReplaceSubscriptionUrl(): Promise<void> {
    if (!this.editing) {
      this.requestEdit();
    }
    await this.requestSaveEdits();
  }

  async requestEnable(): Promise<void> {
    if (this.status === 'SUBMITTING' || !this.state.canEnable) {
      return;
    }
    const token: number = this.beginCommand();
    const result: ManageEnableResult = await this.application.enable(this.profileId);
    this.completeCommand(
      token,
      resolveManageStatus(result),
      result.kind === 'FAILED' ? createSafeErrorState(result.error) : undefined
    );
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
      this.clearPendingPlainHttpEdit();
      this.httpConfirmationHost = sanitizeRefreshHost(profile.sourceDisplay);
      this.status = 'CONFIRMING_HTTP';
      this.publish(this.buildState());
      return;
    }
    const token: number = this.beginCommand();
    const result: RefreshProfileResult = await this.application.refresh(this.profileId);
    this.completeCommand(
      token,
      resolveRefreshStatus(result),
      result.kind === 'FAILED' ? createSafeErrorState(result.error) : undefined
    );
  }

  async requestAutoUpdateInterval(intervalMs: number): Promise<void> {
    if (this.disposed || this.status === 'SUBMITTING') {
      return;
    }
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(this.application.current());
    if (profile === undefined || profile.sourceKind !== 'REMOTE_URL') {
      return;
    }
    const token: number = this.beginCommand();
    const result: UpdateProfileResult = await this.application.updateAutoUpdateInterval(this.profileId, intervalMs);
    if (this.disposed || token !== this.commandToken) {
      return;
    }
    if (result.kind === 'UPDATED') {
      this.completeCommand(token, 'COMPLETED', undefined);
      return;
    }
    this.completeCommand(token, 'ERROR', createSafeErrorState(result.error));
  }

  cancelPlainHttpConfirmation(): void {
    if (!this.pendingPlainHttpRefresh && this.pendingPlainHttpEdit === undefined) {
      return;
    }
    this.pendingPlainHttpRefresh = false;
    this.clearPendingPlainHttpEdit();
    this.httpConfirmationHost = undefined;
    this.status = 'IDLE';
    this.publish(this.buildState());
  }

  async confirmPlainHttpAction(): Promise<void> {
    if (this.pendingPlainHttpRefresh) {
      this.pendingPlainHttpRefresh = false;
      this.httpConfirmationHost = undefined;
      const token: number = this.beginCommand();
      const result: RefreshProfileResult = await this.application.refresh(this.profileId, true);
      this.completeCommand(
        token,
        resolveRefreshStatus(result),
        result.kind === 'FAILED' ? createSafeErrorState(result.error) : undefined
      );
      return;
    }

    const pendingEdit: ParsedRemoteSourceInput | undefined = this.pendingPlainHttpEdit;
    const pendingName: string | undefined = this.pendingPlainHttpEditName;
    if (pendingEdit === undefined || pendingName === undefined) {
      return;
    }
    this.clearPendingPlainHttpEdit();
    this.httpConfirmationHost = undefined;
    await this.executeUpdate(pendingName, pendingEdit.sourceUrl, true);
  }

  async confirmPlainHttpRefresh(): Promise<void> {
    await this.confirmPlainHttpAction();
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
      this.fallbackError = undefined;
      this.status = 'COMPLETED';
      this.publish(this.buildState());
      this.publishNavigation(new ProfileDetailNavigationIntentValue());
      return;
    }
    this.fallbackError = createSafeErrorState(result.error);
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
    this.commandToken += 1;
    this.application.unsubscribe(this.subscriptionId);
    this.listeners.clear();
    this.navigationListeners.clear();
    this.effectListeners.clear();
  }

  private async executeUpdate(name: string, sourceUrl?: string, allowPlainHttp: boolean = false): Promise<void> {
    const token: number = this.beginCommand();
    const result: UpdateProfileResult = await this.application.updateProfile(this.profileId, name, sourceUrl, allowPlainHttp);
    if (token !== this.commandToken) {
      return;
    }
    if (result.kind === 'UPDATED') {
      this.fallbackError = undefined;
      this.editing = false;
      this.clearEditDrafts();
      this.status = 'COMPLETED';
      this.publish(this.buildState());
      return;
    }
    if (result.kind === 'UPDATED_REFRESH_FAILED') {
      this.fallbackError = createSafeErrorState(result.error);
      this.editing = false;
      this.clearEditDrafts();
      this.status = 'ERROR';
      this.publish(this.buildState());
      return;
    }
    this.fallbackError = createSafeErrorState(result.error);
    this.status = 'ERROR';
    this.publish(this.buildState());
  }

  private beginCommand(): number {
    this.commandToken += 1;
    this.confirmingDelete = false;
    this.pendingPlainHttpRefresh = false;
    this.clearPendingPlainHttpEdit();
    this.httpConfirmationHost = undefined;
    this.fallbackError = undefined;
    this.status = 'SUBMITTING';
    this.publish(this.buildState());
    return this.commandToken;
  }

  private completeCommand(
    token: number,
    status: 'IDLE' | 'COMPLETED' | 'ERROR',
    fallbackError: SafeErrorState | undefined
  ): void {
    if (token !== this.commandToken) {
      return;
    }
    this.fallbackError = fallbackError;
    this.status = status;
    this.publish(this.buildState());
  }

  private clearEditDrafts(): void {
    this.editNameDraft = '';
    this.editUrlDraft = '';
    this.editNameIssue = undefined;
    this.editUrlIssue = undefined;
  }

  private clearPendingPlainHttpEdit(): void {
    this.pendingPlainHttpEdit = undefined;
    this.pendingPlainHttpEditName = undefined;
  }

  private clearStaleEditCommandError(): void {
    if (this.status !== 'SUBMITTING') {
      this.fallbackError = undefined;
      if (this.status === 'ERROR') {
        this.status = 'IDLE';
      }
    }
  }

  private buildState(): ProfileDetailViewState {
    const snapshot: ProfileApplicationSnapshot = this.application.current();
    const profile: ProfileApplicationProfileSnapshot | undefined = this.findProfile(snapshot);
    const profileState: ProfileDetailProfileState | undefined = profile === undefined
      ? undefined
      : createProfileDetailProfileState(profile);
    const sourceRepairRequired: boolean = profile?.sourceRepairRequired === true;
    const sourceRetryAvailable: boolean = profile?.lastError?.code === 'SOURCE_DECRYPT_FAILED';
    const canEnable: boolean = isProfileStartEligible(profile) && snapshot.activeProfileId !== profile?.id;
    const canRefresh: boolean = profile !== undefined &&
      (!sourceRepairRequired || sourceRetryAvailable);
    const canDelete: boolean = profile !== undefined;
    const canReplaceSubscriptionUrl: boolean = sourceRepairRequired;
    const error: SafeErrorState | undefined = resolveDetailError(snapshot, profile, this.fallbackError);
    return createProfileDetailViewState(
      this.status,
      profileState,
      canEnable,
      canRefresh,
      canDelete,
      canReplaceSubscriptionUrl,
      sourceRetryAvailable,
      sourceRepairRequired,
      this.confirmingDelete,
      this.httpConfirmationHost,
      error,
      this.editing,
      this.editNameIssue,
      this.editUrlIssue
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
  profile: ProfileApplicationProfileSnapshot | undefined,
  fallbackError: SafeErrorState | undefined
): SafeErrorState | undefined {
  if (fallbackError !== undefined) {
    return fallbackError;
  }
  if (snapshot.error !== null) {
    return createSafeErrorState(snapshot.error);
  }
  if (profile?.lastError !== null && profile?.lastError !== undefined) {
    return createSafeErrorState(profile.lastError);
  }
  return fallbackError;
}

function sanitizeRefreshHost(sourceDisplay: string): string {
  return safeRemoteHostFromUrl(sourceDisplay) ?? sourceDisplay;
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

function resolveManageStatus(result: ManageEnableResult | ManageDeleteResult): 'COMPLETED' | 'ERROR' {
  return result.kind === 'FAILED' ? 'ERROR' : 'COMPLETED';
}

function normalizeRequiredName(rawName: string): string {
  return rawName.trim();
}
