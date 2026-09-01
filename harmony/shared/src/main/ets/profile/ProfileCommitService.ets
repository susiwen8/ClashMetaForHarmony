import { createAppError, type AppError } from './AppErrors';
import { createProfile, type Profile, type ProfileRevision } from './ProfileModels';
import type { Clock, ProfileContentStore, ProfileRepository } from './ProfilePorts';

export interface ProfileCommitServiceDependencies {
  repository: ProfileRepository;
  contentStore: ProfileContentStore;
  clock: Clock;
}

export interface SaveProfileTransaction {
  profile: Profile;
  newRetainedRevisions: ProfileRevision[];
  supersededRevisions: ProfileRevision[];
}

export class ProfileCommitError extends Error {
  readonly appError: AppError;

  constructor(appError: AppError) {
    super(appError.technicalDetail);
    this.appError = appError;
  }
}

export class ProfileCommitService {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;
  private readonly clock: Clock;

  constructor(dependencies: ProfileCommitServiceDependencies) {
    this.repository = dependencies.repository;
    this.contentStore = dependencies.contentStore;
    this.clock = dependencies.clock;
  }

  async saveProfileTransaction(transaction: SaveProfileTransaction): Promise<void> {
    try {
      await this.repository.save(transaction.profile);
    } catch (error) {
      await this.removeRetainedRevisions(transaction.newRetainedRevisions);
      throw new ProfileCommitError(this.toPersistenceError(error, false));
    }

    await this.removeSupersededRevisions(transaction.supersededRevisions);
  }

  async reconcileStoredContent(): Promise<void> {
    const profiles: Profile[] = await this.repository.list();
    const referenced: ProfileRevision[] = [];
    const seenRelativePaths: string[] = [];
    for (let index = 0; index < profiles.length; index += 1) {
      const profile: Profile = profiles[index];
      if (profile.currentRevision !== null) {
        this.pushReferencedRevision(referenced, seenRelativePaths, profile.currentRevision);
      }
      if (profile.failedCandidate !== null) {
        this.pushReferencedRevision(referenced, seenRelativePaths, profile.failedCandidate);
      }
    }
    await this.contentStore.reconcile(referenced);
  }

  buildSavedProfile(profile: Profile): Profile {
    return createProfile({
      id: profile.id,
      name: profile.name,
      sourceKind: profile.sourceKind,
      sourceDisplay: profile.sourceDisplay,
      sourceSecretRef: profile.sourceSecretRef,
      currentRevision: profile.currentRevision,
      failedCandidate: profile.failedCandidate,
      availability: profile.availability,
      lastError: profile.lastError,
      createdAt: profile.createdAt,
      updatedAt: profile.updatedAt,
      lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt,
      autoUpdateIntervalMs: profile.autoUpdateIntervalMs
    });
  }

  now(): string {
    return this.clock.now();
  }

  private pushReferencedRevision(
    referenced: ProfileRevision[],
    seenRelativePaths: string[],
    revision: ProfileRevision
  ): void {
    for (let index = 0; index < seenRelativePaths.length; index += 1) {
      if (seenRelativePaths[index] === revision.relativePath) {
        return;
      }
    }
    seenRelativePaths.push(revision.relativePath);
    referenced.push(revision);
  }

  private async removeRetainedRevisions(revisions: ProfileRevision[]): Promise<void> {
    for (let index = 0; index < revisions.length; index += 1) {
      try {
        await this.contentStore.removeRevision(revisions[index]);
      } catch (_) {
      }
    }
  }

  private async removeSupersededRevisions(revisions: ProfileRevision[]): Promise<void> {
    for (let index = 0; index < revisions.length; index += 1) {
      try {
        await this.contentStore.removeRevision(revisions[index]);
      } catch (_) {
      }
    }
  }

  private toPersistenceError(error: Object | undefined, retryable: boolean): AppError {
    const detail: string = error instanceof Error && error.message.trim().length > 0
      ? error.message
      : 'Profile persistence failed.';
    return createAppError('PERSISTENCE', detail, {
      retryable,
      timestamp: this.clock.now()
    });
  }
}
