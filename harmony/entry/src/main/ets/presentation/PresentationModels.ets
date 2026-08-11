import type {
  AppError,
  AppErrorStage,
  ProfileApplicationErrorSnapshot,
  ProfileApplicationProfileSnapshot,
  ProfileAvailability,
  ProfileSourceKind
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

export type ImportDraftIssue = 'REQUIRED' | 'TOO_LONG' | 'INVALID_URL' | 'INVALID_SCHEME';

export interface ImportProfileViewState {
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'SUBMITTING' | 'COMPLETED' | 'ERROR';
  nameIssue?: 'REQUIRED' | 'TOO_LONG';
  urlIssue?: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME';
  httpConfirmationHost?: string;
  error?: SafeErrorState;
}

export interface ProfileDetailProfileState extends ProfileSummaryState {
  sourceKind: ProfileSourceKind;
  sourceRepairRequired: boolean;
}

export interface ProfileDetailViewState {
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'CONFIRMING_DELETE' | 'SUBMITTING' | 'COMPLETED' | 'ERROR';
  profile?: ProfileDetailProfileState;
  canEnable: boolean;
  canRefresh: boolean;
  canDelete: boolean;
  canReplaceSubscriptionUrl: boolean;
  sourceRepairRequired: boolean;
  confirmingDelete: boolean;
  httpConfirmationHost?: string;
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

class ImportProfileViewStateValue implements ImportProfileViewState {
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'SUBMITTING' | 'COMPLETED' | 'ERROR' = 'IDLE';
  nameIssue?: 'REQUIRED' | 'TOO_LONG';
  urlIssue?: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME';
  httpConfirmationHost?: string;
  error?: SafeErrorState;
}

class ProfileDetailProfileStateValue extends ProfileSummaryStateValue implements ProfileDetailProfileState {
  sourceKind: ProfileSourceKind = 'LOCAL_FILE';
  sourceRepairRequired: boolean = false;
}

class ProfileDetailViewStateValue implements ProfileDetailViewState {
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'CONFIRMING_DELETE' | 'SUBMITTING' | 'COMPLETED' | 'ERROR' = 'IDLE';
  profile?: ProfileDetailProfileState;
  canEnable: boolean = false;
  canRefresh: boolean = false;
  canDelete: boolean = false;
  canReplaceSubscriptionUrl: boolean = false;
  sourceRepairRequired: boolean = false;
  confirmingDelete: boolean = false;
  httpConfirmationHost?: string;
  error?: SafeErrorState;
}

export function createSafeErrorState(error: ProfileApplicationErrorSnapshot | AppError | null): SafeErrorState | undefined {
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

export function createImportProfileViewState(
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'SUBMITTING' | 'COMPLETED' | 'ERROR',
  nameIssue: 'REQUIRED' | 'TOO_LONG' | undefined,
  urlIssue: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME' | undefined,
  httpConfirmationHost: string | undefined,
  error: SafeErrorState | undefined
): ImportProfileViewState {
  const state: ImportProfileViewStateValue = new ImportProfileViewStateValue();
  state.status = status;
  state.nameIssue = nameIssue;
  state.urlIssue = urlIssue;
  state.httpConfirmationHost = httpConfirmationHost;
  state.error = cloneSafeErrorState(error);
  return state;
}

export function cloneImportProfileViewState(state: ImportProfileViewState): ImportProfileViewState {
  return createImportProfileViewState(
    state.status,
    state.nameIssue,
    state.urlIssue,
    state.httpConfirmationHost,
    state.error
  );
}

export function createProfileDetailProfileState(profile: ProfileApplicationProfileSnapshot): ProfileDetailProfileState {
  const state: ProfileDetailProfileStateValue = new ProfileDetailProfileStateValue();
  state.id = profile.id;
  state.name = profile.name;
  state.sourceDisplay = sanitizePresentationSourceDisplay(profile.sourceDisplay);
  state.availability = profile.availability;
  state.updatedAt = profile.updatedAt;
  state.sourceKind = profile.sourceKind;
  state.sourceRepairRequired = profile.sourceRepairRequired;
  return state;
}

export function cloneProfileDetailProfileState(profile: ProfileDetailProfileState | undefined): ProfileDetailProfileState | undefined {
  if (profile === undefined) {
    return undefined;
  }
  const state: ProfileDetailProfileStateValue = new ProfileDetailProfileStateValue();
  state.id = profile.id;
  state.name = profile.name;
  state.sourceDisplay = profile.sourceDisplay;
  state.availability = profile.availability;
  state.updatedAt = profile.updatedAt;
  state.sourceKind = profile.sourceKind;
  state.sourceRepairRequired = profile.sourceRepairRequired;
  return state;
}

export function createProfileDetailViewState(
  status: 'IDLE' | 'CONFIRMING_HTTP' | 'CONFIRMING_DELETE' | 'SUBMITTING' | 'COMPLETED' | 'ERROR',
  profile: ProfileDetailProfileState | undefined,
  canEnable: boolean,
  canRefresh: boolean,
  canDelete: boolean,
  canReplaceSubscriptionUrl: boolean,
  sourceRepairRequired: boolean,
  confirmingDelete: boolean,
  httpConfirmationHost: string | undefined,
  error: SafeErrorState | undefined
): ProfileDetailViewState {
  const state: ProfileDetailViewStateValue = new ProfileDetailViewStateValue();
  state.status = status;
  state.profile = cloneProfileDetailProfileState(profile);
  state.canEnable = canEnable;
  state.canRefresh = canRefresh;
  state.canDelete = canDelete;
  state.canReplaceSubscriptionUrl = canReplaceSubscriptionUrl;
  state.sourceRepairRequired = sourceRepairRequired;
  state.confirmingDelete = confirmingDelete;
  state.httpConfirmationHost = httpConfirmationHost;
  state.error = cloneSafeErrorState(error);
  return state;
}

export function cloneProfileDetailViewState(state: ProfileDetailViewState): ProfileDetailViewState {
  return createProfileDetailViewState(
    state.status,
    state.profile,
    state.canEnable,
    state.canRefresh,
    state.canDelete,
    state.canReplaceSubscriptionUrl,
    state.sourceRepairRequired,
    state.confirmingDelete,
    state.httpConfirmationHost,
    state.error
  );
}

export function sanitizePresentationSourceDisplay(sourceDisplay: string): string {
  const trimmed: string = sourceDisplay.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return safeRemoteHostFromUrl(trimmed) ?? '';
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

export interface ParsedRemoteSourceInput {
  sourceUrl: string;
  sourceDisplay: string;
  host: string;
  plainHttp: boolean;
}

class ParsedRemoteSourceInputValue implements ParsedRemoteSourceInput {
  sourceUrl: string = '';
  sourceDisplay: string = '';
  host: string = '';
  plainHttp: boolean = false;
}

class SafeRemoteAuthorityValue {
  sourceDisplay: string = '';
  host: string = '';
}

export function resolveNameIssue(rawName: string, required: boolean): 'REQUIRED' | 'TOO_LONG' | undefined {
  const trimmed: string = rawName.trim();
  if (trimmed.length === 0) {
    return required ? 'REQUIRED' : undefined;
  }
  if (trimmed.length > 80) {
    return 'TOO_LONG';
  }
  return undefined;
}

export function parseRemoteSourceInput(rawUrl: string): ParsedRemoteSourceInput | undefined {
  const trimmed: string = rawUrl.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  const schemeSeparator: number = trimmed.indexOf('://');
  if (schemeSeparator <= 0) {
    return undefined;
  }
  const scheme: string = trimmed.substring(0, schemeSeparator);
  if (scheme !== 'http' && scheme !== 'https') {
    return undefined;
  }
  const authority: SafeRemoteAuthorityValue | undefined = safeRemoteAuthorityFromUrl(trimmed);
  if (authority === undefined) {
    return undefined;
  }
  const parsed: ParsedRemoteSourceInputValue = new ParsedRemoteSourceInputValue();
  parsed.sourceUrl = trimmed;
  parsed.sourceDisplay = authority.sourceDisplay;
  parsed.host = authority.host;
  parsed.plainHttp = scheme === 'http';
  return parsed;
}

export function resolveRemoteUrlIssue(rawUrl: string): 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME' | undefined {
  const trimmed: string = rawUrl.trim();
  if (trimmed.length === 0) {
    return 'REQUIRED';
  }
  const schemeSeparator: number = trimmed.indexOf('://');
  if (schemeSeparator <= 0) {
    return 'INVALID_URL';
  }
  const scheme: string = trimmed.substring(0, schemeSeparator);
  if (scheme !== 'http' && scheme !== 'https') {
    return 'INVALID_SCHEME';
  }
  return parseRemoteSourceInput(trimmed) === undefined ? 'INVALID_URL' : undefined;
}

export function safeRemoteSourceDisplayFromUrl(rawUrl: string): string | undefined {
  return safeRemoteAuthorityFromUrl(rawUrl)?.sourceDisplay;
}

export function safeRemoteHostFromUrl(rawUrl: string): string | undefined {
  return safeRemoteAuthorityFromUrl(rawUrl)?.host;
}

function safeRemoteAuthorityFromUrl(rawUrl: string): SafeRemoteAuthorityValue | undefined {
  const trimmed: string = rawUrl.trim();
  const schemeSeparator: number = trimmed.indexOf('://');
  if (schemeSeparator <= 0) {
    return undefined;
  }
  const scheme: string = trimmed.substring(0, schemeSeparator);
  const authorityStart: number = schemeSeparator + 3;
  let authorityEnd: number = trimmed.length;
  for (let index: number = authorityStart; index < trimmed.length; index += 1) {
    const character: string = trimmed[index];
    if (character === '/' || character === '?' || character === '#') {
      authorityEnd = index;
      break;
    }
  }
  const rawAuthority: string = trimmed.substring(authorityStart, authorityEnd).trim();
  const host: string | undefined = normalizeRemoteHostPort(rawAuthority);
  if (host === undefined) {
    return undefined;
  }
  const safe: SafeRemoteAuthorityValue = new SafeRemoteAuthorityValue();
  safe.sourceDisplay = `${scheme}://${host}`;
  safe.host = host;
  return safe;
}

function normalizeRemoteHostPort(rawAuthority: string): string | undefined {
  if (rawAuthority.length === 0 || hasControlOrWhitespace(rawAuthority)) {
    return undefined;
  }
  const atIndex: number = rawAuthority.lastIndexOf('@');
  const hostPort: string = atIndex >= 0 ? rawAuthority.substring(atIndex + 1) : rawAuthority;
  if (hostPort.length === 0 || hasControlOrWhitespace(hostPort)) {
    return undefined;
  }
  if (hostPort.startsWith('[')) {
    return normalizeBracketedIpv6HostPort(hostPort);
  }
  return normalizeStandardHostPort(hostPort);
}

function hasControlOrWhitespace(value: string): boolean {
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if (code <= 32 || code === 127) {
      return true;
    }
  }
  return false;
}

function normalizeBracketedIpv6HostPort(hostPort: string): string | undefined {
  const closingBracketIndex: number = hostPort.indexOf(']');
  if (closingBracketIndex <= 1 || hostPort.lastIndexOf(']') !== closingBracketIndex) {
    return undefined;
  }
  const host: string = hostPort.substring(0, closingBracketIndex + 1);
  const suffix: string = hostPort.substring(closingBracketIndex + 1);
  if (suffix.length === 0) {
    return host;
  }
  if (!suffix.startsWith(':') || !isNumericPort(suffix.substring(1))) {
    return undefined;
  }
  return `${host}:${suffix.substring(1)}`;
}

function normalizeStandardHostPort(hostPort: string): string | undefined {
  const firstColonIndex: number = hostPort.indexOf(':');
  const lastColonIndex: number = hostPort.lastIndexOf(':');
  if (firstColonIndex >= 0 && firstColonIndex !== lastColonIndex) {
    return undefined;
  }
  let host: string = hostPort;
  let port: string = '';
  if (lastColonIndex >= 0) {
    host = hostPort.substring(0, lastColonIndex);
    port = hostPort.substring(lastColonIndex + 1);
  }
  if (host.length === 0 || !isSimpleHost(host)) {
    return undefined;
  }
  if (port.length === 0) {
    return host;
  }
  return isNumericPort(port) ? `${host}:${port}` : undefined;
}

function isSimpleHost(host: string): boolean {
  for (let index: number = 0; index < host.length; index += 1) {
    const character: string = host[index];
    const code: number = character.charCodeAt(0);
    const isAlphaNumeric: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    if (!isAlphaNumeric && character !== '.' && character !== '-') {
      return false;
    }
  }
  return true;
}

function isNumericPort(port: string): boolean {
  if (port.length === 0) {
    return false;
  }
  for (let index: number = 0; index < port.length; index += 1) {
    const code: number = port.charCodeAt(index);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}
