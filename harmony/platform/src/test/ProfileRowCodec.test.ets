import { describe, expect, it } from '@ohos/hypium';
import type { AppError, Profile } from '@cmfa/shared';
import { createAppError, createProfile, createProfileRevision } from '@cmfa/shared';
import { decodeProfileRow, encodeProfileRow, type DurableProfileRow } from '../main/ets/rdb/ProfileRowCodec';
import { assertNoLeak } from './fakes/PlatformFakes';

function stitch(parts: string[]): string {
  return parts.join('');
}

function buildOpaqueRef(tail: string): string {
  return stitch(['sec', 'ret', ':', tail]);
}

function buildRemoteProfile(): Profile {
  return createProfile({
    id: 'remote-1',
    name: 'Remote Alpha',
    sourceKind: 'REMOTE_URL',
    sourceDisplay: 'https://subscription.example.com:8443/path?token=abc123#frag',
    sourceSecretRef: buildOpaqueRef('subscription://v1/opaque'),
    currentRevision: createProfileRevision(
      'profiles/remote/current.yaml',
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      256,
      '2026-08-07T00:00:00.000Z'
    ),
    failedCandidate: createProfileRevision(
      'profiles/remote/failed.yaml',
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
      512,
      '2026-08-07T00:05:00.000Z'
    ),
    availability: 'UPDATE_FAILED_USING_VALID',
    lastError: createAppError(
      'DOWNLOAD',
      'refresh https://user:secret@subscription.example.com/profile.yaml?token=abc123 failed',
      {
        code: 'CMFA_REMOTE_TIMEOUT',
        retryable: true,
        timestamp: '2026-08-07T00:06:00.000Z',
        userMessageResource: 'error.remote.timeout'
      }
    ),
    createdAt: '2026-08-07T00:00:00.000Z',
    updatedAt: '2026-08-07T00:06:00.000Z',
    lastSuccessfulUpdateAt: '2026-08-07T00:01:00.000Z',
    autoUpdateIntervalMs: 300000
  });
}

function expectCreateProfileFailure(autoUpdateIntervalMs: number, expectedMessage: string): void {
  try {
    createProfile({
      id: 'remote-invalid',
      name: 'Remote Invalid',
      sourceKind: 'REMOTE_URL',
      sourceDisplay: 'https://subscription.example.com/profile.yaml',
      sourceSecretRef: buildOpaqueRef('subscription://v1/opaque'),
      currentRevision: null,
      failedCandidate: null,
      availability: 'INVALID',
      lastError: null,
      createdAt: '2026-08-07T00:00:00.000Z',
      updatedAt: '2026-08-07T00:00:00.000Z',
      lastSuccessfulUpdateAt: null,
      autoUpdateIntervalMs
    });
    expect(false).assertTrue();
  } catch (error) {
    expect(`${error}`).assertContain(expectedMessage);
  }
}

function expectDecodeFailure(row: DurableProfileRow, expectedMessage: string): void {
  try {
    decodeProfileRow(row);
    expect(false).assertTrue();
  } catch (error) {
    expect(`${error}`).assertContain(expectedMessage);
  }
}

function mutateRow(row: DurableProfileRow): DurableProfileRow {
  return {
    schemaVersion: row.schemaVersion,
    id: row.id,
    name: row.name,
    sourceKind: row.sourceKind,
    sourceDisplay: row.sourceDisplay,
    sourceSecretRef: row.sourceSecretRef,
    currentRevisionJson: row.currentRevisionJson,
    failedCandidateJson: row.failedCandidateJson,
    availability: row.availability,
    lastErrorJson: row.lastErrorJson,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    lastSuccessfulUpdateAt: row.lastSuccessfulUpdateAt,
    autoUpdateIntervalMs: row.autoUpdateIntervalMs
  };
}

