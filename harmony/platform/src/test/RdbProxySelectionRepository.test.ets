import { describe, expect, it } from '@ohos/hypium';
import {
  createProfile,
  createProfileRevision,
  createProxySelectionRecord,
  type Profile,
  type ProfileRevision,
  type ProxySelectionPair,
  type ProxySelectionRecord
} from '@cmfa/shared';
import { runRdbInitialization, type HarmonyRdbInitializationOperations } from '../main/ets/rdb/HarmonyRdbDriver';
import { encodeProfileRow } from '../main/ets/rdb/ProfileRowCodec';
import { encodeProxySelectionRow } from '../main/ets/rdb/ProxySelectionRowCodec';
import { RdbProxySelectionRepository } from '../main/ets/rdb/RdbProxySelectionRepository';
import {
  assertAppErrorExactDetail,
  assertAppErrorShape,
  assertNoLeak,
  buildProfile,
  cloneDurableProxySelectionRow,
  RecordingRdbDriver
} from './fakes/PlatformFakes';
import {
  PROFILE_REFRESH_LEASE_TABLE_SPECS,
  PROFILE_TABLE_SPECS
} from '../main/ets/rdb/HarmonyRdbDriver';

const PROFILE_ID = 'proxy-profile';
const OTHER_PROFILE_ID = 'other-profile';
const GROUP_ALPHA = 'Group Alpha';
const GROUP_BETA = 'Group Beta';
const GROUP_GAMMA = 'Group Gamma';
const NODE_ALPHA = 'Node Alpha';
const NODE_BETA = 'Node Beta';
const NODE_GAMMA = 'Node Gamma';
const REVISION_ID_1 = '2026-08-07T00:00:00.000Z';
const REVISION_ID_2 = '2026-08-07T00:10:00.000Z';
const UPDATED_AT_1 = '2026-08-07T00:11:00.000Z';
const UPDATED_AT_2 = '2026-08-07T00:12:00.000Z';
const UPDATED_AT_3 = '2026-08-07T00:13:00.000Z';

class ScriptedInitializationFailure {
  readonly error: Error;

  constructor(error: Error) {
    this.error = error;
  }
}

class RecordingInitializationOperations implements HarmonyRdbInitializationOperations {
  readonly log: string[] = [];
  readonly profileRows: Map<string, string> = new Map<string, string>();
  versionValue: number;
  private profilesTableExists: boolean = false;
  private profileAutoUpdateIntervalColumnExists: boolean = false;
  private appStateTableExists: boolean = false;
  private appStateSeeded: boolean = false;
  private proxySelectionsTableExists: boolean = false;
  private profileRefreshLeasesTableExists: boolean = false;
  private readonly failures: Map<string, ScriptedInitializationFailure[]> = new Map<string, ScriptedInitializationFailure[]>();

  constructor(versionValue: number, profilesPreserved: string[] = []) {
    this.versionValue = versionValue;
    for (let index = 0; index < profilesPreserved.length; index += 1) {
      this.profileRows.set(profilesPreserved[index], `profile-row:${profilesPreserved[index]}`);
    }
  }

  currentVersion(): number {
    this.log.push(`currentVersion:${this.versionValue}`);
    return this.versionValue;
  }

  async createProfilesTable(): Promise<void> {
    this.log.push('createProfilesTable');
    this.failIfScripted('createProfilesTable');
    this.profilesTableExists = true;
    this.profileAutoUpdateIntervalColumnExists = true;
  }

  async createAppStateTable(): Promise<void> {
    this.log.push('createAppStateTable');
    this.failIfScripted('createAppStateTable');
    this.appStateTableExists = true;
  }

  async seedAppState(): Promise<void> {
    this.log.push('seedAppState');
    this.failIfScripted('seedAppState');
    if (!this.appStateTableExists) {
      throw new Error('app_state must exist before seed.');
    }
    this.appStateSeeded = true;
  }

  async createProxySelectionsTable(): Promise<void> {
    this.log.push('createProxySelectionsTable');
    this.failIfScripted('createProxySelectionsTable');
    this.proxySelectionsTableExists = true;
  }

