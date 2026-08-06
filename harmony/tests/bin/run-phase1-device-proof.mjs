import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import {
  HAP_NATIVE_ENTRIES,
  verifyPhase1NativeManifest
} from '../../tools/lib/native-provenance.mjs';
import {
  createRedactionReplacements,
  sanitizeForPersistence,
  sanitizeText
} from '../../tools/lib/proof-redaction.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  createMaskedDeviceIdentity,
  execCommand
} from './run-phase0-device-proof.mjs';

export const PROOF_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 1;
export const BUNDLE_NAME = 'com.github.kr328.clash.harmony';
export const ENTRY_ABILITY_NAME = 'EntryAbility';
export const APP_PROOF_REMOTE_PATH = '/data/storage/el2/base/files/phase1-device-proof.json';
export const REQUIRED_CHECK_IDS = Object.freeze([
  'nativeHello',
  'coreVersion',
  'promiseResolution',
  'typedRejection',
  'eventDelivery',
  'unsubscribeSilence'
]);

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-device-proof.json');
export const DEFAULT_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');

const PRIVATE_CORE_EXPORTS = ['cmfa_mihomo_core_build_info_json_cstr_v1', 'cmfa_mihomo_core_version_cstr_v1'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const DIGEST_PATTERN = /^[a-f0-9]{64}$/u;
const FINAL_RESULTS = new Set(['pass', 'fail', 'incomplete']);
const STEP_RESULTS = new Set(['pass', 'fail', 'incomplete', 'not-run']);
const APP_CHECK_RESULTS = new Set(['pass', 'fail', 'not-run']);
const INCOMPLETE_CODES = new Set([
  'INPUT_HAP_MISSING',
  'INPUT_HAP_UNSIGNED',
  'SIGNING_REQUIRED',
  'TOOL_MISSING',
  'HDC_HELP_UNSUPPORTED',
  'HDC_TIMEOUT',
  'DEVICE_CONNECTION_FAILED',
  'DEVICE_TARGET_MISSING',
  'DEVICE_TARGET_AMBIGUOUS',
  'DEVICE_TARGET_UNSUPPORTED',
  'DEVICE_FACT_MISSING',
  'APP_SELF_TEST_INCOMPLETE'
]);
const DEVICE_FACT_KEYS = Object.freeze({
  buildVersion: ['const.product.software.version'],
  apiVersion: ['const.ohos.apiversion', 'const.product.apiversion'],
  abi: ['const.product.cpu.abilist'],
  model: ['const.product.model']
});

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isDigest(value) {
  return DIGEST_PATTERN.test(String(value ?? ''));
}

function isUuid(value) {
  return UUID_PATTERN.test(String(value ?? ''));
}

function isoTimestamp(value) {
  return value.toISOString();
}

function createFailure(code, detail, stage) {
  return { code, detail, stage };
}

function normalizePathForReport(repoRoot, filePath) {
  if (!filePath) {
    return null;
  }
  const relative = path.relative(repoRoot, filePath);
  if (relative && !relative.startsWith('..') && !path.isAbsolute(relative)) {
    return relative.split(path.sep).join('/');
  }
  return path.basename(filePath);
}

function isInsideRepo(repoRoot, filePath) {
  const relative = path.relative(repoRoot, filePath);
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative);
}

function isWithinRepo(repoRoot, filePath) {
  const relative = path.relative(repoRoot, filePath);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function pathOutsideRepoError(option) {
  return Object.assign(new Error(`${option} resolves outside the repository through a symlink.`), {
    code: 'PATH_OUTSIDE_REPO'
  });
}

async function resolveExistingRepoScopedPath(fsApi, repoRoot, filePath, option) {
  const resolved = path.resolve(filePath);
  if (!isInsideRepo(repoRoot, resolved)) {
    throw pathOutsideRepoError(option);
  }
  const [realRepoRoot, realFilePath] = await Promise.all([
    fsApi.realpath(repoRoot),
    fsApi.realpath(resolved)
  ]);
  if (!isWithinRepo(realRepoRoot, realFilePath)) {
    throw pathOutsideRepoError(option);
  }
  return realFilePath;
}

async function resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath) {
  const resolved = path.resolve(outputPath);
  if (!isInsideRepo(repoRoot, resolved)) {
    throw pathOutsideRepoError('--out');
  }
  const realRepoRoot = await fsApi.realpath(repoRoot);
  let existingAncestor = path.dirname(resolved);
  while (true) {
    try {
      const realAncestor = await fsApi.realpath(existingAncestor);
      if (!isWithinRepo(realRepoRoot, realAncestor)) {
        throw pathOutsideRepoError('--out');
      }
      break;
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw error;
      }
      const parent = path.dirname(existingAncestor);
      if (parent === existingAncestor) {
        throw error;
      }
      existingAncestor = parent;
    }
  }

  await fsApi.mkdir(path.dirname(resolved), { recursive: true });
  const realParent = await fsApi.realpath(path.dirname(resolved));
  if (!isWithinRepo(realRepoRoot, realParent)) {
    throw pathOutsideRepoError('--out');
  }

  try {
    const outputStats = await fsApi.lstat(resolved);
    if (outputStats.isSymbolicLink()) {
      throw pathOutsideRepoError('--out');
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }
  return path.join(realParent, path.basename(resolved));
}

