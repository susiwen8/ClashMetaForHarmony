import { isCoreError, type CoreError } from '../core/CoreErrors';
import { createAppError, type AppError } from './AppErrors';
import { mapCoreError } from './CoreErrorMapper';
import { createProfile, type Profile, type ProfileAvailability, type ProfileRevision } from './ProfileModels';
import { ProfileCommitError, ProfileCommitService, type SaveProfileTransaction } from './ProfileCommitService';
import type {
  Clock,
  LocalAcquireCommand,
  LocalProfileAcquisition,
  ProfileContentStore,
  ProfileRepository,
  ProfileSourceGateway,
  RemoteAcquireCommand,
  RemoteProfileAcquisition,
  StagedSource,
  SubscriptionSecretError,
  SubscriptionSecretErrorCode,
  SubscriptionSecretStore
} from './ProfilePorts';
import { SerialCommandQueue } from './SerialCommandQueue';

export interface RefreshProfileUseCaseDependencies {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  sourceGateway: ProfileSourceGateway;
  secretStore: SubscriptionSecretStore;
  coreService: ValidationCoreService;
  clock: Clock;
  queue: SerialCommandQueue;
  commitService: ProfileCommitService;
}

interface ValidationCoreService {
  validateConfiguration(path: string): Promise<void>;
}

export interface RefreshProfileCommand {
  profileId: string;
  allowPlainHttp?: boolean;
}

export interface RefreshProfileCancelledResult {
  kind: 'CANCELLED';
}

export interface RefreshProfileUpdatedResult {
  kind: 'UPDATED';
  profile: Profile;
}

export interface RefreshProfileFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type RefreshProfileResult =
  | RefreshProfileCancelledResult
  | RefreshProfileUpdatedResult
  | RefreshProfileFailedResult;

class RefreshProfileCancelledResultValue implements RefreshProfileCancelledResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class RefreshProfileUpdatedResultValue implements RefreshProfileUpdatedResult {
  kind: 'UPDATED' = 'UPDATED';
  profile: Profile;

  constructor(profile: Profile) {
    this.profile = profile;
  }
}

class RefreshProfileFailedResultValue implements RefreshProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

export class RefreshProfileUseCase {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;
  private readonly sourceGateway: ProfileSourceGateway;
  private readonly secretStore: SubscriptionSecretStore;
  private readonly coreService: ValidationCoreService;
  private readonly clock: Clock;
  private readonly queue: SerialCommandQueue;
  private readonly commitService: ProfileCommitService;

  constructor(dependencies: RefreshProfileUseCaseDependencies) {
    this.repository = dependencies.repository;
    this.contentStore = dependencies.contentStore;
    this.sourceGateway = dependencies.sourceGateway;
    this.secretStore = dependencies.secretStore;
    this.coreService = dependencies.coreService;
    this.clock = dependencies.clock;
    this.queue = dependencies.queue;
    this.commitService = dependencies.commitService;
  }

  execute(command: RefreshProfileCommand): Promise<RefreshProfileResult> {
    return this.queue.execute(async () => {
      const existing: Profile | undefined = await this.repository.get(command.profileId);
      if (existing === undefined) {
        return new RefreshProfileFailedResultValue(
          createAppError('PERSISTENCE', 'Profile was not found.', {
            retryable: false,
            timestamp: this.clock.now()
          })
        );
      }

      if (existing.sourceKind === 'LOCAL_FILE') {
        return await this.refreshLocal(existing);
      }
      return await this.refreshRemote(existing, command.allowPlainHttp === true);
    });
  }

  private async refreshLocal(existing: Profile): Promise<RefreshProfileResult> {
      const acquireCommand: LocalAcquireCommand = {
        preferredName: existing.name
      };
    let acquisition: LocalProfileAcquisition;
    try {
      acquisition = await this.sourceGateway.acquireLocal(acquireCommand);
    } catch (error) {
      return new RefreshProfileFailedResultValue(this.toUnexpectedStageError('IMPORT', error));
    }
    if (acquisition.kind === 'CANCELLED') {
      return new RefreshProfileCancelledResultValue();
    }
    if (acquisition.kind === 'FAILED') {
      return await this.commitRefreshFailure(existing, acquisition.error, null);
    }
    return await this.commitRefreshStage(existing, acquisition.staged);
  }

