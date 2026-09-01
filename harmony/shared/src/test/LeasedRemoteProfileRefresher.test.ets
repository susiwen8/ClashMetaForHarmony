import { describe, expect, it } from '@ohos/hypium';
import {
  LeasedRemoteProfileRefresher,
  REMOTE_PROFILE_REFRESH_LEASE_TTL_MS,
  type Clock,
  type IdGenerator,
  type LeasedRemoteProfileRefreshError,
  type ProfileRefreshLeasePort
} from '../../Index';

class AcquireCall {
  readonly profileId: string;
  readonly ownerToken: string;
  readonly nowMs: number;
  readonly expiresAtMs: number;

  constructor(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number) {
    this.profileId = profileId;
    this.ownerToken = ownerToken;
    this.nowMs = nowMs;
    this.expiresAtMs = expiresAtMs;
  }
}

class ReleaseCall {
  readonly profileId: string;
  readonly ownerToken: string;

  constructor(profileId: string, ownerToken: string) {
    this.profileId = profileId;
    this.ownerToken = ownerToken;
  }
}

class RecordingLeasePort implements ProfileRefreshLeasePort {
  readonly acquireCalls: AcquireCall[] = [];
  readonly releaseCalls: ReleaseCall[] = [];
  tryAcquireResult: boolean = true;
  releaseResult: boolean = true;
  tryAcquireError?: Error;
  releaseError?: Error;

  async tryAcquire(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean> {
    this.acquireCalls.push(new AcquireCall(profileId, ownerToken, nowMs, expiresAtMs));
    if (this.tryAcquireError !== undefined) {
      throw this.tryAcquireError;
    }
    return this.tryAcquireResult;
  }

  async renew(_profileId: string, _ownerToken: string, _nowMs: number, _expiresAtMs: number): Promise<boolean> {
    return true;
  }

  async release(profileId: string, ownerToken: string): Promise<boolean> {
    this.releaseCalls.push(new ReleaseCall(profileId, ownerToken));
    if (this.releaseError !== undefined) {
      throw this.releaseError;
    }
    return this.releaseResult;
  }
}

class FixedClock implements Clock {
  private readonly value: string;
  error?: Error;

  constructor(value: string) {
    this.value = value;
  }

  now(): string {
    if (this.error !== undefined) {
      throw this.error;
    }
    return this.value;
  }
}

class FixedIdGenerator implements IdGenerator {
  private readonly value: string;
  error?: Error;

  constructor(value: string) {
    this.value = value;
  }