  async ensureProfileAutoUpdateIntervalColumn(): Promise<void> {
    this.log.push('ensureProfileAutoUpdateIntervalColumn');
    this.failIfScripted('ensureProfileAutoUpdateIntervalColumn');
    if (!this.profilesTableExists) {
      throw new Error('profiles table must exist before adding auto update interval.');
    }
    this.profileAutoUpdateIntervalColumnExists = true;
  }

  async createProfileRefreshLeasesTable(): Promise<void> {
    this.log.push('createProfileRefreshLeasesTable');
    this.failIfScripted('createProfileRefreshLeasesTable');
    this.profileRefreshLeasesTableExists = true;
  }

  async validateProfilesTable(): Promise<void> {
    this.log.push('validateProfilesTable');
    this.failIfScripted('validateProfilesTable');
    if (!this.profilesTableExists) {
      throw new Error('profiles table must exist before validation.');
    }
    if (!this.profileAutoUpdateIntervalColumnExists) {
      throw new Error('profiles auto update interval column must exist before validation.');
    }
    for (const profileId of this.profileRows.keys()) {
      if (!this.profileRows.has(profileId)) {
        throw new Error('profile row is missing during validation.');
      }
    }
  }

  async validateProxySelectionsTable(): Promise<void> {
    this.log.push('validateProxySelectionsTable');
    this.failIfScripted('validateProxySelectionsTable');
    if (!this.proxySelectionsTableExists) {
      throw new Error('proxy selections table must exist before validation.');
    }
    if (!this.appStateSeeded) {
      throw new Error('app_state must be seeded before proxy validation.');
    }
  }

  async validateProfileRefreshLeasesTable(): Promise<void> {
    this.log.push('validateProfileRefreshLeasesTable');
    this.failIfScripted('validateProfileRefreshLeasesTable');
    if (!this.profileRefreshLeasesTableExists) {
      throw new Error('profile refresh leases table must exist before validation.');
    }
  }

  writeVersion(version: number): void {
    this.log.push(`writeVersion:${version}`);
    this.failIfScripted(`writeVersion:${version}`);
    this.versionValue = version;
  }

  hasProfileRow(profileId: string): boolean {
    return this.profileRows.has(profileId);
  }

  readProfileRow(profileId: string): string | undefined {
    return this.profileRows.get(profileId);
  }

  failOn(operation: string, error: Error): void {
    let queued: ScriptedInitializationFailure[] | undefined = this.failures.get(operation);
    if (queued === undefined) {
      queued = [];
      this.failures.set(operation, queued);
    }
    queued.push(new ScriptedInitializationFailure(error));
  }

  private failIfScripted(operation: string): void {
    const queued: ScriptedInitializationFailure[] | undefined = this.failures.get(operation);
    if (queued === undefined || queued.length === 0) {
      return;
    }
    const failure: ScriptedInitializationFailure | undefined = queued.shift();
    if (failure !== undefined) {
      throw failure.error;
    }
  }
}

function buildProfileWithRevision(profileId: string, revisionId: string | undefined): Profile {
  const hasRevision: boolean = revisionId !== undefined;
  let currentRevision: ProfileRevision | null = null;
  if (hasRevision) {
    const resolvedRevisionId: string = revisionId as string;
    currentRevision = createProfileRevision(
      `profiles/${profileId}/current.yaml`,
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      128,
      resolvedRevisionId
    );
  }
  return createProfile({
    id: profileId,
    name: `Profile ${profileId}`,
    sourceKind: 'LOCAL_FILE',
    sourceDisplay: `${profileId}.yaml`,
    currentRevision,
    failedCandidate: null,
    availability: hasRevision ? 'VALID' : 'INVALID',
    lastError: null,
    createdAt: '2026-08-07T00:00:00.000Z',
    updatedAt: '2026-08-07T00:05:00.000Z',
    lastSuccessfulUpdateAt: hasRevision ? '2026-08-07T00:06:00.000Z' : null
  });
}

function buildSelection(
  profileId: string,
  groupName: string,
  selectedNodeName: string,
  revisionId: string,
  updatedAt: string
): ProxySelectionRecord {
  return createProxySelectionRecord(profileId, groupName, selectedNodeName, revisionId, updatedAt);
}

function buildPair(groupName: string, selectedNodeName: string): ProxySelectionPair {
  return {
    groupName,
    selectedNodeName
  };
}

