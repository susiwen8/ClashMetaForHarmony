import { describe, expect, it } from '@ohos/hypium';
import {
  RefreshProfilesUseCase,
  RefreshProfilesUseCaseError,
  type AppError,
  type Clock,
  type Profile,
  type ProfileRevision,
  type ProfileRefreshExecutorPort,
  type ProfileRepository,
  type RefreshProfilesTimestampParser,
  type RefreshProfileResult
} from '../../Index';

class FakeClock implements Clock {
  private nowMsValue: number;

  constructor(nowMsValue: number) {
    this.nowMsValue = nowMsValue;
  }

  now(): string {
    return new Date(this.nowMsValue).toISOString();
  }

  advanceBy(deltaMs: number): void {
    this.nowMsValue += deltaMs;
  }
}

class FakeProfileRepository implements ProfileRepository {
  private readonly profiles: Profile[];
  listCalls: number = 0;
  listError?: Error;

  constructor(profiles: Profile[]) {
    this.profiles = profiles.slice();
  }

  async list(): Promise<Profile[]> {
    this.listCalls += 1;
    if (this.listError !== undefined) {
      throw this.listError;
    }
    return this.profiles.slice();
  }

  async get(_id: string): Promise<Profile | undefined> {
    throw new Error('not used');
  }

  async save(_profile: Profile): Promise<void> {
    throw new Error('not used');
  }

  async deleteAndClearActive(_id: string): Promise<void> {
    throw new Error('not used');
  }

  async getActiveId(): Promise<string | undefined> {
    throw new Error('not used');
  }

  async setActiveId(_id: string | undefined): Promise<void> {
    throw new Error('not used');
  }
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
}

interface ErrorWithCode {
  code: string;
}

class DeferredValue<T> implements Deferred<T> {
  promise: Promise<T>;
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

function createDeferred<T>(): Deferred<T> {
  return new DeferredValue<T>();
}

interface RefreshExecutorCommand {
  profileId: string;
  allowPlainHttp?: boolean;
}

class FakeRefreshExecutor implements ProfileRefreshExecutorPort {
  readonly calls: string[] = [];
  readonly allowPlainHttpCalls: boolean[] = [];
  maxConcurrency: number = 0;
  afterResolve?: () => void;
  private activeCount: number = 0;
  private readonly resultsByProfileId: Map<string, RefreshProfileResult> = new Map();
  private readonly deferredsByProfileId: Map<string, Deferred<RefreshProfileResult>> = new Map();
  private readonly thrownByProfileId: Map<string, Error> = new Map();

  setResult(profileId: string, result: RefreshProfileResult): void {
    this.resultsByProfileId.set(profileId, result);
  }

  setDeferred(profileId: string, deferred: Deferred<RefreshProfileResult>): void {
    this.deferredsByProfileId.set(profileId, deferred);
  }

  setThrow(profileId: string, error: Error): void {
    this.thrownByProfileId.set(profileId, error);
  }

