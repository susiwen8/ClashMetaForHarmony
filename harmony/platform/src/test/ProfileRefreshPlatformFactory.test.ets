import { describe, expect, it } from '@ohos/hypium';
import type common from '@ohos.app.ability.common';
import type {
  Clock,
  IdGenerator,
  Profile,
  ProfileContentStore,
  ProfileRefreshLeasePort,
  ProfileRepository,
  ProfileRevision,
  ProfileSourceGateway,
  StagedSource,
  SubscriptionSecretStore
} from '@cmfa/shared';
import {
  ProfileRefreshPlatformFactory,
  normalizeProfileRefreshSdkApiVersion,
  type ProfileRefreshCloseableRdbDriver,
  type ProfileRefreshPlatformComponents,
  type ProfileRefreshSecretStore
} from '../main/ets/ProfileRefreshPlatformFactory';
import { RecordingRdbDriver } from './fakes/PlatformFakes';

class DeferredValue<T> {
  readonly promise: Promise<T>;
  private resolveValue?: (value: T) => void;

  constructor() {
    this.promise = new Promise<T>((resolve) => {
      this.resolveValue = resolve;
    });
  }

  resolve(value: T): void {
    this.resolveValue?.(value);
  }
}

class FakeRepository implements ProfileRepository {
  readonly log: string[];
  profiles: Profile[] = [];

  constructor(log: string[]) {
    this.log = log;
  }

  async list(): Promise<Profile[]> {
    this.log.push('repository.list');
    return this.profiles.slice();
  }

  async get(_id: string): Promise<Profile | undefined> { return undefined; }
  async save(_profile: Profile): Promise<void> {}
  async deleteAndClearActive(_id: string): Promise<void> {}
  async getActiveId(): Promise<string | undefined> { return undefined; }
  async setActiveId(_id: string | undefined): Promise<void> {}
}

class FakeContentStore implements ProfileContentStore {
  readonly log: string[];

  constructor(log: string[]) { this.log = log; }

  async reconcile(_revisions: ProfileRevision[]): Promise<void> { this.log.push('content.reconcile'); }
  async retain(_profileId: string, _staged: StagedSource, _kind: 'CURRENT' | 'FAILED_CANDIDATE'): Promise<ProfileRevision> { throw new Error('unused'); }
  async discard(_staged: StagedSource): Promise<void> {}
  async removeRevision(_revision: ProfileRevision): Promise<void> {}
  async removeProfile(_profileId: string): Promise<void> {}
  resolveCorePath(_revision: ProfileRevision): string { return ''; }
}

class FakeSecretStore implements ProfileRefreshSecretStore {
  readonly log: string[];
  reconciledSecretRefs: string[] = [];

  constructor(log: string[]) { this.log = log; }

  async reconcile(secretRefs: string[]): Promise<void> {
    this.reconciledSecretRefs = secretRefs.slice();
    this.log.push('secret.reconcile');
  }
  async encrypt(_plaintext: string): Promise<string> { return 'secret-ref'; }
  async decrypt(_secretRef: string): Promise<string> { return 'https://example.invalid'; }
  async remove(_secretRef: string): Promise<void> {}
}

class FakeSourceGateway implements ProfileSourceGateway {
  async acquireLocal(): Promise<never> { throw new Error('unused'); }
  async acquireRemote(): Promise<never> { throw new Error('unused'); }
}

class FakeLeasePort implements ProfileRefreshLeasePort {
  async tryAcquire(): Promise<boolean> { return true; }
  async renew(): Promise<boolean> { return true; }
  async release(): Promise<boolean> { return true; }
}

class FakeClock implements Clock { now(): string { return '2026-09-01T00:00:00.000Z'; } }
class FakeIdGenerator implements IdGenerator { nextId(): string { return 'id-1'; } }

