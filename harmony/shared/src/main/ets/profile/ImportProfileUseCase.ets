import { isCoreError, type CoreError } from '../core/CoreErrors';
import { createAppError, type AppError } from './AppErrors';
import { mapCoreError } from './CoreErrorMapper';
import { createProfile, type Profile, type ProfileAvailability, type ProfileRevision, type ProfileSourceKind } from './ProfileModels';
import { ProfileCommitError, ProfileCommitService, type SaveProfileTransaction } from './ProfileCommitService';
import type {
  Clock,
  IdGenerator,
  LocalAcquireCommand,
  LocalProfileAcquisition,
  LocalProfileAcquisitionFailure,
  LocalProfileAcquisitionSuccess,
  ProfileContentStore,
  ProfileRepository,
  ProfileSourceGateway,
  RemoteAcquireCommand,
  RemoteProfileAcquisition,
  RemoteProfileAcquisitionFailure,
  RemoteProfileAcquisitionSuccess,
  StagedSource,
  SubscriptionSecretError,
  SubscriptionSecretErrorCode,
  SubscriptionSecretStore
} from './ProfilePorts';
import { SerialCommandQueue } from './SerialCommandQueue';

export interface ImportProfileUseCaseDependencies {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  sourceGateway: ProfileSourceGateway;
  secretStore: SubscriptionSecretStore;
  coreService: ValidationCoreService;
  clock: Clock;
  idGenerator: IdGenerator;
  queue: SerialCommandQueue;
  commitService: ProfileCommitService;
}

interface ValidationCoreService {
  validateConfiguration(path: string): Promise<void>;
}

export interface RemoteImportCommand {
  sourceUrl: string;
  name: string;
  allowPlainHttp: boolean;
}

export interface ImportProfileCancelledResult {
  kind: 'CANCELLED';
}

export interface ImportProfileCreatedResult {
  kind: 'CREATED';
  profile: Profile;
}

export interface ImportProfileFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type ImportProfileResult =
  | ImportProfileCancelledResult
  | ImportProfileCreatedResult
  | ImportProfileFailedResult;

class ImportProfileCancelledResultValue implements ImportProfileCancelledResult {
  kind: 'CANCELLED' = 'CANCELLED';
}

class ImportProfileCreatedResultValue implements ImportProfileCreatedResult {
  kind: 'CREATED' = 'CREATED';
  profile: Profile;

  constructor(profile: Profile) {
    this.profile = profile;
  }
}

class ImportProfileFailedResultValue implements ImportProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

class InitialProfileShape {
  readonly profileId: string;
  readonly name: string;
  readonly sourceKind: ProfileSourceKind;
  readonly sourceDisplay: string;
  readonly sourceSecretRef?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly currentRevision: ProfileRevision | null;
  readonly failedCandidate: ProfileRevision | null;
  readonly availability: ProfileAvailability;
  readonly lastError: AppError | null;
  readonly lastSuccessfulUpdateAt: string | null;

  constructor(
    profileId: string,
    name: string,
    sourceKind: ProfileSourceKind,
    sourceDisplay: string,
    createdAt: string,
    updatedAt: string,
    currentRevision: ProfileRevision | null,
    failedCandidate: ProfileRevision | null,
    availability: ProfileAvailability,
    lastError: AppError | null,
    lastSuccessfulUpdateAt: string | null,
    sourceSecretRef?: string
  ) {
    this.profileId = profileId;
    this.name = name;
    this.sourceKind = sourceKind;
    this.sourceDisplay = sourceDisplay;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
    this.currentRevision = currentRevision;
    this.failedCandidate = failedCandidate;
    this.availability = availability;
    this.lastError = lastError;
    this.lastSuccessfulUpdateAt = lastSuccessfulUpdateAt;
    this.sourceSecretRef = sourceSecretRef;
  }
}

export class ImportProfileUseCase {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;
  private readonly sourceGateway: ProfileSourceGateway;
  private readonly secretStore: SubscriptionSecretStore;
  private readonly coreService: ValidationCoreService;
  private readonly clock: Clock;
  private readonly idGenerator: IdGenerator;
  private readonly queue: SerialCommandQueue;
  private readonly commitService: ProfileCommitService;

  constructor(dependencies: ImportProfileUseCaseDependencies) {
    this.repository = dependencies.repository;
    this.contentStore = dependencies.contentStore;
    this.sourceGateway = dependencies.sourceGateway;
    this.secretStore = dependencies.secretStore;
    this.coreService = dependencies.coreService;
    this.clock = dependencies.clock;
    this.idGenerator = dependencies.idGenerator;
    this.queue = dependencies.queue;
    this.commitService = dependencies.commitService;
  }

