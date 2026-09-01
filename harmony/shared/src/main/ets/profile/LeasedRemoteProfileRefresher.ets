import type { Clock, IdGenerator, ProfileRefreshLeasePort } from './ProfilePorts';

export const REMOTE_PROFILE_REFRESH_LEASE_TTL_MS: number = 120000;
const LEASE_FAILURE_MESSAGE: string = 'Profile refresh lease failed.';
const LEASE_FAILURE_CODE: 'PROFILE_REFRESH_LEASE_FAILED' = 'PROFILE_REFRESH_LEASE_FAILED';

export interface LeasedRemoteProfileRefresherDependencies {
  leasePort: ProfileRefreshLeasePort;
  clock: Clock;
  idGenerator: IdGenerator;
}

export interface LeasedRemoteProfileRefreshCompleted<T> {
  kind: 'COMPLETED';
  value: T;
}

export interface LeasedRemoteProfileRefreshBusy {
  kind: 'BUSY';
}

export type LeasedRemoteProfileRefreshResult<T> =
  | LeasedRemoteProfileRefreshCompleted<T>
  | LeasedRemoteProfileRefreshBusy;

export interface LeasedRemoteProfileRefreshError extends Error {
  name: 'LeasedRemoteProfileRefreshError';
  code: 'PROFILE_REFRESH_LEASE_FAILED';
}

class LeasedRemoteProfileRefreshCompletedValue<T> implements LeasedRemoteProfileRefreshCompleted<T> {
  kind: 'COMPLETED' = 'COMPLETED';
  value: T;

  constructor(value: T) {
    this.value = value;
  }
}

class LeasedRemoteProfileRefreshBusyValue implements LeasedRemoteProfileRefreshBusy {
  kind: 'BUSY' = 'BUSY';
}

class LeasedRemoteProfileRefreshErrorValue extends Error implements LeasedRemoteProfileRefreshError {
  name: 'LeasedRemoteProfileRefreshError' = 'LeasedRemoteProfileRefreshError';
  code: 'PROFILE_REFRESH_LEASE_FAILED' = LEASE_FAILURE_CODE;

  constructor() {
    super(LEASE_FAILURE_MESSAGE);
  }
}

export class LeasedRemoteProfileRefresher {
  private readonly leasePort: ProfileRefreshLeasePort;
  private readonly clock: Clock;
  private readonly idGenerator: IdGenerator;

  constructor(dependencies: LeasedRemoteProfileRefresherDependencies) {
    this.leasePort = dependencies.leasePort;
    this.clock = dependencies.clock;
    this.idGenerator = dependencies.idGenerator;
  }

  async execute<T>(profileId: string, operation: () => Promise<T> | T): Promise<LeasedRemoteProfileRefreshResult<T>> {
    const ownerToken: string = this.resolveOwnerToken();
    const nowMs: number = this.resolveNowMs();
    const expiresAtMs: number = this.resolveExpiresAtMs(nowMs);

    let acquired: boolean = false;
    try {
      acquired = await this.leasePort.tryAcquire(profileId, ownerToken, nowMs, expiresAtMs);
    } catch (_) {
      throw this.createLeaseError();
    }

    if (!acquired) {
      return new LeasedRemoteProfileRefreshBusyValue();
    }

    try {
      return new LeasedRemoteProfileRefreshCompletedValue(await operation());
    } finally {
      await this.releaseBestEffort(profileId, ownerToken);
    }
  }

  private resolveOwnerToken(): string {
    let ownerToken: string;
    try {
      ownerToken = this.idGenerator.nextId();
    } catch (_) {
      throw this.createLeaseError();
    }
    if (ownerToken.trim().length === 0) {
      throw this.createLeaseError();
    }
    return ownerToken;
  }

  private resolveNowMs(): number {
    let nowMs: number;
    try {
      nowMs = Date.parse(this.clock.now());
    } catch (_) {
      throw this.createLeaseError();
    }
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
      throw this.createLeaseError();
    }
    return nowMs;
  }

  private resolveExpiresAtMs(nowMs: number): number {
    if (nowMs > Number.MAX_SAFE_INTEGER - REMOTE_PROFILE_REFRESH_LEASE_TTL_MS) {
      throw this.createLeaseError();
    }
    const expiresAtMs: number = nowMs + REMOTE_PROFILE_REFRESH_LEASE_TTL_MS;
    if (!Number.isSafeInteger(expiresAtMs) || expiresAtMs < nowMs) {
      throw this.createLeaseError();
    }
    return expiresAtMs;
  }

  private async releaseBestEffort(profileId: string, ownerToken: string): Promise<void> {
    try {
      await this.leasePort.release(profileId, ownerToken);
    } catch (_) {
    }
  }

  private createLeaseError(): LeasedRemoteProfileRefreshError {
    return new LeasedRemoteProfileRefreshErrorValue();
  }
}
