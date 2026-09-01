import { describe, expect, it } from '@ohos/hypium';
import {
  PROFILE_TRANSFER_AES_GCM_KEY_BYTES,
  PROFILE_TRANSFER_AES_GCM_NONCE_BYTES,
  PROFILE_TRANSFER_AES_GCM_TAG_BYTES,
  PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
  PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION,
  PROFILE_TRANSFER_MAX_AGGREGATE_BYTES,
  PROFILE_TRANSFER_MAX_PROXY_SELECTIONS,
  PROFILE_TRANSFER_MAX_PROFILES,
  PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES,
  PROFILE_TRANSFER_PBKDF2_ITERATIONS,
  PROFILE_TRANSFER_PBKDF2_SALT_BYTES,
  createCancelledQrScanResult,
  createPortableBackupEnvelope,
  createPortableBackupManifest,
  createPortableBackupProfile,
  createPortableBackupProxySelection,
  createPortableBackupYamlEntry,
  createProfileTransferSafeYamlFilename,
  createProfileYamlExportResult,
  createScannedQrScanResult,
  listProfileTransferQrScanResultKinds,
  listProfileTransferYamlExportResultCodes,
  parsePortableBackupEnvelope,
  parsePortableBackupManifest,
  sanitizeProfileTransferQrUrl,
  type PortableBackupCodecPort,
  type PortableBackupEnvelope,
  type PortableBackupManifest,
  type PortableBackupProfile,
  type PortableBackupProxySelection,
  type PortableBackupYamlEntry,
  type ProfileTransferQrScanResult
} from '../../Index';

function exactKeysOf(record: Object): string {
  return Object.keys(record).sort().join(',');
}

function expectThrowsMessage(block: () => void, expectedFragment: string): void {
  let didThrow: boolean = false;
  try {
    block();
  } catch (error) {
    didThrow = true;
    const message: string = error instanceof Error ? error.message : `${error}`;
    expect(message.includes(expectedFragment)).assertTrue();
  }
  expect(didThrow).assertTrue();
}

function buildCanonicalTimestamp(): string {
  return '2026-09-01T00:00:00.000Z';
}

function buildSha256Digest(): string {
  return '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
}

function buildSixteenByteBase64(): string {
  return 'AAAAAAAAAAAAAAAAAAAAAA==';
}

function buildTwelveByteBase64(): string {
  return 'AAAAAAAAAAAAAAAA';
}

function buildThirtyTwoByteBase64(): string {
  return 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
}

function buildYamlBase64(byteLength: number): string {
  let encoded: string = 'AAAA'.repeat(Math.floor(byteLength / 3));
  const remainder: number = byteLength % 3;
  if (remainder === 1) {
    encoded += 'AA==';
  } else if (remainder === 2) {
    encoded += 'AAA=';
  }
  return encoded;
}

function buildYamlEntry(byteLength: number, digest: string = buildSha256Digest()): PortableBackupYamlEntry {
  return createPortableBackupYamlEntry(byteLength, digest, buildYamlBase64(byteLength));
}

function buildRemoteProfile(
  sourceProfileId: string,
  currentYaml: PortableBackupYamlEntry | undefined,
  failedYaml: PortableBackupYamlEntry | undefined
): PortableBackupProfile {
  return createPortableBackupProfile({
    sourceProfileId,
    name: 'Remote profile',
    sourceKind: 'REMOTE_URL',
    sourceLabel: 'https://example.com/profile.yaml',
    remoteSourceUrl: 'https://example.com/profile.yaml',
    autoUpdateIntervalMs: 60000,
    createdAt: buildCanonicalTimestamp(),
    updatedAt: buildCanonicalTimestamp(),
    lastSuccessfulUpdateAt: buildCanonicalTimestamp(),
    currentYaml,
    failedYaml
  });
}

function buildSensitiveRemoteProfile(sourceProfileId: string): PortableBackupProfile {
  return createPortableBackupProfile({
    sourceProfileId,
    name: 'Sensitive remote profile',
    sourceKind: 'REMOTE_URL',
    sourceLabel: 'https://example.com/tokenized/path.yaml?token=secret#frag',
    remoteSourceUrl: 'https://example.com/tokenized/path.yaml?token=secret#frag',
    autoUpdateIntervalMs: 60000,
    createdAt: buildCanonicalTimestamp(),
    updatedAt: buildCanonicalTimestamp()
  });
}

