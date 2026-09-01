import type { ProfileContentStore, ProfileRepository } from '../profile/ProfilePorts';
import type { Profile } from '../profile/ProfileModels';
import { createActiveProxyProfile, type ActiveProxyProfile } from './ProxyModels';
import type { ActiveProfileProxyPort } from './ProxyPorts';

function isEligibleActiveProfile(profile: Profile): boolean {
  return profile.currentRevision !== null &&
    (profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID');
}

function createSanitizedResolveError(): Error {
  return new Error('Active proxy profile resolution failed.');
}

export class ActiveProfileProxyResolver implements ActiveProfileProxyPort {
  private readonly repository: ProfileRepository;
  private readonly contentStore: ProfileContentStore;

  constructor(repository: ProfileRepository, contentStore: ProfileContentStore) {
    this.repository = repository;
    this.contentStore = contentStore;
  }

  async resolve(): Promise<ActiveProxyProfile | undefined> {
    try {
      const activeId: string | undefined = await this.repository.getActiveId();
      if (activeId === undefined) {
        return undefined;
      }
      const profile: Profile | undefined = await this.repository.get(activeId);
      if (profile === undefined || !isEligibleActiveProfile(profile) || profile.currentRevision === null) {
        return undefined;
      }
      const currentRevision = profile.currentRevision;
      const configPath: string = this.contentStore.resolveCorePath(currentRevision);
      return createActiveProxyProfile(
        profile.id,
        currentRevision.validatedAt,
        currentRevision.sha256Digest,
        configPath
      );
    } catch {
      throw createSanitizedResolveError();
    }
  }
}
