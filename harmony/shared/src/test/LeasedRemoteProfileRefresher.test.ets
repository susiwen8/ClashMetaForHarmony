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
    return true;
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

      expect(result.kind).assertEqual('COMPLETED');
      if (result.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(result.value).assertEqual('ok');
      expect(leasePort.acquireCalls.length).assertEqual(1);
      expect(leasePort.acquireCalls[0].profileId).assertEqual('profile-remote-1');
      expect(leasePort.acquireCalls[0].ownerToken).assertEqual('lease-owner-1');
      expect(leasePort.acquireCalls[0].nowMs).assertEqual(Date.parse('2026-09-01T10:00:00.000Z'));
      expect(leasePort.acquireCalls[0].expiresAtMs).assertEqual(
        Date.parse('2026-09-01T10:00:00.000Z') + REMOTE_PROFILE_REFRESH_LEASE_TTL_MS
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

    it('releasesLeaseAndPreservesOriginalOperationErrorWhenOperationFails', 0, async () => {
      const leasePort = new RecordingLeasePort();
      const refresher = new LeasedRemoteProfileRefresher({
        leasePort,
        clock: new FixedClock('2026-09-01T10:02:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-3')
      });

      await expectRejectsWithMessage(
        refresher.execute('profile-remote-3', async () => {
          throw new Error('refresh failed for expected reason');
        }),
        'refresh failed for expected reason'
      );

      expect(leasePort.releaseCalls.length).assertEqual(1);
      expect(leasePort.releaseCalls[0].ownerToken).assertEqual('lease-owner-3');
    });

    it('bestEffortReleaseDoesNotOverrideSuccessfulOrFailedOperationOutcome', 0, async () => {
      const successLeasePort = new RecordingLeasePort();
      successLeasePort.releaseError = new Error('release failed');
      const successRefresher = new LeasedRemoteProfileRefresher({
        leasePort: successLeasePort,
        clock: new FixedClock('2026-09-01T10:03:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-4')
      });

      const successResult = await successRefresher.execute('profile-remote-4', async () => 'still-success');

      expect(successResult.kind).assertEqual('COMPLETED');
      if (successResult.kind !== 'COMPLETED') {
        expect(false).assertTrue();
        return;
      }
      expect(successResult.value).assertEqual('still-success');
      expect(successLeasePort.releaseCalls.length).assertEqual(1);

      const failureLeasePort = new RecordingLeasePort();
      failureLeasePort.releaseError = new Error('release failed');
      const failureRefresher = new LeasedRemoteProfileRefresher({
        leasePort: failureLeasePort,
        clock: new FixedClock('2026-09-01T10:04:00.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-5')
      });

      await expectRejectsWithMessage(
        failureRefresher.execute('profile-remote-5', async () => {
          throw new Error('operation failure survives release failure');
        }),
        'operation failure survives release failure'
      );
      expect(failureLeasePort.releaseCalls.length).assertEqual(1);
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

    it('rejectsInvalidClockValuesUnsafeExpiryAndBlankOwnerBeforeLeaseOrOperation', 0, async () => {
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

      const overflowLeasePort = new RecordingLeasePort();
      const overflowRefresher = new LeasedRemoteProfileRefresher({
        leasePort: overflowLeasePort,
        clock: new FixedClock('2026-09-01T10:05:30.000Z'),
        idGenerator: new FixedIdGenerator('lease-owner-8')
      });

      let overflowError: Object | undefined = undefined;
      const originalParse: (value: string) => number = Date.parse;
      Date.parse = (_value: string): number => Number.MAX_SAFE_INTEGER - REMOTE_PROFILE_REFRESH_LEASE_TTL_MS + 1;
      try {
        try {
          await overflowRefresher.execute('profile-remote-8', async () => 'nope');
        } catch (error) {
          overflowError = error as Object;
        }
      } finally {
        Date.parse = originalParse;
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