async function hashFile(fsApi, filePath) {
  const content = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(content).digest('hex'),
    sizeBytes: content.byteLength
  };
}

function digestExportList(exportedSymbols) {
  const normalized = [...new Set(exportedSymbols ?? [])].sort();
  return crypto.createHash('sha256').update(JSON.stringify(normalized)).digest('hex');
}

function emptyChecks(detail = 'The device self-test did not run.') {
  return REQUIRED_CHECK_IDS.map((id) => ({ id, result: 'not-run', detail }));
}

function createBaseProof({ repoRoot, outputPath, runId, startedAt }) {
  return {
    schemaVersion: PROOF_SCHEMA_VERSION,
    phase: PHASE_NUMBER,
    result: 'incomplete',
    runId,
    outputPath: normalizePathForReport(repoRoot, outputPath) ?? 'harmony/artifacts/phase1-device-proof.json',
    bundle: BUNDLE_NAME,
    ability: ENTRY_ABILITY_NAME,
    timestamps: {
      runnerStartedAt: isoTimestamp(startedAt),
      appStartedAt: null,
      proofAt: null,
      runnerFinishedAt: isoTimestamp(startedAt)
    },
    toolchainLock: {
      path: 'harmony/toolchain.lock.json',
      sha256: null
    },
    hap: {
      path: null,
      sha256: null,
      sizeBytes: null
    },
    native: {
      addon: null,
      core: null
    },
    device: {
      identityMasked: null,
      buildVersion: null,
      apiVersion: null,
      abi: null,
      model: null
    },
    app: {
      bridgeVersion: null,
      coreVersion: null,
      eventCount: 0,
      lastError: null
    },
    steps: {
      nativeManifest: { result: 'not-run' },
      install: { result: 'not-run' },
      launch: { result: 'not-run' },
      pull: { result: 'not-run' },
      cleanup: { result: 'not-run' }
    },
    checks: emptyChecks(),
    failures: []
  };
}

function pushFailure(proof, failure) {
  if (!proof.failures.some((entry) => entry.code === failure.code && entry.stage === failure.stage)) {
    proof.failures.push(failure);
  }
}

function finalizeResult(proof) {
  if (proof.failures.length === 0 && Object.values(proof.steps).every((step) => step.result === 'pass')) {
    proof.result = 'pass';
    return proof;
  }
  proof.result = proof.failures.some((entry) => INCOMPLETE_CODES.has(entry.code)) ? 'incomplete' : 'fail';
  return proof;
}

function validateTypedCoreError(value, errors, prefix) {
  if (!value || typeof value !== 'object') {
    errors.push(`${prefix} must contain a typed CoreError.`);
    return;
  }
  if (value.name !== 'CoreError' || !isNonEmptyString(value.code) || !['CoreError', 'StateError'].includes(value.category)) {
    errors.push(`${prefix} must contain a typed CoreError.`);
  }
  for (const key of ['message', 'detail', 'action']) {
    if (!isNonEmptyString(value[key])) {
      errors.push(`${prefix}.${key} must be a non-empty string.`);
    }
  }
  if (typeof value.retryable !== 'boolean') {
    errors.push(`${prefix}.retryable must be boolean.`);
  }
  if (!value.context || !isNonEmptyString(value.context.operation) || !Number.isInteger(value.context.status)) {
    errors.push(`${prefix}.context must include operation and integer status.`);
  }
}

function validateChecks(checks, { requirePass }, errors) {
  if (!Array.isArray(checks)) {
    errors.push('checks must be an array.');
    return;
  }
  for (const requiredId of REQUIRED_CHECK_IDS) {
    const matches = checks.filter((entry) => entry?.id === requiredId);
    if (matches.length !== 1) {
      errors.push(`checks must contain exactly one ${requiredId} result.`);
      continue;
    }
    if (!APP_CHECK_RESULTS.has(matches[0].result)) {
      errors.push(`${requiredId} must use pass, fail, or not-run.`);
    }
    if (!isNonEmptyString(matches[0].detail)) {
      errors.push(`${requiredId} detail must be non-empty.`);
    }
    if (requirePass && matches[0].result !== 'pass') {
      errors.push(`${requiredId} must pass.`);
    }
  }
  if (checks.length !== REQUIRED_CHECK_IDS.length) {
    errors.push('checks must not contain synthetic or duplicate entries.');
  }
}

