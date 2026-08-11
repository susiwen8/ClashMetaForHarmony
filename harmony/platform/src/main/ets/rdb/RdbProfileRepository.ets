import { createAppError, isProfileEligibleForActivation, type AppError, type Profile, type ProfileRepository } from '@cmfa/shared';
import { decodeProfileRow, encodeProfileRow } from './ProfileRowCodec';
import type { RdbDriver } from './RdbDriver';

class PlatformPersistenceFailure extends Error {
  readonly stage: string;
  readonly code: string;
  readonly technicalDetail: string;
  readonly userMessageResource: string;
  readonly timestamp: string;
  readonly retryable: boolean;

  constructor(error: AppError) {
    super(error.technicalDetail);
    this.stage = error.stage;
    this.code = error.code;
    this.technicalDetail = error.technicalDetail;
    this.userMessageResource = error.userMessageResource;
    this.timestamp = error.timestamp;
    this.retryable = error.retryable;
  }
}

const SCHEMA_VERSION = 1;

function extractSqlKeyword(detail: string): string | null {
  const normalized = detail.trim().toUpperCase();
  const keywords: string[] = ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'REPLACE'];
  for (let index = 0; index < keywords.length; index += 1) {
    if (normalized.startsWith(keywords[index])) {
      return keywords[index];
    }
  }
  return null;
}

function sanitizePersistenceDetail(detail: string): string {
  const sqlKeyword: string | null = extractSqlKeyword(detail);
  if (sqlKeyword !== null) {
    return `${sqlKeyword} statement failed.`;
  }
  return detail;
}

function toPersistenceFailure(error: Object | undefined, fallback: string): PlatformPersistenceFailure {
  if (error instanceof PlatformPersistenceFailure) {
    return error;
  }
  const detail: string = sanitizePersistenceDetail(
    error instanceof Error && error.message.trim().length > 0 ? error.message : fallback
  );
  return new PlatformPersistenceFailure(createAppError('PERSISTENCE', detail, {
    code: 'CMFA_PERSISTENCE_FAILED',
    timestamp: '2026-08-11T00:00:00.000Z',
    retryable: false
  }));
}

export class RdbProfileRepository implements ProfileRepository {
  private readonly driver: RdbDriver;
  private initialized: boolean = false;
  private activeIdValue: string | undefined = undefined;
  private activeIdValidated: boolean = false;

  constructor(driver: RdbDriver) {
    this.driver = driver;
  }

  async list(): Promise<Profile[]> {
    await this.ensureInitialized();
    try {
      const rows = await this.driver.listProfileRows();
      const profiles: Profile[] = [];
      for (let index = 0; index < rows.length; index += 1) {
        profiles.push(decodeProfileRow(rows[index]));
      }
      profiles.sort((left: Profile, right: Profile): number => {
        if (left.updatedAt > right.updatedAt) {
          return -1;
        }
        if (left.updatedAt < right.updatedAt) {
          return 1;
        }
        if (left.id < right.id) {
          return -1;
        }
        if (left.id > right.id) {
          return 1;
        }
        return 0;
      });
      return profiles;
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile list failed.');
    }
  }

  async get(id: string): Promise<Profile | undefined> {
    await this.ensureInitialized();
    try {
      const row = await this.driver.getProfileRow(id);
      return row === undefined ? undefined : decodeProfileRow(row);
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile lookup failed.');
    }
  }

  async save(profile: Profile): Promise<void> {
    await this.ensureInitialized();
    try {
      await this.driver.upsertProfileRow(encodeProfileRow(profile));
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile save failed.');
    }
  }

  async deleteAndClearActive(id: string): Promise<void> {
    await this.ensureInitialized();
    try {
      await this.driver.transaction(async (transaction) => {
        await transaction.clearActiveIfMatching(id);
        await transaction.deleteProfile(id);
      });
      if (this.activeIdValue === id) {
        this.activeIdValue = undefined;
      }
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile delete failed.');
    }
  }

  async getActiveId(): Promise<string | undefined> {
    await this.ensureInitialized();
    await this.ensureActiveIdValidated();
    return this.activeIdValue;
  }

  async setActiveId(id: string | undefined): Promise<void> {
    await this.ensureInitialized();
    try {
      await this.driver.transaction(async (transaction) => {
        if (id === undefined) {
          await transaction.setActiveId(undefined);
          return;
        }
        const row = await transaction.getProfileRow(id);
        if (row === undefined) {
          throw toPersistenceFailure(new Error('Active profile not found.'), 'Active profile not found.');
        }
        const profile: Profile = decodeProfileRow(row);
        if (!isProfileEligibleForActivation(profile) || profile.currentRevision === null) {
          throw toPersistenceFailure(new Error('Profile is not eligible for activation.'), 'Profile is not eligible for activation.');
        }
        await transaction.setActiveId(id);
      });
      this.activeIdValue = id;
      this.activeIdValidated = true;
    } catch (error) {
      throw toPersistenceFailure(error, 'Active profile update failed.');
    }
  }

  private async ensureInitialized(): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      await this.driver.initialize(SCHEMA_VERSION);
      this.initialized = true;
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile persistence initialization failed.');
    }
  }

  private async ensureActiveIdValidated(): Promise<void> {
    if (this.activeIdValidated) {
      return;
    }
    try {
      const activeId = await this.driver.readActiveId();
      if (activeId === undefined) {
        this.activeIdValue = undefined;
        this.activeIdValidated = true;
        return;
      }
      const row = await this.driver.getProfileRow(activeId);
      if (row === undefined) {
        await this.driver.transaction(async (transaction) => {
          await transaction.setActiveId(undefined);
        });
        this.activeIdValue = undefined;
        this.activeIdValidated = true;
        return;
      }
      const profile: Profile = decodeProfileRow(row);
      if (!isProfileEligibleForActivation(profile) || profile.currentRevision === null) {
        await this.driver.transaction(async (transaction) => {
          await transaction.setActiveId(undefined);
        });
        this.activeIdValue = undefined;
        this.activeIdValidated = true;
        return;
      }
      this.activeIdValue = activeId;
      this.activeIdValidated = true;
    } catch (error) {
      throw toPersistenceFailure(error, 'Profile persistence initialization failed.');
    }
  }
}
