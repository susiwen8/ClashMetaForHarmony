import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildPhase1Native } from './build-phase1-native.mjs';
import { inspectHap } from './inspect-hap.mjs';
import {
  classifyHarmonyTarget,
  hashRepoFile,
  resolveExistingRepoScopedPath,
  resolveHdcCommand,
  resolveRepoScopedOutputPath
} from './run-phase2-device-proof.mjs';
import { analyzeTargetDiscovery, buildTargetedHdcArgs, createMaskedDeviceIdentity, execCommand } from './run-phase0-device-proof.mjs';
import { createRedactionReplacements, sanitizeForPersistence, sanitizeText } from '../../tools/lib/proof-redaction.mjs';
import { inspectToolchain, normalizeNodeVersion } from '../../tools/lib/toolchain.mjs';

export const PROOF_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 3;
export const BUNDLE_NAME = 'com.github.kr328.clash.harmony';
export const ENTRY_ABILITY_NAME = 'EntryAbility';
export const TEST_MODULE_NAME = 'entry_test';
export const TEST_RUNNER_NAME = 'OpenHarmonyTestRunner';
export const APP_PROOF_REMOTE_PATH = '/data/storage/el2/base/files/phase3-simulator-app-evidence.json';
export const MAX_PHASE3_APP_EVIDENCE_BYTES = 1024 * 1024;

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase3-simulator-proof.json');
export const DEFAULT_BUILD_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase3-build-manifest.json');
export const DEFAULT_ENTRY_TEST_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'ohosTest', 'entry-ohosTest-unsigned.hap');
export const DEFAULT_FIXTURE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase3-valid.yaml');

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const DIGEST_PATTERN = /^[a-f0-9]{64}$/u;
const STEP_RESULTS = new Set(['pass', 'fail', 'incomplete', 'not-run']);
const CHECK_RESULTS = new Set(['pass', 'fail', 'incomplete']);
const TARGET_KINDS = new Set(['host', 'simulator', 'physical', 'unknown']);
export const REQUIRED_EVIDENCE_SUITES = ['Phase3PlatformAdapters', 'Phase3RuntimeFlow', 'Phase3UiFlow'];
export const REQUIRED_EVIDENCE_CHECKS = [
  'Phase3PlatformAdapters: pass',
  'Phase3RuntimeFlow: validate > retain/save > enable.validate > enable.load > start.revalidate > start.load > startLocal(7890) > RUNNING 127.0.0.1:7890 127.0.0.1:7891 > stop > STOPPED',
  'Phase3UiFlow: pass'
];

