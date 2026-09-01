import { normalizeCanonicalUtcIsoTimestamp } from './AppErrors';
import { normalizeProfileName } from './ProfileModels';

export const PROFILE_TRANSFER_MAX_PROFILES: number = 128;
export const PROFILE_TRANSFER_MAX_PROXY_SELECTIONS: number = 8192;
export const PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES: number = 16 * 1024 * 1024;
export const PROFILE_TRANSFER_MAX_AGGREGATE_BYTES: number = 64 * 1024 * 1024;
export const PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION: number = 1;
export const PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION: number = 1;
export const PROFILE_TRANSFER_PBKDF2_ITERATIONS: number = 210000;
export const PROFILE_TRANSFER_PBKDF2_SALT_BYTES: number = 16;
export const PROFILE_TRANSFER_AES_GCM_NONCE_BYTES: number = 12;
export const PROFILE_TRANSFER_AES_GCM_TAG_BYTES: number = 16;
export const PROFILE_TRANSFER_AES_GCM_KEY_BYTES: number = 32;

export type ProfileTransferQrScanResultKind = 'SCANNED' | 'CANCELLED';
export type ProfileTransferYamlExportResultCode = 'EXPORTED' | 'CANCELLED' | 'FAILED';
export type PortableBackupProfileSourceKind = 'LOCAL_FILE' | 'REMOTE_URL';
export type ProfileTransferQrUrlValidationCode = 'PROFILE_TRANSFER_INVALID_QR_URL';
export type ProfileTransferQrScannerErrorCode = 'PROFILE_TRANSFER_QR_SCAN_FAILED';

const profileTransferQrScanResultKinds: ProfileTransferQrScanResultKind[] = ['SCANNED', 'CANCELLED'];
const profileTransferYamlExportResultCodes: ProfileTransferYamlExportResultCode[] = [
  'EXPORTED',
  'CANCELLED',
  'FAILED'
];
const PROFILE_TRANSFER_QR_SCANNER_ERROR_CODE: ProfileTransferQrScannerErrorCode = 'PROFILE_TRANSFER_QR_SCAN_FAILED';
const PROFILE_TRANSFER_QR_SCANNER_ERROR_MESSAGE: string =
  'QR scan did not produce a usable profile transfer payload.';