  executeLocal(command: LocalAcquireCommand): Promise<ImportProfileResult> {
    return this.queue.execute(async () => {
      const acquisition: LocalProfileAcquisition = await this.sourceGateway.acquireLocal(command);
      if (acquisition.kind === 'CANCELLED') {
        return new ImportProfileCancelledResultValue();
      }
      if (acquisition.kind === 'FAILED') {
        return await this.persistInitialFailure(
          'LOCAL_FILE',
          resolvePreferredName(command.preferredName, acquisition.profileName, acquisition.sourceDisplay),
          resolveLocalSourceDisplay(acquisition.sourceDisplay),
          acquisition.error,
          acquisition.shouldPersistInvalidProfile
        );
      }
      return await this.importAcquiredLocal(command, acquisition);
    });
  }

  executeRemote(command: RemoteImportCommand): Promise<ImportProfileResult> {
    return this.queue.execute(async () => {
      if (isPlainHttpUrl(command.sourceUrl) && command.allowPlainHttp !== true) {
        return new ImportProfileCancelledResultValue();
      }

      const safeSourceDisplay: string | null = toSafeRemoteSourceDisplay(command.sourceUrl);
      if (safeSourceDisplay === null) {
        return new ImportProfileFailedResultValue(
          createAppError('IMPORT', 'Remote profile URL must use http or https.', {
            retryable: false,
            timestamp: this.clock.now()
          })
        );
      }

      let secretRef: string;
      try {
        secretRef = await this.secretStore.encrypt(command.sourceUrl);
      } catch (error) {
        return new ImportProfileFailedResultValue(this.toSecretAppError(error, 'SOURCE_SECRET_WRITE_FAILED'));
      }

      try {
        const acquireCommand: RemoteAcquireCommand = {
          sourceUrl: command.sourceUrl,
          allowPlainHttp: command.allowPlainHttp,
          profileName: command.name,
          sourceDisplay: safeSourceDisplay
        };
        const acquisition: RemoteProfileAcquisition = await this.sourceGateway.acquireRemote(acquireCommand);
        if (acquisition.kind === 'FAILED') {
          return await this.persistInitialFailure(
            'REMOTE_URL',
            resolvePreferredName(command.name, acquisition.profileName, acquisition.sourceDisplay),
            acquisition.sourceDisplay,
            acquisition.error,
            acquisition.shouldPersistInvalidProfile,
            secretRef
          );
        }
        return await this.importAcquiredRemote(secretRef, command.name, acquisition);
      } catch (error) {
        await this.safeRemoveSecret(secretRef);
        return new ImportProfileFailedResultValue(toPersistenceError(error, this.clock));
      }
    });
  }

  private async importAcquiredLocal(
    command: LocalAcquireCommand,
    acquisition: LocalProfileAcquisitionSuccess
  ): Promise<ImportProfileResult> {
    const profileId: string = this.idGenerator.nextId();
    const name: string = resolvePreferredName(command.preferredName, acquisition.profileName, acquisition.sourceDisplay);
    const sourceDisplay: string = resolveLocalSourceDisplay(acquisition.sourceDisplay);
    return await this.commitImportedStage(
      profileId,
      'LOCAL_FILE',
      name,
      sourceDisplay,
      acquisition.staged
    );
  }

  private async importAcquiredRemote(
    secretRef: string,
    fallbackName: string,
    acquisition: RemoteProfileAcquisitionSuccess
  ): Promise<ImportProfileResult> {
    const profileId: string = this.idGenerator.nextId();
    const name: string = resolvePreferredName(fallbackName, acquisition.profileName, acquisition.sourceDisplay);
    return await this.commitImportedStage(
      profileId,
      'REMOTE_URL',
      name,
      acquisition.sourceDisplay,
      acquisition.staged,
      secretRef
    );
  }

