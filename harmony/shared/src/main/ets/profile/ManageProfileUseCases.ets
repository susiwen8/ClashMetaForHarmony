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

export interface ManageProfileFailedResult {
  kind: 'FAILED';
  error: AppError;
}

export type ManageEnableResult = EnableProfileResult | ManageProfileFailedResult;
export type ManageDeleteResult = DeleteProfileResult | ManageProfileFailedResult;
export type ManageReplaceResult = ReplaceSubscriptionUrlResult | ManageProfileFailedResult;

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

class ManageProfileFailedResultValue implements ManageProfileFailedResult {
  kind: 'FAILED' = 'FAILED';
  error: AppError;

  constructor(error: AppError) {
    this.error = error;
  }
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
    await this.runtimeCoordinator.initialize();
    if (!this.isRuntimeStoppedForMutation()) {
      return new ManageProfileFailedResultValue(createAppError('RUNTIME_STOP', 'Runtime must be stopped before profile mutation.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

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
  }

  async delete(profileId: string): Promise<ManageDeleteResult> {
    await this.runtimeCoordinator.initialize();
    if (!this.isRuntimeStoppedForMutation()) {
      return new ManageProfileFailedResultValue(createAppError('RUNTIME_STOP', 'Runtime must be stopped before profile mutation.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

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

    await this.contentStore.removeProfile(profileId);
    if (profile.sourceSecretRef !== undefined) {
      await this.secretStore.remove(profile.sourceSecretRef);
    }
    return new DeleteProfileResultValue(profileId);
  }

  async replaceSubscriptionUrl(profileId: string, sourceUrl: string): Promise<ManageReplaceResult> {
    await this.runtimeCoordinator.initialize();
    if (!this.isRuntimeStoppedForMutation()) {
      return new ManageProfileFailedResultValue(createAppError('RUNTIME_STOP', 'Runtime must be stopped before profile mutation.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const profile: Profile | undefined = await this.repository.get(profileId);
    if (profile === undefined) {
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', 'Profile was not found.', {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    const newSecretRef: string = await this.secretStore.encrypt(sourceUrl);
    const updatedProfile: Profile = createProfile({
      id: profile.id,
      name: profile.name,
      sourceKind: profile.sourceKind,
      sourceDisplay: sourceUrl,
      sourceSecretRef: newSecretRef,
      currentRevision: profile.currentRevision,
      failedCandidate: profile.failedCandidate,
      availability: profile.availability,
      lastError: profile.lastError,
      createdAt: profile.createdAt,
      updatedAt: this.clock.now(),
      lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt
    });

    try {
      await this.repository.save(updatedProfile);
    } catch (error) {
      await this.secretStore.remove(newSecretRef);
      return new ManageProfileFailedResultValue(createAppError('PERSISTENCE', resolveErrorMessage(error, 'Profile persistence failed.'), {
        retryable: false,
        timestamp: this.clock.now()
      }));
    }

    if (profile.sourceSecretRef !== undefined) {
      await this.secretStore.remove(profile.sourceSecretRef);
    }
    return new ReplaceSubscriptionUrlResultValue(updatedProfile);
  }

  private isRuntimeStoppedForMutation(): boolean {
    const state: string = this.runtimeCoordinator.current().state;
    return state === 'STOPPED' || state === 'ERROR';
  }
}

function resolveErrorMessage(error: Object | undefined, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0 ? error.message : fallback;
}