  private async refreshRemote(existing: Profile, allowPlainHttp: boolean): Promise<RefreshProfileResult> {
    if (existing.sourceSecretRef === undefined || existing.sourceSecretRef.trim().length === 0) {
      return await this.commitRefreshFailure(
        existing,
        this.toSecretAppError(undefined, 'SOURCE_SECRET_MISSING'),
        null
      );
    }

    let sourceUrl: string;
    try {
      sourceUrl = await this.secretStore.decrypt(existing.sourceSecretRef);
    } catch (error) {
      return await this.commitRefreshFailure(existing, this.toSecretAppError(error, 'SOURCE_DECRYPT_FAILED'), null);
    }

    if (isPlainHttpUrl(sourceUrl) && !allowPlainHttp) {
      return new RefreshProfileCancelledResultValue();
    }

    const safeSourceDisplay: string | null = toSafeRemoteSourceDisplay(sourceUrl);
    if (safeSourceDisplay === null) {
      return await this.commitRefreshFailure(
        existing,
        createAppError('IMPORT', 'Remote profile URL must use http or https.', {
          retryable: false,
          timestamp: this.clock.now()
        }),
        null
      );
    }

    const acquireCommand: RemoteAcquireCommand = {
      sourceUrl,
      allowPlainHttp,
      profileName: existing.name,
      sourceDisplay: safeSourceDisplay
    };
    let acquisition: RemoteProfileAcquisition;
    try {
      acquisition = await this.sourceGateway.acquireRemote(acquireCommand);
    } catch (error) {
      return new RefreshProfileFailedResultValue(this.toUnexpectedStageError('DOWNLOAD', error));
    }
    if (acquisition.kind === 'FAILED') {
      return await this.commitRefreshFailure(existing, acquisition.error, null);
    }
    return await this.commitRefreshStage(existing, acquisition.staged);
  }

  private async commitRefreshStage(existing: Profile, staged: StagedSource): Promise<RefreshProfileResult> {
    let validationError: AppError | null = null;
    try {
      await this.coreService.validateConfiguration(staged.validationPath);
    } catch (error) {
      validationError = toValidationAppError(error);
    }

    if (validationError === null) {
      let retainedCurrent: ProfileRevision;
      try {
        retainedCurrent = await this.contentStore.retain(existing.id, staged, 'CURRENT');
      } catch (error) {
        return await this.failOwnedStagePersistence(error, staged);
      }
      const updatedAt: string = this.clock.now();
      const lastSuccessfulUpdateAt: string = this.clock.now();
      const updatedProfile: Profile = createProfile({
        id: existing.id,
        name: existing.name,
        sourceKind: existing.sourceKind,
        sourceDisplay: existing.sourceDisplay,
        sourceSecretRef: existing.sourceSecretRef,
        currentRevision: retainedCurrent,
        failedCandidate: null,
        availability: 'VALID',
        lastError: null,
        createdAt: existing.createdAt,
        updatedAt,
        lastSuccessfulUpdateAt,
        autoUpdateIntervalMs: existing.autoUpdateIntervalMs
      });
      const superseded: ProfileRevision[] = collectSuperseded(existing.currentRevision, existing.failedCandidate);
      const transaction: SaveProfileTransaction = {
        profile: updatedProfile,
        newRetainedRevisions: [retainedCurrent],
        supersededRevisions: superseded
      };
      const commitFailure: AppError | null = await trySaveTransaction(this.commitService, transaction, this.clock);
      if (commitFailure !== null) {
        return new RefreshProfileFailedResultValue(commitFailure);
      }
      return new RefreshProfileUpdatedResultValue(updatedProfile);
    }

    let retainedFailedCandidate: ProfileRevision;
    try {
      retainedFailedCandidate = await this.contentStore.retain(existing.id, staged, 'FAILED_CANDIDATE');
    } catch (error) {
      return await this.failOwnedStagePersistence(error, staged);
    }
    return await this.commitRefreshFailure(existing, validationError, retainedFailedCandidate);
  }

  private async commitRefreshFailure(
    existing: Profile,
    appError: AppError,
    retainedFailedCandidate: ProfileRevision | null
  ): Promise<RefreshProfileResult> {
    const hasValidCurrent: boolean = hasUsableCurrent(existing);
    const updatedAt: string = this.clock.now();
    const updatedProfile: Profile = createProfile({
      id: existing.id,
      name: existing.name,
      sourceKind: existing.sourceKind,
      sourceDisplay: existing.sourceDisplay,
      sourceSecretRef: existing.sourceSecretRef,
      currentRevision: existing.currentRevision,
      failedCandidate: retainedFailedCandidate !== null ? retainedFailedCandidate : existing.failedCandidate,
      availability: hasValidCurrent ? 'UPDATE_FAILED_USING_VALID' : fallbackAvailability(existing.availability),
      lastError: appError,
      createdAt: existing.createdAt,
      updatedAt,
      lastSuccessfulUpdateAt: existing.lastSuccessfulUpdateAt,
      autoUpdateIntervalMs: existing.autoUpdateIntervalMs
    });
    const superseded: ProfileRevision[] = [];
    if (retainedFailedCandidate !== null && existing.failedCandidate !== null) {
      superseded.push(existing.failedCandidate);
    }
    const retained: ProfileRevision[] = retainedFailedCandidate !== null ? [retainedFailedCandidate] : [];
    const transaction: SaveProfileTransaction = {
      profile: updatedProfile,
      newRetainedRevisions: retained,
      supersededRevisions: superseded
    };
    try {
      await this.commitService.saveProfileTransaction(transaction);
    } catch (error) {
      return new RefreshProfileFailedResultValue(toPersistenceError(error, this.clock));
    }
    return new RefreshProfileUpdatedResultValue(updatedProfile);
  }