const PORTABLE_BACKUP_PROFILE_SOURCE_KINDS: PortableBackupProfileSourceKind[] = ['LOCAL_FILE', 'REMOTE_URL'];
const SHA256_DIGEST_PATTERN: RegExp = /^[0-9a-f]{64}$/u;
const BASE64_PATTERN: RegExp = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
const CONTROL_CHARACTER_PATTERN: RegExp = /[\u0000-\u001f\u007f]/u;
const CONTROL_CHARACTER_REPLACE_PATTERN: RegExp = /[\u0000-\u001f\u007f]/gu;
const FORMAT_AND_BIDI_CHARACTER_REPLACE_PATTERN: RegExp = /[\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu;
const WHITESPACE_PATTERN: RegExp = /\s/u;
const UNSAFE_URL_CHARACTER_PATTERN: RegExp = /[\\<>"{}|^`]/u;

export interface ScannedQrScanResult {
  kind: 'SCANNED';
  value: string;
}

export interface CancelledQrScanResult {
  kind: 'CANCELLED';
}

export type ProfileTransferQrScanResult = ScannedQrScanResult | CancelledQrScanResult;

export interface ProfileTransferYamlExportResult {
  code: ProfileTransferYamlExportResultCode;
}

export interface ProfileTransferQrScannerError extends Error {
  code: ProfileTransferQrScannerErrorCode;
}

export interface ValidProfileTransferQrUrlResult {
  kind: 'VALID';
  url: string;
}

export interface InvalidProfileTransferQrUrlResult {
  kind: 'INVALID';
  code: ProfileTransferQrUrlValidationCode;
  message: string;
}

export type ProfileTransferQrUrlValidationResult =
  | ValidProfileTransferQrUrlResult
  | InvalidProfileTransferQrUrlResult;

export interface PortableBackupYamlEntry {
  byteLength: number;
  sha256Digest: string;
  contentBase64: string;
}

export interface PortableBackupProfile {
  sourceProfileId: string;
  name: string;
  sourceKind: PortableBackupProfileSourceKind;
  sourceLabel: string;
  remoteSourceUrl?: string;
  autoUpdateIntervalMs: number;
  createdAt: string;
  updatedAt: string;
  lastSuccessfulUpdateAt?: string;
  currentYaml?: PortableBackupYamlEntry;
  failedYaml?: PortableBackupYamlEntry;
}

export interface PortableBackupProxySelection {
  sourceProfileId: string;
  groupName: string;
  selectedNodeName: string;
}

export interface PortableBackupManifest {
  schemaVersion: number;
  profiles: PortableBackupProfile[];
  activeProfileSourceId?: string;
  proxySelections: PortableBackupProxySelection[];
}

export interface PortableBackupEnvelopeKdf {
  name: 'PBKDF2-HMAC-SHA256';
  iterations: number;
  saltBase64: string;
}

export interface PortableBackupEnvelopeCipher {
  name: 'AES-256-GCM';
  nonceBase64: string;
  ciphertextBase64: string;
  tagBase64: string;
}

export interface PortableBackupEnvelope {
  schemaVersion: number;
  kdf: PortableBackupEnvelopeKdf;
  cipher: PortableBackupEnvelopeCipher;
}

export interface CreatePortableBackupProfileInput {
  sourceProfileId: string;
  name: string;
  sourceKind: PortableBackupProfileSourceKind;
  sourceLabel: string;
  remoteSourceUrl?: string;
  autoUpdateIntervalMs: number;
  createdAt: string;
  updatedAt: string;
  lastSuccessfulUpdateAt?: string;
  currentYaml?: PortableBackupYamlEntry;
  failedYaml?: PortableBackupYamlEntry;
}

export interface CreatePortableBackupManifestInput {
  schemaVersion?: number;
  profiles: PortableBackupProfile[];
  activeProfileSourceId?: string;
  proxySelections: PortableBackupProxySelection[];
}

export interface CreatePortableBackupEnvelopeInput {
  schemaVersion?: number;
  kdf: PortableBackupEnvelopeKdf;
  cipher: PortableBackupEnvelopeCipher;
}

const INVALID_QR_URL_MESSAGE: string = 'Scanned QR code must contain an http or https URL.';

function createProfileTransferContractError(message: string): never {
  throw new Error(message);
}

function cloneObjectKeys(record: Object): string[] {
  return Object.keys(record).slice().sort();
}

function containsKey(keys: string[], expected: string): boolean {
  for (let index: number = 0; index < keys.length; index += 1) {
    if (keys[index] === expected) {
      return true;
    }
  }
  return false;
}

function requirePlainRecord(
  value: Object | null | undefined,
  requiredKeys: string[],
  optionalKeys: string[],
  label: string
): Record<string, Object> {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
    createProfileTransferContractError(`${label} must be an object.`);
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const actualKeys: string[] = cloneObjectKeys(record);
  const allowedKeys: string[] = requiredKeys.concat(optionalKeys).slice().sort();
  for (let index: number = 0; index < actualKeys.length; index += 1) {
    if (!containsKey(allowedKeys, actualKeys[index])) {
      createProfileTransferContractError(`${label} contains unknown keys.`);
    }
  }
  for (let index: number = 0; index < requiredKeys.length; index += 1) {
    if (!containsKey(actualKeys, requiredKeys[index])) {
      createProfileTransferContractError(`${label} is missing required keys.`);
    }
  }
  return record;
}

function normalizeNonEmptyTrimmedString(value: string, label: string): string {
  const normalized: string = value.trim();
  if (normalized.length === 0 || CONTROL_CHARACTER_PATTERN.test(normalized)) {
    createProfileTransferContractError(`${label} must be a non-empty safe string.`);
  }
  CONTROL_CHARACTER_PATTERN.lastIndex = 0;
  return normalized;
}

function normalizeSourceProfileId(sourceProfileId: string): string {
  return normalizeNonEmptyTrimmedString(sourceProfileId, 'Profile transfer sourceProfileId');
}

function normalizeSafeInteger(value: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    createProfileTransferContractError(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function normalizeProfileTransferTimestamp(value: string, label: string): string {
  return normalizeCanonicalUtcIsoTimestamp(value, label);
}

function normalizeOptionalTimestamp(value: string | undefined, label: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  return normalizeProfileTransferTimestamp(value, label);
}

function normalizeSourceKind(value: string): PortableBackupProfileSourceKind {
  for (let index: number = 0; index < PORTABLE_BACKUP_PROFILE_SOURCE_KINDS.length; index += 1) {
    if (PORTABLE_BACKUP_PROFILE_SOURCE_KINDS[index] === value) {
      return value as PortableBackupProfileSourceKind;
    }
  }
  createProfileTransferContractError('Profile transfer sourceKind must stay inside the closed contract.');
}

function normalizeSha256Digest(value: string, label: string): string {
  const normalized: string = value.trim().toLowerCase();
  if (!SHA256_DIGEST_PATTERN.test(normalized)) {
    createProfileTransferContractError(`${label} must be a 64-character SHA-256 hex digest.`);
  }
  return normalized;
}

function normalizeBase64(value: string, label: string): string {
  const normalized: string = value.trim();
  if (normalized.length === 0 || !BASE64_PATTERN.test(normalized)) {
    createProfileTransferContractError(`${label} must be valid base64.`);
  }
  return normalized;
}

function computeDecodedBase64Length(base64Value: string): number {
  let paddingLength: number = 0;
  if (base64Value.endsWith('==')) {
    paddingLength = 2;
  } else if (base64Value.endsWith('=')) {
    paddingLength = 1;
  }
  return (base64Value.length / 4) * 3 - paddingLength;
}

function normalizeExactBase64ByteLength(value: string, exactByteLength: number, label: string): string {
  const normalized: string = normalizeBase64(value, label);
  if (computeDecodedBase64Length(normalized) !== exactByteLength) {
    createProfileTransferContractError(`${label} must decode to exactly ${exactByteLength} bytes.`);
  }
  return normalized;
}

function normalizeNonEmptyBase64(value: string, label: string): string {
  const normalized: string = normalizeBase64(value, label);
  if (computeDecodedBase64Length(normalized) <= 0) {
    createProfileTransferContractError(`${label} must not be empty.`);
  }
  return normalized;
}

function normalizeHttpLikeUrl(rawUrl: string): string {
  const trimmed: string = rawUrl.trim();
  if (trimmed.length === 0 || CONTROL_CHARACTER_PATTERN.test(trimmed)) {
    CONTROL_CHARACTER_PATTERN.lastIndex = 0;
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  CONTROL_CHARACTER_PATTERN.lastIndex = 0;
  const separatorIndex: number = trimmed.indexOf('://');
  if (separatorIndex <= 0) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const scheme: string = trimmed.substring(0, separatorIndex).toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const authorityStart: number = separatorIndex + 3;
  let authorityEnd: number = trimmed.length;
  for (let index: number = authorityStart; index < trimmed.length; index += 1) {
    const character: string = trimmed[index];
    if (character === '/' || character === '?' || character === '#') {
      authorityEnd = index;
      break;
    }
  }
  const authority: string = trimmed.substring(authorityStart, authorityEnd);
  if (authority.length === 0) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const normalizedAuthority: string = normalizeValidatedAuthority(authority);
  const normalizedRemainder: string = normalizeValidatedUrlRemainder(trimmed.substring(authorityEnd));
  return `${scheme}://${normalizedAuthority}${normalizedRemainder}`;
}

function containsWhitespaceOrControl(value: string): boolean {
  if (CONTROL_CHARACTER_PATTERN.test(value)) {
    CONTROL_CHARACTER_PATTERN.lastIndex = 0;
    return true;
  }
  CONTROL_CHARACTER_PATTERN.lastIndex = 0;
  return WHITESPACE_PATTERN.test(value);
}

function isNumeric(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  for (let index: number = 0; index < value.length; index += 1) {
    const code: number = value.charCodeAt(index);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

function isAllowedHostCharacter(character: string): boolean {
  const code: number = character.charCodeAt(0);
  return (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    character === '.' ||
    character === '-';
}

function validateAuthorityPort(port: string): void {
  if (!isNumeric(port)) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const normalizedPort: number = Number.parseInt(port, 10);
  if (normalizedPort < 1 || normalizedPort > 65535) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
}

function validateBracketedIpv6Authority(hostPort: string): string {
  const closingBracketIndex: number = hostPort.indexOf(']');
  if (closingBracketIndex <= 1 || hostPort.lastIndexOf(']') !== closingBracketIndex) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const host: string = hostPort.substring(1, closingBracketIndex);
  if (host.indexOf(':') < 0 || containsWhitespaceOrControl(host) || host.indexOf('[') >= 0 || host.indexOf(']') >= 0) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  const suffix: string = hostPort.substring(closingBracketIndex + 1);
  if (suffix.length > 0) {
    if (!suffix.startsWith(':')) {
      createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
    }
    validateAuthorityPort(suffix.substring(1));
  }
  return `[${host.toLowerCase()}]${suffix}`;
}

function validateStandardAuthority(hostPort: string): string {
  const firstColonIndex: number = hostPort.indexOf(':');
  const lastColonIndex: number = hostPort.lastIndexOf(':');
  if (firstColonIndex >= 0 && firstColonIndex !== lastColonIndex) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }

  let host: string = hostPort;
  let suffix: string = '';
  if (lastColonIndex >= 0) {
    host = hostPort.substring(0, lastColonIndex);
    const port: string = hostPort.substring(lastColonIndex + 1);
    validateAuthorityPort(port);
    suffix = `:${port}`;
  }

  if (host.length === 0 || containsWhitespaceOrControl(host)) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  for (let index: number = 0; index < host.length; index += 1) {
    if (!isAllowedHostCharacter(host[index])) {
      createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
    }
  }
  return `${host.toLowerCase()}${suffix}`;
}

function normalizeValidatedAuthority(authority: string): string {
  if (authority.length === 0 || containsWhitespaceOrControl(authority) || authority.indexOf('@') >= 0) {
    createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
  }
  if (authority.startsWith('[')) {
    return validateBracketedIpv6Authority(authority);
  }
  return validateStandardAuthority(authority);
}

function isHexCharacter(character: string): boolean {
  const code: number = character.charCodeAt(0);
  return (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 70) ||
    (code >= 97 && code <= 102);
}

function normalizeValidatedUrlRemainder(remainder: string): string {
  for (let index: number = 0; index < remainder.length; index += 1) {
    const character: string = remainder[index];
    if (containsWhitespaceOrControl(character) || UNSAFE_URL_CHARACTER_PATTERN.test(character)) {
      createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
    }
    if (character === '%') {
      if (index + 2 >= remainder.length ||
        !isHexCharacter(remainder[index + 1]) ||
        !isHexCharacter(remainder[index + 2])) {
        createProfileTransferContractError(INVALID_QR_URL_MESSAGE);
      }
      index += 2;
    }
  }
  return remainder;
}

function normalizeLocalSourceLabel(sourceLabel: string): string {
  const normalized: string = normalizeNonEmptyTrimmedString(sourceLabel, 'Profile transfer local sourceLabel');
  if (normalized.indexOf('/') >= 0 || normalized.indexOf('\\') >= 0 || normalized === '.' || normalized === '..') {
    createProfileTransferContractError('Local backup profile sourceLabel must not contain path separators.');
  }
  return normalized;
}

function normalizeRemoteUrl(sourceLabelOrUrl: string, label: string): string {
  try {
    return normalizeHttpLikeUrl(sourceLabelOrUrl);
  } catch (_) {
    createProfileTransferContractError(`${label} must be a valid http or https URL.`);
  }
}

function normalizeRemoteSourceLabel(sourceLabelOrUrl: string, label: string): string {
  const normalizedRemoteUrl: string = normalizeRemoteUrl(sourceLabelOrUrl, label);
  let authorityEnd: number = normalizedRemoteUrl.length;
  for (let index: number = normalizedRemoteUrl.indexOf('://') + 3; index < normalizedRemoteUrl.length; index += 1) {
    const character: string = normalizedRemoteUrl[index];
    if (character === '/' || character === '?' || character === '#') {
      authorityEnd = index;
      break;
    }
  }
  return normalizedRemoteUrl.substring(0, authorityEnd);
}

function clonePortableBackupYamlEntryOrUndefined(entry: PortableBackupYamlEntry | undefined): PortableBackupYamlEntry | undefined {
  if (entry === undefined) {
    return undefined;
  }
  return createPortableBackupYamlEntry(entry.byteLength, entry.sha256Digest, entry.contentBase64);
}

function clonePortableBackupProxySelection(selection: PortableBackupProxySelection): PortableBackupProxySelection {
  return createPortableBackupProxySelection(selection.sourceProfileId, selection.groupName, selection.selectedNodeName);
}

function clonePortableBackupProfile(profile: PortableBackupProfile): PortableBackupProfile {
  return createPortableBackupProfile({
    sourceProfileId: profile.sourceProfileId,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceLabel: profile.sourceLabel,
    remoteSourceUrl: profile.remoteSourceUrl,
    autoUpdateIntervalMs: profile.autoUpdateIntervalMs,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt,
    currentYaml: clonePortableBackupYamlEntryOrUndefined(profile.currentYaml),
    failedYaml: clonePortableBackupYamlEntryOrUndefined(profile.failedYaml)
  });
}

function requireProfileTransferSchemaVersion(value: number | undefined, label: string): number {
  const normalized: number = normalizeSafeInteger(value ?? PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION, label);
  if (normalized !== PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION) {
    createProfileTransferContractError(`${label} must be ${PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION}.`);
  }
  return normalized;
}

function requireProfileTransferEnvelopeVersion(value: number | undefined, label: string): number {
  const normalized: number = normalizeSafeInteger(value ?? PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION, label);
  if (normalized !== PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION) {
    createProfileTransferContractError(`${label} must be ${PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION}.`);
  }
  return normalized;
}

function normalizeYamlEntryByteLength(byteLength: number): number {
  const normalized: number = normalizeSafeInteger(byteLength, 'Profile transfer YAML byteLength');
  if (normalized > PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES) {
    createProfileTransferContractError('Profile transfer YAML entries must not exceed 16 MiB.');
  }
  return normalized;
}

function computeAggregateYamlBytes(profiles: PortableBackupProfile[]): number {
  let aggregate: number = 0;
  for (let index: number = 0; index < profiles.length; index += 1) {
    const profile: PortableBackupProfile = profiles[index];
    if (profile.currentYaml !== undefined) {
      aggregate += profile.currentYaml.byteLength;
    }
    if (profile.failedYaml !== undefined) {
      aggregate += profile.failedYaml.byteLength;
    }
  }
  return aggregate;
}

function ensureAggregateYamlBytesWithinLimit(profiles: PortableBackupProfile[]): void {
  if (computeAggregateYamlBytes(profiles) > PROFILE_TRANSFER_MAX_AGGREGATE_BYTES) {
    createProfileTransferContractError('Profile transfer backup aggregate YAML payload must not exceed 64 MiB.');
  }
}

function ensureUniqueProfileSourceIds(profiles: PortableBackupProfile[]): void {
  const seenSourceProfileIds: string[] = [];
  for (let index: number = 0; index < profiles.length; index += 1) {
    const sourceProfileId: string = profiles[index].sourceProfileId;
    if (containsKey(seenSourceProfileIds, sourceProfileId)) {
      createProfileTransferContractError('Profile transfer profiles must have unique sourceProfileId values.');
    }
    seenSourceProfileIds.push(sourceProfileId);
  }
}

function ensureActiveProfileExists(
  profiles: PortableBackupProfile[],
  activeProfileSourceId: string | undefined
): void {
  if (activeProfileSourceId === undefined) {
    return;
  }
  for (let index: number = 0; index < profiles.length; index += 1) {
    if (profiles[index].sourceProfileId === activeProfileSourceId) {
      return;
    }
  }
  createProfileTransferContractError('Profile transfer activeProfileSourceId must reference an existing profile.');
}

function ensureProxySelectionsWithinLimit(proxySelections: PortableBackupProxySelection[]): void {
  if (proxySelections.length > PROFILE_TRANSFER_MAX_PROXY_SELECTIONS) {
    createProfileTransferContractError('Profile transfer proxySelections must not contain more than 8192 items.');
  }
}

function ensureProxySelectionsReferenceKnownProfiles(
  profiles: PortableBackupProfile[],
  proxySelections: PortableBackupProxySelection[]
): void {
  const selectionKeys: string[] = [];
  for (let index: number = 0; index < proxySelections.length; index += 1) {
    const selection: PortableBackupProxySelection = proxySelections[index];
    let knownProfile: boolean = false;
    for (let profileIndex: number = 0; profileIndex < profiles.length; profileIndex += 1) {
      if (profiles[profileIndex].sourceProfileId === selection.sourceProfileId) {
        knownProfile = true;
        break;
      }
    }
    if (!knownProfile) {
      createProfileTransferContractError(
        'Profile transfer proxy selection sourceProfileId must reference an existing profile.'
      );
    }
    const uniqueKey: string = `${selection.sourceProfileId}\u0000${selection.groupName}`;
    if (containsKey(selectionKeys, uniqueKey)) {
      createProfileTransferContractError(
        'Profile transfer manifest must not contain a duplicate proxy selection for the same sourceProfileId and groupName.'
      );
    }
    selectionKeys.push(uniqueKey);
  }
}

function normalizeOptionalPortableBackupYamlEntry(value: PortableBackupYamlEntry | undefined): PortableBackupYamlEntry | undefined {
  if (value === undefined) {
    return undefined;
  }
  return createPortableBackupYamlEntry(value.byteLength, value.sha256Digest, value.contentBase64);
}

function normalizeKdfName(name: string): 'PBKDF2-HMAC-SHA256' {
  if (name !== 'PBKDF2-HMAC-SHA256') {
    createProfileTransferContractError('Profile transfer backup KDF name must be PBKDF2-HMAC-SHA256.');
  }
  return name;
}

function normalizeCipherName(name: string): 'AES-256-GCM' {
  if (name !== 'AES-256-GCM') {
    createProfileTransferContractError('Profile transfer backup cipher name must be AES-256-GCM.');
  }
  return name;
}

function normalizeQrScanResultKind(kind: string): ProfileTransferQrScanResultKind {
  for (let index: number = 0; index < profileTransferQrScanResultKinds.length; index += 1) {
    if (profileTransferQrScanResultKinds[index] === kind) {
      return kind as ProfileTransferQrScanResultKind;
    }
  }
  createProfileTransferContractError('Profile transfer QR scan result kind must stay inside the closed contract.');
}

function normalizeYamlExportResultCode(code: string): ProfileTransferYamlExportResultCode {
  for (let index: number = 0; index < profileTransferYamlExportResultCodes.length; index += 1) {
    if (profileTransferYamlExportResultCodes[index] === code) {
      return code as ProfileTransferYamlExportResultCode;
    }
  }
  createProfileTransferContractError('Profile transfer YAML export result code must stay inside the closed contract.');
}

export function listProfileTransferQrScanResultKinds(): ProfileTransferQrScanResultKind[] {
  return profileTransferQrScanResultKinds.slice();
}

export function listProfileTransferYamlExportResultCodes(): ProfileTransferYamlExportResultCode[] {
  return profileTransferYamlExportResultCodes.slice();
}

export function createScannedQrScanResult(value: string): ProfileTransferQrScanResult {
  return {
    kind: normalizeQrScanResultKind('SCANNED'),
    value: normalizeNonEmptyTrimmedString(value, 'Profile transfer QR value')
  };
}

export function createCancelledQrScanResult(): ProfileTransferQrScanResult {
  return {
    kind: normalizeQrScanResultKind('CANCELLED')
  };
}

export function createProfileTransferQrScannerError(): ProfileTransferQrScannerError {
  const error = new Error(PROFILE_TRANSFER_QR_SCANNER_ERROR_MESSAGE) as ProfileTransferQrScannerError;
  error.name = 'ProfileTransferQrScannerError';
  error.code = PROFILE_TRANSFER_QR_SCANNER_ERROR_CODE;
  return error;
}

export function sanitizeProfileTransferQrUrl(rawValue: string): ProfileTransferQrUrlValidationResult {
  try {
    return {
      kind: 'VALID',
      url: normalizeHttpLikeUrl(rawValue)
    };
  } catch (_) {
    return {
      kind: 'INVALID',
      code: 'PROFILE_TRANSFER_INVALID_QR_URL',
      message: INVALID_QR_URL_MESSAGE
    };
  }
}

export function createProfileYamlExportResult(code: ProfileTransferYamlExportResultCode): ProfileTransferYamlExportResult {
  return {
    code: normalizeYamlExportResultCode(code)
  };
}

export function createPortableBackupYamlEntry(
  byteLength: number,
  sha256Digest: string,
  contentBase64: string
): PortableBackupYamlEntry {
  const normalizedByteLength: number = normalizeYamlEntryByteLength(byteLength);
  return {
    byteLength: normalizedByteLength,
    sha256Digest: normalizeSha256Digest(sha256Digest, 'Profile transfer YAML sha256Digest'),
    contentBase64: normalizeExactBase64ByteLength(
      contentBase64,
      normalizedByteLength,
      'Profile transfer YAML contentBase64'
    )
  };
}

export function createPortableBackupProfile(input: CreatePortableBackupProfileInput): PortableBackupProfile {
  const sourceKind: PortableBackupProfileSourceKind = normalizeSourceKind(input.sourceKind);
  const normalizedRemoteSourceLabel: string | undefined = sourceKind === 'REMOTE_URL'
    ? normalizeRemoteSourceLabel(input.sourceLabel, 'Profile transfer remote sourceLabel')
    : undefined;
  const normalizedProfile: PortableBackupProfile = {
    sourceProfileId: normalizeSourceProfileId(input.sourceProfileId),
    name: normalizeProfileName(input.name),
    sourceKind,
    sourceLabel: sourceKind === 'REMOTE_URL'
      ? normalizedRemoteSourceLabel as string
      : normalizeLocalSourceLabel(input.sourceLabel),
    autoUpdateIntervalMs: normalizeSafeInteger(
      input.autoUpdateIntervalMs,
      'Profile transfer autoUpdateIntervalMs'
    ),
    createdAt: normalizeProfileTransferTimestamp(input.createdAt, 'Profile transfer createdAt'),
    updatedAt: normalizeProfileTransferTimestamp(input.updatedAt, 'Profile transfer updatedAt')
  };

  if (sourceKind === 'REMOTE_URL') {
    if (input.remoteSourceUrl === undefined) {
      createProfileTransferContractError('Remote backup profiles require remoteSourceUrl.');
    }
    normalizedProfile.remoteSourceUrl = normalizeRemoteUrl(
      input.remoteSourceUrl,
      'Profile transfer remoteSourceUrl'
    );
  } else if (input.remoteSourceUrl !== undefined) {
    createProfileTransferContractError('Local backup profiles must not include remoteSourceUrl.');
  }

  const normalizedLastSuccessfulUpdateAt: string | undefined = normalizeOptionalTimestamp(
    input.lastSuccessfulUpdateAt,
    'Profile transfer lastSuccessfulUpdateAt'
  );
  if (normalizedLastSuccessfulUpdateAt !== undefined) {
    normalizedProfile.lastSuccessfulUpdateAt = normalizedLastSuccessfulUpdateAt;
  }

  const currentYaml: PortableBackupYamlEntry | undefined = normalizeOptionalPortableBackupYamlEntry(
    input.currentYaml
  );
  if (currentYaml !== undefined) {
    normalizedProfile.currentYaml = currentYaml;
  }

  const failedYaml: PortableBackupYamlEntry | undefined = normalizeOptionalPortableBackupYamlEntry(
    input.failedYaml
  );
  if (failedYaml !== undefined) {
    normalizedProfile.failedYaml = failedYaml;
  }

  return normalizedProfile;
}

export function createPortableBackupProxySelection(
  sourceProfileId: string,
  groupName: string,
  selectedNodeName: string
): PortableBackupProxySelection {
  return {
    sourceProfileId: normalizeSourceProfileId(sourceProfileId),
    groupName: normalizeNonEmptyTrimmedString(groupName, 'Profile transfer proxy selection groupName'),
    selectedNodeName: normalizeNonEmptyTrimmedString(
      selectedNodeName,
      'Profile transfer proxy selection selectedNodeName'
    )
  };
}

export function createPortableBackupManifest(input: CreatePortableBackupManifestInput): PortableBackupManifest {
  const profiles: PortableBackupProfile[] = [];
  for (let index: number = 0; index < input.profiles.length; index += 1) {
    profiles.push(clonePortableBackupProfile(input.profiles[index]));
  }
  if (profiles.length > PROFILE_TRANSFER_MAX_PROFILES) {
    createProfileTransferContractError('Profile transfer backup must not contain more than 128 profiles.');
  }
  ensureUniqueProfileSourceIds(profiles);
  ensureAggregateYamlBytesWithinLimit(profiles);

  const proxySelections: PortableBackupProxySelection[] = [];
  for (let index: number = 0; index < input.proxySelections.length; index += 1) {
    proxySelections.push(clonePortableBackupProxySelection(input.proxySelections[index]));
  }
  ensureProxySelectionsWithinLimit(proxySelections);

  const normalizedActiveProfileSourceId: string | undefined = input.activeProfileSourceId !== undefined
    ? normalizeSourceProfileId(input.activeProfileSourceId)
    : undefined;
  ensureActiveProfileExists(profiles, normalizedActiveProfileSourceId);
  ensureProxySelectionsReferenceKnownProfiles(profiles, proxySelections);

  const manifest: PortableBackupManifest = {
    schemaVersion: requireProfileTransferSchemaVersion(
      input.schemaVersion,
      'Profile transfer backup schemaVersion'
    ),
    profiles,
    proxySelections
  };

  if (normalizedActiveProfileSourceId !== undefined) {
    manifest.activeProfileSourceId = normalizedActiveProfileSourceId;
  }
  return manifest;
}

export function createPortableBackupEnvelope(input: CreatePortableBackupEnvelopeInput): PortableBackupEnvelope {
  const iterations: number = normalizeSafeInteger(
    input.kdf.iterations,
    'Profile transfer backup iterations'
  );
  if (iterations !== PROFILE_TRANSFER_PBKDF2_ITERATIONS) {
    createProfileTransferContractError('Profile transfer backup iterations must be exactly 210000.');
  }

  return {
    schemaVersion: requireProfileTransferEnvelopeVersion(
      input.schemaVersion,
      'Profile transfer backup envelope schemaVersion'
    ),
    kdf: {
      name: normalizeKdfName(input.kdf.name),
      iterations,
      saltBase64: normalizeExactBase64ByteLength(
        input.kdf.saltBase64,
        PROFILE_TRANSFER_PBKDF2_SALT_BYTES,
        'Profile transfer backup saltBase64'
      )
    },
    cipher: {
      name: normalizeCipherName(input.cipher.name),
      nonceBase64: normalizeExactBase64ByteLength(
        input.cipher.nonceBase64,
        PROFILE_TRANSFER_AES_GCM_NONCE_BYTES,
        'Profile transfer backup nonceBase64'
      ),
      ciphertextBase64: normalizeNonEmptyBase64(
        input.cipher.ciphertextBase64,
        'Profile transfer backup ciphertextBase64'
      ),
      tagBase64: normalizeExactBase64ByteLength(
        input.cipher.tagBase64,
        PROFILE_TRANSFER_AES_GCM_TAG_BYTES,
        'Profile transfer backup tagBase64'
      )
    }
  };
}

export function parsePortableBackupManifest(value: Object): PortableBackupManifest {
  const record: Record<string, Object> = requirePlainRecord(
    value,
    ['schemaVersion', 'profiles', 'proxySelections'],
    ['activeProfileSourceId'],
    'Profile transfer backup manifest'
  );
  if (!Array.isArray(record.profiles)) {
    createProfileTransferContractError('Profile transfer backup profiles must be an array.');
  }
  if (!Array.isArray(record.proxySelections)) {
    createProfileTransferContractError('Profile transfer backup proxySelections must be an array.');
  }

  const profiles: PortableBackupProfile[] = [];
  const rawProfiles: Object[] = record.profiles as Object[];
  for (let index: number = 0; index < rawProfiles.length; index += 1) {
    const parsedProfileRecord: Record<string, Object> = requirePlainRecord(
      rawProfiles[index],
      [
        'sourceProfileId',
        'name',
        'sourceKind',
        'sourceLabel',
        'autoUpdateIntervalMs',
        'createdAt',
        'updatedAt'
      ],
      ['remoteSourceUrl', 'lastSuccessfulUpdateAt', 'currentYaml', 'failedYaml'],
      'Profile transfer backup profile'
    );
    const currentYaml: PortableBackupYamlEntry | undefined = parsedProfileRecord.currentYaml !== undefined
      ? parsePortableBackupYamlEntry(parsedProfileRecord.currentYaml)
      : undefined;
    const failedYaml: PortableBackupYamlEntry | undefined = parsedProfileRecord.failedYaml !== undefined
      ? parsePortableBackupYamlEntry(parsedProfileRecord.failedYaml)
      : undefined;
    profiles.push(createPortableBackupProfile({
      sourceProfileId: parsedProfileRecord.sourceProfileId as string,
      name: parsedProfileRecord.name as string,
      sourceKind: parsedProfileRecord.sourceKind as PortableBackupProfileSourceKind,
      sourceLabel: parsedProfileRecord.sourceLabel as string,
      remoteSourceUrl: parsedProfileRecord.remoteSourceUrl as string | undefined,
      autoUpdateIntervalMs: parsedProfileRecord.autoUpdateIntervalMs as number,
      createdAt: parsedProfileRecord.createdAt as string,
      updatedAt: parsedProfileRecord.updatedAt as string,
      lastSuccessfulUpdateAt: parsedProfileRecord.lastSuccessfulUpdateAt as string | undefined,
      currentYaml,
      failedYaml
    }));
  }

  const proxySelections: PortableBackupProxySelection[] = [];
  const rawSelections: Object[] = record.proxySelections as Object[];
  for (let index: number = 0; index < rawSelections.length; index += 1) {
    const selectionRecord: Record<string, Object> = requirePlainRecord(
      rawSelections[index],
      ['sourceProfileId', 'groupName', 'selectedNodeName'],
      [],
      'Profile transfer backup proxySelection'
    );
    proxySelections.push(createPortableBackupProxySelection(
      selectionRecord.sourceProfileId as string,
      selectionRecord.groupName as string,
      selectionRecord.selectedNodeName as string
    ));
  }

  return createPortableBackupManifest({
    schemaVersion: record.schemaVersion as number,
    profiles,
    activeProfileSourceId: record.activeProfileSourceId as string | undefined,
    proxySelections
  });
}

function parsePortableBackupYamlEntry(value: Object): PortableBackupYamlEntry {
  const record: Record<string, Object> = requirePlainRecord(
    value,
    ['byteLength', 'sha256Digest', 'contentBase64'],
    [],
    'Profile transfer backup YAML entry'
  );
  return createPortableBackupYamlEntry(
    record.byteLength as number,
    record.sha256Digest as string,
    record.contentBase64 as string
  );
}

export function parsePortableBackupEnvelope(value: Object): PortableBackupEnvelope {
  const record: Record<string, Object> = requirePlainRecord(
    value,
    ['schemaVersion', 'kdf', 'cipher'],
    [],
    'Profile transfer backup envelope'
  );
  const kdfRecord: Record<string, Object> = requirePlainRecord(
    record.kdf,
    ['name', 'iterations', 'saltBase64'],
    [],
    'Profile transfer backup kdf'
  );
  const cipherRecord: Record<string, Object> = requirePlainRecord(
    record.cipher,
    ['name', 'nonceBase64', 'ciphertextBase64', 'tagBase64'],
    [],
    'Profile transfer backup cipher'
  );
  return createPortableBackupEnvelope({
    schemaVersion: record.schemaVersion as number,
    kdf: {
      name: kdfRecord.name as 'PBKDF2-HMAC-SHA256',
      iterations: kdfRecord.iterations as number,
      saltBase64: kdfRecord.saltBase64 as string
    },
    cipher: {
      name: cipherRecord.name as 'AES-256-GCM',
      nonceBase64: cipherRecord.nonceBase64 as string,
      ciphertextBase64: cipherRecord.ciphertextBase64 as string,
      tagBase64: cipherRecord.tagBase64 as string
    }
  });
}

export function createProfileTransferSafeYamlFilename(rawName: string): string {
  let stem: string = rawName.trim();
  if (typeof ''.normalize === 'function') {
    stem = stem.normalize('NFKC');
  }
  if (stem.toLowerCase().endsWith('.yaml')) {
    stem = stem.substring(0, stem.length - 5);
  } else if (stem.toLowerCase().endsWith('.yml')) {
    stem = stem.substring(0, stem.length - 4);
  }
  stem = stem.replace(CONTROL_CHARACTER_REPLACE_PATTERN, '');
  stem = stem.replace(FORMAT_AND_BIDI_CHARACTER_REPLACE_PATTERN, '');
  stem = stem.replace(/[\\/:\*\?"<>\|]/gu, '');
  stem = stem.replace(/\.\./gu, '');
  stem = stem.replace(/\./gu, '');
  stem = stem.trim();
  if (stem.length > 80) {
    stem = stem.substring(0, 80);
  }
  if (stem.length === 0) {
    stem = 'profile';
  }
  return `${stem}.yaml`;
}
