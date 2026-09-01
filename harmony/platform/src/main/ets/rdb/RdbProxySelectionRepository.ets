import { createAppError, createProxySelectionRecord, type AppError, type ProxySelectionPair, type ProxySelectionRecord, type ProxySelectionRepository } from '@cmfa/shared';
import { decodeProfileRow } from './ProfileRowCodec';
import { decodeProxySelectionRow, encodeProxySelectionRow } from './ProxySelectionRowCodec';
import type { DurableProxySelectionRow, RdbDriver } from './RdbDriver';

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

const SCHEMA_VERSION = 2;

function toPersistenceFailure(error: Object | undefined, fallback: string): PlatformPersistenceFailure {
  if (error instanceof PlatformPersistenceFailure) {
    return error;
  }
  return new PlatformPersistenceFailure(createAppError('PERSISTENCE', fallback, {
    code: 'CMFA_PERSISTENCE_FAILED',
    retryable: false
  }));
}

function cloneSelectionPairs(validPairs: ProxySelectionPair[]): ProxySelectionPair[] {
  const clones: ProxySelectionPair[] = [];
  for (let index = 0; index < validPairs.length; index += 1) {
    clones.push({
      groupName: validPairs[index].groupName,
      selectedNodeName: validPairs[index].selectedNodeName
    });
  }
  return clones;
}

function createGroupKey(groupName: string): string {
  return groupName;
}

export class RdbProxySelectionRepository implements ProxySelectionRepository {
  private readonly driver: RdbDriver;
  private initialized: boolean = false;
  private initializePromise?: Promise<void>;

  constructor(driver: RdbDriver) {
    this.driver = driver;
  }

  async listByProfile(profileId: string): Promise<ProxySelectionRecord[]> {
    await this.ensureInitialized();
    try {
      const rows = await this.driver.listProxySelectionRows(profileId);
      const records: ProxySelectionRecord[] = [];
      for (let index = 0; index < rows.length; index += 1) {
        records.push(decodeProxySelectionRow(rows[index]));
      }
      return records;
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection list failed.');
    }
  }

  async get(profileId: string, groupName: string): Promise<ProxySelectionRecord | undefined> {
    await this.ensureInitialized();
    try {
      const row = await this.driver.getProxySelectionRow(profileId, groupName);
      return row === undefined ? undefined : decodeProxySelectionRow(row);
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection lookup failed.');
    }
  }

  async upsert(record: ProxySelectionRecord): Promise<void> {
    await this.ensureInitialized();
    try {
      const recordClone: ProxySelectionRecord = createProxySelectionRecord(
        record.profileId,
        record.groupName,
        record.selectedNodeName,
        record.revisionId,
        record.updatedAt
      );
      await this.driver.transaction(async (transaction) => {
        const profileRow = await transaction.getProfileRow(recordClone.profileId);
        if (profileRow === undefined) {
          throw new Error('Proxy selection profile is missing.');
        }
        const profile = decodeProfileRow(profileRow);
        if (profile.currentRevision === null || profile.currentRevision.validatedAt !== recordClone.revisionId) {
          throw new Error('Proxy selection revision is invalid.');
        }
        await transaction.upsertProxySelectionRow(encodeProxySelectionRow(recordClone));
      });
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection save failed.');
    }
  }

  async delete(profileId: string, groupName: string): Promise<void> {
    await this.ensureInitialized();
    try {
      await this.driver.transaction(async (transaction) => {
        await transaction.deleteProxySelection(profileId, groupName);
      });
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection delete failed.');
    }
  }

  async deleteProfile(profileId: string): Promise<void> {
    await this.ensureInitialized();
    try {
      await this.driver.transaction(async (transaction) => {
        await transaction.deleteProfileSelections(profileId);
      });
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection delete failed.');
    }
  }

  async reconcileProfile(profileId: string, newRevisionId: string, validPairs: ProxySelectionPair[]): Promise<void> {
    await this.ensureInitialized();
    try {
      const pairClones: ProxySelectionPair[] = cloneSelectionPairs(validPairs);
      await this.driver.transaction(async (transaction) => {
        const profileRow = await transaction.getProfileRow(profileId);
        if (profileRow === undefined) {
          throw new Error('Proxy selection profile is missing.');
        }
        const profile = decodeProfileRow(profileRow);
        if (profile.currentRevision === null || profile.currentRevision.validatedAt !== newRevisionId) {
          throw new Error('Proxy selection reconcile revision is invalid.');
        }

        const existingRows: DurableProxySelectionRow[] = await transaction.listProxySelectionRows(profileId);
        const existingByGroup: Map<string, ProxySelectionRecord> = new Map<string, ProxySelectionRecord>();
        for (let index = 0; index < existingRows.length; index += 1) {
          const existing: ProxySelectionRecord = decodeProxySelectionRow(existingRows[index]);
          existingByGroup.set(createGroupKey(existing.groupName), existing);
        }

        const replacementRows: ProxySelectionRecord[] = [];
        const seenGroups: Set<string> = new Set<string>();
        for (let index = 0; index < pairClones.length; index += 1) {
          const validatedPair: ProxySelectionRecord = createProxySelectionRecord(
            profileId,
            pairClones[index].groupName,
            pairClones[index].selectedNodeName,
            newRevisionId,
            profile.updatedAt
          );
          const groupKey: string = createGroupKey(validatedPair.groupName);
          if (seenGroups.has(groupKey)) {
            throw new Error('Proxy selection reconcile pairs must be unique.');
          }
          seenGroups.add(groupKey);
          const existing: ProxySelectionRecord | undefined = existingByGroup.get(groupKey);
          if (existing === undefined || existing.selectedNodeName !== validatedPair.selectedNodeName) {
            throw new Error('Proxy selection reconcile pair is missing.');
          }
          replacementRows.push(createProxySelectionRecord(
            profileId,
            validatedPair.groupName,
            validatedPair.selectedNodeName,
            newRevisionId,
            existing.updatedAt
          ));
        }

        await transaction.deleteProfileSelections(profileId);
        for (let index = 0; index < replacementRows.length; index += 1) {
          await transaction.upsertProxySelectionRow(encodeProxySelectionRow(replacementRows[index]));
        }
      });
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection reconcile failed.');
    }
  }

  private async ensureInitialized(): Promise<void> {
    if (this.initialized) {
      return;
    }
    if (this.initializePromise !== undefined) {
      await this.initializePromise;
      return;
    }
    const initializePromise: Promise<void> = this.runInitialize();
    this.initializePromise = initializePromise;
    try {
      await initializePromise;
    } finally {
      if (!this.initialized) {
        this.initializePromise = undefined;
      }
    }
  }

  private async runInitialize(): Promise<void> {
    try {
      await this.driver.initialize(SCHEMA_VERSION);
      this.initialized = true;
    } catch (error) {
      throw toPersistenceFailure(error, 'Proxy selection persistence initialization failed.');
    }
  }
}