function buildLocalProfile(sourceProfileId: string): PortableBackupProfile {
  return createPortableBackupProfile({
    sourceProfileId,
    name: 'Local profile',
    sourceKind: 'LOCAL_FILE',
    sourceLabel: 'profile.yaml',
    autoUpdateIntervalMs: 0,
    createdAt: buildCanonicalTimestamp(),
    updatedAt: buildCanonicalTimestamp()
  });
}

function buildProxySelection(sourceProfileId: string): PortableBackupProxySelection {
  return createPortableBackupProxySelection(sourceProfileId, 'Auto', 'Node A');
}

function buildManifest(profiles: PortableBackupProfile[]): PortableBackupManifest {
  return createPortableBackupManifest({
    schemaVersion: PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION,
    profiles,
    activeProfileSourceId: profiles.length > 0 ? profiles[0].sourceProfileId : undefined,
    proxySelections: profiles.length > 0 ? [buildProxySelection(profiles[0].sourceProfileId)] : []
  });
}

function buildEnvelope(): PortableBackupEnvelope {
  return createPortableBackupEnvelope({
    schemaVersion: PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
    kdf: {
      name: 'PBKDF2-HMAC-SHA256',
      iterations: PROFILE_TRANSFER_PBKDF2_ITERATIONS,
      saltBase64: buildSixteenByteBase64()
    },
    cipher: {
      name: 'AES-256-GCM',
      nonceBase64: buildTwelveByteBase64(),
      ciphertextBase64: buildThirtyTwoByteBase64(),
      tagBase64: buildSixteenByteBase64()
    }
  });
}

function buildMutablePlainObject(value: string): Record<string, Object> {
  const record: Record<string, Object> = JSON.parse(value) as Record<string, Object>;
  return record;
}

function buildRepeatedCharacter(character: string, count: number): string {
  let text: string = '';
  for (let index: number = 0; index < count; index += 1) {
    text += character;
  }
  return text;
}

function assertCodecPortRequiresStringPassphrase(port: PortableBackupCodecPort): void {
  const encryptFn: (plaintext: Uint8Array, passphrase: string) => Promise<PortableBackupEnvelope> = port.encrypt;
  const decryptFn: (envelope: PortableBackupEnvelope, passphrase: string) => Promise<Uint8Array> = port.decrypt;
  void encryptFn;
  void decryptFn;
}

