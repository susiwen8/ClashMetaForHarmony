import { relationalStore } from '@kit.ArkData';
import common from '@ohos.app.ability.common';
import type { DurableProfileRow, RdbDriver, RdbTransaction } from './RdbDriver';

type RelationalValueType = relationalStore.ValueType;
type RelationalValuesBucket = relationalStore.ValuesBucket;

const PROFILES_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS profiles (' +
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
  'id, name, source_kind, source_display, source_secret_ref, current_revision_json, failed_candidate_json, availability, last_error_json, created_at, updated_at, last_success_at';

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

function toBindValues(values: Array<RelationalValueType>): Array<RelationalValueType> {
  return values;
}

function rowFromBucket(bucket: RelationalValuesBucket): DurableProfileRow {
  return {
    schemaVersion: 1,
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
  return [
    row.id,
    row.name,
    row.sourceKind,
    row.sourceDisplay,
    row.sourceSecretRef ?? null,
    row.currentRevisionJson,
    row.failedCandidateJson,
    row.availability,
    row.lastErrorJson,
    row.createdAt,
    row.updatedAt,
    row.lastSuccessfulUpdateAt
  ];
}

export class HarmonyRdbDriver implements RdbDriver {
  private readonly context: common.BaseContext;
  private readonly databaseName: string;
  private store?: relationalStore.RdbStore;
  private initializedVersion?: number;

  constructor(context: common.BaseContext, databaseName: string = 'cmfa_profiles.db') {
    this.context = context;
    this.databaseName = databaseName;
  }

  async initialize(_version: number): Promise<void> {
    if (this.initializedVersion === _version) {
      return;
    }
    const store = await this.getStore();
    await store.executeSql(PROFILES_TABLE_SQL);
    await store.executeSql(APP_STATE_TABLE_SQL);
    await store.executeSql(APP_STATE_SEED_SQL);
    if (store.version !== _version && store.version !== 0) {
      throw new Error(`Unsupported database version ${store.version}.`);
    }
    if (store.version !== _version) {
      store.version = _version;
    }
    this.initializedVersion = _version;
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
    await store.executeSql(
      'INSERT OR REPLACE INTO profiles (' +
      PROFILE_COLUMNS +
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      bindRow(_row)
    );
  }

  async readActiveId(): Promise<string | undefined> {
    const store = await this.getStore();
    const resultSet = await store.querySql(
      'SELECT active_profile_id FROM app_state WHERE id = 1'
    );
    try {
      if (!resultSet.goToNextRow()) {
        return undefined;
      }
      const row = resultSet.getRow();
      const activeId = requireNullableStringValue(row.active_profile_id, 'app_state.active_profile_id');
      return activeId ?? undefined;
    } finally {
      resultSet.close();
    }
  }

  async transaction<T>(_block: (transaction: RdbTransaction) => Promise<T>): Promise<T> {
    const store = await this.getStore();
    store.beginTransaction();
    const transaction = new HarmonyRdbTransaction(store);
    try {
      const result = await _block(transaction);
      store.commit();
      return result;
    } catch (error) {
      try {
        store.rollBack();
      } catch (_) {
      }
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
    this.initializedVersion = undefined;
    await store.close();
  }

  private async getStore(): Promise<relationalStore.RdbStore> {
    if (this.store !== undefined) {
      return this.store;
    }
    this.store = await relationalStore.getRdbStore(this.context, {
      name: this.databaseName,
      securityLevel: relationalStore.SecurityLevel.S1
    });
    return this.store;
  }

  private async queryRows(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<DurableProfileRow[]> {
    const resultSet = await store.querySql(sql, bindArgs);
    try {
      const rows: DurableProfileRow[] = [];
      while (resultSet.goToNextRow()) {
        rows.push(rowFromBucket(resultSet.getRow()));
      }
      return rows;
    } finally {
      resultSet.close();
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
      'UPDATE app_state SET active_profile_id = ? WHERE id = 1',
      toBindValues([activeId ?? null])
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