export function validateAppSelfTestProof(appProof, options = {}) {
  const errors = [];
  if (appProof?.schemaVersion !== PROOF_SCHEMA_VERSION || appProof?.phase !== PHASE_NUMBER) {
    errors.push('app proof schemaVersion/phase mismatch.');
  }
  if (!FINAL_RESULTS.has(appProof?.result)) {
    errors.push('app proof result must be pass, fail, or incomplete.');
  }
  if (!isUuid(appProof?.runId)) {
    errors.push('app proof runId must be a UUID.');
  }
  if (options.expectedRunId && appProof?.runId !== options.expectedRunId) {
    errors.push('app proof runId does not match the exact Want runId.');
  }
  const startedAt = appProof?.timestamps?.startedAt;
  const proofAt = appProof?.timestamps?.proofAt;
  if (!isIsoTimestamp(startedAt) || !isIsoTimestamp(proofAt) || Date.parse(proofAt) < Date.parse(startedAt)) {
    errors.push('app proof timestamps must be ordered ISO-8601 values.');
  }
  const lower = Date.parse(options.runnerStartedAt ?? '');
  const upper = Date.parse(options.runnerFinishedAt ?? '');
  if (!Number.isNaN(lower) && !Number.isNaN(upper) && isIsoTimestamp(startedAt) && isIsoTimestamp(proofAt)) {
    if (Date.parse(startedAt) < lower || Date.parse(proofAt) > upper) {
      errors.push('app proof timestamps must fall inside the runner interval.');
    }
  }
  if (!isNonEmptyString(appProof?.bridgeVersion) || !isNonEmptyString(appProof?.coreVersion)) {
    errors.push('app proof must include non-empty bridge/core versions.');
  }
  if (!Number.isInteger(appProof?.eventCount) || appProof.eventCount < 0) {
    errors.push('app proof eventCount must be a non-negative integer.');
  }
  if (appProof?.lastError !== null) {
    validateTypedCoreError(appProof?.lastError, errors, 'app proof lastError');
  }
  const requirePass = appProof?.result === 'pass';
  validateChecks(appProof?.checks, { requirePass }, errors);
  if (!Array.isArray(appProof?.failures)) {
    errors.push('app proof failures must be an array.');
  } else {
    for (const failure of appProof.failures) {
      if (!isNonEmptyString(failure?.code) || !isNonEmptyString(failure?.detail) || !isNonEmptyString(failure?.stage)) {
        errors.push('app proof failures must contain non-empty code, detail, and stage.');
      }
    }
    if (requirePass && appProof.failures.length > 0) {
      errors.push('a passing app self-test must not include failures.');
    }
    if (!requirePass && FINAL_RESULTS.has(appProof?.result) && appProof.failures.length === 0) {
      errors.push('a non-passing app self-test must include a failure.');
    }
  }
  if (requirePass) {
    if (appProof.eventCount < 1) {
      errors.push('a passing app proof must record at least one event.');
    }
    validateTypedCoreError(appProof?.lastError, errors, 'app proof lastError');
  } else if (appProof?.result === 'fail' && Array.isArray(appProof?.checks) && !appProof.checks.some((entry) => entry?.result === 'fail')) {
    errors.push('a failing app proof must contain at least one failed check.');
  }
  return { valid: errors.length === 0, errors };
}

function validateNativeArtifact(value, key, requireConcrete, errors) {
  if (value === null && !requireConcrete) {
    return;
  }
  if (!value || typeof value !== 'object') {
    errors.push(`native.${key} must be present.`);
    return;
  }
  if (!isNonEmptyString(value.path) || !isDigest(value.sha256) || !Number.isInteger(value.sizeBytes) || value.sizeBytes < 1) {
    errors.push(`native.${key}.sha256/path/sizeBytes must describe a concrete artifact.`);
  }
  if (value.elfMachine !== 'AArch64') {
    errors.push(`native.${key} must be AArch64.`);
  }
  if (!isDigest(value.exportListSha256)) {
    errors.push(`native.${key}.exportListSha256 must be a digest.`);
  }
  if (!Array.isArray(value.requiredExports)) {
    errors.push(`native.${key}.requiredExports must be an array.`);
  }
  if (key === 'core' && JSON.stringify(value.requiredExports) !== JSON.stringify(PRIVATE_CORE_EXPORTS)) {
    errors.push(`native.core.requiredExports must contain only ${PRIVATE_CORE_EXPORTS.join(', ')}.`);
  }
}