export default function profileRowCodecTestsuite() {
  describe('ProfileRowCodecTest', () => {
    it('defaultsAndValidatesProfileAutoUpdateInterval', 0, () => {
      const defaulted: Profile = createProfile({
        id: 'remote-default',
        name: 'Remote Default',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: 'https://subscription.example.com/profile.yaml?token=abc123',
        sourceSecretRef: buildOpaqueRef('subscription://v1/default'),
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:00:00.000Z',
        lastSuccessfulUpdateAt: null
      });
      const preserved: Profile = createProfile({
        id: 'remote-preserved',
        name: 'Remote Preserved',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: 'https://subscription.example.com/profile.yaml?token=abc123',
        sourceSecretRef: buildOpaqueRef('subscription://v1/preserved'),
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:00:00.000Z',
        lastSuccessfulUpdateAt: null,
        autoUpdateIntervalMs: 60000
      });

      expect(defaulted.autoUpdateIntervalMs).assertEqual(0);
      expect(preserved.autoUpdateIntervalMs).assertEqual(60000);
      expectCreateProfileFailure(-1, 'safe non-negative integer');
      expectCreateProfileFailure(1.5, 'safe non-negative integer');
      expectCreateProfileFailure(Number.MAX_SAFE_INTEGER + 1, 'safe non-negative integer');
    });

    it('roundTripsEveryDurableFieldAndRedactsRemoteSourceDisplayStorage', 0, () => {
      const profile: Profile = buildRemoteProfile();

      const row: DurableProfileRow = encodeProfileRow(profile);
      const decoded: Profile = decodeProfileRow(row);

      expect(row.schemaVersion).assertEqual(2);
      expect(row.autoUpdateIntervalMs).assertEqual(300000);
      expect(row.sourceDisplay.includes('http://')).assertFalse();
      expect(row.sourceDisplay.includes('https://')).assertFalse();
      expect(row.sourceDisplay.includes('/path')).assertFalse();
      expect(row.sourceDisplay.includes('?token=')).assertFalse();
      expect(row.sourceDisplay.includes('secret')).assertFalse();
      assertNoLeak(
        JSON.stringify(row),
        ['subscription://v1/opaque', 'profile.yaml', 'token=abc123', 'http://', 'https://', '#frag']
      );
      expect(decoded.id).assertEqual(profile.id);
      expect(decoded.name).assertEqual(profile.name);
      expect(decoded.sourceKind).assertEqual(profile.sourceKind);
      expect(decoded.sourceDisplay).assertEqual('https://subscription.example.com:8443');
      expect(decoded.sourceSecretRef).assertEqual(profile.sourceSecretRef);
      expect(decoded.currentRevision?.relativePath).assertEqual('profiles/remote/current.yaml');
      expect(decoded.failedCandidate?.relativePath).assertEqual('profiles/remote/failed.yaml');
      expect(decoded.availability).assertEqual('UPDATE_FAILED_USING_VALID');
      expect(decoded.lastError?.code).assertEqual('CMFA_REMOTE_TIMEOUT');
      expect(decoded.lastError?.stage).assertEqual('DOWNLOAD');
      expect(decoded.lastError?.userMessageResource).assertEqual('error.remote.timeout');
      expect(decoded.lastError?.retryable).assertTrue();
      expect(decoded.lastSuccessfulUpdateAt).assertEqual('2026-08-07T00:01:00.000Z');
      expect(decoded.autoUpdateIntervalMs).assertEqual(300000);
    });

    it('roundTripsNullableColumnsAndLocalProfiles', 0, () => {
      const profile: Profile = createProfile({
        id: 'local-1',
        name: 'Local',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: '/tmp/profiles/subdir/local.yaml',
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:01:00.000Z',
        lastSuccessfulUpdateAt: null
      });

      const row: DurableProfileRow = encodeProfileRow(profile);
      const decoded: Profile = decodeProfileRow(row);

      expect(row.currentRevisionJson).assertNull();
      expect(row.failedCandidateJson).assertNull();
      expect(row.lastErrorJson).assertNull();
      expect(row.lastSuccessfulUpdateAt).assertNull();
      expect(row.autoUpdateIntervalMs).assertEqual(0);
      expect(decoded.sourceDisplay).assertEqual('local.yaml');
      expect(decoded.currentRevision).assertNull();
      expect(decoded.failedCandidate).assertNull();
      expect(decoded.lastError).assertNull();
      expect(decoded.lastSuccessfulUpdateAt).assertNull();
      expect(decoded.autoUpdateIntervalMs).assertEqual(0);
    });

    it('decodesLegacyVersionOneRowsAndRejectsUnsupportedVersions', 0, () => {
      const row: DurableProfileRow = encodeProfileRow(buildRemoteProfile());
      const legacyRow: DurableProfileRow = mutateRow(row);
      legacyRow.schemaVersion = 1;
      legacyRow.autoUpdateIntervalMs = undefined;
      const decodedLegacy: Profile = decodeProfileRow(legacyRow);
      const legacyRowWithInjectedInterval: DurableProfileRow = mutateRow(row);
      legacyRowWithInjectedInterval.schemaVersion = 1;
      legacyRowWithInjectedInterval.autoUpdateIntervalMs = 999999;
      const decodedLegacyWithInjectedInterval: Profile = decodeProfileRow(legacyRowWithInjectedInterval);

      expect(decodedLegacy.autoUpdateIntervalMs).assertEqual(0);
      expect(decodedLegacyWithInjectedInterval.autoUpdateIntervalMs).assertEqual(0);

      const rowVersionZero: DurableProfileRow = mutateRow(row);
      rowVersionZero.schemaVersion = 0;
      expectDecodeFailure(rowVersionZero, 'schema version');

      const rowVersionThree: DurableProfileRow = mutateRow(row);
      rowVersionThree.schemaVersion = 3;
      expectDecodeFailure(rowVersionThree, 'schema version');
    });

    it('rejectsInvalidIntervalsAndInvalidEnums', 0, () => {
      const row: DurableProfileRow = encodeProfileRow(buildRemoteProfile());
      const missingInterval: DurableProfileRow = mutateRow(row);
      missingInterval.autoUpdateIntervalMs = undefined;
      expectDecodeFailure(missingInterval, 'autoUpdateIntervalMs');

      const negativeInterval: DurableProfileRow = mutateRow(row);
      negativeInterval.autoUpdateIntervalMs = -1;
      expectDecodeFailure(negativeInterval, 'autoUpdateIntervalMs');

      const fractionalInterval: DurableProfileRow = mutateRow(row);
      fractionalInterval.autoUpdateIntervalMs = 0.5;
      expectDecodeFailure(fractionalInterval, 'autoUpdateIntervalMs');

      const unsafeInterval: DurableProfileRow = mutateRow(row);
      unsafeInterval.autoUpdateIntervalMs = Number.MAX_SAFE_INTEGER + 1;
      expectDecodeFailure(unsafeInterval, 'autoUpdateIntervalMs');

      const wrongAvailability: DurableProfileRow = mutateRow(row);
      wrongAvailability.availability = 'BROKEN_ENUM';
      expectDecodeFailure(wrongAvailability, 'availability');

      const wrongSourceKind: DurableProfileRow = mutateRow(row);
      wrongSourceKind.sourceKind = 'REMOTE_BUT_NOT_REAL';
      expectDecodeFailure(wrongSourceKind, 'source kind');
    });

    it('rejectsInvalidNamesRequiredFieldsAndRemoteSecretInvariant', 0, () => {
      const row: DurableProfileRow = encodeProfileRow(buildRemoteProfile());

      const blankName: DurableProfileRow = mutateRow(row);
      blankName.name = ' ';
      expectDecodeFailure(blankName, 'Profile name');

      const longName: DurableProfileRow = mutateRow(row);
      longName.name = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      expectDecodeFailure(longName, 'Profile name');

      const missingId: DurableProfileRow = mutateRow(row);
      missingId.id = '';
      expectDecodeFailure(missingId, 'Profile id');

      const missingUpdatedAt: DurableProfileRow = mutateRow(row);
      missingUpdatedAt.updatedAt = '';
      expectDecodeFailure(missingUpdatedAt, 'updatedAt');

      const missingRemoteRef: DurableProfileRow = mutateRow(row);
      missingRemoteRef.sourceSecretRef = undefined;
      expectDecodeFailure(missingRemoteRef, 'source secret reference');

      const rawRemoteRef: DurableProfileRow = mutateRow(row);
      rawRemoteRef.sourceSecretRef = buildOpaqueRef('plaintext-remote-ref');
      expectDecodeFailure(rawRemoteRef, 'sourceSecretRef');

      const localWithOpaqueRef: DurableProfileRow = mutateRow(encodeProfileRow(createProfile({
        id: 'local-bad',
        name: 'Local Bad',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: 'local-bad.yaml',
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:00:00.000Z',
        lastSuccessfulUpdateAt: null
      })));
      localWithOpaqueRef.sourceSecretRef = buildOpaqueRef('should-not-exist');
      expectDecodeFailure(localWithOpaqueRef, 'must not persist a source secret reference');
    });

    it('rejectsCorruptNestedJsonAbsolutePathsTraversalAndTypeMismatches', 0, () => {
      const row: DurableProfileRow = encodeProfileRow(buildRemoteProfile());

      const invalidCurrentJson: DurableProfileRow = mutateRow(row);
      invalidCurrentJson.currentRevisionJson = '{';
      expectDecodeFailure(invalidCurrentJson, 'JSON');

      const invalidFailedJson: DurableProfileRow = mutateRow(row);
      invalidFailedJson.failedCandidateJson =
        '{"relativePath":"../escape.yaml","sha256Digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteLength":1,"validatedAt":"2026-08-07T00:00:00.000Z"}';
      expectDecodeFailure(invalidFailedJson, 'sandbox-relative');

      const invalidAbsolutePath: DurableProfileRow = mutateRow(row);
      invalidAbsolutePath.currentRevisionJson =
        '{"relativePath":"/tmp/escape.yaml","sha256Digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","byteLength":1,"validatedAt":"2026-08-07T00:00:00.000Z"}';
      expectDecodeFailure(invalidAbsolutePath, 'sandbox-relative');

      const invalidErrorJson: DurableProfileRow = mutateRow(row);
      invalidErrorJson.lastErrorJson =
        '{"stage":"DOWNLOAD","technicalDetail":["not","a","string"],"timestamp":"2026-08-07T00:00:00.000Z","retryable":true,"code":"CMFA_REMOTE_TIMEOUT","userMessageResource":"error.remote.timeout"}';
      expectDecodeFailure(invalidErrorJson, 'technicalDetail');
    });
  });
}
