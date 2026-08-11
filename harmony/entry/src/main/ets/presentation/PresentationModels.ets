import type {
  AppErrorStage,
  ProfileApplicationErrorSnapshot,
  ProfileApplicationProfileSnapshot,
  ProfileAvailability
} from '@cmfa/shared';
import { redactSensitiveText } from '@cmfa/shared';

export interface SafeErrorState {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  retryable: boolean;
}

export interface ProfileSummaryState {
  id: string;
  name: string;
  sourceDisplay: string;
  availability: ProfileAvailability;
  updatedAt: string;
}

export interface HomeViewState {
  initialization: 'LOADING' | 'READY' | 'ERROR';
  activeProfile?: ProfileSummaryState;
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
  primaryAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY';
  httpAddress?: string;
  socksAddress?: string;
  error?: SafeErrorState;
}

export interface ProfileRowState {
  id: string;
  name: string;
  sourceDisplay: string;
  availability: ProfileAvailability;
  active: boolean;
  updatedAt: string;
  actionsLockedByRuntime: boolean;
}

export interface ProfilesViewState {
  initialization: 'LOADING' | 'READY' | 'ERROR';
  profiles: ProfileRowState[];
  error?: SafeErrorState;
}

class SafeErrorStateValue implements SafeErrorState {
  code: string = '';
  stage: AppErrorStage = 'PERSISTENCE';
  userMessageResource: string = '';
  technicalDetail: string = '';
  retryable: boolean = false;
}

class ProfileSummaryStateValue implements ProfileSummaryState {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  availability: ProfileAvailability = 'INVALID';
  updatedAt: string = '';
}

class HomeViewStateValue implements HomeViewState {
  initialization: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  activeProfile?: ProfileSummaryState;
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  primaryAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = 'DISABLED';
  httpAddress?: string;
  socksAddress?: string;
  error?: SafeErrorState;
}

class ProfileRowStateValue implements ProfileRowState {
  id: string = '';
  name: string = '';
  sourceDisplay: string = '';
  availability: ProfileAvailability = 'INVALID';
  active: boolean = false;
  updatedAt: string = '';
  actionsLockedByRuntime: boolean = false;
}

class ProfilesViewStateValue implements ProfilesViewState {
  initialization: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  profiles: ProfileRowState[] = [];
  error?: SafeErrorState;
}

export function createSafeErrorState(error: ProfileApplicationErrorSnapshot | null): SafeErrorState | undefined {
  if (error === null) {
    return undefined;
  }
  const safeError: SafeErrorStateValue = new SafeErrorStateValue();
  safeError.code = error.code;
  safeError.stage = error.stage;
  safeError.userMessageResource = error.userMessageResource;
  safeError.technicalDetail = redactSensitiveText(error.technicalDetail);
  safeError.retryable = error.retryable;
  return safeError;
}

export function cloneSafeErrorState(error: SafeErrorState | undefined): SafeErrorState | undefined {
  if (error === undefined) {
    return undefined;
  }
  const safeError: SafeErrorStateValue = new SafeErrorStateValue();
  safeError.code = error.code;
  safeError.stage = error.stage;
  safeError.userMessageResource = error.userMessageResource;
  safeError.technicalDetail = error.technicalDetail;
  safeError.retryable = error.retryable;
  return safeError;
}

export function createProfileSummaryState(profile: ProfileApplicationProfileSnapshot): ProfileSummaryState {
  const summary: ProfileSummaryStateValue = new ProfileSummaryStateValue();
  summary.id = profile.id;
  summary.name = profile.name;
  summary.sourceDisplay = sanitizePresentationSourceDisplay(profile.sourceDisplay);
  summary.availability = profile.availability;
  summary.updatedAt = profile.updatedAt;
  return summary;
}

export function cloneProfileSummaryState(profile: ProfileSummaryState | undefined): ProfileSummaryState | undefined {
  if (profile === undefined) {
    return undefined;
  }
  const summary: ProfileSummaryStateValue = new ProfileSummaryStateValue();
  summary.id = profile.id;
  summary.name = profile.name;
  summary.sourceDisplay = profile.sourceDisplay;
  summary.availability = profile.availability;
  summary.updatedAt = profile.updatedAt;
  return summary;
}

