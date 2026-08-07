import { createAppError, normalizeCanonicalUtcIsoTimestamp, type AppError } from './AppErrors';
import { redactUrl } from './SecretRedactor';

export type ProfileAvailability = 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID';
export type ProfileSourceKind = 'LOCAL_FILE' | 'REMOTE_URL';

export const PROFILE_AVAILABILITIES: ProfileAvailability[] = [
  'VALID',
  'INVALID',
  'UPDATE_FAILED_USING_VALID'
];

export interface ProfileRevision {
  relativePath: string;
  sha256Digest: string;
  byteLength: number;
  validatedAt: string;
}

export interface Profile {
  id: string;
  name: string;
  sourceKind: ProfileSourceKind;
  sourceDisplay: string;
  sourceSecretRef?: string;
  currentRevision: ProfileRevision | null;
  failedCandidate: ProfileRevision | null;
  availability: ProfileAvailability;
  lastError: AppError | null;
  createdAt: string;
  updatedAt: string;
  lastSuccessfulUpdateAt: string | null;
}

export interface CreateProfileInput {
  id: string;
  name: string;
  sourceKind: ProfileSourceKind;
  sourceDisplay: string;
  sourceSecretRef?: string;
  currentRevision: ProfileRevision | null;
  failedCandidate: ProfileRevision | null;
  availability: ProfileAvailability;
  lastError: AppError | null;
  createdAt: string;
  updatedAt: string;
  lastSuccessfulUpdateAt: string | null;
}

const SHA256_DIGEST_PATTERN: RegExp = /^[0-9a-fA-F]{64}$/u;

function basenameOfPath(rawPath: string): string {
  let normalizedPath: string = rawPath.replace(/\\/g, '/');
  while (normalizedPath.endsWith('/')) {
    normalizedPath = normalizedPath.substring(0, normalizedPath.length - 1);
  }
  const separatorIndex: number = normalizedPath.lastIndexOf('/');
  return separatorIndex >= 0 ? normalizedPath.substring(separatorIndex + 1) : normalizedPath;
}

function normalizeProfileId(rawId: string): string {
  const normalizedId: string = rawId.trim();
  if (normalizedId.length === 0) {
    throw new Error('Profile id must not be empty.');
  }
  return normalizedId;
}