export function validatePhase1Proof(proof, options = {}) {
  const errors = [];
  if (proof?.schemaVersion !== PROOF_SCHEMA_VERSION) errors.push(`schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  if (proof?.phase !== PHASE_NUMBER) errors.push('phase must be 1.');
  if (!FINAL_RESULTS.has(proof?.result)) errors.push('result must be pass, fail, or incomplete.');
  if (!isUuid(proof?.runId)) errors.push('runId must be a UUID.');
  if (options.expectedRunId && proof?.runId !== options.expectedRunId) errors.push('runId does not match the expected runner value.');
  if (proof?.bundle !== BUNDLE_NAME || proof?.ability !== ENTRY_ABILITY_NAME) errors.push('bundle/ability identity mismatch.');
  if (!isNonEmptyString(proof?.outputPath)) errors.push('outputPath must be non-empty.');

  const times = proof?.timestamps ?? {};
  if (!isIsoTimestamp(times.runnerStartedAt) || !isIsoTimestamp(times.runnerFinishedAt) || Date.parse(times.runnerFinishedAt) < Date.parse(times.runnerStartedAt)) {
    errors.push('runner timestamps must be ordered ISO-8601 values.');
  }
  if (proof?.result === 'pass') {
    if (!isIsoTimestamp(times.appStartedAt) || !isIsoTimestamp(times.proofAt)) {
      errors.push('pass requires appStartedAt and proofAt.');
    } else if (
      Date.parse(times.appStartedAt) < Date.parse(times.runnerStartedAt) ||
      Date.parse(times.proofAt) < Date.parse(times.appStartedAt) ||
      Date.parse(times.proofAt) > Date.parse(times.runnerFinishedAt)
    ) {
      errors.push('app timestamps must fall inside the runner interval.');
    }
  } else {
    for (const key of ['appStartedAt', 'proofAt']) {
      if (times[key] !== null && !isIsoTimestamp(times[key])) errors.push(`${key} must be null or ISO-8601.`);
    }
  }
  if (options.runnerStartedAt && times.runnerStartedAt !== options.runnerStartedAt) errors.push('runnerStartedAt does not match the runner interval.');
  if (options.runnerFinishedAt && times.runnerFinishedAt !== options.runnerFinishedAt) errors.push('runnerFinishedAt does not match the runner interval.');

  if (proof?.toolchainLock?.path !== 'harmony/toolchain.lock.json') errors.push('toolchainLock.path must be canonical.');
  const requireConcrete = proof?.result === 'pass';
  if (requireConcrete && !isDigest(proof?.toolchainLock?.sha256)) errors.push('pass requires exact toolchainLock.sha256.');
  if (!requireConcrete && proof?.toolchainLock?.sha256 !== null && !isDigest(proof?.toolchainLock?.sha256)) errors.push('toolchainLock.sha256 must be null or a digest.');

  if (requireConcrete || proof?.hap?.path !== null) {
    if (!isNonEmptyString(proof?.hap?.path)) errors.push('hap.path must be present.');
    if (!isDigest(proof?.hap?.sha256)) errors.push('hap.sha256 must be a digest.');
    if (!Number.isInteger(proof?.hap?.sizeBytes) || proof.hap.sizeBytes < 1) errors.push('hap.sizeBytes must be positive.');
  }
  if (options.expectedHapSha256 && proof?.hap?.sha256 !== options.expectedHapSha256) errors.push('HAP digest does not match the just-installed HAP digest.');

  validateNativeArtifact(proof?.native?.addon, 'addon', requireConcrete, errors);
  validateNativeArtifact(proof?.native?.core, 'core', requireConcrete, errors);
  if (proof?.device && 'serial' in proof.device) errors.push('device.serial must never be persisted.');
  if (requireConcrete) {
    if (!/^target-[a-f0-9]{8}$/u.test(String(proof?.device?.identityMasked ?? ''))) errors.push('pass requires a masked device identity.');
    for (const key of ['buildVersion', 'apiVersion', 'abi', 'model']) {
      if (!isNonEmptyString(proof?.device?.[key])) errors.push(`pass requires device.${key}.`);
    }
    if (!/arm64|aarch64/iu.test(String(proof?.device?.abi ?? ''))) errors.push('pass requires an arm64 device ABI.');
    if (/emulator|simulator/iu.test(String(proof?.device?.model ?? ''))) errors.push('an emulator/simulator cannot pass the Phase 1 gate.');
    if (!/^6(?:\.|$)/u.test(String(proof?.device?.buildVersion ?? '').match(/\b\d+(?:\.\d+){1,3}/u)?.[0] ?? '')) errors.push('pass requires a HarmonyOS 6 device build.');
    if (Number.parseInt(String(proof?.device?.apiVersion ?? ''), 10) < 20) errors.push('pass requires device API 20 or later.');

    if (!isNonEmptyString(proof?.app?.bridgeVersion) || !isNonEmptyString(proof?.app?.coreVersion) || !Number.isInteger(proof?.app?.eventCount) || proof.app.eventCount < 1) {
      errors.push('pass requires bridge/core versions and an event count.');
    }
    validateTypedCoreError(proof?.app?.lastError, errors, 'app.lastError typed CoreError');
  }
  validateChecks(proof?.checks, { requirePass: requireConcrete }, errors);
  for (const key of ['nativeManifest', 'install', 'launch', 'pull', 'cleanup']) {
    if (!STEP_RESULTS.has(proof?.steps?.[key]?.result)) errors.push(`steps.${key}.result is invalid.`);
    if (requireConcrete && proof?.steps?.[key]?.result !== 'pass') errors.push(`pass requires steps.${key}.result pass.`);
  }
  if (!Array.isArray(proof?.failures)) errors.push('failures must be an array.');
  if (requireConcrete && proof.failures.length > 0) errors.push('pass must not include failures.');
  if (proof?.result !== 'incomplete' && Array.isArray(proof?.failures) && proof.failures.some((entry) => INCOMPLETE_CODES.has(entry.code))) {
    errors.push('environment/signing/input blockers must produce incomplete.');
  }
  return { valid: errors.length === 0, errors };
}

export function buildPhase1LaunchArgs(target, runId, runnerStartedAt) {
  const wantParameters = {
    'cmfa.phase1.selfTest': true,
    'cmfa.phase1.runId': runId,
    'cmfa.phase1.runnerStartedAt': runnerStartedAt
  };
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', ENTRY_ABILITY_NAME,
    '-b', BUNDLE_NAME,
    '-p', JSON.stringify(wantParameters)
  ]);
}

export function buildPhase1PullArgs(target, localPath) {
  return buildTargetedHdcArgs(target, [
    'file', 'recv', '-b', BUNDLE_NAME,
    APP_PROOF_REMOTE_PATH,
    localPath
  ]);
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID' });
  }
  return value;
}

function resolveRepoScoped(repoRoot, value, option) {
  const resolved = path.isAbsolute(value) ? path.resolve(value) : path.resolve(repoRoot, value);
  if (!isInsideRepo(repoRoot, resolved)) {
    throw Object.assign(new Error(`${option} must stay inside the repository root.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return resolved;
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let hapPath = null;
  let manifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json');
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase1-device-proof.json');
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!['--hap', '--manifest', '--out'].includes(option)) {
      throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID' });
    }
    if (seen.has(option)) throw Object.assign(new Error(`${option} may only be provided once.`), { code: 'ARGUMENT_INVALID' });
    seen.add(option);
    const value = requireValue(argv, index, option);
    const resolved = resolveRepoScoped(repoRoot, value, option);
    if (option === '--hap') hapPath = resolved;
    if (option === '--manifest') manifestPath = resolved;
    if (option === '--out') outputPath = resolved;
    index += 1;
  }
  return { hapPath, manifestPath, outputPath };
}

