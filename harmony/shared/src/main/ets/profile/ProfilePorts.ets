import type { CoreService } from '../core/CoreService';
import type { AppError } from './AppErrors';
import type { Profile, ProfileRevision } from './ProfileModels';

export type RevisionKind = 'CURRENT' | 'FAILED_CANDIDATE';
export type SubscriptionSecretErrorCode =
  | 'SOURCE_SECRET_MISSING'
  | 'SOURCE_DECRYPT_FAILED'
  | 'SOURCE_SECRET_VERSION_UNSUPPORTED'
  | 'SOURCE_SECRET_WRITE_FAILED';

export interface ProfileRepository {
  list(): Promise<Profile[]>;
  get(id: string): Promise<Profile | undefined>;
  save(profile: Profile): Promise<void>;
  deleteAndClearActive(id: string): Promise<void>;
  getActiveId(): Promise<string | undefined>;
  setActiveId(id: string | undefined): Promise<void>;
}

export interface StagedSource {
  stagingId: string;
  validationPath: string;
  sha256Digest: string;
  byteLength: number;
  validatedAt: string;
}

export interface ProfileContentStore {
  retain(profileId: string, staged: StagedSource, kind: RevisionKind): Promise<ProfileRevision>;
  discard(staged: StagedSource): Promise<void>;
  removeRevision(revision: ProfileRevision): Promise<void>;
  removeProfile(profileId: string): Promise<void>;
  reconcile(referenced: ProfileRevision[]): Promise<void>;
  resolveCorePath(revision: ProfileRevision): string;
}

export interface Clock {
  now(): string;
}

export interface IdGenerator {
  nextId(): string;
}

export interface LocalAcquireCommand {
  preferredName?: string;
}

export interface RemoteAcquireCommand {
  sourceUrl: string;
  allowPlainHttp: boolean;
  profileName: string;
  sourceDisplay: string;
}

export interface LocalProfileAcquisitionCancelled {
  kind: 'CANCELLED';
}

export interface LocalProfileAcquisitionSuccess {
  kind: 'ACQUIRED';
  profileName: string;
  sourceDisplay: string;
  staged: StagedSource;
}

export interface LocalProfileAcquisitionFailure {
  kind: 'FAILED';
  error: AppError;
  shouldPersistInvalidProfile: boolean;
  profileName?: string;
  sourceDisplay?: string;
}

export interface RemoteProfileAcquisitionSuccess {
  kind: 'ACQUIRED';
  profileName: string;
  sourceDisplay: string;
  staged: StagedSource;
}

export interface RemoteProfileAcquisitionFailure {
  kind: 'FAILED';
  error: AppError;
  profileName: string;
  sourceDisplay: string;
  shouldPersistInvalidProfile: boolean;
}

export type LocalProfileAcquisition =
  | LocalProfileAcquisitionCancelled
  | LocalProfileAcquisitionSuccess
  | LocalProfileAcquisitionFailure;

export type RemoteProfileAcquisition =
  | RemoteProfileAcquisitionSuccess
  | RemoteProfileAcquisitionFailure;

export interface ProfileSourceGateway {
  acquireLocal(command: LocalAcquireCommand): Promise<LocalProfileAcquisition>;
  acquireRemote(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition>;
}

export interface SubscriptionSecretStore {
  encrypt(plaintext: string): Promise<string>;
  decrypt(secretRef: string): Promise<string>;
  remove(secretRef: string): Promise<void>;
}

export interface SubscriptionSecretError extends Error {
  name: 'SubscriptionSecretError';
  code: SubscriptionSecretErrorCode;
  detail: string;
}

export interface ProfileRefreshLeasePort {
  tryAcquire(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean>;
  renew(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean>;
  release(profileId: string, ownerToken: string): Promise<boolean>;
}

export interface ProfilePorts {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  sourceGateway: ProfileSourceGateway;
  secretStore: SubscriptionSecretStore;
  coreService: CoreService;
  clock: Clock;
  idGenerator: IdGenerator;
}

class SubscriptionSecretErrorException extends Error implements SubscriptionSecretError {
  name: 'SubscriptionSecretError' = 'SubscriptionSecretError';
  code: SubscriptionSecretErrorCode;
  detail: string;

  constructor(code: SubscriptionSecretErrorCode, detail: string) {
    const normalizedDetail: string = detail.trim().length > 0 ? detail.trim() : 'Subscription secret operation failed.';
    super(normalizedDetail);
    this.code = code;
    this.detail = normalizedDetail;
  }
}

export function createSubscriptionSecretError(
  code: SubscriptionSecretErrorCode,
  detail: string
): SubscriptionSecretError {
  return new SubscriptionSecretErrorException(code, detail);
}

export function isSubscriptionSecretError(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return record.name === 'SubscriptionSecretError' &&
    typeof record.code === 'string' &&
    typeof record.detail === 'string';
}
