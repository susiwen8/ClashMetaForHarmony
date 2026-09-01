import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = fileURLToPath(new URL('../../..', import.meta.url));
const fixturePath = path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase5-geoip-rule.yaml');
const goTestPath = path.join(repoRoot, 'harmony', 'core', 'go', 'internal', 'config', 'validate_test.go');
const etsTestPath = path.join(repoRoot, 'harmony', 'platform', 'src', 'test', 'SubscriptionDownloader.test.ets');
const reportPath = path.join(repoRoot, 'docs', 'harmony', 'subscription-validation-compatibility.md');
const geodataLockPath = path.join(repoRoot, 'harmony', 'geodata.lock.json');

const GEODATA_LOCK_REPORT_IDENTITY_LABEL = 'geodata lock/report identity';
const CANONICAL_GEOIP_IDENTITY = Object.freeze({
  name: 'geoip.metadb',
  sizeBytes: 8593535,
  sha256: '71def3ab45393093baf9d39b69787b3e0d0685607c13dd135bfdbb603bd475dd'
});
const LATEST_GEOIP_URL_PATTERN = /^https:\/\/[^/\s?#]+(?:\/[^/\s?#]+)+\/latest\/geoip\.metadb$/u;
const ABSOLUTE_PATH_PATTERN =
  /(?:^|[\s'"`(])(?:\/(?:[^/\s'"`)]+\/)*[^/\s'"`)]*|[A-Za-z]:\\(?:[^\\\s'"`)]+\\)*[^\\\s'"`)]*|\\\\[^\\\s'"`)]+\\[^\\\s'"`)]+(?:\\[^\\\s'"`)]+)*)/u;

const EXPECTED_FIXTURE = [
  'mixed-port: 7890',
  'mode: rule',
  'rules:',
  '  - GEOIP,CN,DIRECT',
  '  - MATCH,DIRECT'
].join('\n');

const REQUIRED_REPORT_LINES = [
  {
    label: 'report statement missing-user-agent response class',
    statement: 'Missing product User-Agent returns a Base64 URI list response class.'
  },
  {
    label: 'report statement product-user-agent response class',
    statement: '`ClashMetaForAndroid/HarmonyOS` returns a full Clash YAML response class.'
  },
  {
    label: 'report statement geodata-missing first rule',
    statement: 'Initial parser replay is categorized as `GEODATA_MISSING` on the first rule entry.'
  },
  {
    label: 'report statement prepared-home acceptance',
    statement: 'Prepared-home replay with verified `geoip.metadb` wiring is accepted.'
  }
];
const EXPECTED_TASK6_FINAL_BOOLEANS = Object.freeze({
  step1_go_zero_failure: true,
  step1_platform_tests_pass: true,
  step1_entry_only_allowlist_failures: true,
  step1_structure_contracts_pass: true,
  step2_build_profile_started_safe_empty: true,
  step2_build_profile_restored_exact_bytes: true,
  step2_signing_temp_empty: true,
  step2_cleanup_safe_empty: true,
  step2_compat_contract_pass: true,
  step2_prebuild_task_tree_pass: true,
  step2_phase1_native_manifest_pass: true,
  step2_inspect_hap_production_pass: true,
  step2_task_tree_contract_pass: true,
  step2_signing_isolation_pass: true,
  step2_geodata_prepare_pass: true,
  step2_package_hap_pass: true,
  step3_device_install_refresh_executed: true,
  step4_device_evidence_collected: true,
  step4_geodata_installed_lock_match: true,
  step4_refresh_valid_current_error_null: true,
  step4_yaml_mapping_not_base64: true,
  step4_huks_ref_unchanged: true,
  step4_huks_envelope_unchanged: true,
  step5_runtime_gate_executed: true,
  step5_enable_active_match: true,
  step5_config_loaded_causal: true,
  step5_config_loaded_direct: false
});

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function joinFragments(fragments) {
  return fragments.join('');
}

function throwRule(label) {
  throw new Error(label);
}

function captureFailure(action) {
  try {
    action();
  } catch (error) {
    return error;
  }
  throw new Error('synthetic self-test expected failure');
}

function assertExactFixture(label, source, expected) {
  if (source.trim() !== expected) {
    throwRule(label);
  }
}

function requireStatement(label, source, statement) {
  if (!source.includes(statement)) {
    throwRule(label);
  }
}

function requirePattern(label, source, pattern) {
  pattern.lastIndex = 0;
  if (!pattern.test(source)) {
    throwRule(label);
  }
}

function assertNoPattern(label, source, pattern) {
  pattern.lastIndex = 0;
  if (pattern.test(source)) {
    throwRule(label);
  }
}

function assertEqualValue(label, actual, expected) {
  if (actual !== expected) {
    throwRule(label);
  }
}

function assertArrayLength(label, value, expectedLength) {
  if (!Array.isArray(value) || value.length !== expectedLength) {
    throwRule(label);
  }
}