async function readJson(fsApi, filePath, code) {
  try {
    return JSON.parse(await fsApi.readFile(filePath, 'utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? `Unable to read ${filePath}`), { code });
  }
}

function nativeEvidence(artifact) {
  return {
    path: artifact.identity,
    sha256: artifact.sha256,
    sizeBytes: artifact.sizeBytes,
    elfMachine: artifact.elf.architecture,
    exportListSha256: digestExportList(artifact.elf.exportedSymbols),
    requiredExports: [...artifact.elf.requiredExports]
  };
}

function commandSucceeded(result, kind) {
  if (result?.timedOut || result?.error || result?.exitCode !== 0) return false;
  const combined = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (/\b(fail(?:ed|ure)?|error|invalid|denied|exception|unable to)\b/iu.test(combined)) return false;
  if (kind === 'install') return /\b(success|successfully|finish)\b/iu.test(combined);
  if (kind === 'launch') return /\b(start ability successfully|ability started successfully|start success|successfully started)\b/iu.test(combined);
  return true;
}

async function readDeviceFact({ execImpl, hdcCommand, target, candidates, cwd }) {
  for (const key of candidates) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    if (result.timedOut) return { value: null, timedOut: true };
    const value = String(result.stdout ?? '').trim();
    if (!result.error && result.exitCode === 0 && value && !/^(?:unknown|null)$/iu.test(value)) return { value, timedOut: false };
  }
  return { value: null, timedOut: false };
}

async function verifyHdcHelp(execImpl, hdcCommand, cwd) {
  for (const args of [['help'], ['-h'], ['--help']]) {
    const result = await execImpl(hdcCommand, args, { cwd });
    if (result.timedOut) return { ok: false, failure: createFailure('HDC_TIMEOUT', 'hdc help timed out.', 'toolchain') };
    if (result.error?.code === 'ENOENT') return { ok: false, failure: createFailure('TOOL_MISSING', 'The integrated hdc command is unavailable.', 'toolchain') };
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    if (/list\s+targets/iu.test(output) && /file\s+recv/iu.test(output) && /install/iu.test(output) && /shell/iu.test(output)) return { ok: true };
  }
  return { ok: false, failure: createFailure('HDC_HELP_UNSUPPORTED', 'hdc help does not confirm the Phase 1 device command surface.', 'toolchain') };
}

async function resolveHdcCommand(toolchainInspectorImpl, repoRoot) {
  const inspection = await toolchainInspectorImpl({ cwd: repoRoot });
  if (inspection?.report?.result !== 'pass' || !inspection?.resolved?.paths?.hdc) {
    throw Object.assign(new Error('The integrated hdc command is unavailable.'), { code: 'TOOL_MISSING' });
  }
  return inspection.resolved.paths.hdc;
}

export async function pullAppProof({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  localPath,
  cwd,
  waitImpl,
  expectedRunId,
  runnerStartedAt,
  redactionReplacements = new Map(),
  now = () => new Date()
} = {}) {
  let lastResult = null;
  let lastInvalidFailure = null;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    lastResult = await execImpl(hdcCommand, buildPhase1PullArgs(target, localPath), { cwd });
    if (commandSucceeded(lastResult, 'pull')) {
      try {
        await fsApi.access(localPath);
        const appProof = await readJson(fsApi, localPath, 'APP_PROOF_INVALID');
        const appValidation = validateAppSelfTestProof(appProof, {
          expectedRunId,
          runnerStartedAt,
          runnerFinishedAt: isoTimestamp(now())
        });
        if (appValidation.valid) {
          return { ok: true, result: lastResult, appProof };
        }
        lastInvalidFailure = createFailure('APP_PROOF_INVALID', appValidation.errors.join('; '), 'app-proof');
      } catch {
        // The command can return before the destination becomes visible or before data is coherent.
        const message = sanitizeText(`Unable to read or parse app proof from ${localPath}.`, redactionReplacements);
        lastInvalidFailure = createFailure('APP_PROOF_INVALID', message, 'app-proof');
      }
    }
    await waitImpl(250);
  }
  return { ok: false, result: lastResult, invalid: lastInvalidFailure };
}