class CloseableRecordingRdbDriver extends RecordingRdbDriver implements ProfileRefreshCloseableRdbDriver {
  closeCalls: number = 0;

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class TestProfileRefreshPlatformComponents implements ProfileRefreshPlatformComponents {
  readonly repository: ProfileRepository;
  readonly profileRefreshLeasePort: ProfileRefreshLeasePort;
  readonly contentStore: ProfileContentStore;
  readonly sourceGateway: ProfileSourceGateway;
  readonly secretStore: ProfileRefreshSecretStore;
  readonly clock: Clock;
  readonly idGenerator: IdGenerator;
  private readonly log: string[];
  private readonly prepareCallback: () => Promise<void>;
  private readonly closeCallback: () => Promise<void>;

  constructor(
    log: string[],
    prepare: () => Promise<void>,
    close: () => Promise<void>
  ) {
    this.log = log;
    this.repository = new FakeRepository(log);
    this.profileRefreshLeasePort = new FakeLeasePort();
    this.contentStore = new FakeContentStore(log);
    this.sourceGateway = new FakeSourceGateway();
    this.secretStore = new FakeSecretStore(log);
    this.clock = new FakeClock();
    this.idGenerator = new FakeIdGenerator();
    this.prepareCallback = prepare;
    this.closeCallback = close;
  }

  async prepareSecrets(): Promise<void> {
    this.log.push('secret.prepare');
    await this.prepareCallback();
  }

  async closeRdb(): Promise<void> {
    await this.closeCallback();
  }
}

function createComponents(
  log: string[],
  prepare: () => Promise<void> = async (): Promise<void> => {},
  close: () => Promise<void> = async (): Promise<void> => { log.push('rdb.close'); }
): ProfileRefreshPlatformComponents {
  return new TestProfileRefreshPlatformComponents(log, prepare, close);
}

export default function profileRefreshPlatformFactoryTestsuite() {
  describe('ProfileRefreshPlatformFactoryTest', () => {
    it('buildsTheProfileOnlyGraphInSafeInitializationOrder', 0, async () => {
      const log: string[] = [];
      const components = createComponents(log);
      const factory = new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createComponents: (): ProfileRefreshPlatformComponents => components
      });

      const graph = await factory.create();

      expect(log.join('>')).assertEqual('secret.prepare>repository.list>content.reconcile>secret.reconcile');
      expect(graph.repository === components.repository).assertTrue();
      expect(graph.profileRefreshLeasePort === components.profileRefreshLeasePort).assertTrue();
      expect(graph.sourceGateway === components.sourceGateway).assertTrue();
    });

    it('sharesOneInFlightGraphAcrossConcurrentCreateCalls', 0, async () => {
      const log: string[] = [];
      const barrier = new DeferredValue<void>();
      let componentCreations = 0;
      const factory = new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createComponents: (): ProfileRefreshPlatformComponents => {
          componentCreations += 1;
          return createComponents(log, async (): Promise<void> => await barrier.promise);
        }
      });

      const first = factory.create();
      const second = factory.create();
      barrier.resolve(undefined);
      const firstGraph = await first;
      const secondGraph = await second;

      expect(firstGraph === secondGraph).assertTrue();
      expect(componentCreations).assertEqual(1);
    });

    it('closesTheOwnedRdbExactlyOnce', 0, async () => {
      const log: string[] = [];
      const graph = await new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createComponents: (): ProfileRefreshPlatformComponents => createComponents(log)
      }).create();

      await Promise.all([graph.close(), graph.close()]);
      await graph.close();

      expect(log.filter((entry) => entry === 'rdb.close').length).assertEqual(1);
    });

    it('closesPartialResourcesMapsErrorsAndAllowsAFreshRetry', 0, async () => {
      const log: string[] = [];
      let attempts = 0;
      const factory = new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createComponents: (): ProfileRefreshPlatformComponents => {
          attempts += 1;
          if (attempts === 1) {
            return createComponents(log, async (): Promise<void> => {
              throw new Error('unsafe secret detail');
            });
          }
          return createComponents(log);
        }
      });
      let firstError = '';
      try {
        await factory.create();
      } catch (error) {
        firstError = `${error}`;
      }

      expect(firstError).assertContain('Profile refresh platform initialization failed.');
      expect(firstError.includes('unsafe secret detail')).assertFalse();
      expect(log.filter((entry) => entry === 'rdb.close').length).assertEqual(1);

      const graph = await factory.create();
      expect(attempts).assertEqual(2);
      await graph.close();
      expect(log.filter((entry) => entry === 'rdb.close').length).assertEqual(2);
    });

    it('closesAnRdbCreatedBeforeDefaultComponentConstructionFails', 0, async () => {
      const drivers: CloseableRecordingRdbDriver[] = [];
      let sdkResolutionCalls = 0;
      const factory = new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createRdbDriver: (): ProfileRefreshCloseableRdbDriver => {
          const driver = new CloseableRecordingRdbDriver();
          drivers.push(driver);
          return driver;
        },
        createHuksDriver: () => {
          throw new Error('unsafe constructor detail');
        },
        resolveSdkApiVersion: (): string => {
          sdkResolutionCalls += 1;
          return '23';
        }
      });

      for (let attempt: number = 0; attempt < 2; attempt += 1) {
        let errorText = '';
        try {
          await factory.create();
        } catch (error) {
          errorText = `${error}`;
        }
        expect(errorText).assertContain('Profile refresh platform initialization failed.');
        expect(errorText.includes('unsafe constructor detail')).assertFalse();
      }

      expect(drivers.length).assertEqual(2);
      expect(drivers[0].closeCalls).assertEqual(1);
      expect(drivers[1].closeCalls).assertEqual(1);
      expect(sdkResolutionCalls).assertEqual(2);
    });

    it('ignoresBlankLegacySecretReferencesDuringReconciliation', 0, async () => {
      const log: string[] = [];
      const components = createComponents(log);
      const malformedProfile = {
        id: 'legacy-profile',
        name: 'Legacy',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: 'https://example.invalid',
        sourceSecretRef: '   ',
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-09-01T00:00:00.000Z',
        updatedAt: '2026-09-01T00:00:00.000Z',
        lastSuccessfulUpdateAt: null,
        autoUpdateIntervalMs: 0
      } as Profile;
      const firstSecretProfile: Profile = cloneProfile(malformedProfile, 'legacy-secret-a', 'secret-a');
      const duplicateSecretProfile: Profile = cloneProfile(malformedProfile, 'legacy-secret-a-spaced', ' secret-a ');
      (components.repository as FakeRepository).profiles = [
        malformedProfile,
        firstSecretProfile,
        duplicateSecretProfile
      ];
      const graph = await new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createComponents: (): ProfileRefreshPlatformComponents => components
      }).create();

      expect((components.secretStore as FakeSecretStore).reconciledSecretRefs).assertDeepEquals(['secret-a']);
      await graph.close();
    });

    it('normalizesSdkApiVersionsFromNumbersAndStrings', 0, () => {
      expect(normalizeProfileRefreshSdkApiVersion(24)).assertEqual(24);
      expect(normalizeProfileRefreshSdkApiVersion('23')).assertEqual(23);
      expect(normalizeProfileRefreshSdkApiVersion('invalid')).assertEqual(0);
      expect(normalizeProfileRefreshSdkApiVersion(-1)).assertEqual(0);
      expect(normalizeProfileRefreshSdkApiVersion(undefined)).assertEqual(0);
    });
  });
}

function cloneProfile(profile: Profile, id: string, sourceSecretRef: string): Profile {
  return {
    id,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceDisplay: profile.sourceDisplay,
    sourceSecretRef,
    currentRevision: profile.currentRevision,
    failedCandidate: profile.failedCandidate,
    availability: profile.availability,
    lastError: profile.lastError,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt,
    autoUpdateIntervalMs: profile.autoUpdateIntervalMs
  };
}