export function createProfileRowState(
  profile: ProfileApplicationProfileSnapshot,
  activeProfileId: string | undefined,
  actionsLockedByRuntime: boolean
): ProfileRowState {
  const row: ProfileRowStateValue = new ProfileRowStateValue();
  row.id = profile.id;
  row.name = profile.name;
  row.sourceDisplay = sanitizePresentationSourceDisplay(profile.sourceDisplay);
  row.availability = profile.availability;
  row.active = activeProfileId === profile.id;
  row.updatedAt = profile.updatedAt;
  row.actionsLockedByRuntime = actionsLockedByRuntime;
  return row;
}

export function cloneProfileRowStates(rows: ProfileRowState[]): ProfileRowState[] {
  const cloned: ProfileRowState[] = [];
  for (let index: number = 0; index < rows.length; index += 1) {
    const row: ProfileRowStateValue = new ProfileRowStateValue();
    row.id = rows[index].id;
    row.name = rows[index].name;
    row.sourceDisplay = rows[index].sourceDisplay;
    row.availability = rows[index].availability;
    row.active = rows[index].active;
    row.updatedAt = rows[index].updatedAt;
    row.actionsLockedByRuntime = rows[index].actionsLockedByRuntime;
    cloned.push(row);
  }
  return cloned;
}

export function createHomeViewState(
  initialization: 'LOADING' | 'READY' | 'ERROR',
  activeProfile: ProfileSummaryState | undefined,
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR',
  primaryAction: 'DISABLED' | 'START' | 'STOP' | 'BUSY',
  httpAddress: string | undefined,
  socksAddress: string | undefined,
  error: SafeErrorState | undefined
): HomeViewState {
  const state: HomeViewStateValue = new HomeViewStateValue();
  state.initialization = initialization;
  state.activeProfile = cloneProfileSummaryState(activeProfile);
  state.runtime = runtime;
  state.primaryAction = primaryAction;
  state.httpAddress = httpAddress;
  state.socksAddress = socksAddress;
  state.error = cloneSafeErrorState(error);
  return state;
}

export function cloneHomeViewState(state: HomeViewState): HomeViewState {
  return createHomeViewState(
    state.initialization,
    state.activeProfile,
    state.runtime,
    state.primaryAction,
    state.httpAddress,
    state.socksAddress,
    state.error
  );
}

export function createProfilesViewState(
  initialization: 'LOADING' | 'READY' | 'ERROR',
  profiles: ProfileRowState[],
  error: SafeErrorState | undefined
): ProfilesViewState {
  const state: ProfilesViewStateValue = new ProfilesViewStateValue();
  state.initialization = initialization;
  state.profiles = cloneProfileRowStates(profiles);
  state.error = cloneSafeErrorState(error);
  return state;
}

export function cloneProfilesViewState(state: ProfilesViewState): ProfilesViewState {
  return createProfilesViewState(state.initialization, state.profiles, state.error);
}

export function sanitizePresentationSourceDisplay(sourceDisplay: string): string {
  const trimmed: string = sourceDisplay.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    const schemeSeparator: number = trimmed.indexOf('://');
    const authorityStart: number = schemeSeparator + 3;
    let authorityEnd: number = trimmed.length;
    for (let index: number = authorityStart; index < trimmed.length; index += 1) {
      const character: string = trimmed[index];
      if (character === '/' || character === '?' || character === '#') {
        authorityEnd = index;
        break;
      }
    }
    return trimmed.substring(authorityStart, authorityEnd);
  }

  const normalized: string = trimmed.replace(/\\/g, '/');
  const separatorIndex: number = normalized.lastIndexOf('/');
  if (separatorIndex >= 0) {
    return normalized.substring(separatorIndex + 1);
  }
  return normalized;
}

export function isProfileStartEligible(profile: ProfileApplicationProfileSnapshot | undefined): boolean {
  if (profile === undefined) {
    return false;
  }
  if (!profile.hasCurrentRevision) {
    return false;
  }
  return profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID';
}

export function areProfileActionsLocked(
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR'
): boolean {
  return runtime === 'STARTING' || runtime === 'RUNNING' || runtime === 'STOPPING';
}