  nextId(): string {
    if (this.error !== undefined) {
      throw this.error;
    }
    return this.value;
  }
}

function expectSafeLeaseError(
  error: Object,
  forbiddenFragments: string[] = []
): void {
  const leaseError: LeasedRemoteProfileRefreshError = error as LeasedRemoteProfileRefreshError;
  expect(leaseError.name).assertEqual('LeasedRemoteProfileRefreshError');
  expect(leaseError.code).assertEqual('PROFILE_REFRESH_LEASE_FAILED');
  expect(leaseError.message).assertEqual('Profile refresh lease failed.');
  for (let index = 0; index < forbiddenFragments.length; index += 1) {
    expect(leaseError.message.includes(forbiddenFragments[index])).assertFalse();
  }
}

async function expectRejectsWithMessage(
  promise: Promise<Object>,
  expectedFragment: string,
  forbiddenFragments: string[] = []
): Promise<void> {
  let didReject: boolean = false;
  try {
    await promise;
  } catch (error) {
    didReject = true;
    const message: string = error instanceof Error ? error.message : `${error}`;
    expect(message.includes(expectedFragment)).assertTrue();
    for (let index = 0; index < forbiddenFragments.length; index += 1) {
      expect(message.includes(forbiddenFragments[index])).assertFalse();
    }
  }
  if (!didReject) {
    throw new Error(`Expected promise to reject with "${expectedFragment}".`);
  }
}

async function expectRejectsWithSameError(promise: Promise<Object>, expectedError: Error): Promise<void> {
  let capturedError: Object | undefined = undefined;
  try {
    await promise;
  } catch (error) {
    capturedError = error as Object;
  }
  if (capturedError === undefined) {
    throw new Error('Expected promise to reject.');
  }
  expect(capturedError === expectedError).assertTrue();
}

export default function leasedRemoteProfileRefresherTestsuite() {
  describe('LeasedRemoteProfileRefresherTest', () => {
    it('acquiresExactDefaultTtlRunsOperationAndReleasesSameOwner', 0, async () => {
      const leasePort = new RecordingLeasePort();
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:00:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-1')
      });

      const result = await refresher.execute('profile-remote-1', async () => 'ok');
      const expectedNowMs: number = Date.parse('2026-09-01T10:00:00.000Z');

      expect(result.kind).assertEqual('COMPLETED');
      if (result.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.value).assertEqual('ok');
      expect(result.leaseReleased).assertTrue();
      expect(leasePort.acquireCalls.length).assertEqual(1);
      expect(leasePort.acquireCalls[0].profileId).assertEqual('profile-remote-1');
      expect(leasePort.acquireCalls[0].ownerToken).assertEqual('lease-owner-1');
      expect(leasePort.acquireCalls[0].nowMs).assertEqual(expectedNowMs);
      expect(leasePort.acquireCalls[0].expiresAtMs).assertEqual(
        expectedNowMs + REMOTE_PROFILE_REFRESH_LEASE_TTL_MS
      );
      expect(leasePort.releaseCalls.length).assertEqual(1);
      expect(leasePort.releaseCalls[0].profileId).assertEqual('profile-remote-1');
      expect(leasePort.releaseCalls[0].ownerToken).assertEqual('lease-owner-1');
    });

    it('returnsBusyWithoutRunningOperationOrReleaseWhenLeaseOwnedByAnotherWorker', 0, async () => {
      const leasePort = new RecordingLeasePort();
      leasePort.tryAcquireResult = false;
      let didRunOperation: boolean = false;
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:01:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-2')
      });

      const result = await refresher.execute('profile-remote-2', async () => {
        didRunOperation = true;
        return 'unexpected';
      });

      expect(result.kind).assertEqual('BUSY');
      expect(didRunOperation).assertFalse();
      expect(leasePort.acquireCalls.length).assertEqual(1);
      expect(leasePort.releaseCalls.length).assertEqual(0);
    });

    it('releasesLeaseAndPreservesOriginalOperationErrorIdentityWhenOperationFails', 0, async () => {
      const leasePort = new RecordingLeasePort();
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:02:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-3')
      });
      const operationError: Error = new Error('refresh failed for expected reason');

      await expectRejectsWithSameError(
        refresher.execute('profile-remote-3', async () => {
          throw operationError;
        }),
        operationError
      );

      expect(leasePort.releaseCalls.length).assertEqual(1);
      expect(leasePort.releaseCalls[0].ownerToken).assertEqual('lease-owner-3');
    });

    it('returnsCompletedWithLeaseReleasedFalseWhenReleasePortReturnsFalse', 0, async () => {
      const leasePort = new RecordingLeasePort();
      leasePort.releaseResult = false;
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:03:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-4')
      });

      const result = await refresher.execute('profile-remote-4', async () => 'still-success');

      expect(result.kind).assertEqual('COMPLETED');
      if (result.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.value).assertEqual('still-success');
      expect(result.leaseReleased).assertFalse();
      expect(leasePort.releaseCalls.length).assertEqual(1);
    });

    it('returnsCompletedWithLeaseReleasedFalseWhenReleaseThrows', 0, async () => {
      const leasePort = new RecordingLeasePort();
      leasePort.releaseError = new Error('release failed');
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:04:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-5')
      });

      const result = await refresher.execute('profile-remote-5', async () => 'success survives release throw');

      expect(result.kind).assertEqual('COMPLETED');
      if (result.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.value).assertEqual('success survives release throw');
      expect(result.leaseReleased).assertFalse();
      expect(leasePort.releaseCalls.length).assertEqual(1);
    });

    it('wrapsAcquireFailuresWithFixedSafeLeaseErrorWithoutProfileOrTokenLeak', 0, async () => {
      const leasePort = new RecordingLeasePort();
      leasePort.tryAcquireError = new Error('db failure profile-remote-6 lease-owner-6 token=abc');
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:05:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-6')
      });

      let capturedError: Object | undefined = undefined;
      try {
        await refresher.execute('profile-remote-6', async () => 'nope');
      } catch (error) {
        capturedError = error as Object;
      }
      if (capturedError === undefined) {
        throw new Error('Expected safe lease error.');
      }
      expectSafeLeaseError(capturedError, ['profile-remote-6', 'lease-owner-6', 'token=abc']);
      expect(leasePort.releaseCalls.length).assertEqual(0);
    });

    it('rejectsInvalidClockValuesNonCanonicalTimestampsUnsafeExpiryAndBlankOwnerBeforeLeaseOrOperation', 0, async () => {
      const leasePort = new RecordingLeasePort();
      let didRunOperation: boolean = false;
      const invalidClockRefresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('not-a-date'),
        idGenerator: new FixedIdGenerator('lease-owner-7')
      });

      let invalidClockError: Object | undefined = undefined;
      try {
        await invalidClockRefresher.execute('profile-remote-7', async () => {
          didRunOperation = true;
          return 'nope';
        });
      } catch (error) {
        invalidClockError = error as Object;
      }
      if (invalidClockError === undefined) {
        throw new Error('Expected invalid clock rejection.');
      }
      expectSafeLeaseError(invalidClockError);
      expect(didRunOperation).assertFalse();
      expect(leasePort.acquireCalls.length).assertEqual(0);

      const nonCanonicalMissingMillisecondsLeasePort = new RecordingLeasePort();
      const nonCanonicalMissingMillisecondsRefresher = new LeasedRemoteProfileRefresher({
        leasePort: nonCanonicalMissingMillisecondsLeasePort,
        clock: new FixedClock('2026-09-01T10:05:00Z'),
        idGenerator: new FixedIdGenerator('lease-owner-7b')
      });

      let nonCanonicalMissingMillisecondsError: Object | undefined = undefined;
      try {
        await nonCanonicalMissingMillisecondsRefresher.execute('profile-remote-7b', async () => 'nope');
      } catch (error) {
        nonCanonicalMissingMillisecondsError = error as Object;
      }
      if (nonCanonicalMissingMillisecondsError === undefined) {
        throw new Error('Expected noncanonical timestamp rejection.');
      }
      expectSafeLeaseError(nonCanonicalMissingMillisecondsError);
      expect(nonCanonicalMissingMillisecondsLeasePort.acquireCalls.length).assertEqual(0);

      const nonCanonicalOffsetLeasePort = new RecordingLeasePort();
      const nonCanonicalOffsetRefresher = new LeasedRemoteProfileRefresher({
        leasePort: nonCanonicalOffsetLeasePort,
        clock: new FixedClock('2026-09-01T18:05:00.000+08:00'),
        idGenerator: new FixedIdGenerator('lease-owner-7c')
      });

      let nonCanonicalOffsetError: Object | undefined = undefined;
      try {
        await nonCanonicalOffsetRefresher.execute('profile-remote-7c', async () => 'nope');
      } catch (error) {
        nonCanonicalOffsetError = error as Object;
      }
      if (nonCanonicalOffsetError === undefined) {
        throw new Error('Expected offset timestamp rejection.');
      }
      expectSafeLeaseError(nonCanonicalOffsetError);
      expect(nonCanonicalOffsetLeasePort.acquireCalls.length).assertEqual(0);

      const overflowLeasePort = new RecordingLeasePort();
      const overflowRefresher = new LeasedRemoteProfileRefresher({
        leasePort: overflowLeasePort,
        clock: new FixedClock('2026-09-01T10:05:30.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-8'),
        parseTimestampMs: (_timestamp: string): number => Number.MAX_SAFE_INTEGER - REMOTE_PROFILE_REFRESH_LEASE_TTL_MS + 1
      });

      let overflowError: Object | undefined = undefined;
      try {
        await overflowRefresher.execute('profile-remote-8', async () => 'nope');
      } catch (error) {
        overflowError = error as Object;
      }
      if (overflowError === undefined) {
        throw new Error('Expected unsafe expiry rejection.');
      }
      expectSafeLeaseError(overflowError);
      expect(overflowLeasePort.acquireCalls.length).assertEqual(0);

      const blankOwnerLeasePort = new RecordingLeasePort();
      const blankOwnerRefresher = new LeasedRemoteProfileRefresher({
        leasePort: blankOwnerLeasePort,
        clock: new FixedClock('2026-09-01T10:06:00.000Z'),
        idGenerator: new FixedIdGenerator('   ')
      });

      let blankOwnerError: Object | undefined = undefined;
      try {
        await blankOwnerRefresher.execute('profile-remote-9', async () => 'nope');
      } catch (error) {
        blankOwnerError = error as Object;
      }
      if (blankOwnerError === undefined) {
        throw new Error('Expected blank owner rejection.');
      }
      expectSafeLeaseError(blankOwnerError);
      expect(blankOwnerLeasePort.acquireCalls.length).assertEqual(0);
      expect(blankOwnerLeasePort.releaseCalls.length).assertEqual(0);
    });
  });
}
