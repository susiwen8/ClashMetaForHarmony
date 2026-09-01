import { relationalStore } from '@kit.ArkData';
import common from '@ohos.app.ability.common';
import type { DurableProfileRow, DurableProxySelectionRow, RdbDriver, RdbTransaction } from './RdbDriver';

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
  'last_success_at TEXT,' +
  'auto_update_interval_ms INTEGER NOT NULL DEFAULT 0' +
  ')';
const APP_STATE_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS app_state (' +
  'id INTEGER PRIMARY KEY CHECK (id = 1),' +
  'active_profile_id TEXT' +
  ')';
const PROXY_SELECTIONS_TABLE = 'proxy_selections';
const PROXY_SELECTIONS_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS ' + PROXY_SELECTIONS_TABLE + ' (' +
  'profile_id TEXT NOT NULL,' +
  'group_name TEXT NOT NULL,' +
  'selected_node_name TEXT NOT NULL,' +
  'revision_id TEXT NOT NULL,' +
  'updated_at TEXT NOT NULL,' +
  'PRIMARY KEY (profile_id, group_name)' +
  ')';
const PROFILE_REFRESH_LEASES_TABLE = 'profile_refresh_leases';
const PROFILE_REFRESH_LEASES_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS ' + PROFILE_REFRESH_LEASES_TABLE + ' (' +
  'profile_id TEXT PRIMARY KEY NOT NULL,' +
  'owner_token TEXT NOT NULL,' +
  'expires_at INTEGER NOT NULL' +
  ')';
const PROFILE_AUTO_UPDATE_INTERVAL_COLUMN = 'auto_update_interval_ms';
const PROFILE_AUTO_UPDATE_INTERVAL_SQL =
  'ALTER TABLE profiles ADD COLUMN auto_update_interval_ms INTEGER NOT NULL DEFAULT 0';
const APP_STATE_SEED_SQL = 'INSERT OR IGNORE INTO app_state (id, active_profile_id) VALUES (1, NULL)';
const PROFILE_COLUMNS =
  'schema_version, id, name, source_kind, source_display, source_secret_ref, current_revision_json, failed_candidate_json, availability, last_error_json, created_at, updated_at, last_success_at, auto_update_interval_ms';
const PROXY_SELECTION_COLUMNS =
  'profile_id, group_name, selected_node_name, revision_id, updated_at';

export class TableColumnSpec {
  readonly name: string;
  readonly type: string;
  readonly notNull: number;
  readonly primaryKeyPosition: number;

  constructor(name: string, type: string, notNull: number, primaryKeyPosition: number) {
    this.name = name;
    this.type = type;
    this.notNull = notNull;
    this.primaryKeyPosition = primaryKeyPosition;
  }
}

export const PROFILE_TABLE_SPECS: TableColumnSpec[] = [
  new TableColumnSpec('schema_version', 'INTEGER', 1, 0),
  new TableColumnSpec('id', 'TEXT', 1, 1),
  new TableColumnSpec('name', 'TEXT', 1, 0),
  new TableColumnSpec('source_kind', 'TEXT', 1, 0),
  new TableColumnSpec('source_display', 'TEXT', 1, 0),
  new TableColumnSpec('source_secret_ref', 'TEXT', 0, 0),
  new TableColumnSpec('current_revision_json', 'TEXT', 0, 0),
  new TableColumnSpec('failed_candidate_json', 'TEXT', 0, 0),
  new TableColumnSpec('availability', 'TEXT', 1, 0),
  new TableColumnSpec('last_error_json', 'TEXT', 0, 0),
  new TableColumnSpec('created_at', 'TEXT', 1, 0),
  new TableColumnSpec('updated_at', 'TEXT', 1, 0),
  new TableColumnSpec('last_success_at', 'TEXT', 0, 0),
  new TableColumnSpec('auto_update_interval_ms', 'INTEGER', 1, 0)
];

const PROXY_SELECTION_TABLE_SPECS: TableColumnSpec[] = [
  new TableColumnSpec('profile_id', 'TEXT', 1, 1),
  new TableColumnSpec('group_name', 'TEXT', 1, 2),
  new TableColumnSpec('selected_node_name', 'TEXT', 1, 0),
  new TableColumnSpec('revision_id', 'TEXT', 1, 0),
  new TableColumnSpec('updated_at', 'TEXT', 1, 0)
];
export const PROFILE_REFRESH_LEASE_TABLE_SPECS: TableColumnSpec[] = [
  new TableColumnSpec('profile_id', 'TEXT', 1, 1),
  new TableColumnSpec('owner_token', 'TEXT', 1, 0),
  new TableColumnSpec('expires_at', 'INTEGER', 1, 0)
];

export interface HarmonyRdbInitializationOperations {
  currentVersion(): number;
  createProfilesTable(): Promise<void>;
  createAppStateTable(): Promise<void>;
  seedAppState(): Promise<void>;
  createProxySelectionsTable(): Promise<void>;
  ensureProfileAutoUpdateIntervalColumn(): Promise<void>;
  createProfileRefreshLeasesTable(): Promise<void>;
  validateProfilesTable(): Promise<void>;
  validateProxySelectionsTable(): Promise<void>;
  validateProfileRefreshLeasesTable(): Promise<void>;
  writeVersion(version: number): void;
}

function isSupportedSchemaVersion(version: number): boolean {
  return version === 0 || version === 1 || version === 2 || version === 3;
}

export async function runRdbInitialization(
  version: number,
  operations: HarmonyRdbInitializationOperations
): Promise<void> {
  if (!isSupportedSchemaVersion(version)) {
    throw new Error(`Unsupported database version ${version}.`);
  }
  const currentVersion: number = operations.currentVersion();
  if (!isSupportedSchemaVersion(currentVersion)) {
    throw new Error(`Unsupported database version ${currentVersion}.`);
  }
  await operations.createProfilesTable();
  await operations.createAppStateTable();
  await operations.seedAppState();
  await operations.createProxySelectionsTable();
  if (currentVersion === 1 || currentVersion === 2) {
    await operations.ensureProfileAutoUpdateIntervalColumn();
  }
  await operations.createProfileRefreshLeasesTable();
  await operations.validateProfilesTable();
  await operations.validateProxySelectionsTable();
  await operations.validateProfileRefreshLeasesTable();
  if (currentVersion !== version) {
    operations.writeVersion(version);
  }
}

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
    lastSuccessfulUpdateAt: requireNullableStringValue(bucket.last_success_at, 'profiles.last_success_at'),
    autoUpdateIntervalMs: requireNumberValue(bucket.auto_update_interval_ms, 'profiles.auto_update_interval_ms')
  };
}

function proxySelectionRowFromBucket(bucket: RelationalValuesBucket): DurableProxySelectionRow {
  return {
    profileId: requireStringValue(bucket.profile_id, 'proxy_selections.profile_id'),
    groupName: requireStringValue(bucket.group_name, 'proxy_selections.group_name'),
    selectedNodeName: requireStringValue(bucket.selected_node_name, 'proxy_selections.selected_node_name'),
    revisionId: requireStringValue(bucket.revision_id, 'proxy_selections.revision_id'),
    updatedAt: requireStringValue(bucket.updated_at, 'proxy_selections.updated_at')
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
  values.push(row.autoUpdateIntervalMs ?? 0);
  return values;
}

function bindProxySelectionRow(row: DurableProxySelectionRow): Array<RelationalValueType> {
  return [
    row.profileId,
    row.groupName,
    row.selectedNodeName,
    row.revisionId,
    row.updatedAt
  ];
}

function upsertActiveIdBindArgs(activeId: string | undefined): Array<RelationalValueType> {
  const values: Array<RelationalValueType> = [1];
  appendBindValue(values, activeId);
  return values;
}

async function querySqlWithSafeFallback(
  store: relationalStore.RdbStore,
  sql: string,
  bindArgs: Array<RelationalValueType> | undefined,
  fallback: string
): Promise<relationalStore.ResultSet> {
  try {
    return await store.querySql(sql, bindArgs);
  } catch (error) {
    return await Promise.reject(toDriverError(error, fallback));
  }
}

async function executeSqlWithSafeFallback(
  store: relationalStore.RdbStore,
  sql: string,
  bindArgs: Array<RelationalValueType> | undefined,
  fallback: string
): Promise<void> {
  try {
    await store.executeSql(sql, bindArgs);
  } catch (error) {
    return await Promise.reject(toDriverError(error, fallback));
  }
}

function advanceResultSetWithSafeFallback(
  resultSet: relationalStore.ResultSet,
  fallback: string
): boolean {
  try {
    return resultSet.goToNextRow();
  } catch (error) {
    throw toDriverError(error, fallback);
  }
}

function readResultSetRowWithSafeFallback(
  resultSet: relationalStore.ResultSet,
  fallback: string
): RelationalValuesBucket {
  try {
    return resultSet.getRow();
  } catch (error) {
    throw toDriverError(error, fallback);
  }
}

function closeResultSetWithSafeFallback(
  resultSet: relationalStore.ResultSet,
  primaryError: Error | undefined,
  fallback: string
): void {
  try {
    resultSet.close();
  } catch (error) {
    if (primaryError === undefined) {
      throw toDriverError(error, fallback);
    }
  }
}

export class HarmonyRdbDriver implements RdbDriver {
  private readonly context: common.BaseContext;
  private readonly databaseName: string;
  private store?: relationalStore.RdbStore;
  private storePromise?: Promise<relationalStore.RdbStore>;
  private initializedVersion?: number;
  private initializePromise?: Promise<void>;
  private closePromise?: Promise<void>;
  private closing: boolean = false;
  private closed: boolean = false;

  constructor(context: common.BaseContext, databaseName: string = 'cmfa_profiles.db') {
    this.context = context;
    this.databaseName = databaseName;
  }

  async initialize(_version: number): Promise<void> {
    this.throwIfClosingOrClosed();
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
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      bindRow(_row)
    );
  }

  async listProxySelectionRows(profileId: string): Promise<DurableProxySelectionRow[]> {
    const store = await this.getStore();
    return await this.queryProxySelectionRows(
      store,
      `SELECT ${PROXY_SELECTION_COLUMNS} FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ? ORDER BY group_name ASC`,
      [profileId]
    );
  }

  async getProxySelectionRow(profileId: string, groupName: string): Promise<DurableProxySelectionRow | undefined> {
    const store = await this.getStore();
    const rows = await this.queryProxySelectionRows(
      store,
      `SELECT ${PROXY_SELECTION_COLUMNS} FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ? AND group_name = ?`,
      [profileId, groupName]
    );
    return rows.length === 0 ? undefined : rows[0];
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
    if (this.closePromise !== undefined) {
      await this.closePromise;
      return;
    }
    if (this.closed) {
      return;
    }
    this.closing = true;
    const closePromise = this.runClose();
    this.closePromise = closePromise;
    await closePromise;
  }

  private async getStore(): Promise<relationalStore.RdbStore> {
    this.throwIfClosingOrClosed();
    if (this.store !== undefined) {
      return this.store;
    }
    if (this.storePromise !== undefined) {
      return await this.storePromise;
    }
    let acquisition: Promise<relationalStore.RdbStore>;
    try {
      acquisition = relationalStore.getRdbStore(this.context, {
        name: this.databaseName,
        securityLevel: relationalStore.SecurityLevel.S1
      });
    } catch (error) {
      return await Promise.reject(toDriverError(error, 'Database open failed.'));
    }
    this.storePromise = acquisition;
    try {
      const store = await acquisition;
      if (this.closing || this.closed) {
        throw toDriverError(undefined, 'Driver is closing.');
      }
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

  private async queryProxySelectionRows(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<DurableProxySelectionRow[]> {
    const resultSet = await this.querySql(store, sql, bindArgs);
    let primaryError: Error | undefined = undefined;
    try {
      const rows: DurableProxySelectionRow[] = [];
      while (resultSet.goToNextRow()) {
        rows.push(proxySelectionRowFromBucket(resultSet.getRow()));
      }
      return rows;
    } catch (error) {
      primaryError = toDriverError(error, 'Proxy selection row query failed.');
      throw primaryError;
    } finally {
      this.closeResultSet(resultSet, primaryError);
    }
  }

  private async runInitialize(version: number): Promise<void> {
    try {
      const store = await this.getStore();
      await runRdbInitialization(version, this.createInitializationOperations(store));
      this.initializedVersion = version;
    } catch (error) {
      this.initializePromise = undefined;
      this.initializedVersion = undefined;
      throw toDriverError(error, 'Database initialization failed.');
    }
  }

  private async runClose(): Promise<void> {
    let primaryError: Error | undefined = undefined;
    const pendingInitialize: Promise<void> | undefined = this.initializePromise;
    const pendingStore: Promise<relationalStore.RdbStore> | undefined = this.storePromise;
    let acquiredStore: relationalStore.RdbStore | undefined = undefined;
    try {
      if (pendingInitialize !== undefined) {
        try {
          await pendingInitialize;
        } catch (_) {
        }
      }
      if (pendingStore !== undefined) {
        try {
          acquiredStore = await pendingStore;
        } catch (_) {
        }
      }

      const storeToClose: relationalStore.RdbStore | undefined = this.store ?? acquiredStore;
      this.store = undefined;
      this.storePromise = undefined;
      this.initializePromise = undefined;
      this.initializedVersion = undefined;
      if (storeToClose !== undefined) {
        await this.closeStore(storeToClose);
      }
    } catch (error) {
      primaryError = error instanceof Error ? error : new Error(`${error}`);
      throw primaryError;
    } finally {
      this.store = undefined;
      this.storePromise = undefined;
      this.initializePromise = undefined;
      this.initializedVersion = undefined;
      this.closing = false;
      this.closed = true;
      if (primaryError === undefined) {
        this.closePromise = Promise.resolve();
      }
    }
  }

  private createInitializationOperations(store: relationalStore.RdbStore): HarmonyRdbInitializationOperations {
    return new HarmonyRdbStoreInitializationOperations(this, store);
  }

  async assertTableSchema(
    store: relationalStore.RdbStore,
    tableName: string,
    expectedColumns: TableColumnSpec[],
    fallback: string
  ): Promise<void> {
    const resultSet = await this.querySql(store, `PRAGMA table_info(${tableName})`);
    let primaryError: Error | undefined = undefined;
    try {
      const observedColumns: TableColumnSpec[] = [];
      while (resultSet.goToNextRow()) {
        const row = resultSet.getRow();
        observedColumns.push(new TableColumnSpec(
          requireStringValue(row.name, `${tableName}.pragma.name`),
          requireStringValue(row.type, `${tableName}.pragma.type`),
          requireNumberValue(row.notnull, `${tableName}.pragma.notnull`),
          requireNumberValue(row.pk, `${tableName}.pragma.pk`)
        ));
      }
      if (observedColumns.length !== expectedColumns.length) {
        throw new Error(`${tableName} column count mismatch.`);
      }
      for (let index = 0; index < expectedColumns.length; index += 1) {
        const expected: TableColumnSpec = expectedColumns[index];
        const observed: TableColumnSpec = observedColumns[index];
        if (
          observed.name !== expected.name ||
          observed.type !== expected.type ||
          observed.notNull !== expected.notNull ||
          observed.primaryKeyPosition !== expected.primaryKeyPosition
        ) {
          throw new Error(`${tableName} column mismatch.`);
        }
      }
    } catch (error) {
      primaryError = toDriverError(error, fallback);
      throw primaryError;
    } finally {
      this.closeResultSet(resultSet, primaryError);
    }
  }

  async tableHasColumn(
    store: relationalStore.RdbStore,
    tableName: string,
    columnName: string,
    fallback: string
  ): Promise<boolean> {
    const resultSet = await this.querySql(store, `PRAGMA table_info(${tableName})`);
    let primaryError: Error | undefined = undefined;
    try {
      while (resultSet.goToNextRow()) {
        const row = resultSet.getRow();
        if (requireStringValue(row.name, `${tableName}.pragma.name`) === columnName) {
          return true;
        }
      }
      return false;
    } catch (error) {
      primaryError = toDriverError(error, fallback);
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
    return await querySqlWithSafeFallback(store, sql, bindArgs, 'Query execution failed.');
  }

  async executeSql(
    store: relationalStore.RdbStore,
    sql: string,
    bindArgs?: Array<RelationalValueType>
  ): Promise<void> {
    await executeSqlWithSafeFallback(store, sql, bindArgs, 'Statement execution failed.');
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

  private throwIfClosingOrClosed(): void {
    if (this.closing || this.closed) {
      throw toDriverError(undefined, this.closed ? 'Driver is closed.' : 'Driver is closing.');
    }
  }
}

class HarmonyRdbStoreInitializationOperations implements HarmonyRdbInitializationOperations {
  private readonly driver: HarmonyRdbDriver;
  private readonly store: relationalStore.RdbStore;

  constructor(driver: HarmonyRdbDriver, store: relationalStore.RdbStore) {
    this.driver = driver;
    this.store = store;
  }

  currentVersion(): number {
    return this.store.version;
  }

  async createProfilesTable(): Promise<void> {
    await this.driver.executeSql(this.store, PROFILES_TABLE_SQL);
  }

  async createAppStateTable(): Promise<void> {
    await this.driver.executeSql(this.store, APP_STATE_TABLE_SQL);
  }

  async seedAppState(): Promise<void> {
    await this.driver.executeSql(this.store, APP_STATE_SEED_SQL);
  }

  async createProxySelectionsTable(): Promise<void> {
    await this.driver.executeSql(this.store, PROXY_SELECTIONS_TABLE_SQL);
  }

  async ensureProfileAutoUpdateIntervalColumn(): Promise<void> {
    const columnExists = await this.driver.tableHasColumn(
      this.store,
      'profiles',
      PROFILE_AUTO_UPDATE_INTERVAL_COLUMN,
      'Profiles schema probe failed.'
    );
    if (columnExists) {
      return;
    }
    await this.driver.executeSql(this.store, PROFILE_AUTO_UPDATE_INTERVAL_SQL);
  }

  async createProfileRefreshLeasesTable(): Promise<void> {
    await this.driver.executeSql(this.store, PROFILE_REFRESH_LEASES_TABLE_SQL);
  }

  async validateProfilesTable(): Promise<void> {
    await this.driver.assertTableSchema(this.store, 'profiles', PROFILE_TABLE_SPECS, 'Profiles schema validation failed.');
  }

  async validateProxySelectionsTable(): Promise<void> {
    await this.driver.assertTableSchema(
      this.store,
      PROXY_SELECTIONS_TABLE,
      PROXY_SELECTION_TABLE_SPECS,
      'Proxy selections schema validation failed.'
    );
  }

  async validateProfileRefreshLeasesTable(): Promise<void> {
    await this.driver.assertTableSchema(
      this.store,
      PROFILE_REFRESH_LEASES_TABLE,
      PROFILE_REFRESH_LEASE_TABLE_SPECS,
      'Profile refresh leases schema validation failed.'
    );
  }

  writeVersion(version: number): void {
    this.store.version = version;
  }
}

class HarmonyRdbTransaction implements RdbTransaction {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async getProfileRow(id: string): Promise<DurableProfileRow | undefined> {
    const resultSet = await querySqlWithSafeFallback(
      this.store,
      `SELECT ${PROFILE_COLUMNS} FROM profiles WHERE id = ?`,
      toBindValues([id]),
      'Transaction profile lookup failed.'
    );
    let primaryError: Error | undefined = undefined;
    try {
      if (!advanceResultSetWithSafeFallback(resultSet, 'Transaction profile lookup failed.')) {
        return undefined;
      }
      return rowFromBucket(readResultSetRowWithSafeFallback(resultSet, 'Transaction profile lookup failed.'));
    } catch (error) {
      primaryError = error instanceof Error ? error : new Error(`${error}`);
      throw primaryError;
    } finally {
      closeResultSetWithSafeFallback(resultSet, primaryError, 'Transaction result set close failed.');
    }
  }

  async listProxySelectionRows(profileId: string): Promise<DurableProxySelectionRow[]> {
    const resultSet = await querySqlWithSafeFallback(
      this.store,
      `SELECT ${PROXY_SELECTION_COLUMNS} FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ? ORDER BY group_name ASC`,
      toBindValues([profileId]),
      'Transaction proxy selection list failed.'
    );
    let primaryError: Error | undefined = undefined;
    try {
      const rows: DurableProxySelectionRow[] = [];
      while (advanceResultSetWithSafeFallback(resultSet, 'Transaction proxy selection list failed.')) {
        rows.push(proxySelectionRowFromBucket(
          readResultSetRowWithSafeFallback(resultSet, 'Transaction proxy selection list failed.')
        ));
      }
      return rows;
    } catch (error) {
      primaryError = error instanceof Error ? error : new Error(`${error}`);
      throw primaryError;
    } finally {
      closeResultSetWithSafeFallback(resultSet, primaryError, 'Transaction result set close failed.');
    }
  }

  async getProxySelectionRow(profileId: string, groupName: string): Promise<DurableProxySelectionRow | undefined> {
    const resultSet = await querySqlWithSafeFallback(
      this.store,
      `SELECT ${PROXY_SELECTION_COLUMNS} FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ? AND group_name = ?`,
      toBindValues([profileId, groupName]),
      'Transaction proxy selection lookup failed.'
    );
    let primaryError: Error | undefined = undefined;
    try {
      if (!advanceResultSetWithSafeFallback(resultSet, 'Transaction proxy selection lookup failed.')) {
        return undefined;
      }
      return proxySelectionRowFromBucket(
        readResultSetRowWithSafeFallback(resultSet, 'Transaction proxy selection lookup failed.')
      );
    } catch (error) {
      primaryError = error instanceof Error ? error : new Error(`${error}`);
      throw primaryError;
    } finally {
      closeResultSetWithSafeFallback(resultSet, primaryError, 'Transaction result set close failed.');
    }
  }

  async upsertProxySelectionRow(row: DurableProxySelectionRow): Promise<void> {
    await executeSqlWithSafeFallback(
      this.store,
      'INSERT OR REPLACE INTO ' + PROXY_SELECTIONS_TABLE + ' (' +
      PROXY_SELECTION_COLUMNS +
      ') VALUES (?, ?, ?, ?, ?)',
      bindProxySelectionRow(row),
      'Transaction proxy selection write failed.'
    );
  }

  async deleteProxySelection(profileId: string, groupName: string): Promise<void> {
    await executeSqlWithSafeFallback(
      this.store,
      `DELETE FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ? AND group_name = ?`,
      toBindValues([profileId, groupName]),
      'Transaction proxy selection delete failed.'
    );
  }

  async deleteProfileSelections(profileId: string): Promise<void> {
    await executeSqlWithSafeFallback(
      this.store,
      `DELETE FROM ${PROXY_SELECTIONS_TABLE} WHERE profile_id = ?`,
      toBindValues([profileId]),
      'Transaction profile selection delete failed.'
    );
  }

  async setActiveId(activeId: string | undefined): Promise<void> {
    await executeSqlWithSafeFallback(
      this.store,
      'INSERT OR REPLACE INTO app_state (id, active_profile_id) VALUES (?, ?)',
      upsertActiveIdBindArgs(activeId),
      'Transaction active-id write failed.'
    );
  }

  async clearActiveIfMatching(id: string): Promise<void> {
    await executeSqlWithSafeFallback(
      this.store,
      'UPDATE app_state SET active_profile_id = NULL WHERE id = 1 AND active_profile_id = ?',
      toBindValues([id]),
      'Transaction active-id clear failed.'
    );
  }

  async deleteProfile(id: string): Promise<void> {
    await this.deleteProfileSelections(id);
    await executeSqlWithSafeFallback(
      this.store,
      'DELETE FROM profiles WHERE id = ?',
      toBindValues([id]),
      'Transaction profile delete failed.'
    );
  }
}