function parseTask6FinalBooleans(source) {
  const sectionMatch = source.match(/^## Plan A Task 6 Safe Status\s*$([\s\S]*)/mu);
  if (!sectionMatch) {
    throwRule('task6 final boolean block');
  }

  const parsed = {};
  const booleanLines = sectionMatch[1]
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);

  for (const line of booleanLines) {
    const match = line.match(/^- `([^`]+)`: (true|false)$/u);
    if (!match) {
      throwRule('task6 final boolean block');
    }

    const [, key, rawValue] = match;
    if (Object.hasOwn(parsed, key)) {
      throwRule('task6 final boolean block');
    }
    parsed[key] = rawValue === 'true';
  }

  return parsed;
}

function assertExactTask6FinalBooleans(label, actual, expected) {
  const actualKeys = Object.keys(actual).sort();
  const expectedKeys = Object.keys(expected).sort();

  if (actualKeys.length !== expectedKeys.length) {
    throwRule(label);
  }

  for (let index = 0; index < expectedKeys.length; index += 1) {
    const expectedKey = expectedKeys[index];
    if (actualKeys[index] !== expectedKey || actual[expectedKey] !== expected[expectedKey]) {
      throwRule(label);
    }
  }
}

async function readCanonicalGeodataIdentity() {
  let parsed;
  try {
    parsed = JSON.parse(await fs.readFile(geodataLockPath, 'utf8'));
  } catch {
    throwRule(GEODATA_LOCK_REPORT_IDENTITY_LABEL);
  }

  assertArrayLength(GEODATA_LOCK_REPORT_IDENTITY_LABEL, parsed?.assets, 1);
  const asset = parsed.assets[0];

  assertEqualValue(GEODATA_LOCK_REPORT_IDENTITY_LABEL, asset?.name, CANONICAL_GEOIP_IDENTITY.name);
  assertEqualValue(GEODATA_LOCK_REPORT_IDENTITY_LABEL, asset?.sizeBytes, CANONICAL_GEOIP_IDENTITY.sizeBytes);
  assertEqualValue(GEODATA_LOCK_REPORT_IDENTITY_LABEL, asset?.sha256, CANONICAL_GEOIP_IDENTITY.sha256);
  assertArrayLength(GEODATA_LOCK_REPORT_IDENTITY_LABEL, asset?.urls, 1);

  if (typeof asset.urls[0] !== 'string') {
    throwRule(GEODATA_LOCK_REPORT_IDENTITY_LABEL);
  }
  requirePattern(GEODATA_LOCK_REPORT_IDENTITY_LABEL, asset.urls[0], LATEST_GEOIP_URL_PATTERN);

  return {
    name: asset.name,
    sizeBytes: asset.sizeBytes,
    sha256: asset.sha256
  };
}

test('sanitized pattern failures never echo the forbidden payload', () => {
  const syntheticPayload = 'token=masked-secret /private/var/mobile/report.yaml';
  const error = captureFailure(() => {
    assertNoPattern('synthetic leak rule', syntheticPayload, /token=/u);
  });

  assert.equal(error instanceof Error, true);
  assert.match(error.message, /synthetic leak rule/u);
  assert.doesNotMatch(error.message, /masked-secret|private|report\.yaml|token=/u);
});

test('sanitized statement failures only report the stable statement label', () => {
  const syntheticPayload = 'missing-statement body with /tmp/report.md and token=masked-secret';
  const error = captureFailure(() => {
    requireStatement('required statement label', syntheticPayload, 'Prepared-home replay is accepted.');
  });

  assert.equal(error instanceof Error, true);
  assert.match(error.message, /required statement label/u);
  assert.doesNotMatch(error.message, /masked-secret|\/tmp\/report\.md|Prepared-home replay is accepted\./u);
});

test('sanitized exact fixture failures never echo mutated fixture content', () => {
  const syntheticPayload = 'mixed-port: 7890\nmode: rule\ntoken=masked-secret\n';
  const error = captureFailure(() => {
    assertExactFixture('fixture exactness rule', syntheticPayload, EXPECTED_FIXTURE);
  });

  assert.equal(error instanceof Error, true);
  assert.match(error.message, /fixture exactness rule/u);
  assert.doesNotMatch(error.message, /masked-secret|mixed-port: 7890/u);
});

test('absolute path scanner catches common unix windows and unc forms without leaking them', () => {
  const windowsDrivePath = `${joinFragments(['C', ':'])}${joinFragments(['\\', '\\'])}${joinFragments(['Us', 'ers'])}${joinFragments(['\\', '\\'])}${joinFragments(['tester'])}${joinFragments(['\\', '\\'])}${joinFragments(['report.yaml'])}`;
  const pathSamples = [
    '/private/var/mobile/report.yaml',
    '/tmp/report.yaml',
    '/home/tester/report.yaml',
    '/opt/cmfa/report.yaml',
    windowsDrivePath,
    '\\\\server\\share\\report.yaml'
  ];

  for (const sample of pathSamples) {
    const error = captureFailure(() => {
      assertNoPattern('absolute path rule', sample, ABSOLUTE_PATH_PATTERN);
    });
    assert.equal(error instanceof Error, true);
    assert.match(error.message, /absolute path rule/u);
    assert.doesNotMatch(error.message, /private|tmp|home|opt|Users|server|report\.yaml/u);
  }
});

test('phase5 compatibility fixture stays minimal and credential-free', async () => {
  const fixture = await fs.readFile(fixturePath, 'utf8');

  assertExactFixture('fixture exactness', fixture, EXPECTED_FIXTURE);
  assertNoPattern('fixture forbidden section', fixture, /(?:^|\n)\s*(proxies|proxy-providers|proxy-groups|dns):/imu);
  assertNoPattern('fixture forbidden url', fixture, /https?:\/\//iu);
  assertNoPattern('fixture forbidden content uri', fixture, /content:\/\//iu);
  assertNoPattern('fixture forbidden credential marker', fixture, /@/u);
  assertNoPattern('fixture forbidden ipv4 endpoint', fixture, /\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/u);
  assertNoPattern('fixture forbidden absolute path', fixture, ABSOLUTE_PATH_PATTERN);
});

test('phase5 compatibility report keeps only safe evidence and the required root-cause statements', async () => {
  const [report, identity] = await Promise.all([
    fs.readFile(reportPath, 'utf8'),
    readCanonicalGeodataIdentity()
  ]);
  const task6FinalBooleans = parseTask6FinalBooleans(report);

  for (const entry of REQUIRED_REPORT_LINES) {
    requireStatement(entry.label, report, entry.statement);
  }

  requirePattern(
    GEODATA_LOCK_REPORT_IDENTITY_LABEL,
    report,
    new RegExp(`Canonical name:\\s*\`${escapeRegex(identity.name)}\``, 'u')
  );
  requirePattern(
    GEODATA_LOCK_REPORT_IDENTITY_LABEL,
    report,
    new RegExp(`Size:\\s*\`${escapeRegex(String(identity.sizeBytes))}\``, 'u')
  );
  requirePattern(
    GEODATA_LOCK_REPORT_IDENTITY_LABEL,
    report,
    new RegExp(`SHA-256:\\s*\`${escapeRegex(identity.sha256)}\``, 'u')
  );
  requirePattern('report redaction controls statement', report, /credentials are redacted/iu);
  requirePattern(
    'report safe evidence statement',
    report,
    /response class, validation category, first-rule placement, and pinned asset identity/iu
  );
  assertExactTask6FinalBooleans('task6 final boolean contract', task6FinalBooleans, EXPECTED_TASK6_FINAL_BOOLEANS);

  const forbiddenPatterns = [
    ['report forbidden url', /https?:\/\//iu],
    ['report forbidden content uri', /content:\/\//iu],
    ['report forbidden token marker', /token=/iu],
    ['report forbidden credential marker', /@/u],
    ['report forbidden absolute path', ABSOLUTE_PATH_PATTERN],
    ['report forbidden parser text', /can't find MMDB/iu],
    ['report forbidden ipv4 endpoint', /\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/u],
    ['report forbidden host endpoint', /\b(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)\b/iu]
  ];
  for (const [label, pattern] of forbiddenPatterns) {
    assertNoPattern(label, report, pattern);
  }
});

test('phase5 source contracts pin the exact UA negotiation fixture and GeoIP identity', async () => {
  const [goTestSource, etsTestSource] = await Promise.all([
    fs.readFile(goTestPath, 'utf8'),
    fs.readFile(etsTestPath, 'utf8')
  ]);

  requirePattern(
    'go compatibility contract geodata-missing fixture replay',
    goTestSource,
    /TestValidateFileWithDepsClassifiesGeoIPFixtureAsGeodataMissing/u
  );
  requirePattern(
    'go compatibility contract prepared-home replay',
    goTestSource,
    /TestValidateFileWithDepsAcceptsGeoIPFixtureWhenPreparedHomeContainsPinnedGeoIP/u
  );
  requirePattern('go compatibility contract fixture path', goTestSource, /phase5-geoip-rule\.yaml/u);
  requirePattern('go compatibility contract geoip filename', goTestSource, /geoip\.metadb/u);

  requirePattern('ets compatibility contract transport helper', etsTestSource, /CompatibilityNegotiatingTransport/u);
  requirePattern('ets compatibility contract base64 branch sentinel', etsTestSource, /QkFTRTY0X0NMQVNTX09OTFk=/u);
  requirePattern('ets compatibility contract product user-agent', etsTestSource, /ClashMetaForAndroid\/HarmonyOS/u);
  requirePattern(
    'ets compatibility contract staged yaml branch',
    etsTestSource,
    /keepsResponseNegotiationBranchesSeparatedAndStagesOnlyTheProductYamlPayload/u
  );

  await readCanonicalGeodataIdentity();
});
