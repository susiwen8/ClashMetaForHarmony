import {
  ProfileApplication,
  type ImportProfileResult,
  type ProfileApplicationListener,
  type ProfileApplicationSnapshot,
  type RemoteImportCommand
} from '@cmfa/shared';
import {
  cloneImportProfileViewState,
  createImportProfileViewState,
  createSafeErrorState,
  parseRemoteSourceInput,
  resolveNameIssue,
  resolveRemoteUrlIssue,
  type ImportProfileViewState,
  type ParsedRemoteSourceInput,
  type SafeErrorState
} from './PresentationModels';

export interface ImportNavigationIntent {
  destination: 'PROFILE_DETAIL';
  profileId: string;
}

export type ImportProfileViewListener = (state: ImportProfileViewState) => void;
export type ImportNavigationListener = (intent: ImportNavigationIntent) => void;

class ImportNavigationIntentValue implements ImportNavigationIntent {
  destination: 'PROFILE_DETAIL' = 'PROFILE_DETAIL';
  profileId: string = '';
}

export class ImportProfileViewModel {
  private readonly application: ProfileApplication;
  private readonly applicationListener: ProfileApplicationListener;
  private readonly listeners: Map<number, ImportProfileViewListener> = new Map();
  private readonly navigationListeners: Map<number, ImportNavigationListener> = new Map();
  private state: ImportProfileViewState;
  private subscriptionId: number;
  private nextListenerId: number = 0;
  private nextNavigationId: number = 0;
  private commandToken: number = 0;
  private disposed: boolean = false;
  private nameDraft: string = '';
  private urlDraft: string = '';
  private nameIssue?: 'REQUIRED' | 'TOO_LONG';
  private urlIssue?: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME';
  private httpConfirmationHost?: string;
  private error?: SafeErrorState;
  private pendingHttpImport?: ParsedRemoteSourceInput;
  private pendingHttpName?: string;

  constructor(application: ProfileApplication) {
    this.application = application;
    const initialSnapshot: ProfileApplicationSnapshot = application.current();
    this.error = initialSnapshot.error === null ? undefined : createSafeErrorState(initialSnapshot.error);
    this.state = createImportProfileViewState('IDLE', undefined, undefined, undefined, this.error);
    this.applicationListener = (snapshot: ProfileApplicationSnapshot): void => {
      if (this.state.status === 'SUBMITTING') {
        return;
      }
      this.error = snapshot.error === null ? undefined : createSafeErrorState(snapshot.error);
      this.publishCurrent(this.state.status === 'ERROR' && this.error === undefined ? 'IDLE' : this.state.status);
    };
    this.subscriptionId = this.application.subscribe(this.applicationListener);
  }

  current(): ImportProfileViewState {
    return cloneImportProfileViewState(this.state);
  }

  subscribe(listener: ImportProfileViewListener): number {
    this.nextListenerId += 1;
    this.listeners.set(this.nextListenerId, listener);
    return this.nextListenerId;
  }

  unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  subscribeNavigation(listener: ImportNavigationListener): number {
    this.nextNavigationId += 1;
    this.navigationListeners.set(this.nextNavigationId, listener);
    return this.nextNavigationId;
  }

  unsubscribeNavigation(id: number): void {
    this.navigationListeners.delete(id);
  }

  updateNameDraft(value: string): void {
    this.nameDraft = value;
    this.nameIssue = undefined;
    this.clearIdleError();
    if (this.state.status !== 'SUBMITTING') {
      this.publishCurrent(this.pendingHttpImport === undefined ? 'IDLE' : 'CONFIRMING_HTTP');
    }
  }

  updateUrlDraft(value: string): void {
    this.urlDraft = value;
    this.urlIssue = undefined;
    this.clearIdleError();
    if (this.state.status !== 'SUBMITTING') {
      this.publishCurrent(this.pendingHttpImport === undefined ? 'IDLE' : 'CONFIRMING_HTTP');
    }
  }

  async requestImportLocal(): Promise<void> {
    if (this.state.status === 'SUBMITTING') {
      return;
    }
    this.nameIssue = resolveNameIssue(this.nameDraft, false);
    this.urlIssue = undefined;
    if (this.nameIssue !== undefined) {
      this.error = undefined;
      this.publishCurrent('IDLE');
      return;
    }
    const preferredName: string | undefined = normalizeOptionalName(this.nameDraft);
    const profileIdsBefore: string[] = collectProfileIds(this.application.current());
    const token: number = this.beginCommand();
    const result: ImportProfileResult = await this.application.importLocal({
      preferredName
    });
    this.completeImportCommand(token, result, profileIdsBefore);
  }

  async requestImportUrl(): Promise<void> {
    if (this.state.status === 'SUBMITTING') {
      return;
    }
    this.nameIssue = resolveNameIssue(this.nameDraft, true);
    this.urlIssue = resolveRemoteUrlIssue(this.urlDraft);
    if (this.nameIssue !== undefined || this.urlIssue !== undefined) {
      this.error = undefined;
      this.publishCurrent('IDLE');
      return;
    }

    const parsed: ParsedRemoteSourceInput | undefined = parseRemoteSourceInput(this.urlDraft);
    if (parsed === undefined) {
      this.urlIssue = 'INVALID_URL';
      this.error = undefined;
      this.publishCurrent('IDLE');
      return;
    }
    if (parsed.plainHttp) {
      this.pendingHttpImport = parsed;
      this.pendingHttpName = normalizeRequiredName(this.nameDraft);
      this.error = undefined;
      this.publishCurrent('CONFIRMING_HTTP');
      return;
    }
    await this.executeUrlImport(parsed, false, normalizeRequiredName(this.nameDraft));
  }