function hasCurrentValidRevision(profile: Profile): boolean {
  return profile.currentRevision !== null &&
    (profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID');
}

function ensureProfileCanRepresentAvailability(profile: Profile): void {
  if (profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID') {
    if (profile.currentRevision === null) {
      throw new Error('Profiles with valid availability require a current revision.');
    }
  }
}

function normalizeLocalSourceDisplay(sourceDisplay: string): string {
  const normalizedDisplay: string = basenameOfPath(sourceDisplay.trim());
  if (normalizedDisplay.length === 0 || normalizedDisplay === '.' || normalizedDisplay === '..') {
    throw new Error('Local profile source display must normalize to a file basename.');
  }
  return normalizedDisplay;
}

function normalizeRemoteSourceDisplay(sourceDisplay: string): string {
  if (!(sourceDisplay.startsWith('http://') || sourceDisplay.startsWith('https://'))) {
    throw new Error('Remote profile source display must use http or https.');
  }
  const redactedDisplay: string = redactUrl(sourceDisplay);
  if (redactedDisplay === '<redacted-url>' || redactedDisplay.indexOf('<redacted-host>') >= 0) {
    throw new Error('Remote profile source display must contain a valid host.');
  }
  return redactedDisplay;
}

function normalizeSourceDisplay(sourceKind: ProfileSourceKind, sourceDisplay: string): string {
  if (sourceKind === 'REMOTE_URL') {
    return normalizeRemoteSourceDisplay(sourceDisplay);
  }
  return normalizeLocalSourceDisplay(sourceDisplay);
}

function normalizeProfileTimestamp(rawTimestamp: string, label: string): string {
  return normalizeCanonicalUtcIsoTimestamp(rawTimestamp, label);
}

function normalizeOptionalProfileTimestamp(rawTimestamp: string | null, label: string): string | null {
  if (rawTimestamp === null) {
    return null;
  }
  return normalizeProfileTimestamp(rawTimestamp, label);
}

function normalizeSha256Digest(rawDigest: string): string {
  const normalizedDigest: string = rawDigest.trim();
  if (!SHA256_DIGEST_PATTERN.test(normalizedDigest)) {
    throw new Error('Profile revision digest must be a 64-character SHA-256 hex string.');
  }
  return normalizedDigest.toLowerCase();
}

function normalizeByteLength(byteLength: number): number {
  if (byteLength !== byteLength ||
    byteLength === Number.POSITIVE_INFINITY ||
    byteLength === Number.NEGATIVE_INFINITY ||
    byteLength < 0 ||
    Math.floor(byteLength) !== byteLength) {
    throw new Error('Profile revision byte length must be a non-negative integer.');
  }
  return byteLength;
}

function cloneProfileRevision(revision: ProfileRevision | null): ProfileRevision | null {
  if (revision === null) {
    return null;
  }
  return createProfileRevision(
    revision.relativePath,
    revision.sha256Digest,
    revision.byteLength,
    revision.validatedAt
  );
}

function cloneProfileError(error: AppError | null): AppError | null {
  if (error === null) {
    return null;
  }
  return createAppError(error.stage, error.technicalDetail, {
    code: error.code,
    timestamp: error.timestamp,
    retryable: error.retryable,
    userMessageResource: error.userMessageResource
  });
}

export function normalizeProfileName(rawName: string): string {
  const normalizedName: string = rawName.trim();
  if (normalizedName.length < 1 || normalizedName.length > 80) {
    throw new Error('Profile name must be 1-80 characters after trimming.');
  }
  return normalizedName;
}

export function isSandboxRelativePath(relativePath: string): boolean {
  if (relativePath.trim().length === 0) {
    return false;
  }
  if (relativePath.indexOf('\\') >= 0 || relativePath.startsWith('/') || relativePath.indexOf(':') >= 0) {
    return false;
  }
  const segments: string[] = relativePath.split('/');
  for (let index = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    if (segment.length === 0 || segment === '.' || segment === '..') {
      return false;
    }
  }
  return true;
}

export function createProfileRevision(
  relativePath: string,
  sha256Digest: string,
  byteLength: number,
  validatedAt: string
): ProfileRevision {
  if (!isSandboxRelativePath(relativePath)) {
    throw new Error('Profile revision path must stay sandbox-relative.');
  }
  return {
    relativePath,
    sha256Digest: normalizeSha256Digest(sha256Digest),
    byteLength: normalizeByteLength(byteLength),
    validatedAt: normalizeProfileTimestamp(validatedAt, 'Profile revision timestamp')
  };
}

export function createProfile(input: CreateProfileInput): Profile {
  if (input.sourceKind === 'REMOTE_URL') {
    if (input.sourceSecretRef === undefined || input.sourceSecretRef.trim().length === 0) {
      throw new Error('Remote profiles require an encrypted source secret reference.');
    }
  }
  if (input.sourceKind === 'LOCAL_FILE' && input.sourceSecretRef !== undefined) {
    throw new Error('Local profiles must not persist a source secret reference.');
  }

  const profile: Profile = {
    id: normalizeProfileId(input.id),
    name: normalizeProfileName(input.name),
    sourceKind: input.sourceKind,
    sourceDisplay: normalizeSourceDisplay(input.sourceKind, input.sourceDisplay),
    currentRevision: cloneProfileRevision(input.currentRevision),
    failedCandidate: cloneProfileRevision(input.failedCandidate),
    availability: input.availability,
    lastError: cloneProfileError(input.lastError),
    createdAt: normalizeProfileTimestamp(input.createdAt, 'Profile createdAt'),
    updatedAt: normalizeProfileTimestamp(input.updatedAt, 'Profile updatedAt'),
    lastSuccessfulUpdateAt: normalizeOptionalProfileTimestamp(
      input.lastSuccessfulUpdateAt,
      'Profile lastSuccessfulUpdateAt'
    )
  };

  if (input.sourceSecretRef !== undefined && input.sourceSecretRef.trim().length > 0) {
    profile.sourceSecretRef = input.sourceSecretRef.trim();
  }

  ensureProfileCanRepresentAvailability(profile);
  return profile;
}

export function isProfileEligibleForActivation(profile: Profile): boolean {
  return hasCurrentValidRevision(profile);
}