  private async commitImportedStage(
    profileId: string,
    sourceKind: ProfileSourceKind,
    name: string,
    sourceDisplay: string,
    staged: StagedSource,
    sourceSecretRef?: string
  ): Promise<ImportProfileResult> {
    let validationError: AppError | null = null;
    try {
      await this.coreService.validateConfiguration(staged.validationPath);
    } catch (error) {
      validationError = toValidationAppError(error);
    }

    if (validationError === null) {
      const retainedCurrent: ProfileRevision = await this.contentStore.retain(profileId, staged, 'CURRENT');
      const createdAt: string = this.clock.now();
      const updatedAt: string = this.clock.now();
      const profile: Profile = createInitialProfile(new InitialProfileShape(
        profileId,
        name,
        sourceKind,
        sourceDisplay,
        createdAt,
        updatedAt,
        retainedCurrent,
        null,
        'VALID',
        null,
        updatedAt,
        sourceSecretRef
      ));
      const transaction: SaveProfileTransaction = {
        profile,
        newRetainedRevisions: [retainedCurrent],
        supersededRevisions: []
      };
      const commitFailure: AppError | null = await this.trySaveTransaction(transaction);
      if (commitFailure !== null) {
        if (sourceSecretRef !== undefined) {
          await this.safeRemoveSecret(sourceSecretRef);
        }
        return new ImportProfileFailedResultValue(commitFailure);
      }
      return new ImportProfileCreatedResultValue(profile);
    }

    const failedRevision: ProfileRevision = await this.contentStore.retain(profileId, staged, 'FAILED_CANDIDATE');
    const createdAt: string = this.clock.now();
    const updatedAt: string = this.clock.now();
    const invalidProfile: Profile = createInitialProfile(new InitialProfileShape(
      profileId,
      name,
      sourceKind,
      sourceDisplay,
      createdAt,
      updatedAt,
      null,
      failedRevision,
      'INVALID',
      validationError,
      null,
      sourceSecretRef
    ));
    const invalidTransaction: SaveProfileTransaction = {
      profile: invalidProfile,
      newRetainedRevisions: [failedRevision],
      supersededRevisions: []
    };
    const invalidCommitFailure: AppError | null = await this.trySaveTransaction(invalidTransaction);
    if (invalidCommitFailure !== null) {
      if (sourceSecretRef !== undefined) {
        await this.safeRemoveSecret(sourceSecretRef);
      }
      return new ImportProfileFailedResultValue(invalidCommitFailure);
    }
    return new ImportProfileCreatedResultValue(invalidProfile);
  }

  private async persistInitialFailure(
    sourceKind: ProfileSourceKind,
    name: string,
    sourceDisplay: string,
    error: AppError,
    shouldPersistInvalidProfile: boolean,
    sourceSecretRef?: string
  ): Promise<ImportProfileResult> {
    if (!shouldPersistInvalidProfile) {
      if (sourceSecretRef !== undefined) {
        await this.safeRemoveSecret(sourceSecretRef);
      }
      return new ImportProfileFailedResultValue(error);
    }

    const createdAt: string = this.clock.now();
    const updatedAt: string = this.clock.now();
    const profile: Profile = createInitialProfile(new InitialProfileShape(
      this.idGenerator.nextId(),
      name,
      sourceKind,
      sourceDisplay,
      createdAt,
      updatedAt,
      null,
      null,
      'INVALID',
      error,
      null,
      sourceSecretRef
    ));
    const transaction: SaveProfileTransaction = {
      profile,
      newRetainedRevisions: [],
      supersededRevisions: []
    };

    try {
      await this.commitService.saveProfileTransaction(transaction);
    } catch (commitError) {
      if (sourceSecretRef !== undefined) {
        await this.safeRemoveSecret(sourceSecretRef);
      }
      return new ImportProfileFailedResultValue(toPersistenceError(commitError, this.clock));
    }
    return new ImportProfileCreatedResultValue(profile);
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

  private async safeRemoveSecret(secretRef: string): Promise<void> {
    try {
      await this.secretStore.remove(secretRef);
    } catch (_) {
    }
  }

  private async trySaveTransaction(transaction: SaveProfileTransaction): Promise<AppError | null> {
    try {
      await this.commitService.saveProfileTransaction(transaction);
      return null;
    } catch (error) {
      return toPersistenceError(error, this.clock);
    }
  }
}

function createInitialProfile(shape: InitialProfileShape): Profile {
  return createProfile({
    id: shape.profileId,
    name: shape.name,
    sourceKind: shape.sourceKind,
    sourceDisplay: shape.sourceDisplay,
    sourceSecretRef: shape.sourceSecretRef,
    currentRevision: shape.currentRevision,
    failedCandidate: shape.failedCandidate,
    availability: shape.availability,
    lastError: shape.lastError,
    createdAt: shape.createdAt,
    updatedAt: shape.updatedAt,
    lastSuccessfulUpdateAt: shape.lastSuccessfulUpdateAt
  });
}

function resolvePreferredName(primary?: string, secondary?: string, tertiary?: string): string {
  const candidates: string[] = [];
  if (primary !== undefined) {
    candidates.push(primary);
  }
  if (secondary !== undefined) {
    candidates.push(secondary);
  }
  if (tertiary !== undefined) {
    candidates.push(tertiary);
  }
  for (let index = 0; index < candidates.length; index += 1) {
    const normalized: string = candidates[index].trim();
    if (normalized.length > 0) {
      return normalized;
    }
  }
  return '本地配置';
}

function resolveLocalSourceDisplay(sourceDisplay?: string): string {
  const normalized: string = sourceDisplay?.trim() ?? '';
  return normalized.length > 0 ? normalized : '本地配置';
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

function hasSubscriptionSecretErrorCode(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return record.name === 'SubscriptionSecretError' &&
    typeof record.code === 'string' &&
    typeof record.detail === 'string';
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