export default function profileTransferModelsTestsuite() {
  describe('ProfileTransferModelsTest', () => {
    it('exposesExactConstantsAndClosedResultKinds', 0, () => {
      expect(PROFILE_TRANSFER_MAX_PROFILES).assertEqual(128);
      expect(PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES).assertEqual(16 * 1024 * 1024);
      expect(PROFILE_TRANSFER_MAX_AGGREGATE_BYTES).assertEqual(64 * 1024 * 1024);
      expect(PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION).assertEqual(1);
      expect(PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION).assertEqual(1);
      expect(PROFILE_TRANSFER_PBKDF2_ITERATIONS).assertEqual(210000);
      expect(PROFILE_TRANSFER_PBKDF2_SALT_BYTES).assertEqual(16);
      expect(PROFILE_TRANSFER_AES_GCM_NONCE_BYTES).assertEqual(12);
      expect(PROFILE_TRANSFER_AES_GCM_TAG_BYTES).assertEqual(16);
      expect(PROFILE_TRANSFER_AES_GCM_KEY_BYTES).assertEqual(32);

      const qrKinds: string[] = listProfileTransferQrScanResultKinds();
      const exportCodes: string[] = listProfileTransferYamlExportResultCodes();
      qrKinds[0] = 'MUTATED';
      exportCodes[0] = 'MUTATED';

      expect(listProfileTransferQrScanResultKinds().join(',')).assertEqual('SCANNED,CANCELLED');
      expect(listProfileTransferYamlExportResultCodes().join(',')).assertEqual('EXPORTED,CANCELLED,FAILED');
    });

    it('createsClosedQrAndYamlExportResultShapes', 0, () => {
      const scanned: ProfileTransferQrScanResult = createScannedQrScanResult('https://example.com/a.yaml');
      const cancelled: ProfileTransferQrScanResult = createCancelledQrScanResult();
      const exported: Object = createProfileYamlExportResult('EXPORTED');
      const failed: Object = createProfileYamlExportResult('FAILED');

      expect(exactKeysOf(scanned as Object)).assertEqual('kind,value');
      expect(exactKeysOf(cancelled as Object)).assertEqual('kind');
      expect(exactKeysOf(exported)).assertEqual('code');
      expect(exactKeysOf(failed)).assertEqual('code');
      expect(scanned.kind).assertEqual('SCANNED');
      expect(cancelled.kind).assertEqual('CANCELLED');
      expect(createProfileYamlExportResult('EXPORTED').code).assertEqual('EXPORTED');
      expect(createProfileYamlExportResult('FAILED').code).assertEqual('FAILED');
    });

    it('sanitizesOnlyHttpAndHttpsWithoutEchoingRawInput', 0, () => {
      const valid = sanitizeProfileTransferQrUrl('https://Example.com/path?q=1#frag');
      const validIpv6 = sanitizeProfileTransferQrUrl('https://[2001:DB8::1]:8443/path');
      const validEncoded = sanitizeProfileTransferQrUrl('https://example.com/a%20b?q=%2Fok#frag');
      const invalidRaw: string = 'ftp://example.com/secret?token=abc123';
      const invalid = sanitizeProfileTransferQrUrl(invalidRaw);

      expect(valid.kind).assertEqual('VALID');
      expect(valid.url).assertEqual('https://example.com/path?q=1#frag');
      expect(validIpv6.kind).assertEqual('VALID');
      expect(validIpv6.url).assertEqual('https://[2001:db8::1]:8443/path');
      expect(validEncoded.kind).assertEqual('VALID');
      expect(validEncoded.url).assertEqual('https://example.com/a%20b?q=%2Fok#frag');
      expect(invalid.kind).assertEqual('INVALID');
      expect(invalid.code).assertEqual('PROFILE_TRANSFER_INVALID_QR_URL');
      expect(invalid.message).assertEqual('Scanned QR code must contain an http or https URL.');
      expect(JSON.stringify(invalid).includes(invalidRaw)).assertFalse();
      expect(JSON.stringify(invalid).includes('abc123')).assertFalse();
    });

    it('rejectsInvalidUrlAuthoritiesWithoutEchoingRawInput', 0, () => {
      const invalidAuthorities: string[] = [
        'https://bad host/x',
        'https://example.com:0/x',
        'https://example.com:65536/x',
        'https://example.com:abc/x',
        'https://2001:db8::1/x',
        'https://example.com/a b',
        'https://example.com/a\u00A0b',
        'https://example.com/a\u3000b',
        'https://example.com/?bad value',
        'https://example.com/bad%',
        'https://example.com/bad%2',
        'https://example.com/bad%zz',
        'https://example.com\\bad',
        'https://example.com/<bad>',
        'https://example.com/\"bad\"',
        'https://example.com/{bad}',
        'https://example.com/|bad',
        'https://example.com/^bad',
        'https://example.com/`bad`'
      ];

      for (let index: number = 0; index < invalidAuthorities.length; index += 1) {
        const invalidRaw: string = invalidAuthorities[index];
        const invalid = sanitizeProfileTransferQrUrl(invalidRaw);
        expect(invalid.kind).assertEqual('INVALID');
        expect(invalid.code).assertEqual('PROFILE_TRANSFER_INVALID_QR_URL');
        expect(JSON.stringify(invalid).includes(invalidRaw)).assertFalse();
      }
    });

    it('rejectsRemoteProfileUnicodeWhitespaceUrlsWithoutEchoingRawInput', 0, () => {
      const invalidRaw: string = 'https://example.com/a\u00A0b?token=secret';
      let didThrow: boolean = false;
      try {
        createPortableBackupProfile({
          sourceProfileId: 'remote-invalid',
          name: 'Remote invalid',
          sourceKind: 'REMOTE_URL',
          sourceLabel: invalidRaw,
          remoteSourceUrl: invalidRaw,
          autoUpdateIntervalMs: 60000,
          createdAt: buildCanonicalTimestamp(),
          updatedAt: buildCanonicalTimestamp()
        });
      } catch (error) {
        didThrow = true;
        const message: string = error instanceof Error ? error.message : `${error}`;
        expect(message).assertEqual('Profile transfer remote sourceLabel must be a valid http or https URL.');
        expect(message.includes(invalidRaw)).assertFalse();
        expect(message.includes('secret')).assertFalse();
      }
      expect(didThrow).assertTrue();
    });

    it('createsAndParsesManifestWithExactAllowlistedKeys', 0, () => {
      const currentYaml: PortableBackupYamlEntry = buildYamlEntry(32);
      const failedYaml: PortableBackupYamlEntry = buildYamlEntry(16);
      const remoteProfile: PortableBackupProfile = createPortableBackupProfile({
        sourceProfileId: 'remote-1',
        name: 'Remote profile',
        sourceKind: 'REMOTE_URL',
        sourceLabel: 'https://example.com/tokenized/path.yaml?token=secret#frag',
        remoteSourceUrl: 'https://example.com/tokenized/path.yaml?token=secret#frag',
        autoUpdateIntervalMs: 60000,
        createdAt: buildCanonicalTimestamp(),
        updatedAt: buildCanonicalTimestamp(),
        lastSuccessfulUpdateAt: buildCanonicalTimestamp(),
        currentYaml,
        failedYaml
      });
      const localProfile: PortableBackupProfile = buildLocalProfile('local-1');
      const manifest: PortableBackupManifest = buildManifest([remoteProfile, localProfile]);
      const parsed: PortableBackupManifest = parsePortableBackupManifest(
        buildMutablePlainObject(JSON.stringify(manifest))
      );

      expect(exactKeysOf(manifest as Object)).assertEqual(
        'activeProfileSourceId,profiles,proxySelections,schemaVersion'
      );
      expect(exactKeysOf(remoteProfile as Object)).assertEqual(
        'autoUpdateIntervalMs,createdAt,currentYaml,failedYaml,lastSuccessfulUpdateAt,name,remoteSourceUrl,sourceKind,sourceLabel,sourceProfileId,updatedAt'
      );
      expect(exactKeysOf(localProfile as Object)).assertEqual(
        'autoUpdateIntervalMs,createdAt,name,sourceKind,sourceLabel,sourceProfileId,updatedAt'
      );
      expect(exactKeysOf(currentYaml as Object)).assertEqual('byteLength,contentBase64,sha256Digest');
      expect(exactKeysOf(manifest.proxySelections[0] as Object)).assertEqual(
        'groupName,selectedNodeName,sourceProfileId'
      );
      expect(exactKeysOf(parsed.profiles[0] as Object)).assertEqual(
        'autoUpdateIntervalMs,createdAt,currentYaml,failedYaml,lastSuccessfulUpdateAt,name,remoteSourceUrl,sourceKind,sourceLabel,sourceProfileId,updatedAt'
      );
      expect(remoteProfile.sourceLabel).assertEqual('https://example.com');
      expect(remoteProfile.remoteSourceUrl).assertEqual('https://example.com/tokenized/path.yaml?token=secret#frag');

      const manifestJson: string = JSON.stringify(manifest);
      expect(manifestJson.includes('https://example.com/tokenized/path.yaml?token=secret#frag')).assertTrue();
      expect(manifestJson.includes('\"sourceLabel\":\"https://example.com\"')).assertTrue();
      expect(manifestJson.includes('tokenized/path')).assertTrue();
      expect(manifestJson.includes('\"sourceLabel\":\"https://example.com/tokenized')).assertFalse();
      expect(manifestJson.includes('\"sourceLabel\":\"https://example.com?token=secret')).assertFalse();
      expect(manifestJson.includes('sourceSecretRef')).assertFalse();
      expect(manifestJson.includes('relativePath')).assertFalse();
      expect(manifestJson.includes('validationPath')).assertFalse();
      expect(manifestJson.includes('huks')).assertFalse();
      expect(manifestJson.includes('geodata')).assertFalse();
      expect(manifestJson.includes('vpn')).assertFalse();
      expect(manifestJson.includes('rpc')).assertFalse();
    });

    it('rejectsUnknownManifestKeysAndEnforcesLimits', 0, () => {
      const maxYamlEntry: PortableBackupYamlEntry = buildYamlEntry(PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES);
      const maxProfiles: PortableBackupProfile[] = [];
      for (let index: number = 0; index < PROFILE_TRANSFER_MAX_PROFILES; index += 1) {
        maxProfiles.push(buildLocalProfile(`max-${index}`));
      }
      const withinProfileLimit: PortableBackupManifest = createPortableBackupManifest({
        schemaVersion: PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION,
        profiles: maxProfiles,
        proxySelections: []
      });
      const withinAggregate: PortableBackupManifest = buildManifest([
        buildRemoteProfile('remote-a', maxYamlEntry, undefined),
        buildRemoteProfile('remote-b', maxYamlEntry, undefined),
        buildRemoteProfile('remote-c', maxYamlEntry, undefined),
        buildRemoteProfile('remote-d', maxYamlEntry, undefined)
      ]);
      expect(withinProfileLimit.profiles.length).assertEqual(128);
      expect(maxYamlEntry.byteLength).assertEqual(PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES);
      expect(withinAggregate.profiles.length).assertEqual(4);

      const tooManyProfiles: PortableBackupProfile[] = [];
      for (let index: number = 0; index < PROFILE_TRANSFER_MAX_PROFILES + 1; index += 1) {
        tooManyProfiles.push(buildLocalProfile(`local-${index}`));
      }

      expectThrowsMessage(() => {
        createPortableBackupManifest({
          schemaVersion: PROFILE_TRANSFER_BACKUP_SCHEMA_VERSION,
          profiles: tooManyProfiles,
          proxySelections: []
        });
      }, 'Profile transfer backup must not contain more than 128 profiles.');

      expectThrowsMessage(() => buildYamlEntry(PROFILE_TRANSFER_MAX_YAML_ENTRY_BYTES + 1), '16 MiB');
      expectThrowsMessage(() => {
        createPortableBackupYamlEntry(1, buildSha256Digest(), buildYamlBase64(2));
      }, 'exactly 1 bytes');
      expectThrowsMessage(() => {
        createPortableBackupYamlEntry(2, buildSha256Digest(), buildYamlBase64(1));
      }, 'exactly 2 bytes');
      expectThrowsMessage(() => {
        buildManifest([
          buildRemoteProfile('remote-a', maxYamlEntry, undefined),
          buildRemoteProfile('remote-b', maxYamlEntry, undefined),
          buildRemoteProfile('remote-c', maxYamlEntry, undefined),
          buildRemoteProfile('remote-d', maxYamlEntry, undefined),
          buildRemoteProfile('remote-e', buildYamlEntry(1), undefined)
        ]);
      }, '64 MiB');
      expectThrowsMessage(() => {
        createPortableBackupProfile({
          sourceProfileId: 'remote-missing',
          name: 'Remote missing',
          sourceKind: 'REMOTE_URL',
          sourceLabel: 'https://example.com/missing.yaml',
          autoUpdateIntervalMs: 0,
          createdAt: buildCanonicalTimestamp(),
          updatedAt: buildCanonicalTimestamp()
        });
      }, 'Remote backup profiles require remoteSourceUrl.');
      expectThrowsMessage(() => {
        createPortableBackupProfile({
          sourceProfileId: 'local-invalid',
          name: 'Local invalid',
          sourceKind: 'LOCAL_FILE',
          sourceLabel: 'profile.yaml',
          remoteSourceUrl: 'https://example.com/should-not-exist.yaml',
          autoUpdateIntervalMs: 0,
          createdAt: buildCanonicalTimestamp(),
          updatedAt: buildCanonicalTimestamp()
        });
      }, 'Local backup profiles must not include remoteSourceUrl.');

      const rootWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(withinAggregate));
      rootWithUnknown.extra = {};
      expectThrowsMessage(() => parsePortableBackupManifest(rootWithUnknown), 'unknown keys');

      const profileWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(withinAggregate));
      ((profileWithUnknown.profiles as Object[])[0] as Record<string, Object>).relativePath = {};
      expectThrowsMessage(() => parsePortableBackupManifest(profileWithUnknown), 'unknown keys');

      const yamlWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(withinAggregate));
      (((yamlWithUnknown.profiles as Object[])[0] as Record<string, Object>).currentYaml as Record<string, Object>).path = {};
      expectThrowsMessage(() => parsePortableBackupManifest(yamlWithUnknown), 'unknown keys');

      const selectionWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(withinAggregate));
      ((selectionWithUnknown.proxySelections as Object[])[0] as Record<string, Object>).sessionId = {};
      expectThrowsMessage(() => parsePortableBackupManifest(selectionWithUnknown), 'unknown keys');
    });

    it('enforcesManifestReferentialIntegrityAndProxySelectionBounds', 0, () => {
      expect(PROFILE_TRANSFER_MAX_PROXY_SELECTIONS).assertEqual(8192);

      const profiles: PortableBackupProfile[] = [buildLocalProfile('local-1'), buildSensitiveRemoteProfile('remote-1')];
      const maxSelections: PortableBackupProxySelection[] = [];
      for (let index: number = 0; index < PROFILE_TRANSFER_MAX_PROXY_SELECTIONS; index += 1) {
        maxSelections.push(createPortableBackupProxySelection('local-1', `Group-${index}`, 'Node A'));
      }

      const withinLimit: PortableBackupManifest = createPortableBackupManifest({
        profiles,
        activeProfileSourceId: 'remote-1',
        proxySelections: maxSelections
      });
      expect(withinLimit.proxySelections.length).assertEqual(8192);

      expectThrowsMessage(() => {
        createPortableBackupManifest({
          profiles,
          activeProfileSourceId: 'missing-profile',
          proxySelections: []
        });
      }, 'activeProfileSourceId');

      expectThrowsMessage(() => {
        createPortableBackupManifest({
          profiles: [buildLocalProfile('dup'), buildSensitiveRemoteProfile('dup')],
          proxySelections: []
        });
      }, 'sourceProfileId');

      expectThrowsMessage(() => {
        createPortableBackupManifest({
          profiles,
          proxySelections: [createPortableBackupProxySelection('missing-profile', 'Auto', 'Node A')]
        });
      }, 'proxy selection sourceProfileId');

      expectThrowsMessage(() => {
        createPortableBackupManifest({
          profiles,
          proxySelections: [
            createPortableBackupProxySelection('local-1', 'Auto', 'Node A'),
            createPortableBackupProxySelection('local-1', 'Auto', 'Node B')
          ]
        });
      }, 'duplicate proxy selection');

      expectThrowsMessage(() => {
        const tooManySelections: PortableBackupProxySelection[] = maxSelections.slice();
        tooManySelections.push(createPortableBackupProxySelection('remote-1', 'Overflow', 'Node Z'));
        createPortableBackupManifest({
          profiles,
          proxySelections: tooManySelections
        });
      }, '8192');
    });

    it('createsAndParsesEnvelopeWithExactAllowlistedKeysAndBounds', 0, () => {
      const envelope: PortableBackupEnvelope = buildEnvelope();
      const parsed: PortableBackupEnvelope = parsePortableBackupEnvelope(
        buildMutablePlainObject(JSON.stringify(envelope))
      );

      expect(exactKeysOf(envelope as Object)).assertEqual('cipher,kdf,schemaVersion');
      expect(exactKeysOf(envelope.kdf as Object)).assertEqual('iterations,name,saltBase64');
      expect(exactKeysOf(envelope.cipher as Object)).assertEqual(
        'ciphertextBase64,name,nonceBase64,tagBase64'
      );
      expect(exactKeysOf(parsed.kdf as Object)).assertEqual('iterations,name,saltBase64');
      expect(JSON.stringify(envelope).includes('plaintext')).assertFalse();
      expect(JSON.stringify(envelope).includes('sourceSecretRef')).assertFalse();
      expect(JSON.stringify(envelope).includes('relativePath')).assertFalse();

      const rootWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(envelope));
      rootWithUnknown.extra = {};
      expectThrowsMessage(() => parsePortableBackupEnvelope(rootWithUnknown), 'unknown keys');

      const kdfWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(envelope));
      (kdfWithUnknown.kdf as Record<string, Object>).keyLength = {};
      expectThrowsMessage(() => parsePortableBackupEnvelope(kdfWithUnknown), 'unknown keys');

      const cipherWithUnknown: Record<string, Object> = buildMutablePlainObject(JSON.stringify(envelope));
      (cipherWithUnknown.cipher as Record<string, Object>).headerBase64 = {};
      expectThrowsMessage(() => parsePortableBackupEnvelope(cipherWithUnknown), 'unknown keys');

      expectThrowsMessage(() => {
        createPortableBackupEnvelope({
          schemaVersion: PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
          kdf: {
            name: 'PBKDF2-HMAC-SHA256',
            iterations: PROFILE_TRANSFER_PBKDF2_ITERATIONS - 1,
            saltBase64: buildSixteenByteBase64()
          },
          cipher: {
            name: 'AES-256-GCM',
            nonceBase64: buildTwelveByteBase64(),
            ciphertextBase64: buildThirtyTwoByteBase64(),
            tagBase64: buildSixteenByteBase64()
          }
        });
      }, '210000');
      expectThrowsMessage(() => {
        createPortableBackupEnvelope({
          schemaVersion: PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
          kdf: {
            name: 'PBKDF2-HMAC-SHA256',
            iterations: PROFILE_TRANSFER_PBKDF2_ITERATIONS,
            saltBase64: buildTwelveByteBase64()
          },
          cipher: {
            name: 'AES-256-GCM',
            nonceBase64: buildTwelveByteBase64(),
            ciphertextBase64: buildThirtyTwoByteBase64(),
            tagBase64: buildSixteenByteBase64()
          }
        });
      }, 'salt');
      expectThrowsMessage(() => {
        createPortableBackupEnvelope({
          schemaVersion: PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
          kdf: {
            name: 'PBKDF2-HMAC-SHA256',
            iterations: PROFILE_TRANSFER_PBKDF2_ITERATIONS,
            saltBase64: buildSixteenByteBase64()
          },
          cipher: {
            name: 'AES-256-GCM',
            nonceBase64: buildSixteenByteBase64(),
            ciphertextBase64: buildThirtyTwoByteBase64(),
            tagBase64: buildSixteenByteBase64()
          }
        });
      }, 'nonce');
      expectThrowsMessage(() => {
        createPortableBackupEnvelope({
          schemaVersion: PROFILE_TRANSFER_BACKUP_ENVELOPE_VERSION,
          kdf: {
            name: 'PBKDF2-HMAC-SHA256',
            iterations: PROFILE_TRANSFER_PBKDF2_ITERATIONS,
            saltBase64: buildSixteenByteBase64()
          },
          cipher: {
            name: 'AES-256-GCM',
            nonceBase64: buildTwelveByteBase64(),
            ciphertextBase64: buildThirtyTwoByteBase64(),
            tagBase64: buildTwelveByteBase64()
          }
        });
      }, 'tag');
      expectThrowsMessage(() => createPortableBackupYamlEntry(32, 'abc', buildYamlBase64(32)), 'SHA-256');
      expectThrowsMessage(() => createPortableBackupYamlEntry(32, buildSha256Digest(), '!not-base64!'), 'base64');
    });

    it('buildsSafeYamlFilenamesWithoutTraversalOrControlCharacters', 0, () => {
      expect(createProfileTransferSafeYamlFilename('../../')).assertEqual('profile.yaml');
      expect(createProfileTransferSafeYamlFilename('..\u0000/测试/配置')).assertEqual('测试配置.yaml');
      expect(createProfileTransferSafeYamlFilename(' already.yaml ')).assertEqual('already.yaml');
      expect(createProfileTransferSafeYamlFilename('\u202Eab\u200Bc\uFEFF')).assertEqual('abc.yaml');
      expect(createProfileTransferSafeYamlFilename('ＡＢＣ.yaml')).assertEqual('ABC.yaml');

      const longName: string = buildRepeatedCharacter('x', 120);
      const safeLongName: string = createProfileTransferSafeYamlFilename(longName);
      expect(safeLongName.endsWith('.yaml')).assertTrue();
      expect(safeLongName.length <= 85).assertTrue();
      expect(safeLongName.includes('/')).assertFalse();
      expect(safeLongName.includes('\\')).assertFalse();
      expect(safeLongName.includes('..')).assertFalse();
      expect(safeLongName.includes('\u202E')).assertFalse();
      expect(safeLongName.includes('\u200B')).assertFalse();
      expect(createProfileTransferSafeYamlFilename('')).assertEqual('profile.yaml');
    });

    it('keepsPortableBackupCodecPortPassphrasesStringOnly', 0, async () => {
      const codecPort: PortableBackupCodecPort = {
        async encrypt(_plaintext: Uint8Array, _passphrase: string): Promise<PortableBackupEnvelope> {
          return buildEnvelope();
        },
        async decrypt(_envelope: PortableBackupEnvelope, _passphrase: string): Promise<Uint8Array> {
          return new Uint8Array(0);
        }
      };

      assertCodecPortRequiresStringPassphrase(codecPort);
      const encrypted: PortableBackupEnvelope = await codecPort.encrypt(new Uint8Array(0), 'passphrase');
      const decrypted: Uint8Array = await codecPort.decrypt(encrypted, 'passphrase');
      expect(decrypted.length).assertEqual(0);
    });
  });
}