  private toSecretAppError(error: Object | undefined, fallbackCode: SubscriptionSecretErrorCode): AppError {
    const detail: string = error instanceof Error && error.message.trim().length > 0
      ? error.message
      : 'Subscription secret operation failed.';
    let code: SubscriptionSecretErrorCode = fallbackCode;
    if (hasSubscriptionSecretErrorCode(error)) {
      code = (error as SubscriptionSecretError).code;
    }
    return createAppError('PERSISTENCE', detail, {
      code,
      retryable: false,
      timestamp: this.clock.now()
    });
  }

  // Refresh owns only the newly staged temp content here; the persisted secret ref belongs
  // to the existing profile and must survive transient acquire/retain failures.
  private async failOwnedStagePersistence(
    error: Object | undefined,
    staged: StagedSource
  ): Promise<RefreshProfileFailedResult> {
    await this.safeDiscardStage(staged);
    return new RefreshProfileFailedResultValue(toPersistenceError(error, this.clock));
  }

  private async safeDiscardStage(staged: StagedSource): Promise<void> {
    try {
      await this.contentStore.discard(staged);
    } catch (_) {
    }
  }

  private toUnexpectedStageError(
    stage: 'IMPORT' | 'DOWNLOAD',
    error: Object | undefined
  ): AppError {
    const detail: string = error instanceof Error && error.message.trim().length > 0
      ? error.message
      : 'Profile acquisition failed.';
    return createAppError(stage, detail, {
      retryable: false,
      timestamp: this.clock.now()
    });
  }
}

function collectSuperseded(
  currentRevision: ProfileRevision | null,
  failedCandidate: ProfileRevision | null
): ProfileRevision[] {
  const revisions: ProfileRevision[] = [];
  if (currentRevision !== null) {
    revisions.push(currentRevision);
  }
  if (failedCandidate !== null) {
    revisions.push(failedCandidate);
  }
  return revisions;
}

function fallbackAvailability(existingAvailability: ProfileAvailability): ProfileAvailability {
  return existingAvailability === 'VALID' ? 'UPDATE_FAILED_USING_VALID' : 'INVALID';
}

function hasUsableCurrent(profile: Profile): boolean {
  return profile.currentRevision !== null &&
    (profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID');
}

function toValidationAppError(error: Object | undefined): AppError {
  if (error instanceof Error && isCoreError(error as Object)) {
    const coreError: CoreError = error as CoreError;
    return mapCoreError('validate', coreError);
  }
  const detail: string = error instanceof Error && error.message.trim().length > 0
    ? error.message
    : 'Profile validation failed.';
  return createAppError('VALIDATION', detail, {
    retryable: false
  });
}

function toPersistenceError(error: Object | undefined, clock: Clock): AppError {
  if (error instanceof ProfileCommitError) {
    return error.appError;
  }
  const detail: string = error instanceof Error && error.message.trim().length > 0
    ? error.message
    : 'Profile persistence failed.';
  return createAppError('PERSISTENCE', detail, {
    retryable: false,
    timestamp: clock.now()
  });
}

function toSafeRemoteSourceDisplay(rawUrl: string): string | null {
  const normalizedUrl: string = rawUrl.trim();
  if (!(normalizedUrl.startsWith('http://') || normalizedUrl.startsWith('https://'))) {
    return null;
  }
  const separatorIndex: number = normalizedUrl.indexOf('://');
  if (separatorIndex <= 0) {
    return null;
  }
  const scheme: string = normalizedUrl.substring(0, separatorIndex);
  const authorityStart: number = separatorIndex + 3;
  let authorityEnd: number = normalizedUrl.length;
  for (let index = authorityStart; index < normalizedUrl.length; index += 1) {
    const character: string = normalizedUrl[index];
    if (character === '/' || character === '?' || character === '#') {
      authorityEnd = index;
      break;
    }
  }
  const authority: string = normalizedUrl.substring(authorityStart, authorityEnd);
  if (authority.length === 0) {
    return null;
  }
  const atIndex: number = authority.lastIndexOf('@');
  const hostPort: string = atIndex >= 0 ? authority.substring(atIndex + 1) : authority;
  if (hostPort.length === 0) {
    return null;
  }
  return `${scheme}://${hostPort}`;
}

function isPlainHttpUrl(rawUrl: string): boolean {
  return rawUrl.trim().startsWith('http://');
}

function hasSubscriptionSecretErrorCode(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return record.name === 'SubscriptionSecretError' &&
    typeof record.code === 'string' &&
    typeof record.detail === 'string';
}

async function trySaveTransaction(
  commitService: ProfileCommitService,
  transaction: SaveProfileTransaction,
  clock: Clock
): Promise<AppError | null> {
  try {
    await commitService.saveProfileTransaction(transaction);
    return null;
  } catch (error) {
    return toPersistenceError(error, clock);
  }
}
