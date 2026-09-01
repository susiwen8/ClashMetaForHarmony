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

  constructor(log: string[]) { this.log = log; }

  async reconcile(_secretRefs: string[]): Promise<void> { this.log.push('secret.reconcile'); }
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

function createComponents(
  log: string[],
  prepare: () => Promise<void> = async (): Promise<void> => {},
  close: () => Promise<void> = async (): Promise<void> => { log.push('rdb.close'); }
): ProfileRefreshPlatformComponents {
  return {
    repository: new FakeRepository(log),
    profileRefreshLeasePort: new FakeLeasePort(),
    contentStore: new FakeContentStore(log),
    sourceGateway: new FakeSourceGateway(),
    secretStore: new FakeSecretStore(log),
    clock: new FakeClock(),
    idGenerator: new FakeIdGenerator(),
    prepareSecrets: async (): Promise<void> => {
      log.push('secret.prepare');
      await prepare();
    },
    closeRdb: close
  };
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
      const factory = new ProfileRefreshPlatformFactory({ filesDir: '/data/test' } as common.Context, {
        createRdbDriver: (): ProfileRefreshCloseableRdbDriver => {
          const driver = new CloseableRecordingRdbDriver();
          drivers.push(driver);
          return driver;
        },
        createHuksDriver: () => {
          throw new Error('unsafe constructor detail');
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
    });
  });
}