  async execute(command: RefreshExecutorCommand): Promise<RefreshProfileResult> {
    this.calls.push(command.profileId);
    this.allowPlainHttpCalls.push(command.allowPlainHttp === true);
    this.activeCount += 1;
    if (this.activeCount > this.maxConcurrency) {
      this.maxConcurrency = this.activeCount;
    }
    try {
      const thrown: Error | undefined = this.thrownByProfileId.get(command.profileId);
      if (thrown !== undefined) {
        throw thrown;
      }
      const deferred: Deferred<RefreshProfileResult> | undefined = this.deferredsByProfileId.get(command.profileId);
      if (deferred !== undefined) {
        return await deferred.promise;
      }
      const result: RefreshProfileResult | undefined = this.resultsByProfileId.get(command.profileId);
      if (result === undefined) {
        throw new Error(`Missing scripted result for ${command.profileId}.`);
      }
      this.afterResolve?.();
      return result;
    } finally {
      this.activeCount -= 1;
    }
  }
}

function isoAt(secondsFromEpoch: number): string {
  return new Date(secondsFromEpoch * 1000).toISOString();
}

function buildRemoteProfile(
  id: string,
  sourceDisplay: string,
  lastSuccessfulUpdateAtSeconds: number | null,
  autoUpdateIntervalMs: number
): Profile {
  return {
    id,
    name: id,
    sourceKind: 'REMOTE_URL',
    sourceDisplay,
    sourceSecretRef: `${id}-secret`,
    currentRevision: null,
    failedCandidate: null,
    availability: 'INVALID',
    lastError: null,
    createdAt: isoAt(1),
    updatedAt: isoAt(2),
    lastSuccessfulUpdateAt: lastSuccessfulUpdateAtSeconds === null ? null : isoAt(lastSuccessfulUpdateAtSeconds),
    autoUpdateIntervalMs
  };
}

function copyProfile(profile: Profile): Profile {
  return {
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
  };
}

function buildLocalProfile(id: string): Profile {
  return {
    id,
    name: id,
    sourceKind: 'LOCAL_FILE',
    sourceDisplay: `${id}.yaml`,
    currentRevision: null,
    failedCandidate: null,
    availability: 'INVALID',
    lastError: null,
    createdAt: isoAt(1),
    updatedAt: isoAt(2),
    lastSuccessfulUpdateAt: null,
    autoUpdateIntervalMs: 0
  };
}

function buildUpdatedResult(
  profile: Profile,
  availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID',
  lastError: AppError | null,
  hasCurrentRevision: boolean
): RefreshProfileResult {
  const currentRevision: ProfileRevision | null = hasCurrentRevision
    ? {
      relativePath: `profiles/${profile.id}/current.yaml`,
      sha256Digest: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      byteLength: 128,
      validatedAt: isoAt(900)
    }
    : null;
  const updatedProfile: Profile = copyProfile(profile);
  updatedProfile.availability = availability;
  updatedProfile.lastError = lastError;
  updatedProfile.currentRevision = currentRevision;
  return {
    kind: 'UPDATED',
    profile: updatedProfile
  };
}

function buildFailedResult(code: string): RefreshProfileResult {
  const error: AppError = {
    code,
    stage: 'PERSISTENCE',
    userMessageResource: 'error.persistence',
    technicalDetail: `internal ${code}`,
    timestamp: isoAt(1000),
    retryable: code === 'PROFILE_REFRESH_BUSY'
  };
  return {
    kind: 'FAILED',
    error
  };
}

function buildFailedError(code: string): AppError {
  const result: RefreshProfileResult = buildFailedResult(code);
  if (result.kind !== 'FAILED') {
    throw new Error(`Expected FAILED result for ${code}.`);
  }
  return result.error;
}

interface BuildUseCaseResult {
  useCase: RefreshProfilesUseCase;
  fakeExecutor: FakeRefreshExecutor;
  fakeClock: FakeClock;
}

class BuildUseCaseResultValue implements BuildUseCaseResult {
  useCase: RefreshProfilesUseCase;
  fakeExecutor: FakeRefreshExecutor;
  fakeClock: FakeClock;

