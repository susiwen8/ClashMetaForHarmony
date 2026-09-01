import type { ProfileRefreshLeasePort } from '@cmfa/shared';
import type { DurableProfileRefreshLeaseRow, RdbDriver } from './RdbDriver';

const MAX_IDENTIFIER_LENGTH = 256;

function isSafeNonNegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function requireBoundedNonBlankText(value: string, label: 'profile' | 'owner'): void {
  if (value.trim().length === 0) {
    throw new Error(`Profile refresh lease ${label} is invalid.`);
  }
  if (value.length > MAX_IDENTIFIER_LENGTH) {
    throw new Error(`Profile refresh lease ${label} is invalid.`);
  }
}

function requireLeaseWindow(nowMs: number, expiresAtMs: number): void {
  if (!isSafeNonNegativeInteger(nowMs) || !isSafeNonNegativeInteger(expiresAtMs) || expiresAtMs <= nowMs) {
    throw new Error('Profile refresh lease timing is invalid.');
  }
}

function createLeaseRow(profileId: string, ownerToken: string, expiresAtMs: number): DurableProfileRefreshLeaseRow {
  return {
    profileId,
    ownerToken,
    expiresAtMs
  };
}

export class RdbProfileRefreshLeaseStore implements ProfileRefreshLeasePort {
  private readonly driver: RdbDriver;

  constructor(driver: RdbDriver) {
    this.driver = driver;
  }

  async tryAcquire(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean> {
    this.validateLeaseMutation(profileId, ownerToken, nowMs, expiresAtMs);
    try {
      return await this.driver.transaction(async (transaction) => {
        const existing = await transaction.getProfileRefreshLeaseRow(profileId);
        if (existing !== undefined && existing.ownerToken !== ownerToken && existing.expiresAtMs > nowMs) {
          return false;
        }
        await transaction.upsertProfileRefreshLeaseRow(createLeaseRow(profileId, ownerToken, expiresAtMs));
        return true;
      });
    } catch (_) {
      throw new Error('Profile refresh lease acquisition failed.');
    }
  }

  async renew(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): Promise<boolean> {
    this.validateLeaseMutation(profileId, ownerToken, nowMs, expiresAtMs);
    try {
      return await this.driver.transaction(async (transaction) => {
        const existing = await transaction.getProfileRefreshLeaseRow(profileId);
        if (existing === undefined || existing.ownerToken !== ownerToken || existing.expiresAtMs <= nowMs) {
          return false;
        }
        await transaction.upsertProfileRefreshLeaseRow(createLeaseRow(profileId, ownerToken, expiresAtMs));
        return true;
      });
    } catch (_) {
      throw new Error('Profile refresh lease renewal failed.');
    }
  }

  async release(profileId: string, ownerToken: string): Promise<boolean> {
    this.validateLeaseIdentity(profileId, ownerToken);
    try {
      return await this.driver.transaction(async (transaction) =>
        await transaction.deleteProfileRefreshLeaseRowIfOwned(profileId, ownerToken)
      );
    } catch (_) {
      throw new Error('Profile refresh lease release failed.');
    }
  }

  private validateLeaseMutation(profileId: string, ownerToken: string, nowMs: number, expiresAtMs: number): void {
    this.validateLeaseIdentity(profileId, ownerToken);
    requireLeaseWindow(nowMs, expiresAtMs);
  }

  private validateLeaseIdentity(profileId: string, ownerToken: string): void {
    requireBoundedNonBlankText(profileId, 'profile');
    requireBoundedNonBlankText(ownerToken, 'owner');
  }
}
