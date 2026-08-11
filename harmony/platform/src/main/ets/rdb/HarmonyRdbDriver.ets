import { relationalStore } from '@kit.ArkData';
import common from '@ohos.app.ability.common';
import type { DurableProfileRow, RdbDriver, RdbTransaction } from './RdbDriver';

type RelationalValueType = relationalStore.ValueType;
type RelationalValuesBucket = relationalStore.ValuesBucket;

const PROFILES_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS profiles (' +
  'schema_version INTEGER NOT NULL,' +
  'id TEXT PRIMARY KEY NOT NULL,' +
  'name TEXT NOT NULL,' +
  'source_kind TEXT NOT NULL,' +
  'source_display TEXT NOT NULL,' +
  'source_secret_ref TEXT,' +
  'current_revision_json TEXT,' +
  'failed_candidate_json TEXT,' +
  'availability TEXT NOT NULL,' +
  'last_error_json TEXT,' +
  'created_at TEXT NOT NULL,' +
  'updated_at TEXT NOT NULL,' +
  'last_success_at TEXT' +
  ')';
const APP_STATE_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS app_state (' +
  'id INTEGER PRIMARY KEY CHECK (id = 1),' +
  'active_profile_id TEXT' +
  ')';
const APP_STATE_SEED_SQL = 'INSERT OR IGNORE INTO app_state (id, active_profile_id) VALUES (1, NULL)';
const PROFILE_COLUMNS =
  'schema_version, id, name, source_kind, source_display, source_secret_ref, current_revision_json, failed_candidate_json, availability, last_error_json, created_at, updated_at, last_success_at';

function toDriverError(error: Object | undefined, fallback: string): Error {
  if (error instanceof Error && error.message.trim().length > 0) {
    return new Error(fallback);
  }
  return new Error(fallback);
}

function requireStringValue(value: RelationalValueType | undefined, label: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} must be a string.`);
  }
  return value;
}

function requireNullableStringValue(value: RelationalValueType | undefined, label: string): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return requireStringValue(value, label);
}

function requireNumberValue(value: RelationalValueType | undefined, label: string): number {
  if (typeof value !== 'number' || value !== value) {
    throw new Error(`${label} must be a number.`);
  }
  return value;
}

function toBindValues(values: Array<RelationalValueType>): Array<RelationalValueType> {
  return values;
}

function appendBindValue(values: Array<RelationalValueType>, value: string | null | undefined): void {
  values.push(value ?? null);
}

function rowFromBucket(bucket: RelationalValuesBucket): DurableProfileRow {
  return {
    schemaVersion: requireNumberValue(bucket.schema_version, 'profiles.schema_version'),
    id: requireStringValue(bucket.id, 'profiles.id'),
    name: requireStringValue(bucket.name, 'profiles.name'),
    sourceKind: requireStringValue(bucket.source_kind, 'profiles.source_kind'),
    sourceDisplay: requireStringValue(bucket.source_display, 'profiles.source_display'),
    sourceSecretRef: requireNullableStringValue(bucket.source_secret_ref, 'profiles.source_secret_ref') ?? undefined,
    currentRevisionJson: requireNullableStringValue(bucket.current_revision_json, 'profiles.current_revision_json'),
    failedCandidateJson: requireNullableStringValue(bucket.failed_candidate_json, 'profiles.failed_candidate_json'),
    availability: requireStringValue(bucket.availability, 'profiles.availability'),
    lastErrorJson: requireNullableStringValue(bucket.last_error_json, 'profiles.last_error_json'),
    createdAt: requireStringValue(bucket.created_at, 'profiles.created_at'),
    updatedAt: requireStringValue(bucket.updated_at, 'profiles.updated_at'),
    lastSuccessfulUpdateAt: requireNullableStringValue(bucket.last_success_at, 'profiles.last_success_at')
  };
}

function bindRow(row: DurableProfileRow): Array<RelationalValueType> {
  const values: Array<RelationalValueType> = [
    row.schemaVersion,
    row.id,
    row.name,
    row.sourceKind,
    row.sourceDisplay
  ];
  appendBindValue(values, row.sourceSecretRef);
  appendBindValue(values, row.currentRevisionJson);
  appendBindValue(values, row.failedCandidateJson);
  values.push(row.availability);
  appendBindValue(values, row.lastErrorJson);
  values.push(row.createdAt);
  values.push(row.updatedAt);
  appendBindValue(values, row.lastSuccessfulUpdateAt);
  return values;
}

function schemaVersionBindArgs(version: number): Array<RelationalValueType> {
  return [version];
}

function upsertActiveIdBindArgs(activeId: string | undefined): Array<RelationalValueType> {
  const values: Array<RelationalValueType> = [1];
  appendBindValue(values, activeId);
  return values;
}

export class HarmonyRdbDriver implements RdbDriver {
  private readonly context: common.BaseContext;
  private readonly databaseName: string;
  private store?: relationalStore.RdbStore;
  private storePromise?: Promise<relationalStore.RdbStore>;
  private initializedVersion?: number;
  private initializePromise?: Promise<void>;

  constructor(context: common.BaseContext, databaseName: string = 'cmfa_profiles.db') {
    this.context = context;
    this.databaseName = databaseName;
  }

  async initialize(_version: number): Promise<void> {
    if (this.initializedVersion === _version) {
      return;
    }
    if (this.initializePromise !== undefined) {
      await this.initializePromise;
      return;
    }
    const initializePromise = this.runInitialize(_version);
    this.initializePromise = initializePromise;
    try {
      await initializePromise;
    } finally {
      if (this.initializedVersion !== _version) {
        this.initializePromise = undefined;
      }
    }
  }

  async listProfileRows(): Promise<DurableProfileRow[]> {
    const store = await this.getStore();
    return await this.queryRows(
      store,
      `SELECT ${PROFILE_COLUMNS} FROM profiles ORDER BY updated_at DESC, id ASC`
    );
  }

  async getProfileRow(_id: string): Promise<DurableProfileRow | undefined> {
    const store = await this.getStore();
    const rows = await this.queryRows(
      store,
      `SELECT ${PROFILE_COLUMNS} FROM profiles WHERE id = ?`,
      [_id]
    );
    return rows.length === 0 ? undefined : rows[0];
  }

  async upsertProfileRow(_row: DurableProfileRow): Promise<void> {
    const store = await this.getStore();
    await this.executeSql(
      store,
      'INSERT OR REPLACE INTO profiles (' +
      PROFILE_COLUMNS +
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      bindRow(_row)
    );
  }

  async readActiveId(): Promise<string | undefined> {
    const store = await this.getStore();
    const resultSet = await this.querySql(
      store,
      'SELECT active_profile_id FROM app_state WHERE id = 1'
    );
    let primaryError: Error | undefined = undefined;
    try {
      if (!resultSet.goToNextRow()) {
        return undefined;
      }
      const row = resultSet.getRow();
      const activeId = requireNullableStringValue(row.active_profile_id, 'app_state.active_profile_id');
      return activeId ?? undefined;
    } catch (error) {
      primaryError = toDriverError(error, 'Active profile lookup failed.');
      throw primaryError;
    } finally {
      this.closeResultSet(resultSet, primaryError);
    }
  }

  async transaction<T>(_block: (transaction: RdbTransaction) => Promise<T>): Promise<T> {
    const store = await this.getStore();
    this.beginTransaction(store);
    const transaction = new HarmonyRdbTransaction(store);
    try {
      const result = await _block(transaction);
      this.commitTransaction(store);
      return result;
    } catch (error) {
      this.rollbackTransaction(store, error instanceof Error ? error : undefined);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error(`${error}`);
    }
  }

  async close(): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const store = this.store;
    this.store = undefined;
    this.storePromise = undefined;
    this.initializedVersion = undefined;
    this.initializePromise = undefined;
    await this.closeStore(store);
  }

  private async getStore(): Promise<relationalStore.RdbStore> {
    if (this.store !== undefined) {
      return this.store;
    }
    if (this.storePromise !== undefined) {
      return await this.storePromise;
    }
    const acquisition: Promise<relationalStore.RdbStore> = relationalStore.getRdbStore(this.context, {
      name: this.databaseName,
      securityLevel: relationalStore.SecurityLevel.S1
    });
    this.storePromise = acquisition;
    try {
      const store = await acquisition;
      if (this.storePromise === acquisition) {
        this.store = store;
      }
      return store;
    } catch (error) {
      if (this.storePromise === acquisition) {
        this.storePromise = undefined;
      }
      throw toDriverError(error, 'Database open failed.');
    }
  }

  private async queryRows(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<DurableProfileRow[]> {
    const resultSet = await this.querySql(store, sql, bindArgs);
    let primaryError: Error | undefined = undefined;
    try {
      const rows: DurableProfileRow[] = [];
      while (resultSet.goToNextRow()) {
        rows.push(rowFromBucket(resultSet.getRow()));
      }
      return rows;
    } catch (error) {
      primaryError = toDriverError(error, 'Profile row query failed.');
      throw primaryError;
    } finally {
      this.closeResultSet(resultSet, primaryError);
    }
  }

  private async runInitialize(version: number): Promise<void> {
    try {
      const store = await this.getStore();
      await this.executeSql(store, PROFILES_TABLE_SQL);
      await this.executeSql(store, APP_STATE_TABLE_SQL);
      await this.executeSql(store, APP_STATE_SEED_SQL);
      await this.assertProfilesSchemaVersionColumn(store);
      if (store.version !== version && store.version !== 0) {
        throw new Error(`Unsupported database version ${store.version}.`);
      }
      if (store.version !== version) {
        store.version = version;
      }
      this.initializedVersion = version;
    } catch (error) {
      this.initializePromise = undefined;
      this.initializedVersion = undefined;
      throw toDriverError(error, 'Database initialization failed.');
    }
  }

  private async assertProfilesSchemaVersionColumn(store: relationalStore.RdbStore): Promise<void> {
    const resultSet = await this.querySql(store, 'PRAGMA table_info(profiles)');
    let primaryError: Error | undefined = undefined;
    try {
      let hasSchemaVersion: boolean = false;
      while (resultSet.goToNextRow()) {
        const row = resultSet.getRow();
        if (requireStringValue(row.name, 'pragma.name') === 'schema_version') {
          hasSchemaVersion = true;
          break;
        }
      }
      if (!hasSchemaVersion) {
        throw new Error('profiles schema_version column is required.');
      }
    } catch (error) {
      primaryError = toDriverError(error, 'Profiles schema validation failed.');
      throw primaryError;
    } finally {
      this.closeResultSet(resultSet, primaryError);
    }
  }

  private async querySql(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<relationalStore.ResultSet> {
    try {
      return await store.querySql(sql, bindArgs);
    } catch (error) {
      throw toDriverError(error, 'Query execution failed.');
    }
  }

  private async executeSql(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<void> {
    try {
      await store.executeSql(sql, bindArgs);
    } catch (error) {
      throw toDriverError(error, 'Statement execution failed.');
    }
  }

  private beginTransaction(store: relationalStore.RdbStore): void {
    try {
      store.beginTransaction();
    } catch (error) {
      throw toDriverError(error, 'Transaction begin failed.');
    }
  }

  private commitTransaction(store: relationalStore.RdbStore): void {
    try {
      store.commit();
    } catch (error) {
      throw toDriverError(error, 'Transaction commit failed.');
    }
  }

  private rollbackTransaction(store: relationalStore.RdbStore, primaryError?: Error): void {
    try {
      store.rollBack();
    } catch (error) {
      if (primaryError === undefined) {
        throw toDriverError(error, 'Transaction rollback failed.');
      }
    }
  }

  private closeResultSet(resultSet: relationalStore.ResultSet, primaryError?: Error): void {
    try {
      resultSet.close();
    } catch (error) {
      if (primaryError === undefined) {
        throw toDriverError(error, 'Result set close failed.');
      }
    }
  }

  private async closeStore(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.close();
    } catch (error) {
      throw toDriverError(error, 'Database close failed.');
    }
  }
}

class HarmonyRdbTransaction implements RdbTransaction {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async getProfileRow(id: string): Promise<DurableProfileRow | undefined> {
    const resultSet = await this.store.querySql(
      `SELECT ${PROFILE_COLUMNS} FROM profiles WHERE id = ?`,
      toBindValues([id])
    );
    try {
      if (!resultSet.goToNextRow()) {
        return undefined;
      }
      return rowFromBucket(resultSet.getRow());
    } finally {
      resultSet.close();
    }
  }

  async setActiveId(activeId: string | undefined): Promise<void> {
    await this.store.executeSql(
      'INSERT OR REPLACE INTO app_state (id, active_profile_id) VALUES (?, ?)',
      upsertActiveIdBindArgs(activeId)
    );
  }

  async clearActiveIfMatching(id: string): Promise<void> {
    await this.store.executeSql(
      'UPDATE app_state SET active_profile_id = NULL WHERE id = 1 AND active_profile_id = ?',
      toBindValues([id])
    );
  }

  async deleteProfile(id: string): Promise<void> {
    await this.store.executeSql(
      'DELETE FROM profiles WHERE id = ?',
      toBindValues([id])
    );
  }
}