async function expectSelectionFailure(
  operation: () => Promise<void>,
  expectedDetail: string,
  forbiddenFragments: string[]
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    assertAppErrorExactDetail(error as Object, expectedDetail);
    assertNoLeak(`${(error as Error).message}`, forbiddenFragments);
  }
}

export default function rdbProxySelectionRepositoryTestsuite() {
  describe('HarmonyRdbDriverInitializationTest', () => {
    it('migratesVersionsZeroOneAndTwoToThreeAndAcceptsVersionThreeWithoutRewritingIt', 0, async () => {
      const fresh = new RecordingInitializationOperations(0);

      await runRdbInitialization(3, fresh);

      expect(fresh.versionValue).assertEqual(3);
      expect(fresh.log.join('>')).assertEqual(
        'currentVersion:0>createProfilesTable>createAppStateTable>seedAppState>createProxySelectionsTable>' +
        'createProfileRefreshLeasesTable>validateProfilesTable>validateProxySelectionsTable>' +
        'validateProfileRefreshLeasesTable>writeVersion:3'
      );

      const versionOne = new RecordingInitializationOperations(1);
      await runRdbInitialization(3, versionOne);
      expect(versionOne.versionValue).assertEqual(3);
      expect(versionOne.log.join('>')).assertEqual(
        'currentVersion:1>createProfilesTable>createAppStateTable>seedAppState>createProxySelectionsTable>' +
        'ensureProfileAutoUpdateIntervalColumn>createProfileRefreshLeasesTable>validateProfilesTable>' +
        'validateProxySelectionsTable>validateProfileRefreshLeasesTable>writeVersion:3'
      );

      const versionTwo = new RecordingInitializationOperations(2);
      await runRdbInitialization(3, versionTwo);
      expect(versionTwo.versionValue).assertEqual(3);
      expect(versionTwo.log.join('>')).assertEqual(
        'currentVersion:2>createProfilesTable>createAppStateTable>seedAppState>createProxySelectionsTable>' +
        'ensureProfileAutoUpdateIntervalColumn>createProfileRefreshLeasesTable>validateProfilesTable>' +
        'validateProxySelectionsTable>validateProfileRefreshLeasesTable>writeVersion:3'
      );

      const current = new RecordingInitializationOperations(3);
      await runRdbInitialization(3, current);
      expect(current.versionValue).assertEqual(3);
      expect(current.log.join('>')).assertEqual(
        'currentVersion:3>createProfilesTable>createAppStateTable>seedAppState>createProxySelectionsTable>' +
        'createProfileRefreshLeasesTable>validateProfilesTable>validateProxySelectionsTable>' +
        'validateProfileRefreshLeasesTable'
      );
    });

    it('rejectsUnsupportedFutureVersionsAndKeepsTheStoredVersionUntouched', 0, async () => {
      const futureOperations = new RecordingInitializationOperations(4);

      try {
        await runRdbInitialization(3, futureOperations);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`).assertContain('Unsupported database version');
      }

      expect(futureOperations.versionValue).assertEqual(4);
      expect(futureOperations.log.join('>')).assertEqual('currentVersion:4');
      expect(futureOperations.log.includes('writeVersion:3')).assertFalse();

      const negativeOperations = new RecordingInitializationOperations(-1);
      try {
        await runRdbInitialization(3, negativeOperations);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`).assertContain('Unsupported database version');
      }
      expect(negativeOperations.versionValue).assertEqual(-1);
      expect(negativeOperations.log.join('>')).assertEqual('currentVersion:-1');
    });

    it('exportsSchemaSpecsForProfileIntervalAndRefreshLeases', 0, () => {
      expect(PROFILE_TABLE_SPECS.length).assertEqual(14);
      expect(PROFILE_TABLE_SPECS[13].name).assertEqual('auto_update_interval_ms');
      expect(PROFILE_TABLE_SPECS[13].type).assertEqual('INTEGER');
      expect(PROFILE_TABLE_SPECS[13].notNull).assertEqual(1);
      expect(PROFILE_TABLE_SPECS[13].primaryKeyPosition).assertEqual(0);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS.length).assertEqual(3);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[0].name).assertEqual('profile_id');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[0].type).assertEqual('TEXT');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[0].notNull).assertEqual(1);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[0].primaryKeyPosition).assertEqual(1);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[1].name).assertEqual('owner_token');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[1].type).assertEqual('TEXT');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[1].notNull).assertEqual(1);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[1].primaryKeyPosition).assertEqual(0);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[2].name).assertEqual('expires_at');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[2].type).assertEqual('INTEGER');
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[2].notNull).assertEqual(1);
      expect(PROFILE_REFRESH_LEASE_TABLE_SPECS[2].primaryKeyPosition).assertEqual(0);
    });

    it('keepsVersionTwoOnPartialFailureAndRetryPreservesProfiles', 0, async () => {
      const operations = new RecordingInitializationOperations(2, [PROFILE_ID, OTHER_PROFILE_ID]);
      operations.failOn('validateProfileRefreshLeasesTable', new Error('synthetic lease validation failure'));

      try {
        await runRdbInitialization(3, operations);
        expect(false).assertTrue();
      } catch (error) {
        expect(`${error}`).assertContain('synthetic lease validation failure');
      }

      expect(operations.versionValue).assertEqual(2);
      expect(operations.log.includes('writeVersion:3')).assertFalse();
      expect(operations.hasProfileRow(PROFILE_ID)).assertTrue();
      expect(operations.hasProfileRow(OTHER_PROFILE_ID)).assertTrue();
      expect(operations.readProfileRow(PROFILE_ID)).assertEqual(`profile-row:${PROFILE_ID}`);
      expect(operations.readProfileRow(OTHER_PROFILE_ID)).assertEqual(`profile-row:${OTHER_PROFILE_ID}`);

      operations.log.length = 0;
      await runRdbInitialization(3, operations);

      expect(operations.versionValue).assertEqual(3);
      expect(operations.hasProfileRow(PROFILE_ID)).assertTrue();
      expect(operations.hasProfileRow(OTHER_PROFILE_ID)).assertTrue();
      expect(operations.readProfileRow(PROFILE_ID)).assertEqual(`profile-row:${PROFILE_ID}`);
      expect(operations.readProfileRow(OTHER_PROFILE_ID)).assertEqual(`profile-row:${OTHER_PROFILE_ID}`);
      expect(operations.log.join('>')).assertEqual(
        'currentVersion:2>createProfilesTable>createAppStateTable>seedAppState>createProxySelectionsTable>' +
        'ensureProfileAutoUpdateIntervalColumn>createProfileRefreshLeasesTable>validateProfilesTable>' +
        'validateProxySelectionsTable>validateProfileRefreshLeasesTable>writeVersion:3'
      );
    });
  });

  describe('RdbProxySelectionRepositoryTest', () => {
    it('listsGetsAndClonesSelectionRowsOrderedByGroupName', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_GAMMA, NODE_GAMMA, REVISION_ID_1, UPDATED_AT_3)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(OTHER_PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID_1, UPDATED_AT_2)));
      const repository = new RdbProxySelectionRepository(driver);

      const listed: ProxySelectionRecord[] = await repository.listByProfile(PROFILE_ID);
      const loaded: ProxySelectionRecord | undefined = await repository.get(PROFILE_ID, GROUP_BETA);

      expect(listed.length).assertEqual(3);
      expect(listed[0].groupName).assertEqual(GROUP_ALPHA);
      expect(listed[1].groupName).assertEqual(GROUP_BETA);
      expect(listed[2].groupName).assertEqual(GROUP_GAMMA);
      expect(loaded?.selectedNodeName).assertEqual(NODE_BETA);

      listed[0].selectedNodeName = 'Mutated Node';
      const reread: ProxySelectionRecord | undefined = await repository.get(PROFILE_ID, GROUP_ALPHA);
      expect(reread?.selectedNodeName).assertEqual(NODE_ALPHA);
    });

    it('upsertsWhenTheProfileCurrentRevisionMatchesInsideOneTransaction', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_1)));
      const repository = new RdbProxySelectionRepository(driver);

      await repository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1));

      const stored: ProxySelectionRecord | undefined = await repository.get(PROFILE_ID, GROUP_ALPHA);
      expect(stored?.revisionId).assertEqual(REVISION_ID_1);
      expect(driver.log.join('>')).assertContain(
        `begin>tx.getProfileRow:${PROFILE_ID}>tx.upsertProxySelectionRow:${PROFILE_ID}:${GROUP_ALPHA}>commit`
      );
    });

    it('rejectsMissingProfilesNullRevisionsCorruptProfilesAndRevisionMismatch', 0, async () => {
      const missingDriver = new RecordingRdbDriver();
      const missingRepository = new RdbProxySelectionRepository(missingDriver);
      await expectSelectionFailure(
        async () => {
          await missingRepository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1));
        },
        'Proxy selection save failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1]
      );
      expect(missingDriver.committedSelectionRows.size).assertEqual(0);

      const nullRevisionDriver = new RecordingRdbDriver();
      nullRevisionDriver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, undefined)));
      const nullRevisionRepository = new RdbProxySelectionRepository(nullRevisionDriver);
      await expectSelectionFailure(
        async () => {
          await nullRevisionRepository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1));
        },
        'Proxy selection save failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1]
      );
      expect(nullRevisionDriver.committedSelectionRows.size).assertEqual(0);

      const corruptDriver = new RecordingRdbDriver();
      const corruptProfileRow = encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_1));
      corruptProfileRow.currentRevisionJson = '{"validatedAt":"broken"';
      corruptDriver.seedRow(corruptProfileRow);
      const corruptRepository = new RdbProxySelectionRepository(corruptDriver);
      await expectSelectionFailure(
        async () => {
          await corruptRepository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1));
        },
        'Proxy selection save failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA]
      );

      const mismatchDriver = new RecordingRdbDriver();
      mismatchDriver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_1)));
      const mismatchRepository = new RdbProxySelectionRepository(mismatchDriver);
      await expectSelectionFailure(
        async () => {
          await mismatchRepository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_2, UPDATED_AT_1));
        },
        'Proxy selection save failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_2]
      );
      expect(mismatchDriver.committedSelectionRows.size).assertEqual(0);
    });

    it('rollsBackWriteFailuresAndRemainsReusable', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_1)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      driver.injectFailure(
        `tx.upsertProxySelectionRow:${PROFILE_ID}:${GROUP_ALPHA}`,
        new Error(`write leaked ${PROFILE_ID} ${GROUP_ALPHA} ${NODE_BETA} ${REVISION_ID_1}`)
      );
      const repository = new RdbProxySelectionRepository(driver);

      await expectSelectionFailure(
        async () => {
          await repository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_BETA, REVISION_ID_1, UPDATED_AT_2));
        },
        'Proxy selection save failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_BETA, REVISION_ID_1]
      );

      expect((await repository.get(PROFILE_ID, GROUP_ALPHA))?.selectedNodeName).assertEqual(NODE_ALPHA);
      await repository.upsert(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_BETA, REVISION_ID_1, UPDATED_AT_2));
      expect((await repository.get(PROFILE_ID, GROUP_ALPHA))?.selectedNodeName).assertEqual(NODE_BETA);
    });

    it('deletesPairsAndProfilesIdempotently', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID_1, UPDATED_AT_2)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(OTHER_PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      const repository = new RdbProxySelectionRepository(driver);

      await repository.delete(PROFILE_ID, GROUP_ALPHA);
      await repository.delete(PROFILE_ID, GROUP_ALPHA);
      await repository.deleteProfile(OTHER_PROFILE_ID);
      await repository.deleteProfile(OTHER_PROFILE_ID);

      expect((await repository.listByProfile(PROFILE_ID)).length).assertEqual(1);
      expect((await repository.get(PROFILE_ID, GROUP_ALPHA))).assertUndefined();
      expect((await repository.listByProfile(OTHER_PROFILE_ID)).length).assertEqual(0);
    });

    it('reconcilesRowsToANewRevisionWhilePreservingTimestamps', 0, async () => {
      const driver = new RecordingRdbDriver();
      driver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_2)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID_1, UPDATED_AT_2)));
      driver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      const repository = new RdbProxySelectionRepository(driver);

      await repository.reconcileProfile(PROFILE_ID, REVISION_ID_2, [buildPair(GROUP_ALPHA, NODE_ALPHA)]);

      const listed: ProxySelectionRecord[] = await repository.listByProfile(PROFILE_ID);
      expect(listed.length).assertEqual(1);
      expect(listed[0].groupName).assertEqual(GROUP_ALPHA);
      expect(listed[0].revisionId).assertEqual(REVISION_ID_2);
      expect(listed[0].updatedAt).assertEqual(UPDATED_AT_1);
      expect(driver.log.join('>')).assertContain(
        `begin>tx.getProfileRow:${PROFILE_ID}>tx.listProxySelectionRows:${PROFILE_ID}>deleteProfileSelections:${PROFILE_ID}>` +
        `tx.upsertProxySelectionRow:${PROFILE_ID}:${GROUP_ALPHA}>commit`
      );
    });

    it('rejectsReconcileRevisionMismatchDuplicatePairsAndMissingExistingRowsWithRollback', 0, async () => {
      const mismatchDriver = new RecordingRdbDriver();
      mismatchDriver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_1)));
      mismatchDriver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      const mismatchRepository = new RdbProxySelectionRepository(mismatchDriver);
      await expectSelectionFailure(
        async () => {
          await mismatchRepository.reconcileProfile(PROFILE_ID, REVISION_ID_2, [buildPair(GROUP_ALPHA, NODE_ALPHA)]);
        },
        'Proxy selection reconcile failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_2]
      );
      expect((await mismatchRepository.listByProfile(PROFILE_ID))[0].revisionId).assertEqual(REVISION_ID_1);

      const duplicateDriver = new RecordingRdbDriver();
      duplicateDriver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_2)));
      duplicateDriver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      const duplicateRepository = new RdbProxySelectionRepository(duplicateDriver);
      await expectSelectionFailure(
        async () => {
          await duplicateRepository.reconcileProfile(PROFILE_ID, REVISION_ID_2, [
            buildPair(GROUP_ALPHA, NODE_ALPHA),
            buildPair(GROUP_ALPHA, NODE_ALPHA)
          ]);
        },
        'Proxy selection reconcile failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_2]
      );
      expect((await duplicateRepository.listByProfile(PROFILE_ID)).length).assertEqual(1);

      const missingRowDriver = new RecordingRdbDriver();
      missingRowDriver.seedRow(encodeProfileRow(buildProfileWithRevision(PROFILE_ID, REVISION_ID_2)));
      missingRowDriver.seedSelectionRow(encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1)));
      const missingRowRepository = new RdbProxySelectionRepository(missingRowDriver);
      await expectSelectionFailure(
        async () => {
          await missingRowRepository.reconcileProfile(PROFILE_ID, REVISION_ID_2, [buildPair(GROUP_BETA, NODE_BETA)]);
        },
        'Proxy selection reconcile failed.',
        [PROFILE_ID, GROUP_BETA, NODE_BETA, REVISION_ID_2]
      );
      expect((await missingRowRepository.listByProfile(PROFILE_ID)).length).assertEqual(1);
    });

    it('sanitizesDriverAndDecodeFailuresWithoutLeakingSelectionValues', 0, async () => {
      const driverFailure = new RecordingRdbDriver();
      driverFailure.injectFailure(
        `listProxySelectionRows:${PROFILE_ID}`,
        new Error(`driver leaked ${PROFILE_ID} ${GROUP_ALPHA} ${NODE_ALPHA} ${REVISION_ID_1}`)
      );
      const failureRepository = new RdbProxySelectionRepository(driverFailure);
      await expectSelectionFailure(
        async () => {
          await failureRepository.listByProfile(PROFILE_ID);
        },
        'Proxy selection list failed.',
        [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1]
      );

      const decodeDriver = new RecordingRdbDriver();
      const corruptRow = cloneDurableProxySelectionRow(
        encodeProxySelectionRow(buildSelection(PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, UPDATED_AT_1))
      );
      corruptRow.updatedAt = 'not-a-timestamp';
      decodeDriver.seedSelectionRow(corruptRow);
      const decodeRepository = new RdbProxySelectionRepository(decodeDriver);
      try {
        await decodeRepository.listByProfile(PROFILE_ID);
        expect(false).assertTrue();
      } catch (error) {
        assertAppErrorShape(error as Object, 'Proxy selection list failed.');
        assertNoLeak(`${(error as Error).message}`, [PROFILE_ID, GROUP_ALPHA, NODE_ALPHA, REVISION_ID_1, 'not-a-timestamp']);
      }
    });
  });
}
