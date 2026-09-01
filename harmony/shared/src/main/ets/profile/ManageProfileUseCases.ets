import { createAppError, type AppError } from './AppErrors';
import { createProfile, isProfileEligibleForActivation, type Profile } from './ProfileModels';
import type { Clock, ProfileContentStore, ProfileRepository, SubscriptionSecretStore } from './ProfilePorts';
import { LocalRuntimeCoordinator } from './LocalRuntimeCoordinator';
import type { CoreService } from '../core/CoreService';

export interface ManageProfileUseCasesDependencies {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  secretStore: SubscriptionSecretStore;
  coreService: CoreService;
  clock: Clock;
  runtimeCoordinator: LocalRuntimeCoordinator;
}

export interface EnableProfileResult {
  kind: 'ENABLED';
  profile: Profile;
}

export interface DeleteProfileResult {
  kind: 'DELETED';
  profileId: string;
}

export interface ReplaceSubscriptionUrlResult {
  kind: 'REPLACED';
  profile: Profile;
}

export interface UpdateProfileMetadataResult {
  kind: 'UPDATED';
  profile: Profile;
  sourceChanged: boolean;
}

export interface ManageProfileFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type ManageEnableResult = EnableProfileResult | ManageProfileFailedResult;
export type ManageDeleteResult = DeleteProfileResult | ManageProfileFailedResult;
export type ManageReplaceResult = ReplaceSubscriptionUrlResult | ManageProfileFailedResult;
export type ManageUpdateResult = UpdateProfileMetadataResult | ManageProfileFailedResult;

class EnableProfileResultValue implements EnableProfileResult {
  kind: 'ENABLED' = 'ENABLED';
  profile: Profile;

  constructor(profile: Profile) {
    this.profile = profile;
  }
}

class DeleteProfileResultValue implements DeleteProfileResult {
  kind: 'DELETED' = 'DELETED';
  profileId: string;

  constructor(profileId: string) {
    this.profileId = profileId;
  }
}

class ReplaceSubscriptionUrlResultValue implements ReplaceSubscriptionUrlResult {
  kind: 'REPLACED' = 'REPLACED';
  profile: Profile;

  constructor(profile: Profile) {
    this.profile = profile;
  }
}

class UpdateProfileMetadataResultValue implements UpdateProfileMetadataResult {
  kind: 'UPDATED' = 'UPDATED';
  profile: Profile;
  sourceChanged: boolean;

  constructor(profile: Profile, sourceChanged: boolean) {
    this.profile = profile;
    this.sourceChanged = sourceChanged;
  }
}

class ManageProfileFailedResultValue implements ManageProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
}

export function createManageProfileFailedResult(error: AppError): ManageProfileFailedResult {
  return new ManageProfileFailedResultValue(error);
}

export class ManageProfileUseCases {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;
  private readonly secretStore: SubscriptionSecretStore;
  private readonly coreService: CoreService;
  private readonly clock: Clock;
  private readonly runtimeCoordinator: LocalRuntimeCoordinator;

  constructor(dependencies: ManageProfileUseCasesDependencies) {
    this.repository = dependencies.repository;
    this.contentStore = dependencies.contentStore;
    this.secretStore = dependencies.secretStore;
    this.coreService = dependencies.coreService;
    this.clock = dependencies.clock;
    this.runtimeCoordinator = dependencies.runtimeCoordinator;
  }