export async function writeProof(proof, outputPath, fsApi = fs, repoRoot = REPO_ROOT) {
  const safeOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath);
  await fsApi.writeFile(safeOutputPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
}

export async function runPhase1DeviceProof({
  hapPath,
  manifestPath = DEFAULT_MANIFEST_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  verifyManifestImpl = verifyPhase1NativeManifest,
  toolchainInspectorImpl = inspectToolchain,
  now = () => new Date(),
  randomUUID = () => crypto.randomUUID(),
  waitImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
} = {}) {
  const startedAt = now();
  const proof = createBaseProof({ repoRoot, outputPath, runId: randomUUID(), startedAt });
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  let target = null;
  let hdcCommand = null;
  let tempRoot = null;
  let installed = false;

  const finish = () => {
    proof.timestamps.runnerFinishedAt = isoTimestamp(now());
    const sanitized = sanitizeForPersistence(finalizeResult(proof), replacements);
    const validation = validatePhase1Proof(sanitized);
    if (!validation.valid) {
      sanitized.result = 'fail';
      pushFailure(sanitized, createFailure('PHASE1_PROOF_INVALID', validation.errors.join('; '), 'proof'));
    }
    return sanitized;
  };

  const cleanupAndFinish = async () => {
    if (!installed || !target || !hdcCommand) {
      proof.steps.cleanup.result = 'pass';
      return finish();
    }
    const cleanupResult = await execImpl(
      hdcCommand,
      buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', BUNDLE_NAME]),
      { cwd: repoRoot }
    );
    proof.steps.cleanup.result = commandSucceeded(cleanupResult, 'cleanup') ? 'pass' : (cleanupResult.timedOut ? 'incomplete' : 'fail');
    if (proof.steps.cleanup.result !== 'pass') {
      pushFailure(proof, createFailure(
        cleanupResult.timedOut ? 'HDC_TIMEOUT' : 'FORCE_STOP_FAILED',
        'The Phase 1 runner could not force-stop the installed proof app.',
        'cleanup'
      ));
    }
    return finish();
  };

  if (!hapPath) {
    proof.steps.nativeManifest.result = 'incomplete';
    pushFailure(proof, createFailure('INPUT_HAP_MISSING', 'The --hap argument must name an exact signed Phase 1 HAP.', 'input'));
    return finish();
  }

  let resolvedHapPath;
  try {
    resolvedHapPath = await resolveExistingRepoScopedPath(fsApi, repoRoot, hapPath, '--hap');
    proof.hap.path = normalizePathForReport(repoRoot, resolvedHapPath);
    const digest = await hashFile(fsApi, resolvedHapPath);
    proof.hap.sha256 = digest.sha256;
    proof.hap.sizeBytes = digest.sizeBytes;
  } catch (error) {
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure(error?.code ?? 'INPUT_HAP_INVALID', sanitizeText(error?.message ?? 'Unable to read HAP.', replacements), 'input'));
    return finish();
  }

  if (/-unsigned\.hap$/iu.test(path.basename(resolvedHapPath))) {
    proof.steps.nativeManifest.result = 'incomplete';
    pushFailure(proof, createFailure('INPUT_HAP_UNSIGNED', 'An unsigned HAP cannot enter the device proof lane.', 'input'));
    pushFailure(proof, createFailure('SIGNING_REQUIRED', 'A valid developer-signed debug HAP is required.', 'signing'));
    return finish();
  }

  let manifest;
  try {
    const resolvedManifestPath = await resolveExistingRepoScopedPath(fsApi, repoRoot, manifestPath, '--manifest');
    manifest = await readJson(fsApi, resolvedManifestPath, 'PHASE1_MANIFEST_INVALID');
    const liveVerification = await verifyManifestImpl(manifest, { repoRoot });
    if (!liveVerification.valid) throw Object.assign(new Error(liveVerification.errors.join('; ')), { code: 'PHASE1_MANIFEST_INVALID' });
  } catch (error) {
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure(error?.code ?? 'PHASE1_MANIFEST_INVALID', sanitizeText(error?.message ?? 'Unable to verify native provenance.', replacements), 'native-manifest'));
    return finish();
  }

  proof.toolchainLock = { ...manifest.toolchainLock };
  if (manifest.nativeBuildResult !== 'pass') {
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure('NATIVE_BUILD_REQUIRED', 'The fresh native build manifest must record nativeBuildResult pass.', 'native-manifest'));
    return finish();
  }
  if (manifest.signing?.result !== 'pass') {
    proof.steps.nativeManifest.result = 'incomplete';
    pushFailure(proof, createFailure('SIGNING_REQUIRED', 'The fresh native manifest does not prove a signed HAP.', 'signing'));
    return finish();
  }
  const manifestHap = manifest.artifacts?.hap;
  const hapAddon = manifest.artifacts?.hapAddon;
  const hapCore = manifest.artifacts?.hapCore;
  if (!manifestHap || !hapAddon || !hapCore || manifestHap.sha256 !== proof.hap.sha256 || manifestHap.sizeBytes !== proof.hap.sizeBytes) {
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure('HAP_PROVENANCE_MISMATCH', 'The supplied HAP does not match the live-verified native provenance manifest.', 'native-manifest'));
    return finish();
  }
  if (hapAddon.identity !== HAP_NATIVE_ENTRIES.addon || hapCore.identity !== HAP_NATIVE_ENTRIES.core || hapAddon.elf?.result !== 'pass' || hapCore.elf?.result !== 'pass') {
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure('NATIVE_ELF_CONTRACT_INVALID', 'Packaged addon/core artifacts do not satisfy the Task 7 ELF contracts.', 'native-manifest'));
    return finish();
  }
  proof.native.addon = nativeEvidence(hapAddon);
  proof.native.core = nativeEvidence(hapCore);
  proof.steps.nativeManifest.result = 'pass';

  try {
    hdcCommand = await resolveHdcCommand(toolchainInspectorImpl, repoRoot);
  } catch (error) {
    pushFailure(proof, createFailure(error?.code ?? 'TOOL_MISSING', error?.message ?? 'hdc is unavailable.', 'toolchain'));
    return finish();
  }
  const help = await verifyHdcHelp(execImpl, hdcCommand, repoRoot);
  if (!help.ok) {
    pushFailure(proof, help.failure);
    return finish();
  }

  const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
  const targetAnalysis = analyzeTargetDiscovery(targetsResult);
  if (targetAnalysis.kind === 'connection-failed' || targetsResult.timedOut) {
    pushFailure(proof, createFailure(targetsResult.timedOut ? 'HDC_TIMEOUT' : 'DEVICE_CONNECTION_FAILED', 'Unable to query an authorized HarmonyOS target.', 'device'));
    return finish();
  }
  if (targetAnalysis.kind === 'missing') {
    pushFailure(proof, createFailure('DEVICE_TARGET_MISSING', 'Exactly one authorized HarmonyOS phone is required.', 'device'));
    return finish();
  }
  if (targetAnalysis.kind === 'ambiguous') {
    pushFailure(proof, createFailure('DEVICE_TARGET_AMBIGUOUS', 'Exactly one authorized HarmonyOS phone is required.', 'device'));
    return finish();
  }
  target = targetAnalysis.targets[0];
  proof.device.identityMasked = createMaskedDeviceIdentity(target);
  replacements.set(target, proof.device.identityMasked);

  for (const [field, candidates] of Object.entries(DEVICE_FACT_KEYS)) {
    const fact = await readDeviceFact({ execImpl, hdcCommand, target, candidates, cwd: repoRoot });
    proof.device[field] = fact.value;
    if (fact.timedOut) pushFailure(proof, createFailure('HDC_TIMEOUT', `Timed out reading device ${field}.`, 'device'));
  }
  if (Object.values(proof.device).some((value) => value === null)) {
    pushFailure(proof, createFailure('DEVICE_FACT_MISSING', 'Exact build, API, ABI, model, and masked identity facts are required.', 'device'));
    return await cleanupAndFinish();
  }
  if (!/arm64|aarch64/iu.test(proof.device.abi) || /emulator|simulator/iu.test(proof.device.model) || !/\b6(?:\.\d+)+/u.test(proof.device.buildVersion) || Number.parseInt(proof.device.apiVersion, 10) < 20) {
    pushFailure(proof, createFailure('DEVICE_TARGET_UNSUPPORTED', 'Phase 1 requires a physical HarmonyOS 6/API 20+/arm64 phone.', 'device'));
    return await cleanupAndFinish();
  }

  const installResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['install', '-r', resolvedHapPath]), { cwd: repoRoot });
  proof.steps.install.result = commandSucceeded(installResult, 'install') ? 'pass' : (installResult.timedOut ? 'incomplete' : 'fail');
  if (proof.steps.install.result !== 'pass') {
    const combined = `${installResult.stdout ?? ''}\n${installResult.stderr ?? ''}`;
    const signatureFailureDetected = /sign|certificate/iu.test(combined);
    pushFailure(proof, createFailure(
      signatureFailureDetected ? 'SIGNING_REQUIRED' : (installResult.timedOut ? 'HDC_TIMEOUT' : 'INSTALL_FAILED'),
      signatureFailureDetected ? 'The device rejected HAP signing.' : 'hdc install failed.',
      'install'
    ));
    return await cleanupAndFinish();
  }
  installed = true;

  const launchResult = await execImpl(hdcCommand, buildPhase1LaunchArgs(target, proof.runId, proof.timestamps.runnerStartedAt), { cwd: repoRoot });
  proof.steps.launch.result = commandSucceeded(launchResult, 'launch') ? 'pass' : (launchResult.timedOut ? 'incomplete' : 'fail');
  if (proof.steps.launch.result !== 'pass') {
    pushFailure(proof, createFailure(launchResult.timedOut ? 'HDC_TIMEOUT' : 'LAUNCH_FAILED', 'The Phase 1 self-test ability did not launch.', 'launch'));
    return await cleanupAndFinish();
  }

  try {
    tempRoot = await fsApi.mkdtemp(path.join(os.tmpdir(), 'cmfa-phase1-app-proof-'));
    const localProofPath = path.join(tempRoot, 'phase1-device-proof.json');
    const pulled = await pullAppProof({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      localPath: localProofPath,
      cwd: repoRoot,
      waitImpl,
      expectedRunId: proof.runId,
      runnerStartedAt: proof.timestamps.runnerStartedAt,
      redactionReplacements: replacements,
      now
    });
    proof.steps.pull.result = pulled.ok ? 'pass' : (pulled.result?.timedOut ? 'incomplete' : 'fail');
    if (!pulled.ok) {
      pushFailure(proof, createFailure(
        pulled.invalid ? 'APP_PROOF_INVALID' : (pulled.result?.timedOut ? 'HDC_TIMEOUT' : 'APP_PROOF_MISSING'),
        pulled.invalid ? pulled.invalid.detail : 'The app sandbox proof was not available before the pull deadline.',
        'pull'
      ));
      return await cleanupAndFinish();
    }
    proof.timestamps.appStartedAt = pulled.appProof.timestamps.startedAt;
    proof.timestamps.proofAt = pulled.appProof.timestamps.proofAt;
    proof.app = {
      bridgeVersion: pulled.appProof.bridgeVersion,
      coreVersion: pulled.appProof.coreVersion,
      eventCount: pulled.appProof.eventCount,
      lastError: pulled.appProof.lastError
    };
    proof.checks = pulled.appProof.checks.map((entry) => ({ ...entry }));
    for (const failure of pulled.appProof.failures) {
      pushFailure(proof, { ...failure });
    }
    if (pulled.appProof.result === 'incomplete') {
      pushFailure(proof, createFailure(
        'APP_SELF_TEST_INCOMPLETE',
        'The app self-test could not complete all Phase 1 checks.',
        'self-test'
      ));
    }
  } catch (error) {
    proof.steps.pull.result = 'fail';
    pushFailure(proof, createFailure(error?.code ?? 'APP_PROOF_INVALID', sanitizeText(error?.message ?? 'Unable to read app proof.', replacements), 'app-proof'));
    return await cleanupAndFinish();
  } finally {
    if (tempRoot) await fsApi.rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }

  return await cleanupAndFinish();
}

