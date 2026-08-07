import type { AppError } from './AppErrors';
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

function basenameOfPath(rawPath: string): string {
  let normalizedPath: string = rawPath.replace(/\\/g, '/');
  while (normalizedPath.endsWith('/')) {
    normalizedPath = normalizedPath.substring(0, normalizedPath.length - 1);
  }
  const separatorIndex: number = normalizedPath.lastIndexOf('/');
  return separatorIndex >= 0 ? normalizedPath.substring(separatorIndex + 1) : normalizedPath;
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

function normalizeSourceDisplay(sourceKind: ProfileSourceKind, sourceDisplay: string): string {
  if (sourceKind === 'REMOTE_URL') {
    return redactUrl(sourceDisplay);
  }
  return basenameOfPath(sourceDisplay.trim());
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
  if (sha256Digest.trim().length === 0) {
    throw new Error('Profile revision digest must not be empty.');
  }
  if (byteLength < 0) {
    throw new Error('Profile revision byte length must be non-negative.');
  }
  return {
    relativePath,
    sha256Digest: sha256Digest.trim(),
    byteLength,
    validatedAt: validatedAt.trim()
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
    id: input.id.trim(),
    name: normalizeProfileName(input.name),
    sourceKind: input.sourceKind,
    sourceDisplay: normalizeSourceDisplay(input.sourceKind, input.sourceDisplay),
    currentRevision: input.currentRevision,
    failedCandidate: input.failedCandidate,
    availability: input.availability,
    lastError: input.lastError,
    createdAt: input.createdAt.trim(),
    updatedAt: input.updatedAt.trim(),
    lastSuccessfulUpdateAt: input.lastSuccessfulUpdateAt === null ? null : input.lastSuccessfulUpdateAt.trim()
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