  constructor(useCase: RefreshProfilesUseCase, fakeExecutor: FakeRefreshExecutor, fakeClock: FakeClock) {
    this.useCase = useCase;
    this.fakeExecutor = fakeExecutor;
    this.fakeClock = fakeClock;
  }
}

function buildUseCase(
  profiles: Profile[],
  nowMs: number,
  executor?: FakeRefreshExecutor,
  clock?: Clock,
  parser?: RefreshProfilesTimestampParser
): BuildUseCaseResult {
  const fakeExecutor = executor ?? new FakeRefreshExecutor();
  const fakeClock = clock instanceof FakeClock ? clock : new FakeClock(nowMs);
  return new BuildUseCaseResultValue(
    new RefreshProfilesUseCase({
      repository: new FakeProfileRepository(profiles),
      executor: fakeExecutor,
      clock: clock ?? fakeClock,
      parser
    }),
    fakeExecutor,
    fakeClock
  );
}

async function expectSafeUseCaseError(
  promise: Promise<Object>,
  expectedCode: string,
  forbiddenFragments: string[]
): Promise<void> {
  let rejected: boolean = false;
  try {
    await promise;
  } catch (error) {
    rejected = true;
    expect(error instanceof RefreshProfilesUseCaseError).assertTrue();
    const record = error as ErrorWithCode;
    expect(record.code).assertEqual(expectedCode);
    const message: string = error instanceof Error ? error.message : `${error}`;
    for (let index = 0; index < forbiddenFragments.length; index += 1) {
      expect(message.includes(forbiddenFragments[index])).assertFalse();
    }
  }
  if (!rejected) {
    throw new Error(`Expected rejection with ${expectedCode}.`);
  }
}

export default function refreshProfilesUseCaseTestsuite() {
  describe('RefreshProfilesUseCaseTest', () => {
    it('refreshesAllModeRemoteOnlyInStableIdOrderAndSequentially', 0, async () => {
      const profileB = buildRemoteProfile('profile-b', 'https://b.example.com', 5, 1000);
      const profileA = buildRemoteProfile('profile-a', 'https://a.example.com', 4, 1000);
      const local = buildLocalProfile('profile-local');
      const firstDeferred = createDeferred<RefreshProfileResult>();
      const secondDeferred = createDeferred<RefreshProfileResult>();
      const executor = new FakeRefreshExecutor();
      executor.setDeferred('profile-a', firstDeferred);
      executor.setDeferred('profile-b', secondDeferred);
      const useCaseBundle: BuildUseCaseResult = buildUseCase(
        [profileB, local, profileA],
        Date.parse(isoAt(500)),
        executor
      );
      const useCase = useCaseBundle.useCase;

      const pending = useCase.execute({ mode: 'ALL' });
      await Promise.resolve();
      await Promise.resolve();

      expect(executor.calls.length).assertEqual(1);
      expect(executor.calls[0]).assertEqual('profile-a');
      expect(executor.maxConcurrency).assertEqual(1);

      firstDeferred.resolve(buildUpdatedResult(profileA, 'VALID', null, true));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(executor.calls.length).assertEqual(2);
      expect(executor.calls[1]).assertEqual('profile-b');

      secondDeferred.resolve(buildUpdatedResult(profileB, 'VALID', null, true));
      const result = await pending;

      expect(result.items.length).assertEqual(2);
      expect(result.items[0].profileId).assertEqual('profile-a');
      expect(result.items[0].status).assertEqual('SUCCESS');
      expect(result.items[1].profileId).assertEqual('profile-b');
      expect(result.items[1].status).assertEqual('SUCCESS');
      expect(result.deadlineReached).assertFalse();
      expect(result.cancelled).assertFalse();
      expect(result.remainingCount).assertEqual(0);
    });

    it('sortsDueModeByNullThenOldestBoundaryAndSkipsFutureAndDisabled', 0, async () => {
      const nowMs: number = Date.parse('2026-09-01T12:00:00.000Z');
      const nullDue = buildRemoteProfile('profile-null', 'https://null.example.com', null, 1000);
      const olderDue = buildRemoteProfile('profile-older', 'https://older.example.com', 43190, 1000);
      const boundaryDue = buildRemoteProfile('profile-boundary', 'https://boundary.example.com', 43199, 1000);
      const future = buildRemoteProfile(
        'profile-future',
        'https://future.example.com',
        Math.floor((nowMs - 3600000) / 1000),
        7200000
      );
      const disabled = buildRemoteProfile('profile-disabled', 'https://disabled.example.com', 30000, 0);
      const executor = new FakeRefreshExecutor();
      executor.setResult('profile-null', buildUpdatedResult(nullDue, 'VALID', null, true));
      executor.setResult('profile-older', buildUpdatedResult(olderDue, 'VALID', null, true));
      executor.setResult('profile-boundary', buildUpdatedResult(boundaryDue, 'VALID', null, true));
      const useCaseBundle: BuildUseCaseResult = buildUseCase(
        [boundaryDue, future, disabled, olderDue, nullDue],
        nowMs,
        executor
      );
      const useCase = useCaseBundle.useCase;

      const result = await useCase.execute({ mode: 'DUE' });

      expect(executor.calls.length).assertEqual(3);
      expect(executor.calls[0]).assertEqual('profile-null');
      expect(executor.calls[1]).assertEqual('profile-older');
      expect(executor.calls[2]).assertEqual('profile-boundary');
      expect(executor.calls.includes('profile-future')).assertFalse();
      expect(executor.calls.includes('profile-disabled')).assertFalse();
      expect(result.items.length).assertEqual(5);
      expect(result.items[0].profileId).assertEqual('profile-null');
      expect(result.items[0].status).assertEqual('SUCCESS');
      expect(result.items[1].profileId).assertEqual('profile-older');
      expect(result.items[1].status).assertEqual('SUCCESS');
      expect(result.items[2].profileId).assertEqual('profile-boundary');
      expect(result.items[2].status).assertEqual('SUCCESS');
      expect(result.items[3].profileId).assertEqual('profile-future');
      expect(result.items[3].status).assertEqual('SKIPPED_NOT_DUE');
      expect(result.items[4].profileId).assertEqual('profile-disabled');
      expect(result.items[4].status).assertEqual('SKIPPED_NOT_DUE');
    });

    it('skipsExactHttpWithoutExecutingAndStillExecutesHttpsWithFalseConsent', 0, async () => {
      const httpProfile = buildRemoteProfile('profile-http', 'http://plain.example.com', 1, 1);
      const httpsProfile = buildRemoteProfile('profile-https', 'https://secure.example.com', 1, 1);
      const executor = new FakeRefreshExecutor();
      executor.setResult('profile-https', buildUpdatedResult(httpsProfile, 'VALID', null, true));
      const useCaseBundle: BuildUseCaseResult = buildUseCase(
        [httpsProfile, httpProfile],
        Date.parse(isoAt(500)),
        executor
      );
      const useCase = useCaseBundle.useCase;

      const result = await useCase.execute({ mode: 'ALL' });

      expect(executor.calls.length).assertEqual(1);
      expect(executor.calls[0]).assertEqual('profile-https');
      expect(executor.allowPlainHttpCalls[0]).assertFalse();
      expect(result.items.length).assertEqual(2);
      expect(result.items[0].profileId).assertEqual('profile-http');
      expect(result.items[0].status).assertEqual('SKIPPED_HTTP');
      expect(result.items[1].profileId).assertEqual('profile-https');
      expect(result.items[1].status).assertEqual('SUCCESS');
    });

    it('classifiesSixRefreshOutcomesIntoBatchStatuses', 0, async () => {
      const busy = buildRemoteProfile('a-busy', 'https://busy.example.com', 1, 1);
      const cancelled = buildRemoteProfile('b-cancelled', 'https://cancelled.example.com', 1, 1);
      const failedUsingCurrent = buildRemoteProfile('c-using-current', 'https://current.example.com', 1, 1);
      const failedUsingLastError = buildRemoteProfile('d-last-error', 'https://last-error.example.com', 1, 1);
      const failed = buildRemoteProfile('e-invalid', 'https://invalid.example.com', 1, 1);
      const success = buildRemoteProfile('f-success', 'https://success.example.com', 1, 1);
      const executor = new FakeRefreshExecutor();
      executor.setResult('a-busy', buildFailedResult('PROFILE_REFRESH_BUSY'));
      executor.setResult('b-cancelled', { kind: 'CANCELLED' });
      executor.setResult(
        'c-using-current',
        buildUpdatedResult(failedUsingCurrent, 'UPDATE_FAILED_USING_VALID', null, true)
      );
      executor.setResult(
        'd-last-error',
        buildUpdatedResult(
          failedUsingLastError,
          'VALID',
          buildFailedError('CMFA_DOWNLOAD_FAILED'),
          true
        )
      );
      executor.setResult('e-invalid', buildUpdatedResult(failed, 'INVALID', null, false));
      executor.setResult('f-success', buildUpdatedResult(success, 'VALID', null, true));
      const useCaseBundle: BuildUseCaseResult = buildUseCase(
        [success, failed, cancelled, failedUsingLastError, busy, failedUsingCurrent],
        Date.parse(isoAt(500)),
        executor
      );
      const useCase = useCaseBundle.useCase;

      const result = await useCase.execute({ mode: 'ALL' });

      expect(result.items.length).assertEqual(6);
      expect(result.items[0].status).assertEqual('BUSY');
      expect(result.items[1].status).assertEqual('FAILED');
      expect(result.items[2].status).assertEqual('FAILED_USING_CURRENT');
      expect(result.items[3].status).assertEqual('FAILED_USING_CURRENT');
      expect(result.items[4].status).assertEqual('FAILED');
      expect(result.items[5].status).assertEqual('SUCCESS');
    });

    it('stopsBetweenItemsForDeadlineAndCancellationWhileDrainingCurrentItem', 0, async () => {
      const first = buildRemoteProfile('profile-a', 'https://a.example.com', 1, 1);
      const second = buildRemoteProfile('profile-b', 'https://b.example.com', 1, 1);
      const third = buildRemoteProfile('profile-c', 'https://c.example.com', 1, 1);

      const deadlineExecutor = new FakeRefreshExecutor();
      deadlineExecutor.setResult('profile-a', buildUpdatedResult(first, 'VALID', null, true));
      deadlineExecutor.setResult('profile-b', buildUpdatedResult(second, 'VALID', null, true));
      deadlineExecutor.setResult('profile-c', buildUpdatedResult(third, 'VALID', null, true));
      const deadlineClock = new FakeClock(Date.parse(isoAt(500)));
      const deadlineBuild = buildUseCase([first, second, third], Date.parse(isoAt(500)), deadlineExecutor, deadlineClock);
      deadlineExecutor.afterResolve = (): void => {
        deadlineClock.advanceBy(5);
      };

      const deadlineResult = await deadlineBuild.useCase.execute({
        mode: 'ALL',
        deadlineMs: Date.parse(isoAt(500)) + 1
      });

      expect(deadlineExecutor.calls.length).assertEqual(1);
      expect(deadlineResult.items.length).assertEqual(1);
      expect(deadlineResult.items[0].status).assertEqual('SUCCESS');
      expect(deadlineResult.deadlineReached).assertTrue();
      expect(deadlineResult.cancelled).assertFalse();
      expect(deadlineResult.remainingCount).assertEqual(2);

      const cancellationExecutor = new FakeRefreshExecutor();
      cancellationExecutor.setResult('profile-a', buildUpdatedResult(first, 'VALID', null, true));
      cancellationExecutor.setResult('profile-b', buildUpdatedResult(second, 'VALID', null, true));
      cancellationExecutor.setResult('profile-c', buildUpdatedResult(third, 'VALID', null, true));
      const cancellationBuild = buildUseCase([first, second, third], Date.parse(isoAt(500)), cancellationExecutor);
      let cancelChecks: number = 0;

      const cancellationResult = await cancellationBuild.useCase.execute({
        mode: 'ALL',
        isCancelled: (): boolean => {
          cancelChecks += 1;
          return cancelChecks >= 2;
        }
      });

      expect(cancellationExecutor.calls.length).assertEqual(1);
      expect(cancellationResult.items.length).assertEqual(1);
      expect(cancellationResult.items[0].status).assertEqual('SUCCESS');
      expect(cancellationResult.deadlineReached).assertFalse();
      expect(cancellationResult.cancelled).assertTrue();
      expect(cancellationResult.remainingCount).assertEqual(2);
    });

    it('rejectsInvalidDeadlineValuesBeforeRepositoryOrExecutorAndAllowsZeroAsImmediateDeadline', 0, async () => {
      const profile = buildRemoteProfile('profile-deadline', 'https://deadline.example.com', 1, 1);
      const repository = new FakeProfileRepository([profile]);
      const executor = new FakeRefreshExecutor();
      const useCase = new RefreshProfilesUseCase({
        repository,
        executor,
        clock: new FakeClock(Date.parse(isoAt(500)))
      });

      await expectSafeUseCaseError(
        useCase.execute({ mode: 'ALL', deadlineMs: -1 }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-deadline', 'deadline.example.com']
      );
      await expectSafeUseCaseError(
        useCase.execute({ mode: 'ALL', deadlineMs: 0.5 }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-deadline', 'deadline.example.com']
      );
      await expectSafeUseCaseError(
        useCase.execute({ mode: 'ALL', deadlineMs: Number.MAX_SAFE_INTEGER + 1 }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-deadline', 'deadline.example.com']
      );

      expect(repository.listCalls).assertEqual(0);
      expect(executor.calls.length).assertEqual(0);

      const zeroRepository = new FakeProfileRepository([profile]);
      const zeroExecutor = new FakeRefreshExecutor();
      zeroExecutor.setResult('profile-deadline', buildUpdatedResult(profile, 'VALID', null, true));
      const zeroUseCase = new RefreshProfilesUseCase({
        repository: zeroRepository,
        executor: zeroExecutor,
        clock: new FakeClock(0)
      });

      const result = await zeroUseCase.execute({ mode: 'ALL', deadlineMs: 0 });

      expect(zeroRepository.listCalls).assertEqual(1);
      expect(zeroExecutor.calls.length).assertEqual(0);
      expect(result.items.length).assertEqual(0);
      expect(result.deadlineReached).assertTrue();
      expect(result.cancelled).assertFalse();
      expect(result.remainingCount).assertEqual(1);
    });

    it('isolatesThrownItemFailuresAndRejectsInvalidClockWithSafePrivacy', 0, async () => {
      const first = buildRemoteProfile('profile-a', 'https://a.example.com', 1, 1);
      const second = buildRemoteProfile('profile-b', 'https://b.example.com', 1, 1);
      const third = buildRemoteProfile('profile-c', 'https://c.example.com', 1, 1);
      const executor = new FakeRefreshExecutor();
      executor.setResult('profile-a', buildUpdatedResult(first, 'VALID', null, true));
      executor.setThrow('profile-b', new Error('https://sensitive.example.com token=abc123 lease-owner=xyz'));
      executor.setResult('profile-c', buildUpdatedResult(third, 'VALID', null, true));
      const useCaseBundle: BuildUseCaseResult = buildUseCase([first, second, third], Date.parse(isoAt(500)), executor);
      const useCase = useCaseBundle.useCase;

      class InvalidClockValue implements Clock {
        now(): string {
          return 'not-a-date';
        }
      }
      const invalidClock: Clock = new InvalidClockValue();

      const result = await useCase.execute({ mode: 'ALL' });
      const serialized: string = JSON.stringify(result);

      expect(result.items.length).assertEqual(3);
      expect(result.items[0].status).assertEqual('SUCCESS');
      expect(result.items[1].status).assertEqual('FAILED');
      expect(result.items[2].status).assertEqual('SUCCESS');
      expect(serialized.includes('https://sensitive.example.com')).assertFalse();
      expect(serialized.includes('token=abc123')).assertFalse();
      expect(serialized.includes('lease-owner=xyz')).assertFalse();

      await expectSafeUseCaseError(
        new RefreshProfilesUseCase({
          repository: new FakeProfileRepository([first]),
          executor: new FakeRefreshExecutor(),
          clock: invalidClock
        }).execute({ mode: 'ALL', deadlineMs: Number.NaN }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-a', 'a.example.com']
      );

      await expectSafeUseCaseError(
        (() => {
          const invalidProfile: Profile = copyProfile(first);
          invalidProfile.lastSuccessfulUpdateAt = 'yesterday';
          return new RefreshProfilesUseCase({
            repository: new FakeProfileRepository([invalidProfile]),
            executor: new FakeRefreshExecutor(),
            clock: new FakeClock(Date.parse(isoAt(500)))
          }).execute({ mode: 'DUE' });
        })(),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-a', 'a.example.com', 'yesterday']
      );

      await expectSafeUseCaseError(
        new RefreshProfilesUseCase({
          repository: new FakeProfileRepository([first]),
          executor: new FakeRefreshExecutor(),
          clock: invalidClock
        }).execute({ mode: 'ALL' }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-a', 'a.example.com', 'not-a-date']
      );
    });

    it('rejectsOverflowFromInjectedTimestampParserWithFixedSafeError', 0, async () => {
      const profile = buildRemoteProfile('profile-overflow', 'https://overflow.example.com', 1, 2);
      class FixedRefreshProfilesTimestampParser implements RefreshProfilesTimestampParser {
        parseUtcMillis(_timestamp: string, label: string): number {
          if (label === 'Clock timestamp') {
            return Date.parse('2026-09-01T12:00:00.000Z');
          }
          return Number.MAX_SAFE_INTEGER;
        }
      }
      const parser: RefreshProfilesTimestampParser = new FixedRefreshProfilesTimestampParser();

      await expectSafeUseCaseError(
        buildUseCase(
          [profile],
          Date.parse('2026-09-01T12:00:00.000Z'),
          new FakeRefreshExecutor(),
          undefined,
          parser
        ).useCase.execute({ mode: 'DUE' }),
        'REFRESH_PROFILES_INVALID_INPUT',
        ['profile-overflow', 'overflow.example.com']
      );
    });
  });
}