function isoTimestamp(date = new Date()) {
  return date.toISOString();
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isDigest(value) {
  return DIGEST_PATTERN.test(String(value ?? ''));
}

function isUuid(value) {
  return UUID_PATTERN.test(String(value ?? ''));
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function createFailure(code, detail, stage = 'proof') {
  return { code, detail, stage };
}

function normalizePathForReport(repoRoot, absolutePath) {
  if (!absolutePath) {
    return null;
  }
  const relativePath = path.relative(repoRoot, absolutePath);
  if (!relativePath.startsWith('..') && !path.isAbsolute(relativePath)) {
    return relativePath.split(path.sep).join('/');
  }
  return path.basename(absolutePath);
}

async function hashFile(fsApi, filePath) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

async function readJson(fsApi, filePath, code) {
  try {
    return JSON.parse(await fsApi.readFile(filePath, 'utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? `Unable to read ${filePath}`), { code });
  }
}

async function readToolchainVersions(fsApi, harmonyRoot) {
  try {
    const lock = JSON.parse(await fsApi.readFile(path.join(harmonyRoot, 'toolchain.lock.json'), 'utf8'));
    return {
      devecoVersion: lock?.installed?.devecoVersion ?? null,
      sdkVersion: lock?.installed?.sdkVersion ?? null,
      ndkVersion: lock?.installed?.ndkVersion ?? null,
      hvigorVersion: lock?.installed?.hvigorVersion ?? null,
      nodeVersion: normalizeNodeVersion(process.version),
      hdcVersion: lock?.installed?.hdcVersion ?? null
    };
  } catch {
    return {
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hvigorVersion: null,
      nodeVersion: normalizeNodeVersion(process.version),
      hdcVersion: null
    };
  }
}

function createBaseProof({ repoRoot, outputPath, runId, startedAt }) {
  return {
    schemaVersion: PROOF_SCHEMA_VERSION,
    phase: PHASE_NUMBER,
    result: 'incomplete',
    runId,
    outputPath: normalizePathForReport(repoRoot, outputPath),
    bundle: BUNDLE_NAME,
    productionAbility: ENTRY_ABILITY_NAME,
    testModule: TEST_MODULE_NAME,
    testRunner: TEST_RUNNER_NAME,
    timestamps: {
      runnerStartedAt: isoTimestamp(startedAt),
      testStartedAt: null,
      proofAt: null,
      runnerFinishedAt: isoTimestamp(startedAt)
    },
    toolchain: {
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hvigorVersion: null,
      nodeVersion: normalizeNodeVersion(process.version),
      hdcVersion: null
    },
    target: {
      targetKind: 'host',
      identityMasked: null,
      model: null,
      product: null,
      buildVersion: null,
      apiVersion: null,
      abi: null
    },
    fixture: {
      path: null,
      sha256: null,
      sizeBytes: null
    },
    haps: {
      production: {
        path: null,
        sha256: null,
        sizeBytes: null,
        buildKind: 'production',
        stubDetected: null,
        architecture: null
      },
      entryTest: {
        path: null,
        sha256: null,
        sizeBytes: null
      }
    },
    appEvidence: {
      path: null,
      sha256: null,
      sizeBytes: null,
      runId: null,
      productionHapSha256: null,
      entryTestHapSha256: null,
      fixtureSha256: null,
      status: null,
      suites: [],
      checks: [],
      trace: [],
      failureCount: 0,
      homeSnapshotAddress: null,
      homeRuntimeAddress: null,
      cleanup: null
    },
    checks: {
      adapterSuite: 'incomplete',
      runtimeSuite: 'incomplete',
      uiSuite: 'incomplete',
      startStop: 'incomplete',
      identitiesMatch: 'incomplete',
      homeAddressesMatch: 'incomplete',
      cleanup: 'incomplete'
    },
    cleanup: {
      forceStopResult: 'not-run',
      uninstallResult: 'not-run',
      rebuildDefaultProductionLane: 'not-run',
      localPullDirectoryResult: 'not-run'
    },
    physicalDeviceGates: {
      phase2Traffic: 'incomplete',
      phase3ProfileRuntime: 'incomplete'
    },
    failures: []
  };
}

function pushFailure(proof, code, detail, stage) {
  if (proof.failures.some((entry) => entry.code === code && entry.detail === detail && entry.stage === stage)) {
    return;
  }
  proof.failures.push(createFailure(code, detail, stage));
}

function exactOrderedArrayEqual(actual, expected) {
  return Array.isArray(actual) &&
    actual.length === expected.length &&
    actual.every((entry, index) => entry === expected[index]);
}

function copyInspectionSummary(target, inspection) {
  target.path = inspection?.hap?.path ?? target.path;
  target.sha256 = inspection?.hap?.sha256 ?? target.sha256;
  target.sizeBytes = inspection?.hap?.sizeBytes ?? target.sizeBytes;
  target.stubDetected = inspection?.stubDetected ?? null;
  target.architecture = inspection?.packaged?.core?.elf?.architecture ?? null;
}

function finalizeChecksFromEvidence(proof, evidence) {
  const exactSuites = exactOrderedArrayEqual(evidence.suites, REQUIRED_EVIDENCE_SUITES);
  const exactChecks = exactOrderedArrayEqual(evidence.checks, REQUIRED_EVIDENCE_CHECKS);
  proof.checks.adapterSuite = exactSuites && evidence.checks?.[0] === REQUIRED_EVIDENCE_CHECKS[0] ? 'pass' : 'fail';
  proof.checks.runtimeSuite = exactSuites && evidence.checks?.[1] === REQUIRED_EVIDENCE_CHECKS[1] ? 'pass' : 'fail';
  proof.checks.uiSuite = exactSuites && evidence.checks?.[2] === REQUIRED_EVIDENCE_CHECKS[2] ? 'pass' : 'fail';
  proof.checks.startStop = exactChecks && evidence.status === 'PASS' ? 'pass' : 'fail';
  proof.checks.identitiesMatch = (
    evidence.runId === proof.runId &&
    evidence.productionHapSha256 === proof.haps.production.sha256 &&
    evidence.entryTestHapSha256 === proof.haps.entryTest.sha256 &&
    evidence.fixtureSha256 === proof.fixture.sha256
  ) ? 'pass' : 'fail';
  proof.checks.homeAddressesMatch = evidence.homeSnapshotAddress === evidence.homeRuntimeAddress &&
    isNonEmptyString(evidence.homeSnapshotAddress)
    ? 'pass'
    : 'fail';
  proof.checks.cleanup = evidence.cleanup === 'pass' ? 'pass' : 'fail';
}

function allChecksPass(checks) {
  return Object.values(checks).every((value) => value === 'pass');
}

function canProvisionalPass(proof) {
  return proof.target.targetKind === 'simulator' &&
    proof.haps.production.architecture === 'AArch64' &&
    proof.haps.production.stubDetected === false &&
    proof.physicalDeviceGates.phase2Traffic === 'incomplete' &&
    proof.physicalDeviceGates.phase3ProfileRuntime === 'incomplete' &&
    proof.appEvidence.status === 'PASS' &&
    proof.appEvidence.failureCount === 0 &&
    exactOrderedArrayEqual(proof.appEvidence.suites, REQUIRED_EVIDENCE_SUITES) &&
    exactOrderedArrayEqual(proof.appEvidence.checks, REQUIRED_EVIDENCE_CHECKS) &&
    allChecksPass(proof.checks) &&
    proof.cleanup.forceStopResult === 'pass' &&
    proof.cleanup.uninstallResult === 'pass' &&
    proof.cleanup.rebuildDefaultProductionLane === 'pass' &&
    proof.cleanup.localPullDirectoryResult === 'pass' &&
    proof.failures.length === 0;
}

function finalizeResult(proof) {
  proof.result = canProvisionalPass(proof) ? 'provisional-pass' : 'incomplete';
  return proof;
}

function validateFailureArray(failures, errors) {
  if (!Array.isArray(failures)) {
    errors.push('failures must be an array.');
    return;
  }
  for (const failure of failures) {
    if (!isNonEmptyString(failure?.code) || !isNonEmptyString(failure?.detail) || !isNonEmptyString(failure?.stage)) {
      errors.push('failures entries must contain non-empty code/detail/stage strings.');
      return;
    }
  }
}

export function validatePhase3Proof(proof) {
  const errors = [];
  if (proof?.schemaVersion !== PROOF_SCHEMA_VERSION) errors.push(`schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  if (proof?.phase !== PHASE_NUMBER) errors.push(`phase must be ${PHASE_NUMBER}.`);
  if (!['provisional-pass', 'incomplete'].includes(String(proof?.result ?? ''))) errors.push('result must be provisional-pass or incomplete.');
  if (!isUuid(proof?.runId)) errors.push('runId must be a UUID.');
  if (!isNonEmptyString(proof?.outputPath)) errors.push('outputPath must be a non-empty string.');
  if (!isIsoTimestamp(proof?.timestamps?.runnerStartedAt) || !isIsoTimestamp(proof?.timestamps?.runnerFinishedAt)) {
    errors.push('timestamps.runnerStartedAt and runnerFinishedAt must be ISO timestamps.');
  }
  if (!TARGET_KINDS.has(String(proof?.target?.targetKind ?? ''))) errors.push('target.targetKind must be host, simulator, physical, or unknown.');
  if (!isNonEmptyString(proof?.fixture?.path) || !isDigest(proof?.fixture?.sha256) || !Number.isInteger(proof?.fixture?.sizeBytes)) {
    errors.push('fixture must include path/sha256/sizeBytes.');
  }
  if (!isNonEmptyString(proof?.haps?.production?.path) || !isDigest(proof?.haps?.production?.sha256) || !Number.isInteger(proof?.haps?.production?.sizeBytes)) {
    errors.push('haps.production must include path/sha256/sizeBytes.');
  }
  if (!isNonEmptyString(proof?.haps?.entryTest?.path) || !isDigest(proof?.haps?.entryTest?.sha256) || !Number.isInteger(proof?.haps?.entryTest?.sizeBytes)) {
    errors.push('haps.entryTest must include path/sha256/sizeBytes.');
  }
  for (const key of ['adapterSuite', 'runtimeSuite', 'uiSuite', 'startStop', 'identitiesMatch', 'homeAddressesMatch', 'cleanup']) {
    if (!CHECK_RESULTS.has(String(proof?.checks?.[key] ?? ''))) {
      errors.push(`checks.${key} must be pass, fail, or incomplete.`);
    }
  }
  for (const key of ['forceStopResult', 'uninstallResult', 'rebuildDefaultProductionLane', 'localPullDirectoryResult']) {
    if (!STEP_RESULTS.has(String(proof?.cleanup?.[key] ?? ''))) {
      errors.push(`cleanup.${key} must be pass, fail, incomplete, or not-run.`);
    }
  }
  if (proof?.physicalDeviceGates?.phase2Traffic !== 'incomplete' || proof?.physicalDeviceGates?.phase3ProfileRuntime !== 'incomplete') {
    errors.push('physicalDeviceGates must stay fixed to incomplete.');
  }
  validateFailureArray(proof?.failures, errors);
  if (proof?.result === 'provisional-pass') {
    if (proof?.target?.targetKind !== 'simulator') errors.push('provisional-pass requires a simulator target.');
    if (proof?.haps?.production?.stubDetected !== false) errors.push('provisional-pass requires haps.production.stubDetected === false.');
    if (proof?.haps?.production?.architecture !== 'AArch64') errors.push('provisional-pass requires AArch64 production core.');
    if (proof?.appEvidence?.status !== 'PASS') errors.push('provisional-pass requires appEvidence.status === PASS.');
    if (proof?.appEvidence?.failureCount !== 0) errors.push('provisional-pass requires appEvidence.failureCount === 0.');
    if (!exactOrderedArrayEqual(proof?.appEvidence?.suites, REQUIRED_EVIDENCE_SUITES)) errors.push('provisional-pass requires exact suite coverage.');
    if (!exactOrderedArrayEqual(proof?.appEvidence?.checks, REQUIRED_EVIDENCE_CHECKS)) errors.push('provisional-pass requires exact allowlisted checks.');
    if (proof?.appEvidence?.runId !== proof?.runId) errors.push('provisional-pass requires appEvidence.runId to match runId.');
    if (proof?.appEvidence?.productionHapSha256 !== proof?.haps?.production?.sha256 || proof?.appEvidence?.entryTestHapSha256 !== proof?.haps?.entryTest?.sha256) {
      errors.push('provisional-pass requires appEvidence HAP identities to match the runner inputs.');
    }
    if (proof?.appEvidence?.fixtureSha256 !== proof?.fixture?.sha256) errors.push('provisional-pass requires appEvidence.fixtureSha256 to match the runner fixture.');
    if (proof?.appEvidence?.cleanup !== 'pass') errors.push('provisional-pass requires appEvidence.cleanup === pass.');
    if (proof?.appEvidence?.homeSnapshotAddress !== proof?.appEvidence?.homeRuntimeAddress) {
      errors.push('provisional-pass requires matching Home/runtime addresses.');
    }
    if (!allChecksPass(proof?.checks ?? {})) errors.push('provisional-pass requires all checks to pass.');
    if (proof?.cleanup?.forceStopResult !== 'pass' || proof?.cleanup?.uninstallResult !== 'pass' || proof?.cleanup?.rebuildDefaultProductionLane !== 'pass' || proof?.cleanup?.localPullDirectoryResult !== 'pass') {
      errors.push('provisional-pass requires cleanup and rebuild to pass.');
    }
    if ((proof?.failures?.length ?? 0) !== 0) errors.push('provisional-pass requires failures to be empty.');
  }
  return { valid: errors.length === 0, errors };
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID' });
  }
  return value;
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase3-simulator-proof.json');
  let productionManifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase3-build-manifest.json');
  let entryTestHapPath = path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'outputs', 'ohosTest', 'entry-ohosTest-unsigned.hap');
  let fixturePath = path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase3-valid.yaml');

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--out') {
      outputPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--production-manifest') {
      productionManifestPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--entry-test-hap') {
      entryTestHapPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--fixture') {
      fixturePath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID' });
  }

  return {
    outputPath,
    productionManifestPath,
    entryTestHapPath,
    fixturePath
  };
}

function parseCliArgumentsPartial(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase3-simulator-proof.json');
  let productionManifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase3-build-manifest.json');
  let entryTestHapPath = path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'outputs', 'ohosTest', 'entry-ohosTest-unsigned.hap');
  let fixturePath = path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase3-valid.yaml');

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--out') {
      outputPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--production-manifest') {
      productionManifestPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--entry-test-hap') {
      entryTestHapPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--fixture') {
      fixturePath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    throw Object.assign(new Error(`Unknown argument: ${option}`), {
      code: 'ARGUMENT_INVALID',
      partial: {
        outputPath,
        productionManifestPath,
        entryTestHapPath,
        fixturePath
      }
    });
  }

  return {
    outputPath,
    productionManifestPath,
    entryTestHapPath,
    fixturePath
  };
}

async function writeProof(proof, outputPath, fsApi = fs, repoRoot = REPO_ROOT) {
  const resolvedOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath);
  await fsApi.writeFile(resolvedOutputPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
}

function buildPullArgs(target, localPath) {
  return buildTargetedHdcArgs(target, [
    'file', 'recv', '-b', BUNDLE_NAME,
    APP_PROOF_REMOTE_PATH,
    localPath
  ]);
}

function buildTestArgs(target, runId, proof) {
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'test',
    '-b', BUNDLE_NAME,
    '-m', TEST_MODULE_NAME,
    '-s', 'unittest', TEST_RUNNER_NAME,
    '-s', 'cmfa.phase3.runId', runId,
    '-s', 'cmfa.phase3.fixtureSha256', proof.fixture.sha256,
    '-s', 'cmfa.phase3.productionHapSha256', proof.haps.production.sha256,
    '-s', 'cmfa.phase3.entryTestHapSha256', proof.haps.entryTest.sha256
  ]);
}

async function ensureRepoScopedPullPath(fsApi, repoRoot, localPath) {
  return await resolveRepoScopedOutputPath(fsApi, repoRoot, localPath);
}

export function parsePhase3AppEvidence(raw) {
  const errors = [];
  if (raw?.schemaVersion !== '1.0.0') errors.push('schemaVersion must be 1.0.0.');
  if (raw?.phase !== 3) errors.push('phase must be 3.');
  if (raw?.task !== 14) errors.push('task must be 14.');
  if (!['RUNNING', 'PASS', 'FAIL', 'INCOMPLETE'].includes(String(raw?.status ?? ''))) errors.push('status must be RUNNING, PASS, FAIL, or INCOMPLETE.');
  if (!isIsoTimestamp(raw?.updatedAt)) errors.push('updatedAt must be an ISO timestamp.');
  if (!isUuid(raw?.runId)) errors.push('runId must be a UUID.');
  for (const key of ['productionHapSha256', 'entryTestHapSha256', 'fixtureSha256']) {
    if (!isDigest(raw?.[key])) errors.push(`${key} must be a SHA-256 digest.`);
  }
  if (!Array.isArray(raw?.suites) || !raw.suites.every(isNonEmptyString)) errors.push('suites must be a non-empty string array.');
  if (!Array.isArray(raw?.checks) || !raw.checks.every(isNonEmptyString)) errors.push('checks must be a string array.');
  if (!Array.isArray(raw?.trace) || !raw.trace.every(isNonEmptyString)) errors.push('trace must be a string array.');
  if (!Array.isArray(raw?.failures)) {
    errors.push('failures must be an array.');
  } else if (!raw.failures.every((entry) => isNonEmptyString(entry?.suite) && isNonEmptyString(entry?.detail))) {
    errors.push('failures entries must include suite/detail strings.');
  }
  if (!['pass', 'fail', 'incomplete'].includes(String(raw?.cleanup ?? ''))) errors.push('cleanup must be pass, fail, or incomplete.');
  if (!isNonEmptyString(raw?.homeSnapshotAddress) || !isNonEmptyString(raw?.homeRuntimeAddress)) {
    errors.push('homeSnapshotAddress and homeRuntimeAddress must be non-empty strings.');
  }

  return {
    valid: errors.length === 0,
    errors,
    normalized: errors.length === 0 ? {
      ...raw,
      suites: [...raw.suites],
      checks: [...raw.checks],
      trace: [...raw.trace],
      failures: raw.failures.map((entry) => ({ suite: entry.suite, detail: entry.detail }))
    } : null
  };
}

export async function pullPhase3AppEvidence({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  localPath,
  cwd,
  expectedRunId,
  expectedProductionHapSha256,
  expectedEntryTestHapSha256,
  expectedFixtureSha256,
  startedAt,
  remotePath = APP_PROOF_REMOTE_PATH
} = {}) {
  let safeLocalPath = localPath;
  try {
    safeLocalPath = await ensureRepoScopedPullPath(fsApi, cwd, localPath);
  } catch (error) {
    return {
      ok: false,
      invalid: createFailure(error?.code ?? 'APP_EVIDENCE_PATH_INVALID', error?.message ?? 'Invalid pull path.', 'app-proof')
    };
  }

  const result = await execImpl(hdcCommand, buildPullArgs(target, safeLocalPath), { cwd, remotePath });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    return {
      ok: false,
      result,
      invalid: createFailure('APP_EVIDENCE_MISSING', 'The simulator did not produce a readable app evidence file.', 'app-proof')
    };
  }

  let fileHandle = null;
  try {
    fileHandle = await fsApi.open(safeLocalPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    const stats = await fileHandle.stat();
    if (!stats.isFile()) {
      throw Object.assign(new Error('Pulled app evidence must be a regular file.'), { code: 'APP_EVIDENCE_NOT_REGULAR' });
    }
    if (stats.size < 1 || stats.size > MAX_PHASE3_APP_EVIDENCE_BYTES) {
      throw Object.assign(new Error(`Pulled app evidence must be between 1 and ${MAX_PHASE3_APP_EVIDENCE_BYTES} bytes.`), { code: 'APP_EVIDENCE_SIZE_INVALID' });
    }
    if (startedAt && stats.mtimeMs < startedAt.getTime()) {
      throw Object.assign(new Error('Pulled app evidence predates the current runner start time.'), { code: 'APP_EVIDENCE_STALE' });
    }
    const buffer = await fileHandle.readFile();
    let parsed;
    try {
      parsed = JSON.parse(buffer.toString('utf8'));
    } catch (error) {
      throw Object.assign(new Error(error?.message ?? 'Unable to parse app evidence JSON.'), { code: 'APP_EVIDENCE_INVALID' });
    }
    const validation = parsePhase3AppEvidence(parsed);
    if (!validation.valid) {
      return {
        ok: false,
        result,
        invalid: createFailure('APP_EVIDENCE_INVALID', validation.errors.join('; '), 'app-proof')
      };
    }
    const normalized = validation.normalized;
    if (normalized.runId !== expectedRunId) {
      return { ok: false, result, invalid: createFailure('APP_EVIDENCE_RUN_ID_MISMATCH', 'App evidence runId did not match the runner runId.', 'app-proof') };
    }
    if (normalized.productionHapSha256 !== expectedProductionHapSha256 || normalized.entryTestHapSha256 !== expectedEntryTestHapSha256) {
      return { ok: false, result, invalid: createFailure('APP_EVIDENCE_HAP_MISMATCH', 'App evidence HAP identities did not match the runner inputs.', 'app-proof') };
    }
    if (normalized.fixtureSha256 !== expectedFixtureSha256) {
      return { ok: false, result, invalid: createFailure('APP_EVIDENCE_FIXTURE_MISMATCH', 'App evidence fixture identity did not match the runner input.', 'app-proof') };
    }
    const digest = {
      sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
      sizeBytes: buffer.byteLength
    };
    return {
      ok: true,
      result,
      proof: normalized,
      localPath: safeLocalPath,
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes
    };
  } catch (error) {
    return {
      ok: false,
      result,
      invalid: createFailure(error?.code ?? 'APP_EVIDENCE_INVALID', error?.message ?? 'Unable to read app evidence.', 'app-proof')
    };
  } finally {
    if (fileHandle) {
      await fileHandle.close().catch(() => {});
    }
  }
}

async function readTargetFact({ execImpl, hdcCommand, target, keys, cwd }) {
  for (const key of keys) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    if (!result?.error && result?.exitCode === 0) {
      const value = String(result.stdout ?? '').trim();
      if (value.length > 0) {
        return value;
      }
    }
  }
  return null;
}

async function installHap({ execImpl, hdcCommand, target, hapPath, cwd }) {
  return await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['install', '-r', hapPath]), { cwd });
}

async function runDefaultSimulatorTest({ execImpl, hdcCommand, target, proof, cwd }) {
  return await execImpl(hdcCommand, buildTestArgs(target, proof.runId, proof), { cwd });
}

export async function runPhase3SimulatorProof({
  productionManifestPath = DEFAULT_BUILD_MANIFEST_PATH,
  entryTestHapPath = DEFAULT_ENTRY_TEST_HAP_PATH,
  fixturePath = DEFAULT_FIXTURE_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  buildPhase1NativeImpl = buildPhase1Native,
  inspectHapImpl = inspectHap,
  toolchainInspectorImpl = inspectToolchain,
  execImpl = execCommand,
  runTestImpl = runDefaultSimulatorTest,
  pullPhase3AppEvidenceImpl = pullPhase3AppEvidence,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date()
} = {}) {
  const startedAt = now();
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  const proof = createBaseProof({ repoRoot, outputPath, runId: randomUUID(), startedAt });
  const harmonyRoot = path.join(repoRoot, 'harmony');
  let target = null;
  let hdcCommand = null;
  let installedAny = false;
  let shouldRebuildDefaultProductionLane = false;
  const pullDirectoryPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase3-pull', proof.runId);

  const finish = async () => {
    proof.timestamps.runnerFinishedAt = isoTimestamp(now());
    const sanitized = sanitizeForPersistence(finalizeResult(proof), replacements);
    const validation = validatePhase3Proof(sanitized);
    if (!validation.valid) {
      sanitized.result = 'incomplete';
      sanitized.failures.push(createFailure('PHASE3_SIMULATOR_PROOF_INVALID', validation.errors.join('; '), 'proof'));
    }
    await writeProof(sanitized, outputPath, fsApi, repoRoot);
    return sanitized;
  };

  try {
    main: {
      proof.toolchain = await readToolchainVersions(fsApi, harmonyRoot);
      const fixtureDigest = await hashRepoFile(fsApi, repoRoot, fixturePath, '--fixture');
      proof.fixture = {
        path: fixtureDigest.path,
        sha256: fixtureDigest.sha256,
        sizeBytes: fixtureDigest.sizeBytes
      };

      const builtManifest = await buildPhase1NativeImpl({
        outputPath: productionManifestPath,
        phase2SelfTestEnabled: false
      });
      const manifest = builtManifest ?? await readJson(fsApi, productionManifestPath, 'BUILD_MANIFEST_INVALID');

      const productionIdentity = manifest?.artifacts?.hap?.identity;
      if (!isNonEmptyString(productionIdentity)) {
        pushFailure(proof, 'INPUT_HAP_MISSING', 'The production manifest did not expose a signed production HAP identity.', 'build');
        break main;
      }

      const productionArtifact = await hashRepoFile(fsApi, repoRoot, path.join(repoRoot, productionIdentity), '--production-hap');
      proof.haps.production.path = productionArtifact.path;
      proof.haps.production.sha256 = productionArtifact.sha256;
      proof.haps.production.sizeBytes = productionArtifact.sizeBytes;

      const entryTestArtifact = await hashRepoFile(fsApi, repoRoot, entryTestHapPath, '--entry-test-hap');
      proof.haps.entryTest = {
        path: entryTestArtifact.path,
        sha256: entryTestArtifact.sha256,
        sizeBytes: entryTestArtifact.sizeBytes
      };

      let unsignedBlocker = false;
      if (/-unsigned\.hap$/iu.test(path.basename(productionArtifact.absolutePath)) || /-unsigned\.hap$/iu.test(path.basename(entryTestArtifact.absolutePath))) {
        pushFailure(proof, 'INPUT_HAP_UNSIGNED', 'Unsigned simulator proof HAPs cannot enter the install/test lane.', 'input');
        unsignedBlocker = true;
      }
      if (manifest?.signing?.result !== 'pass') {
        pushFailure(proof, 'SIGNING_REQUIRED', 'A signed production HAP is required before any simulator proof can run.', 'signing');
        break main;
      }
      if (unsignedBlocker) {
        break main;
      }

      const inspection = await inspectHapImpl({
        hapPath: productionArtifact.absolutePath,
        manifest,
        manifestPath: productionManifestPath,
        buildKind: 'production',
        repoRoot,
        fsApi
      });
      copyInspectionSummary(proof.haps.production, inspection);
      for (const failure of inspection.failures ?? []) {
        pushFailure(proof, failure.code, failure.detail, failure.stage ?? 'archive');
      }
      if (inspection.result !== 'pass') {
        break main;
      }

      hdcCommand = await resolveHdcCommand(toolchainInspectorImpl, repoRoot);
      const targetResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
      const targetAnalysis = analyzeTargetDiscovery(targetResult);
      if (targetAnalysis.kind === 'missing') {
        pushFailure(proof, 'DEVICE_TARGET_MISSING', 'No HarmonyOS simulator target is available for Phase 3.', 'target');
        break main;
      }
      if (targetAnalysis.kind === 'ambiguous') {
        pushFailure(proof, 'DEVICE_TARGET_AMBIGUOUS', 'Phase 3 requires exactly one selected HarmonyOS simulator target.', 'target');
        break main;
      }

      target = targetAnalysis.targets[0];
      proof.target.identityMasked = createMaskedDeviceIdentity(target);
      proof.target.buildVersion = await readTargetFact({ execImpl, hdcCommand, target, keys: ['const.product.software.version'], cwd: repoRoot });
      proof.target.apiVersion = await readTargetFact({ execImpl, hdcCommand, target, keys: ['const.ohos.apiversion', 'const.product.apiversion'], cwd: repoRoot });
      proof.target.abi = await readTargetFact({ execImpl, hdcCommand, target, keys: ['const.product.cpu.abilist'], cwd: repoRoot });
      proof.target.model = await readTargetFact({ execImpl, hdcCommand, target, keys: ['const.product.model'], cwd: repoRoot });
      proof.target.product = await readTargetFact({ execImpl, hdcCommand, target, keys: ['const.product.name', 'const.product.device'], cwd: repoRoot });
      const classification = classifyHarmonyTarget(proof.target);
      if (classification.kind === 'physical') {
        proof.target.targetKind = 'physical';
        pushFailure(proof, 'SIMULATOR_TARGET_REQUIRED', 'Phase 3 simulator proof must never classify a physical-only target as sufficient evidence.', 'target');
        break main;
      }
      if (classification.kind !== 'simulator') {
        proof.target.targetKind = 'unknown';
        pushFailure(proof, classification.code, classification.detail, 'target');
        break main;
      }
      proof.target.targetKind = 'simulator';

      const productionInstall = await installHap({ execImpl, hdcCommand, target, hapPath: productionArtifact.absolutePath, cwd: repoRoot });
      if (productionInstall?.error || productionInstall?.exitCode !== 0 || productionInstall?.timedOut) {
        pushFailure(proof, 'HDC_INSTALL_FAILED', sanitizeText(productionInstall?.stderr ?? 'Failed to install the production HAP on the simulator.', replacements), 'install');
        break main;
      }
      installedAny = true;

      const entryTestInstall = await installHap({ execImpl, hdcCommand, target, hapPath: entryTestArtifact.absolutePath, cwd: repoRoot });
      if (entryTestInstall?.error || entryTestInstall?.exitCode !== 0 || entryTestInstall?.timedOut) {
        pushFailure(proof, 'HDC_INSTALL_FAILED', sanitizeText(entryTestInstall?.stderr ?? 'Failed to install the entry_test HAP on the simulator.', replacements), 'install');
        break main;
      }

      proof.timestamps.testStartedAt = isoTimestamp(now());
      shouldRebuildDefaultProductionLane = true;
      const testResult = await runTestImpl({ execImpl, hdcCommand, target, proof, cwd: repoRoot });
      if (testResult?.timedOut) {
        pushFailure(proof, 'SIMULATOR_TEST_TIMEOUT', sanitizeText(testResult?.stderr ?? 'The simulator test runner timed out.', replacements), 'test');
        break main;
      }
      if (testResult?.error || testResult?.exitCode !== 0) {
        pushFailure(proof, 'SIMULATOR_TEST_FAILED', sanitizeText(testResult?.stderr ?? 'The simulator test runner failed.', replacements), 'test');
        break main;
      }

      const pulled = await pullPhase3AppEvidenceImpl({
        fsApi,
        execImpl,
        hdcCommand,
        target,
        localPath: path.join(pullDirectoryPath, 'phase3-simulator-app-evidence.json'),
        cwd: repoRoot,
        expectedRunId: proof.runId,
        expectedProductionHapSha256: proof.haps.production.sha256,
        expectedEntryTestHapSha256: proof.haps.entryTest.sha256,
        expectedFixtureSha256: proof.fixture.sha256,
        startedAt
      });
      if (!pulled?.ok) {
        const failure = pulled?.invalid ?? createFailure('APP_EVIDENCE_MISSING', 'The simulator did not produce a usable app evidence file.', 'app-proof');
        pushFailure(proof, failure.code, sanitizeText(failure.detail, replacements), failure.stage);
        break main;
      }

      const evidence = pulled.proof;
      proof.timestamps.proofAt = isoTimestamp(now());
      proof.appEvidence = {
        path: normalizePathForReport(repoRoot, pulled.localPath),
        sha256: pulled.sha256 ?? null,
        sizeBytes: pulled.sizeBytes ?? null,
        runId: evidence.runId,
        productionHapSha256: evidence.productionHapSha256,
        entryTestHapSha256: evidence.entryTestHapSha256,
        fixtureSha256: evidence.fixtureSha256,
        status: evidence.status,
        suites: evidence.suites,
        checks: evidence.checks,
        trace: evidence.trace,
        failureCount: evidence.failures.length,
        homeSnapshotAddress: evidence.homeSnapshotAddress,
        homeRuntimeAddress: evidence.homeRuntimeAddress,
        cleanup: evidence.cleanup
      };
      finalizeChecksFromEvidence(proof, evidence);

      if (evidence.runId !== proof.runId) {
        pushFailure(proof, 'APP_EVIDENCE_RUN_ID_MISMATCH', 'App evidence runId did not match the runner runId.', 'app-proof');
      }
      if (evidence.productionHapSha256 !== proof.haps.production.sha256 || evidence.entryTestHapSha256 !== proof.haps.entryTest.sha256) {
        pushFailure(proof, 'APP_EVIDENCE_HAP_MISMATCH', 'App evidence HAP identities did not match the runner inputs.', 'app-proof');
      }
      if (evidence.fixtureSha256 !== proof.fixture.sha256) {
        pushFailure(proof, 'APP_EVIDENCE_FIXTURE_MISMATCH', 'App evidence fixture identity did not match the runner input.', 'app-proof');
      }
      if (evidence.status !== 'PASS') {
        pushFailure(proof, 'SIMULATOR_EVIDENCE_NOT_PASSING', 'Simulator evidence did not report PASS.', 'app-proof');
      }
      if (evidence.failures.length > 0) {
        pushFailure(proof, 'APP_EVIDENCE_FAILURES_PRESENT', 'Simulator evidence must report zero failures.', 'app-proof');
      }
      if (!exactOrderedArrayEqual(evidence.suites, REQUIRED_EVIDENCE_SUITES)) {
        pushFailure(proof, 'APP_EVIDENCE_SUITES_INVALID', 'Simulator evidence suite coverage must match the exact allowlist.', 'app-proof');
      }
      if (!exactOrderedArrayEqual(evidence.checks, REQUIRED_EVIDENCE_CHECKS)) {
        pushFailure(proof, 'APP_EVIDENCE_CHECKS_INVALID', 'Simulator evidence checks must match the exact allowlist.', 'app-proof');
      }
      if (proof.checks.homeAddressesMatch !== 'pass') {
        pushFailure(proof, 'HOME_ADDRESS_MISMATCH', 'Home addresses must match the captured runtime snapshot.', 'app-proof');
      }
      if (proof.checks.identitiesMatch !== 'pass') {
        pushFailure(proof, 'APP_EVIDENCE_IDENTITY_MISMATCH', 'App evidence identities did not match the runner inputs.', 'app-proof');
      }
      if (proof.checks.cleanup !== 'pass') {
        pushFailure(proof, 'APP_EVIDENCE_CLEANUP_INVALID', 'App evidence cleanup status must be pass.', 'app-proof');
      }
      if (proof.checks.startStop !== 'pass') {
        pushFailure(proof, 'APP_EVIDENCE_RUNTIME_TRACE_INVALID', 'Simulator evidence must include the exact runtime start/stop check.', 'app-proof');
      }
    }
  } catch (error) {
    pushFailure(proof, error?.code ?? 'UNEXPECTED_ERROR', sanitizeText(error?.message ?? String(error), replacements), 'runner');
  } finally {
    if (installedAny && target) {
      try {
        const forceStop = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', BUNDLE_NAME]), { cwd: repoRoot });
        proof.cleanup.forceStopResult = (!forceStop?.error && forceStop?.exitCode === 0 && !forceStop?.timedOut) ? 'pass' : 'fail';
        if (proof.cleanup.forceStopResult !== 'pass') {
          pushFailure(proof, 'CLEANUP_FORCE_STOP_FAILED', sanitizeText(forceStop?.stderr ?? 'Failed to force-stop the simulator app.', replacements), 'cleanup');
        }
      } catch (error) {
        proof.cleanup.forceStopResult = 'fail';
        pushFailure(proof, 'CLEANUP_FORCE_STOP_FAILED', sanitizeText(error?.message ?? 'Failed to force-stop the simulator app.', replacements), 'cleanup');
      }

      try {
        const uninstall = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['uninstall', BUNDLE_NAME]), { cwd: repoRoot });
        proof.cleanup.uninstallResult = (!uninstall?.error && uninstall?.exitCode === 0 && !uninstall?.timedOut) ? 'pass' : 'fail';
        if (proof.cleanup.uninstallResult !== 'pass') {
          pushFailure(proof, 'CLEANUP_UNINSTALL_FAILED', sanitizeText(uninstall?.stderr ?? 'Failed to uninstall simulator artifacts.', replacements), 'cleanup');
        }
      } catch (error) {
        proof.cleanup.uninstallResult = 'fail';
        pushFailure(proof, 'CLEANUP_UNINSTALL_FAILED', sanitizeText(error?.message ?? 'Failed to uninstall simulator artifacts.', replacements), 'cleanup');
      }
    }

    try {
      await fsApi.rm(pullDirectoryPath, { recursive: true });
      proof.cleanup.localPullDirectoryResult = 'pass';
    } catch (error) {
      if (error?.code === 'ENOENT') {
        proof.cleanup.localPullDirectoryResult = 'pass';
      } else {
        proof.cleanup.localPullDirectoryResult = 'fail';
        pushFailure(proof, 'LOCAL_PULL_CLEANUP_FAILED', sanitizeText(error?.message ?? 'Failed to remove local simulator pull artifacts.', replacements), 'cleanup');
      }
    }

    if (shouldRebuildDefaultProductionLane) {
      try {
        await buildPhase1NativeImpl({
          outputPath: productionManifestPath,
          phase2SelfTestEnabled: false
        });
        proof.cleanup.rebuildDefaultProductionLane = 'pass';
      } catch (error) {
        proof.cleanup.rebuildDefaultProductionLane = 'fail';
        pushFailure(proof, 'DEFAULT_PRODUCTION_REBUILD_FAILED', sanitizeText(error?.message ?? 'Failed to restore the default production lane.', replacements), 'cleanup');
      }
    }
  }

  return await finish();
}

async function writeArgumentErrorProof({ outputPath, repoRoot, fsApi = fs, randomUUID = () => crypto.randomUUID(), now = () => new Date(), detail }) {
  const proof = createBaseProof({ repoRoot, outputPath, runId: randomUUID(), startedAt: now() });
  proof.fixture = {
    path: normalizePathForReport(repoRoot, DEFAULT_FIXTURE_PATH),
    sha256: '0'.repeat(64),
    sizeBytes: 0
  };
  proof.haps.production = { ...proof.haps.production, path: normalizePathForReport(repoRoot, path.join(repoRoot, 'harmony', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-unsigned.hap')), sha256: '0'.repeat(64), sizeBytes: 0 };
  proof.haps.entryTest = { path: normalizePathForReport(repoRoot, DEFAULT_ENTRY_TEST_HAP_PATH), sha256: '0'.repeat(64), sizeBytes: 0 };
  proof.timestamps.runnerFinishedAt = isoTimestamp(now());
  pushFailure(proof, 'ARGUMENT_INVALID', detail, 'cli');
  await writeProof(proof, outputPath, fsApi, repoRoot);
}

export async function runCli({
  argv = process.argv.slice(2),
  repoRoot = REPO_ROOT,
  fsApi = fs,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date(),
  buildPhase1NativeImpl = buildPhase1Native,
  inspectHapImpl = inspectHap,
  toolchainInspectorImpl = inspectToolchain,
  execImpl = execCommand,
  runTestImpl = runDefaultSimulatorTest,
  pullPhase3AppEvidenceImpl = pullPhase3AppEvidence
} = {}) {
  let parsed;
  try {
    parsed = parseCliArgumentsPartial(argv, repoRoot);
    parseCliArguments(argv, repoRoot);
  } catch (error) {
    await writeArgumentErrorProof({
      outputPath: error?.partial?.outputPath ?? path.join(repoRoot, 'harmony', 'artifacts', 'phase3-simulator-proof.json'),
      repoRoot,
      fsApi,
      randomUUID,
      now,
      detail: error?.message ?? 'Invalid CLI arguments.'
    });
    return 1;
  }

  const proof = await runPhase3SimulatorProof({
    ...parsed,
    repoRoot,
    fsApi,
    buildPhase1NativeImpl,
    inspectHapImpl,
    toolchainInspectorImpl,
    execImpl,
    runTestImpl,
    pullPhase3AppEvidenceImpl,
    randomUUID,
    now
  });
  return proof.result === 'provisional-pass' ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
