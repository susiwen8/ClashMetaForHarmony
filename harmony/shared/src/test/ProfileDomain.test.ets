import { describe, expect, it } from '@ohos/hypium';
import {
  APP_ERROR_STAGES,
  PROFILE_AVAILABILITIES,
  createAppError,
  createProfile,
  createProfileRevision,
  isProfileEligibleForActivation,
  mapCoreError,
  normalizeCanonicalUtcIsoTimestamp,
  normalizeProfileName,
  redactCoreEventMessage,
  redactSensitiveText,
  redactUrl
} from '../../Index';
import type { AppError, AppErrorStage, CoreError, CreateProfileInput, Profile, ProfileRevision } from '../../Index';

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

class MutableAppErrorFixture implements AppError {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;

  constructor(
    code: string,
    stage: AppErrorStage,
    userMessageResource: string,
    technicalDetail: string,
    timestamp: string,
    retryable: boolean
  ) {
    this.code = code;
    this.stage = stage;
    this.userMessageResource = userMessageResource;
    this.technicalDetail = technicalDetail;
    this.timestamp = timestamp;
    this.retryable = retryable;
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

function buildLocalFilePath(fileName: string): string {
  return `/sandbox/local/${fileName}`;
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

function buildTimestampWithOuterWhitespace(): string {
  return ` ${buildCanonicalIsoTimestamp()} `;
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

function buildQuotedYamlCredentialLine(quote: string, keyFragments: string[], value: string): string {
  const key: string = joinTextFragments(keyFragments);
  return `${quote}${key}${quote}: ${quote}${value}${quote}`;
}

function buildYamlBlockScalar(
  keyFragments: string[],
  indicator: string,
  valueLines: string[],
  trailingLine: string
): string {
  const lines: string[] = [`${joinTextFragments(keyFragments)}: ${indicator}`];
  for (let index = 0; index < valueLines.length; index += 1) {
    lines.push(`  ${valueLines[index]}`);
  }
  lines.push(trailingLine);
  return lines.join('\n');
}

function buildYamlListBlockScalar(
  keyFragments: string[],
  indicator: string,
  valueLines: string[],
  siblingLine: string
): string {
  const lines: string[] = [`- ${joinTextFragments(keyFragments)}: ${indicator}`];
  for (let index: number = 0; index < valueLines.length; index += 1) {
    lines.push(`    ${valueLines[index]}`);
  }
  lines.push(`  ${siblingLine}`);
  return lines.join('\n');
}

function buildDrivePathWithSpaces(): string {
  return joinTextFragments([
    'C',
    ':',
    '\\',
    '\\',
    'Us',
    'ers',
    '\\',
    '\\',
    'demo',
    '\\',
    '\\',
    'Space Folder',
    '\\',
    '\\',
    'config.yaml'
  ]);
}

function buildUncPathWithSpaces(): string {
  return joinTextFragments([
    '\\',
    '\\',
    '\\',
    '\\',
    'server',
    '\\',
    '\\',
    'share',
    '\\',
    '\\',
    'Folder Name',
    '\\',
    '\\',
    'secret.yaml'
  ]);
}

function buildValidProfileRevision(): ProfileRevision {
  return createProfileRevision(
    'profiles/current/valid.yaml',
    buildLowercaseDigest(),
    64,
    buildCanonicalIsoTimestamp()
  );
}

function buildAllowedBusyCoreError(): CoreError {
  return {
    name: 'CoreError',
    code: 'CMFA_BUSY',
    category: 'StateError',
    message: 'busy',
    detail: 'retry later',
    retryable: true,
    action: 'retry',
    context: {
      operation: 'startLocal',
      status: 8
    }
  };
}

function buildAllowedNapiFailureError(): CoreError {
  return {
    name: 'CoreError',
    code: 'NAPI_FAILURE',
    category: 'CoreError',
    message: 'bridge failed',
    detail: 'bridge failed',
    retryable: false,
    action: 'check bridge',
    context: {
      operation: 'load',
      status: -1
    }
  };
}

function buildUntrustedCoreError(code: string): CoreError {
  return {
    name: 'CoreError',
    code,
    category: 'CoreError',
    message: 'untrusted',
    detail: `detail ${buildYamlLine(['to', 'ken'], '=', 'abc123')}`,
    retryable: false,
    action: 'ignore',
    context: {
      operation: 'startLocal',
      status: 500
    }
  };
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

    it('rejectsWhitespaceWrappedCanonicalTimestampsInsteadOfTrimmingThem', 0, () => {
      expectThrows((): void => {
        normalizeCanonicalUtcIsoTimestamp(buildTimestampWithOuterWhitespace(), 'Shared timestamp');
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfileRevision(
          'profiles/current/space-wrapped.yaml',
          buildLowercaseDigest(),
          0,
          buildTimestampWithOuterWhitespace()
        );
      }, 'ISO-8601');
      expectThrows((): void => {
        createProfile({
          id: 'space-wrapped-profile',
          name: 'Space Wrapped',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildDownloadFixturePath('space.yaml'),
          currentRevision: createProfileRevision(
            'profiles/current/space.yaml',
            buildLowercaseDigest(),
            0,
            buildCanonicalIsoTimestamp()
          ),
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildTimestampWithOuterWhitespace(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'ISO-8601');
    });

    it('treatsExplicitBlankOrWhitespaceErrorTimestampsAsInvalidNotMissing', 0, () => {
      expectThrows((): void => {
        createAppError('IMPORT', 'safe detail', {
          timestamp: '   '
        });
      }, 'ISO-8601');
      expectThrows((): void => {
        createAppError('IMPORT', 'safe detail', {
          timestamp: buildTimestampWithOuterWhitespace()
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
      const urlSafe: string = redactSensitiveText(`Download failed for ${buildUrlWithUserinfo()}`);
      expect(urlSafe.includes('https://example.com')).assertTrue();
      expect(urlSafe.includes(joinTextFragments(['sec', 'ret']))).assertFalse();

      const inlineSafe: string = redactSensitiveText(
        `${buildYamlLine(['to', 'ken'], '=', 'secret-value')} ${buildYamlLine(['pass', 'word'], ': ', 'hunter2')}`
      );
      expect(
        inlineSafe.includes(`${buildYamlLine(['to', 'ken'], '=', '<redacted>')} ${buildYamlLine(['pass', 'word'], ': ', '<redacted>')}`)
      ).assertTrue();
      expect(inlineSafe.includes(joinTextFragments(['sec', 'ret']))).assertFalse();
      expect(inlineSafe.includes('hunter2')).assertFalse();

      const repoSafe: string = redactSensitiveText(buildRepoFixturePath());
      expect(repoSafe.includes('<repo>')).assertTrue();

      const homeSafe: string = redactSensitiveText(buildHomeFixturePath());
      expect(homeSafe.includes('<home>')).assertTrue();
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

    it('redactsQuotedYamlKeysAndBlockScalarsWithoutSwallowingFollowingLines', 0, () => {
      const quotedSafe: string = redactSensitiveText([
        `- ${buildQuotedYamlCredentialLine('"', ['to', 'ken'], 'abc123')}`,
        buildQuotedYamlCredentialLine('\'', ['pass', 'word'], 'hunter2'),
        'label: keep'
      ].join('\n'));
      expect(quotedSafe.includes('abc123')).assertFalse();
      expect(quotedSafe.includes('hunter2')).assertFalse();
      expect(quotedSafe.includes('- "token": "<redacted>"')).assertTrue();
      expect(quotedSafe.includes('\'password\': \'<redacted>\'')).assertTrue();
      expect(quotedSafe.includes('label: keep')).assertTrue();

      const blockSafe: string = redactSensitiveText(buildYamlBlockScalar(
        ['to', 'ken'],
        '|',
        ['abc123', 'second-line'],
        'label: keep'
      ));
      expect(blockSafe.includes('abc123')).assertFalse();
      expect(blockSafe.includes('second-line')).assertFalse();
      expect(blockSafe.includes('label: keep')).assertTrue();

      const foldedSafe: string = redactSensitiveText(buildYamlBlockScalar(
        ['pass', 'word'],
        '>-',
        ['hunter2', 'second-line'],
        'next: keep'
      ));
      expect(foldedSafe.includes('hunter2')).assertFalse();
      expect(foldedSafe.includes('second-line')).assertFalse();
      expect(foldedSafe.includes('next: keep')).assertTrue();
    });

    it('keepsYamlListBlockSiblingsWhileRedactingBlockContent', 0, () => {
      const literalSafe: string = redactSensitiveText(buildYamlListBlockScalar(
        ['to', 'ken'],
        '|',
        ['abc123'],
        'label: keep'
      ));
      expect(literalSafe.includes('abc123')).assertFalse();
      expect(literalSafe.includes('label: keep')).assertTrue();

      const foldedSafe: string = redactSensitiveText(buildYamlListBlockScalar(
        ['pass', 'word'],
        '>-',
        ['hunter2'],
        'label: keep'
      ));
      expect(foldedSafe.includes('hunter2')).assertFalse();
      expect(foldedSafe.includes('label: keep')).assertTrue();
    });

    it('redactsBlockScalarsWithCrLfWithoutLeavingMixedNewlines', 0, () => {
      const crlfInput: string = `token: |\r\n  abc123\r\nlabel: keep`;
      const safe: string = redactSensitiveText(crlfInput);
      expect(safe.includes('abc123')).assertFalse();
      expect(safe.includes('label: keep')).assertTrue();
      expect(safe.includes('\r')).assertFalse();
    });

    it('redactsWindowsDriveAndUncPathsIncludingQuotedPathsWithSpaces', 0, () => {
      const safe: string = redactSensitiveText(`failed at "${buildDrivePathWithSpaces()}" and "${buildUncPathWithSpaces()}"`);
      expect(safe.includes('Space Folder')).assertFalse();
      expect(safe.includes('server')).assertFalse();
      expect(safe.includes('<path>')).assertTrue();
    });

    it('redactsRawCoreEventMessages', 0, () => {
      const safe: string = redactCoreEventMessage(
        `Proxy started with ${buildYamlLine(['to', 'ken'], '=', 'secret')} at ${buildRepoFixturePath()}`
      );
      expect(safe).assertEqual('Core event received.');
    });

    it('requiresNonEmptyProfileIdsAndValidLocalSourceDisplays', 0, () => {
      const revision: ProfileRevision = buildValidProfileRevision();
      expectThrows((): void => {
        createProfile({
          id: '   ',
          name: 'Local Invalid',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: buildLocalFilePath('local.yaml'),
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'id');
      expectThrows((): void => {
        createProfile({
          id: 'local-empty',
          name: 'Local Invalid',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: '/',
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'source');
      expectThrows((): void => {
        createProfile({
          id: 'local-dot',
          name: 'Local Invalid',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: '.',
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'source');
      expectThrows((): void => {
        createProfile({
          id: 'local-dotdot',
          name: 'Local Invalid',
          sourceKind: 'LOCAL_FILE',
          sourceDisplay: 'folder/..',
          currentRevision: revision,
          failedCandidate: null,
          availability: 'VALID',
          lastError: null,
          createdAt: buildCanonicalIsoTimestamp(),
          updatedAt: buildSecondCanonicalIsoTimestamp(),
          lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
        });
      }, 'source');
    });

    it('requiresSupportedRemoteUrlsForDurableSourceDisplay', 0, () => {
      const revision: ProfileRevision = buildValidProfileRevision();
      const validProfile: Profile = createProfile({
        id: 'remote-valid',
        name: 'Remote Valid',
        sourceKind: 'REMOTE_URL',
        sourceDisplay: buildIpv6UrlWithUserinfo(),
        sourceSecretRef: 'secret-ref-remote',
        currentRevision: revision,
        failedCandidate: null,
        availability: 'VALID',
        lastError: null,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildSecondCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
      });
      expect(validProfile.sourceDisplay).assertEqual('http://[2001:db8::1]:9090');

      const invalidUrls: string[] = [
        'https:///missing-host',
        'ftp://example.com/path',
        '<redacted-url>',
        'https://<redacted-host>',
        'not-a-url',
        'https://:443/path',
        'https://example.com bad',
        'https://example.com:/path',
        'https://2001:db8::1/path',
        'https://example.com\t/path'
      ];
      for (let index = 0; index < invalidUrls.length; index += 1) {
        expectThrows((): void => {
          createProfile({
            id: `remote-invalid-${index}`,
            name: 'Remote Invalid',
            sourceKind: 'REMOTE_URL',
            sourceDisplay: invalidUrls[index],
            sourceSecretRef: 'secret-ref-remote',
            currentRevision: revision,
            failedCandidate: null,
            availability: 'VALID',
            lastError: null,
            createdAt: buildCanonicalIsoTimestamp(),
            updatedAt: buildSecondCanonicalIsoTimestamp(),
            lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
          });
        }, 'source');
      }
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
      expect(error.code).assertEqual('CMFA_RUNTIME_START_FAILED');
      expect(error.retryable).assertTrue();
      expect(error.technicalDetail.includes(buildYamlLine(['to', 'ken'], '=', ''))).assertFalse();
      expect(error.technicalDetail.includes('.config/cmfa')).assertFalse();
      expect(error.technicalDetail.includes(joinTextFragments(['us', 'er']))).assertFalse();
      expect(error.technicalDetail.includes('example.com')).assertTrue();
      expect(error.technicalDetail.includes('raw core message')).assertFalse();
    });

    it('allowsOnlyKnownNativeCoreErrorCodesAndFallsBackForUntrustedCodes', 0, () => {
      const busyError: AppError = mapCoreError('startLocal', buildAllowedBusyCoreError());
      expect(busyError.code).assertEqual('CMFA_BUSY');

      const napiError: AppError = mapCoreError('load', buildAllowedNapiFailureError());
      expect(napiError.code).assertEqual('NAPI_FAILURE');

      const secretCodeError: AppError = mapCoreError(
        'startLocal',
        buildUntrustedCoreError('CMFA_SECRET_TOKEN')
      );
      expect(secretCodeError.code).assertEqual('CMFA_RUNTIME_START_FAILED');

      const longCodeError: AppError = mapCoreError(
        'startLocal',
        buildUntrustedCoreError(`CMFA_${'A'.repeat(200)}`)
      );
      expect(longCodeError.code).assertEqual('CMFA_RUNTIME_START_FAILED');
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

    it('defensivelyCopiesAndRedactsLastErrorWhenPersistingProfiles', 0, () => {
      const mutableError: MutableAppErrorFixture = new MutableAppErrorFixture(
        'APP_PLATFORM_TIMEOUT',
        'DOWNLOAD',
        'error.download.platform',
        `download failed for ${buildUrlWithUserinfo()} at ${buildHomeFixturePath()}`,
        buildCanonicalIsoTimestamp(),
        true
      );
      const profile: Profile = createProfile({
        id: 'last-error-profile',
        name: 'Last Error Profile',
        sourceKind: 'LOCAL_FILE',
        sourceDisplay: buildLocalFilePath('error.yaml'),
        currentRevision: buildValidProfileRevision(),
        failedCandidate: null,
        availability: 'VALID',
        lastError: mutableError,
        createdAt: buildCanonicalIsoTimestamp(),
        updatedAt: buildSecondCanonicalIsoTimestamp(),
        lastSuccessfulUpdateAt: buildThirdCanonicalIsoTimestamp()
      });

      mutableError.code = 'MUTATED_CODE';
      mutableError.technicalDetail = buildYamlLine(['to', 'ken'], '=', 'abc123');

      expect(profile.lastError?.code).assertEqual('APP_PLATFORM_TIMEOUT');
      expect(profile.lastError?.userMessageResource).assertEqual('error.download.platform');
      expect(profile.lastError?.retryable).assertTrue();
      expect(profile.lastError?.technicalDetail.includes('example.com')).assertTrue();
      expect(profile.lastError?.technicalDetail.includes('abc123')).assertFalse();
      expect(profile.lastError?.technicalDetail.includes('hunter2')).assertFalse();
    });
  });
}