  cancelPlainHttpConfirmation(): void {
    if (this.pendingHttpImport === undefined) {
      return;
    }
    this.pendingHttpImport = undefined;
    this.pendingHttpName = undefined;
    this.httpConfirmationHost = undefined;
    this.urlDraft = '';
    this.error = undefined;
    this.publishCurrent('IDLE');
  }

  async confirmPlainHttpImport(): Promise<void> {
    if (this.state.status === 'SUBMITTING') {
      return;
    }
    const pendingImport: ParsedRemoteSourceInput | undefined = this.pendingHttpImport;
    const pendingName: string | undefined = this.pendingHttpName;
    if (pendingImport === undefined || pendingName === undefined) {
      return;
    }
    this.pendingHttpImport = undefined;
    this.pendingHttpName = undefined;
    this.httpConfirmationHost = undefined;
    await this.executeUrlImport(pendingImport, true, pendingName);
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
  }

  private async executeUrlImport(
    parsed: ParsedRemoteSourceInput,
    allowPlainHttp: boolean,
    name: string
  ): Promise<void> {
    const profileIdsBefore: string[] = collectProfileIds(this.application.current());
    this.urlDraft = '';
    const token: number = this.beginCommand();
    const result: ImportProfileResult = await this.application.importUrl(createRemoteImportCommand(parsed.sourceUrl, name, allowPlainHttp));
    this.completeImportCommand(token, result, profileIdsBefore);
  }

  private completeImportCommand(token: number, result: ImportProfileResult, profileIdsBefore: string[]): void {
    if (token !== this.commandToken) {
      return;
    }
    const snapshot: ProfileApplicationSnapshot = this.application.current();
    this.error = snapshot.error !== null
      ? createSafeErrorState(snapshot.error)
      : result.kind === 'FAILED'
        ? createSafeErrorState(result.error)
        : undefined;
    const profileId: string | undefined = resolveImportedProfileId(result, snapshot, profileIdsBefore);
    if (profileId !== undefined) {
      this.publishNavigation(createNavigationIntent(profileId));
      this.publishCurrent('COMPLETED');
      return;
    }
    if (result.kind === 'CANCELLED') {
      this.publishCurrent(this.error === undefined ? 'IDLE' : 'ERROR');
      return;
    }
    this.publishCurrent('ERROR');
  }

  private beginCommand(): number {
    this.commandToken += 1;
    this.pendingHttpImport = undefined;
    this.pendingHttpName = undefined;
    this.httpConfirmationHost = undefined;
    this.error = undefined;
    this.nameIssue = undefined;
    this.urlIssue = undefined;
    this.publishCurrent('SUBMITTING');
    return this.commandToken;
  }

  private clearIdleError(): void {
    if (this.state.status === 'ERROR' || this.state.status === 'COMPLETED') {
      this.error = undefined;
    }
  }

  private publishCurrent(status: 'IDLE' | 'CONFIRMING_HTTP' | 'SUBMITTING' | 'COMPLETED' | 'ERROR'): void {
    this.httpConfirmationHost = status === 'CONFIRMING_HTTP' && this.pendingHttpImport !== undefined
      ? this.pendingHttpImport.host
      : undefined;
    this.state = createImportProfileViewState(
      status,
      this.nameIssue,
      this.urlIssue,
      this.httpConfirmationHost,
      this.error
    );
    if (this.listeners.size === 0) {
      return;
    }
    const listeners: ImportProfileViewListener[] = [];
    this.listeners.forEach((listener: ImportProfileViewListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneImportProfileViewState(this.state));
    }
  }

  private publishNavigation(intent: ImportNavigationIntent): void {
    if (this.navigationListeners.size === 0) {
      return;
    }
    const listeners: ImportNavigationListener[] = [];
    this.navigationListeners.forEach((listener: ImportNavigationListener): void => {
      listeners.push(listener);
    });
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](cloneNavigationIntent(intent));
    }
  }
}

function createRemoteImportCommand(sourceUrl: string, name: string, allowPlainHttp: boolean): RemoteImportCommand {
  return {
    sourceUrl,
    name,
    allowPlainHttp
  };
}

function normalizeOptionalName(rawName: string): string | undefined {
  const trimmed: string = rawName.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function normalizeRequiredName(rawName: string): string {
  return rawName.trim();
}

function collectProfileIds(snapshot: ProfileApplicationSnapshot): string[] {
  const profileIds: string[] = [];
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    profileIds.push(snapshot.profiles[index].id);
  }
  return profileIds;
}

function resolveImportedProfileId(
  result: ImportProfileResult,
  snapshot: ProfileApplicationSnapshot,
  profileIdsBefore: string[]
): string | undefined {
  if (result.kind === 'CREATED') {
    return result.profile.id;
  }
  if (result.kind !== 'FAILED') {
    return undefined;
  }
  for (let index: number = 0; index < snapshot.profiles.length; index += 1) {
    if (!containsProfileId(profileIdsBefore, snapshot.profiles[index].id)) {
      return snapshot.profiles[index].id;
    }
  }
  return undefined;
}

function containsProfileId(profileIds: string[], candidate: string): boolean {
  for (let index: number = 0; index < profileIds.length; index += 1) {
    if (profileIds[index] === candidate) {
      return true;
    }
  }
  return false;
}

function createNavigationIntent(profileId: string): ImportNavigationIntent {
  const intent: ImportNavigationIntentValue = new ImportNavigationIntentValue();
  intent.profileId = profileId;
  return intent;
}

function cloneNavigationIntent(intent: ImportNavigationIntent): ImportNavigationIntent {
  const cloned: ImportNavigationIntentValue = new ImportNavigationIntentValue();
  cloned.destination = intent.destination;
  cloned.profileId = intent.profileId;
  return cloned;
}
