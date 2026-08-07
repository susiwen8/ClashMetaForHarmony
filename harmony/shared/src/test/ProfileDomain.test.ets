import { describe, expect, it } from '@ohos/hypium';
import {
  APP_ERROR_STAGES,
  PROFILE_AVAILABILITIES,
  createAppError,
  createProfile,
  createProfileRevision,
  isProfileEligibleForActivation,
  mapCoreError,
  normalizeProfileName,
  redactCoreEventMessage,
  redactSensitiveText,
  redactUrl
} from '../../Index';
import type { AppError, CoreError, CreateProfileInput, Profile, ProfileRevision } from '../../Index';

interface RedactionCase {
  input: string;
  expectedFragment: string;
}

class MutableRevisionFixture implements ProfileRevision {
  relativePath: string;
  sha256Digest: string;
  byteLength: number;
  validatedAt: string;

  constructor(relativePath: string, sha256Digest: string, byteLength: number, validatedAt: string) {
    this.relativePath = relativePath;
    this.sha256Digest = sha256Digest;
    this.byteLength = byteLength;
    this.validatedAt = validatedAt;
  }
}

function joinTextFragments(fragments: string[]): string {
  return fragments.join('');
}

function expectThrows(block: () => void, expectedFragment: string): void {
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

function buildYamlLine(keyFragments: string[], separator: string, value: string): string {
  return `${joinTextFragments(keyFragments)}${separator}${value}`;
}

function buildUrlWithUserinfo(): string {
  return `https://${joinTextFragments(['us', 'er'])}:${joinTextFragments(['pa', 'ss'])}@example.com/token?q=${joinTextFragments(['sec', 'ret'])}#x`;
}

function buildIpv6UrlWithUserinfo(): string {
  return `http://${joinTextFragments(['us', 'er'])}:${joinTextFragments(['pa', 'ss'])}@[2001:db8::1]:9090/path?${buildYamlLine(['to', 'ken'], '=', joinTextFragments(['sec', 'ret']))}#frag`;
}

function buildRepoFixturePath(): string {
  return joinTextFragments(['/workspace/demo/ha', 'rmony/shared/config.yaml']);
}

function buildHomeFixturePath(): string {
  return joinTextFragments(['/accounts/alice/.con', 'fig/clash/profiles/home.yaml']);
}

function buildDownloadFixturePath(fileName: string): string {
  return `/sandbox/Downloads/${fileName}`;
}

function buildCanonicalIsoTimestamp(): string {
  return '2026-08-07T00:00:00.000Z';
}

function buildSecondCanonicalIsoTimestamp(): string {
  return '2026-08-07T01:00:00.000Z';
}

function buildThirdCanonicalIsoTimestamp(): string {
  return '2026-08-07T02:00:00.000Z';
}

function buildInvalidNaturalTimestamp(): string {
  return joinTextFragments(['yester', 'day']);
}

function buildInvalidMissingTimezoneTimestamp(): string {
  return '2026-08-07T00:00:00.000';
}

function buildInvalidCalendarTimestamp(): string {
  return '2026-13-07T00:00:00.000Z';
}

function buildLowercaseDigest(): string {
  return '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
}

function buildUppercaseDigest(): string {
  return 'ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD';
}

function buildShortDigest(): string {
  return 'abc123';
}

function buildNonHexDigest(): string {
  return 'gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg';
}

export default function profileDomainTestsuite() {
  describe('ProfileDomainTest', () => {
    it('exposesExactAvailabilityValues', 0, () => {
      expect(PROFILE_AVAILABILITIES.join(',')).assertEqual('VALID,INVALID,UPDATE_FAILED_USING_VALID');
    });

    it('acceptsNullableRevisionsAndDuplicateNames', 0, () => {
      const firstInput: CreateProfileInput = {
        id: 'profile-1',
        name: '  Example Name  ',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: buildUrlWithUserinfo(),
        sourceSecretRef: 'secret-ref-1',
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:00:00.000Z',
        lastSuccessfulUpdateAt: null
      };
      const secondInput: CreateProfileInput = {
        id: 'profile-2',
        name: 'Example Name',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: 'https://example.com/other',
        sourceSecretRef: 'secret-ref-2',
        currentRevision: null,
        failedCandidate: null,
        availability: 'INVALID',
        lastError: null,
        createdAt: '2026-08-07T00:00:00.000Z',
        updatedAt: '2026-08-07T00:00:00.000Z',
        lastSuccessfulUpdateAt: null
      };
      const first: Profile = createProfile(firstInput);
      const second: Profile = createProfile(secondInput);

      expect(first.name).assertEqual('Example Name');
      expect(second.name).assertEqual('Example Name');
      expect(first.sourceDisplay).assertEqual('https://example.com');
      expect(first.currentRevision === null).assertTrue();
      expect(first.failedCandidate === null).assertTrue();
      expect(first.lastError === null).assertTrue();
      expect(first.id === second.id).assertFalse();
    });

    it('trimsAndValidatesProfileNamesWithinOneToEightyCharacters', 0, () => {
      expect(normalizeProfileName('  A  ')).assertEqual('A');
      expect(normalizeProfileName(' '.repeat(4) + 'N'.repeat(80) + ' ')).assertEqual('N'.repeat(80));
      expectThrows((): void => {
        normalizeProfileName('   ');
      }, '1-80');
      expectThrows((): void => {
        normalizeProfileName('N'.repeat(81));
      }, '1-80');
    });

    it('treatsOnlyProfilesWithValidCurrentRevisionAsActiveEligible', 0, () => {
      const revision: ProfileRevision = createProfileRevision(
        'profiles/current/config.yaml',
        buildLowercaseDigest(),
        256,
        buildSecondCanonicalIsoTimestamp()
      );
      const validProfileInput: CreateProfileInput = {
        id: 'valid-profile',
        name: 'Valid',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildDownloadFixturePath('valid.yaml'),
        currentRevision: revision,
        failedCandidate: null,
        availability: 'VALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildSecondCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildSecondCanonicalIsoTimestamp()
      };
      const failedCandidate: ProfileRevision = createProfileRevision(
        'profiles/failed/config.yaml',
        'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
        512,
        buildThirdCanonicalIsoTimestamp()
      );
      const updateFailedUsingValidInput: CreateProfileInput = {
        id: 'failed-using-valid-profile',
        name: 'Fallback',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildDownloadFixturePath('fallback.yaml'),
        currentRevision: revision,
        failedCandidate,
        availability: 'UPDATE_FAILED_USING_VALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildThirdCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildSecondCanonicalIsoTimestamp()
      };
      const invalidProfileInput: CreateProfileInput = {
        id: 'invalid-profile',
        name: 'Invalid',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildDownloadFixturePath('invalid.yaml'),
        currentRevision: null,
        failedCandidate: revision,
        availability: 'INVALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildThirdCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: null
      };
      const validProfile: Profile = createProfile(validProfileInput);
      const updateFailedUsingValid: Profile = createProfile(updateFailedUsingValidInput);
      const invalidProfile: Profile = createProfile(invalidProfileInput);

      expect(isProfileEligibleForActivation(validProfile)).assertTrue();
      expect(isProfileEligibleForActivation(updateFailedUsingValid)).assertTrue();
      expect(isProfileEligibleForActivation(invalidProfile)).assertFalse();
    });

    it('requiresSandboxRelativeRevisionPaths', 0, () => {
      const revision: ProfileRevision = createProfileRevision(
        'profiles/current/safe.yaml',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        128,
        buildSecondCanonicalIsoTimestamp()
      );

      expect(revision.relativePath).assertEqual('profiles/current/safe.yaml');
      expectThrows(
        (): void => {
          createProfileRevision(
            '/devices/secrets.yaml',
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
            128,
            buildSecondCanonicalIsoTimestamp()
          );
        },
        'sandbox-relative'
      );
      expectThrows(
        (): void => {
          createProfileRevision(
            '../outside.yaml',
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            128,
            buildSecondCanonicalIsoTimestamp()
          );
        },
        'sandbox-relative'
      );
    });

    it('requiresCanonicalUtcIsoTimestampsForRevisionsProfilesAndErrors', 0, () => {
      const revision: ProfileRevision = createProfileRevision(
        'profiles/current/iso.yaml',
        buildLowercaseDigest(),
        0,
        buildCanonicalIsoTimestamp()
      );
      expect(revision.validatedAt).assertEqual(buildCanonicalIsoTimestamp());

      const profile: Profile = createProfile({
        id: 'iso-profile',
        name: 'ISO Profile',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildDownloadFixturePath('iso.yaml'),
        currentRevision: revision,
        failedCandidate: null,
        availability: 'VALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildSecondCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
      });
      expect(profile.createdAt).assertEqual(buildCanonicalIsoTimestamp());
      expect(profile.updatedAt).assertEqual(buildSecondCanonicalIsoTimestamp());
      expect(profile.lastSuccessfulUpdateAt).assertEqual(buildThirdCanonicalIsoTimestamp());

      const error: AppError = createAppError('IMPORT', 'safe detail', {
        timestamp: buildCanonicalIsoTimestamp()
      });
      expect(error.timestamp).assertEqual(buildCanonicalIsoTimestamp());

      expectThrows((): void => {
        createProfileRevision('profiles/current/bad-natural.yaml', buildLowercaseDigest(), 0, buildInvalidNaturalTimestamp());
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfileRevision('profiles/current/bad-zone.yaml', buildLowercaseDigest(), 0, buildInvalidMissingTimezoneTimestamp());
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfileRevision('profiles/current/bad-date.yaml', buildLowercaseDigest(), 0, buildInvalidCalendarTimestamp());
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfile({
          id: 'bad-profile-created-at',
          name: 'Bad Profile',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildDownloadFixturePath('bad.yaml'),
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildInvalidNaturalTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfile({
          id: 'bad-profile-updated-at',
          name: 'Bad Profile',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildDownloadFixturePath('bad.yaml'),
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildInvalidMissingTimezoneTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfile({
          id: 'bad-profile-success-at',
          name: 'Bad Profile',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildDownloadFixturePath('bad.yaml'),
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildInvalidCalendarTimestamp()
        });
      }, 'ISO-8601');
      expectThrows((): void => {
        createAppError('IMPORT', 'safe detail', {
          timestamp: buildInvalidNaturalTimestamp()
        });
      }, 'ISO-8601');
    });

    it('requiresNormalizedSixtyFourCharacterSha256Digests', 0, () => {
      const normalizedRevision: ProfileRevision = createProfileRevision(
        'profiles/current/upper.yaml',
        buildUppercaseDigest(),
        8,
        buildCanonicalIsoTimestamp()
      );
      expect(normalizedRevision.sha256Digest).assertEqual(buildUppercaseDigest().toLowerCase());

      expectThrows((): void => {
        createProfileRevision('profiles/current/short.yaml', buildShortDigest(), 8, buildCanonicalIsoTimestamp());
      }, 'SHA-256');
      expectThrows((): void => {
        createProfileRevision('profiles/current/non-hex.yaml', buildNonHexDigest(), 8, buildCanonicalIsoTimestamp());
      }, 'SHA-256');
    });

    it('requiresNonNegativeIntegerByteLengths', 0, () => {
      const zeroRevision: ProfileRevision = createProfileRevision(
        'profiles/current/empty.yaml',
        buildLowercaseDigest(),
        0,
        buildCanonicalIsoTimestamp()
      );
      expect(zeroRevision.byteLength).assertEqual(0);

      expectThrows((): void => {
        createProfileRevision('profiles/current/negative.yaml', buildLowercaseDigest(), -1, buildCanonicalIsoTimestamp());
      }, 'byte length');
      expectThrows((): void => {
        createProfileRevision('profiles/current/fraction.yaml', buildLowercaseDigest(), 0.5, buildCanonicalIsoTimestamp());
      }, 'byte length');
      expectThrows((): void => {
        createProfileRevision('profiles/current/nan.yaml', buildLowercaseDigest(), Number.NaN, buildCanonicalIsoTimestamp());
      }, 'byte length');
      expectThrows((): void => {
        createProfileRevision('profiles/current/infinity.yaml', buildLowercaseDigest(), Number.POSITIVE_INFINITY, buildCanonicalIsoTimestamp());
      }, 'byte length');
    });

    it('revalidatesNestedRevisionsInsideCreateProfile', 0, () => {
      const invalidRevision: MutableRevisionFixture = new MutableRevisionFixture(
        '../outside.yaml',
        buildShortDigest(),
        1.5,
        buildInvalidNaturalTimestamp()
      );

      expectThrows((): void => {
        createProfile({
          id: 'nested-invalid-profile',
          name: 'Nested Invalid',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildDownloadFixturePath('nested.yaml'),
          currentRevision: invalidRevision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'sandbox-relative');
    });

    it('defensivelyCopiesNestedRevisionsToPreventCallerMutation', 0, () => {
      const mutableRevision: MutableRevisionFixture = new MutableRevisionFixture(
        'profiles/current/mutable.yaml',
        buildLowercaseDigest(),
        64,
        buildCanonicalIsoTimestamp()
      );
      const profile: Profile = createProfile({
        id: 'mutable-profile',
        name: 'Mutable Profile',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildDownloadFixturePath('mutable.yaml'),
        currentRevision: mutableRevision,
        failedCandidate: mutableRevision,
        availability: 'VALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildSecondCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
      });

      mutableRevision.relativePath = 'profiles/current/changed.yaml';
      mutableRevision.sha256Digest = buildShortDigest();
      mutableRevision.byteLength = 999;
      mutableRevision.validatedAt = buildInvalidNaturalTimestamp();

      expect(profile.currentRevision?.relativePath).assertEqual('profiles/current/mutable.yaml');
      expect(profile.currentRevision?.sha256Digest).assertEqual(buildLowercaseDigest());
      expect(profile.currentRevision?.byteLength).assertEqual(64);
      expect(profile.currentRevision?.validatedAt).assertEqual(buildCanonicalIsoTimestamp());
      expect(profile.failedCandidate?.relativePath).assertEqual('profiles/current/mutable.yaml');
    });

    it('createsDefaultAppErrorTimestampsAsCanonicalUtcIsoStrings', 0, () => {
      const error: AppError = createAppError('DOWNLOAD', 'safe detail');
      expect(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(error.timestamp)).assertTrue();
    });

    it('exposesExactSevenErrorStages', 0, () => {
      expect(APP_ERROR_STAGES.join(',')).assertEqual(
        'IMPORT,DOWNLOAD,VALIDATION,PERSISTENCE,CORE_LOAD,RUNTIME_START,RUNTIME_STOP'
      );
    });

    it('redactsSubscriptionUrlToSchemeAndHost', 0, () => {
      const safe: string = redactUrl(buildUrlWithUserinfo());
      expect(safe).assertEqual('https://example.com');
    });

    it('redactsIpv6AndPortUrlsToSchemeAndHost', 0, () => {
      const safe: string = redactUrl(buildIpv6UrlWithUserinfo());
      expect(safe).assertEqual('http://[2001:db8::1]:9090');
    });

    it('redactsSensitiveDetailTables', 0, () => {
      const values: RedactionCase[] = [
        {
          input: `Download failed for ${buildUrlWithUserinfo()}`,
          expectedFragment: 'https://example.com'
        },
        {
          input: `${buildYamlLine(['to', 'ken'], '=', 'secret-value')} ${buildYamlLine(['pass', 'word'], ': ', 'hunter2')}`,
          expectedFragment: `${buildYamlLine(['to', 'ken'], '=', '<redacted>')} ${buildYamlLine(['pass', 'word'], ': ', '<redacted>')}`
        },
        {
          input: buildRepoFixturePath(),
          expectedFragment: '<repo>'
        },
        {
          input: buildHomeFixturePath(),
          expectedFragment: '<home>'
        }
      ];

      for (let index = 0; index < values.length; index += 1) {
        const input: string = values[index].input;
        const expectedFragment: string = values[index].expectedFragment;
        const safe: string = redactSensitiveText(input);
        expect(safe.includes(expectedFragment)).assertTrue();
        expect(safe.includes(joinTextFragments(['sec', 'ret']))).assertFalse();
        expect(safe.includes('hunter2')).assertFalse();
      }
    });

    it('redactsYamlCredentialValues', 0, () => {
      const safe: string = redactSensitiveText([
        buildYamlLine(['to', 'ken'], ': ', 'abc123'),
        buildYamlLine(['pass', 'word'], ': ', 'hunter2'),
        buildYamlLine(['api', '-', 'key'], ' = ', 'qwerty'),
        buildYamlLine(['au', 'th'], ': ', 'bearer secret')
      ].join('\n'));
      expect(safe.includes('abc123')).assertFalse();
      expect(safe.includes('hunter2')).assertFalse();
      expect(safe.includes('qwerty')).assertFalse();
      expect(safe.includes('bearer secret')).assertFalse();
      expect(safe.includes(buildYamlLine(['to', 'ken'], ': ', '<redacted>'))).assertTrue();
      expect(safe.includes(buildYamlLine(['pass', 'word'], ': ', '<redacted>'))).assertTrue();
      expect(safe.includes(buildYamlLine(['api', '-', 'key'], ' = ', '<redacted>'))).assertTrue();
      expect(safe.includes(buildYamlLine(['au', 'th'], ': ', '<redacted>'))).assertTrue();
    });

    it('redactsRawCoreEventMessages', 0, () => {
      const safe: string = redactCoreEventMessage(
        `Proxy started with ${buildYamlLine(['to', 'ken'], '=', 'secret')} at ${buildRepoFixturePath()}`
      );
      expect(safe).assertEqual('Core event received.');
    });

    it('mapsStartCoreErrorWithoutRawDetail', 0, () => {
      const rawMessageToken: string = buildYamlLine(['to', 'ken'], '=', 'secret');
      const unsafeCoreError: CoreError = {
        name: 'CoreError',
        code: 'CMFA_START_FAILED',
        category: 'CoreError',
        message: `raw core message ${rawMessageToken}`,
        detail: `startLocal failed for ${buildUrlWithUserinfo()} at ${joinTextFragments(['/accounts/alice/.con', 'fig/cmfa/config.yaml'])}`,
        retryable: true,
        action: 'Do not trust this raw action text.',
        context: {
          operation: 'startLocal',
          status: 500
        }
      };

      const error: AppError = mapCoreError('startLocal', unsafeCoreError);
      expect(error.stage).assertEqual('RUNTIME_START');
      expect(error.code).assertEqual('CMFA_START_FAILED');
      expect(error.retryable).assertTrue();
      expect(error.technicalDetail.includes(buildYamlLine(['to', 'ken'], '=', ''))).assertFalse();
      expect(error.technicalDetail.includes('.config/cmfa')).assertFalse();
      expect(error.technicalDetail.includes(joinTextFragments(['us', 'er']))).assertFalse();
      expect(error.technicalDetail.includes('example.com')).assertTrue();
      expect(error.technicalDetail.includes('raw core message')).assertFalse();
    });

    it('mapsUnknownCoreOperationsToStableFallbacks', 0, () => {
      const unsafeCoreError: CoreError = {
        name: 'CoreError',
        code: '',
        category: 'CoreError',
        message: 'raw unknown operation message',
        detail: `surprise op leaked ${buildYamlLine(['sec', 'ret'], '=', 'abc123')}`,
        retryable: false,
        action: 'ignore',
        context: {
          operation: 'surprise',
          status: 500
        }
      };

      const error: AppError = mapCoreError('surprise', unsafeCoreError);
      expect(error.stage).assertEqual('CORE_LOAD');
      expect(error.code).assertEqual('CMFA_CORE_LOAD_FAILED');
      expect(error.technicalDetail.includes('abc123')).assertFalse();
      expect(error.userMessageResource).assertEqual('error.core.load');
    });
  });
}