export async function runCli({
  argv = process.argv.slice(2),
  repoRoot = REPO_ROOT,
  fsApi = fs,
  now = () => new Date(),
  randomUUID = () => crypto.randomUUID(),
  runPhase1DeviceProofImpl = runPhase1DeviceProof,
  writeProofImpl = writeProof,
  ...dependencies
} = {}) {
  let parsed;
  const defaultOutputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase1-device-proof.json');
  try {
    parsed = parseCliArguments(argv, repoRoot);
  } catch (error) {
    const startedAt = now();
    const proof = createBaseProof({ repoRoot, outputPath: defaultOutputPath, runId: randomUUID(), startedAt });
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure(error?.code ?? 'ARGUMENT_INVALID', error?.message ?? 'Invalid arguments.', 'arguments'));
    proof.timestamps.runnerFinishedAt = isoTimestamp(now());
    await writeProofImpl(finalizeResult(proof), defaultOutputPath, fsApi, repoRoot);
    return 2;
  }

  let proof;
  try {
    proof = await runPhase1DeviceProofImpl({
      ...parsed,
      repoRoot,
      fsApi,
      now,
      randomUUID,
      ...dependencies
    });
  } catch (error) {
    const startedAt = now();
    proof = createBaseProof({ repoRoot, outputPath: parsed.outputPath, runId: randomUUID(), startedAt });
    proof.steps.nativeManifest.result = 'fail';
    pushFailure(proof, createFailure(error?.code ?? 'PHASE1_PROOF_FATAL', sanitizeText(error?.message ?? 'Unexpected Phase 1 proof failure.', createRedactionReplacements({ repoRoot, env: process.env })), 'proof'));
    proof.timestamps.runnerFinishedAt = isoTimestamp(now());
    finalizeResult(proof);
  }
  await writeProofImpl(proof, parsed.outputPath, fsApi, repoRoot);
  return proof.result === 'pass' ? 0 : 2;
}

function isDirectExecution() {
  return Boolean(process.argv[1]) && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
}

if (isDirectExecution()) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