  async enable(profileId: string): Promise<ManageEnableResult> {
    try {
      if (!this.runtimeCoordinator.isInitialized()) {
        await this.runtimeCoordinator.initialize();
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('ENABLE');
      if (admission.error !== undefined) {
        return new ManageProfileFailedResultValue(admission.error);
      }
      try {
        const activeId: string | undefined = await this.repository.getActiveId();
        const profile: Profile | undefined = await this.repository.get(profileId);
        if (profile === undefined) {
          return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', 'Profile was not found.', {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }
        if (activeId === profileId && isProfileEligibleForActivation(profile) && profile.currentRevision !== null) {
          return new EnableProfileResultValue(profile);
        }
        if (profile.currentRevision === null) {
          return new ManageProfileFailedResultValue(createAppError('VALIDATION', 'Profile is not eligible for activation.', {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }

        const configPath: string = this.contentStore.resolveCorePath(profile.currentRevision);
        try {
          await this.coreService.validateConfiguration(configPath);
        } catch (error) {
          return new ManageProfileFailedResultValue(createAppError('VALIDATION', resolveErrorMessage(error, 'Profile validation failed.'), {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }
        if (!isProfileEligibleForActivation(profile)) {
          return new ManageProfileFailedResultValue(createAppError('VALIDATION', 'Profile is not eligible for activation.', {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }
        try {
          await this.coreService.loadConfiguration(configPath);
        } catch (error) {
          return new ManageProfileFailedResultValue(createAppError('CORE_LOAD', resolveErrorMessage(error, 'Core configuration load failed.'), {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }
        await this.repository.setActiveId(profileId);
        return new EnableProfileResultValue(profile);
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
  }

  async delete(profileId: string): Promise<ManageDeleteResult> {
    try {
      if (!this.runtimeCoordinator.isInitialized()) {
        await this.runtimeCoordinator.initialize();
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('DELETE');
      if (admission.error !== undefined) {
        return new ManageProfileFailedResultValue(admission.error);
      }
      try {
        const profile: Profile | undefined = await this.repository.get(profileId);
        if (profile === undefined) {
          return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', 'Profile was not found.', {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }

        try {
          await this.repository.deleteAndClearActive(profileId);
        } catch (error) {
          return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
            retryable: false,
            timestamp: this.clock.now()
          }));
        }

        try {
          await this.contentStore.removeProfile(profileId);
        } catch (_) {
        }
        if (profile.sourceSecretRef !== undefined) {
          try {
            await this.secretStore.remove(profile.sourceSecretRef);
          } catch (_) {
          }
        }
        return new DeleteProfileResultValue(profileId);
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
  }

  async replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResult> {
    try {
      if (!this.runtimeCoordinator.isInitialized()) {
        await this.runtimeCoordinator.initialize();
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('REPLACE');
      if (admission.error !== undefined) {
        return new ManageProfileFailedResultValue(admission.error);
      }
      try {
        const result: ManageUpdateResult = await this.updateMetadataInsideLease(profileId, undefined, sourceUrl, true);
        if (result.kind === 'FAILED') {
          return result;
        }
        return new ReplaceSubscriptionUrlResultValue(result.profile);
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
  }

  async updateMetadata(profileId: string, name: string, sourceUrl?: string): Promise<ManageUpdateResult> {
    try {
      if (!this.runtimeCoordinator.isInitialized()) {
        await this.runtimeCoordinator.initialize();
      }
      const admission = this.runtimeCoordinator.acquireMutationLease('REPLACE');
      if (admission.error !== undefined) {
        return new ManageProfileFailedResultValue(admission.error);
      }
      try {
        return await this.updateMetadataInsideLease(profileId, name, sourceUrl, false);
      } finally {
        admission.lease?.release();
      }
    } catch (error) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
  }

  private async updateMetadataInsideLease(
    profileId: string,
    name: string | undefined,
    sourceUrl: string | undefined,
    requireSourceChange: boolean
  ): Promise<ManageUpdateResult> {
    const profile: Profile | undefined = await this.repository.get(profileId);
    if (profile === undefined) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', 'Profile was not found.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
    const normalizedSourceUrl: string | undefined = normalizeOptionalSourceUrl(sourceUrl);
    if (requireSourceChange && normalizedSourceUrl === undefined) {
      return new ManageProfileFailedResultValue(createAppError('IMPORT', 'Remote profile URL must use http or https.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }
    if (normalizedSourceUrl !== undefined && profile.sourceKind !== 'REMOTE_URL') {
      return new ManageProfileFailedResultValue(createAppError('IMPORT', 'Only remote profiles can update their subscription URL.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const sourceChanged: boolean = normalizedSourceUrl !== undefined;
    let nextSecretRef: string | undefined = profile.sourceSecretRef;
    if (sourceChanged) {
      try {
        nextSecretRef = await this.secretStore.encrypt(normalizedSourceUrl!);
      } catch (error) {
        return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Subscription secret operation failed.'), {
          retryable: false,
          timestamp: this.clock.now()
        }));
      }
    }

    let updatedProfile: Profile;
    try {
      updatedProfile = createProfile({
        id: profile.id,
        name: name ?? profile.name,
        sourceKind: profile.sourceKind,
        sourceDisplay: sourceChanged ? normalizedSourceUrl! : profile.sourceDisplay,
        sourceSecretRef: nextSecretRef,
        currentRevision: profile.currentRevision,
        failedCandidate: profile.failedCandidate,
        availability: profile.availability,
        lastError: profile.lastError,
        createdAt: profile.createdAt,
        updatedAt: this.clock.now(),
        lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt
      });
    } catch (error) {
      if (sourceChanged && nextSecretRef !== undefined) {
        await safeRemoveSecret(this.secretStore, nextSecretRef);
      }
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    try {
      await this.repository.save(updatedProfile);
    } catch (error) {
      if (sourceChanged && nextSecretRef !== undefined) {
        await safeRemoveSecret(this.secretStore, nextSecretRef);
      }
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    if (sourceChanged && profile.sourceSecretRef !== undefined) {
      await safeRemoveSecret(this.secretStore, profile.sourceSecretRef);
    }
    return new UpdateProfileMetadataResultValue(updatedProfile, sourceChanged);
  }
}

function resolveErrorMessage(error: Object | undefined, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0 ? error.message : fallback;
}

function normalizeOptionalSourceUrl(sourceUrl: string | undefined): string | undefined {
  if (sourceUrl === undefined) {
    return undefined;
  }
  const normalized: string = sourceUrl.trim();
  return normalized.length === 0 ? undefined : normalized;
}

async function safeRemoveSecret(secretStore: SubscriptionSecretStore, secretRef: string): Promise<void> {
  try {
    await secretStore.remove(secretRef);
  } catch (_) {
  }
}
