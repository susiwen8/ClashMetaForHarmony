import { randomUUID } from 'node:crypto';
import { spawn as spawnChild } from 'node:child_process';
import { constants as FS_CONSTANTS, readFileSync } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { stripVTControlCharacters } from 'node:util';

import { analyzeTargetDiscovery, createMaskedDeviceIdentity } from './run-phase0-device-proof.mjs';
import { buildHap } from './build-hap.mjs';
import { inspectNativeLibrary } from './inspect-native-lib.mjs';
import { buildMihomoOhos } from '../../tools/build-mihomo-ohos.mjs';
import { createRedactionReplacements, sanitizeText } from '../../tools/lib/proof-redaction.mjs';
import {
  collectArtifactElfContractErrors,
  CORE_EXPORTS,
  derivePhase1Result,
  hashFile,
  HAP_NATIVE_ENTRIES,
  inspectHapNativeEntries,
  NODE_ADDON_ALLOWED_EXPORTS,
  normalizeElfReport,
  PHASE1_NATIVE_PHASE,
  PHASE1_NATIVE_SCHEMA_VERSION,
  PLAN_B_PROXY_ERROR_CODES,
  PLAN_B_PROXY_LIMITS,
  PLAN_B_PROXY_NAPI_METHODS,
  PLAN_B_PROXY_RUNTIME_TYPES,
  PLAN_B_PROXY_SHARED_METHODS,
  RAW_PROXY_EXPORTS,
  resolveLiveRepoPath,
  validatePhase1NativeManifest,
  verifyPhase1NativeManifest
} from '../../tools/lib/native-provenance.mjs';
import { inspectToolchain } from '../../tools/lib/toolchain.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');
export {
  CORE_EXPORTS,
  HAP_NATIVE_ENTRIES,
  NODE_ADDON_ALLOWED_EXPORTS,
  PHASE1_NATIVE_PHASE,
  PHASE1_NATIVE_SCHEMA_VERSION,
  PLAN_B_PROXY_ERROR_CODES,
  PLAN_B_PROXY_LIMITS,
  PLAN_B_PROXY_NAPI_METHODS,
  PLAN_B_PROXY_RUNTIME_TYPES,
  PLAN_B_PROXY_SHARED_METHODS,
  RAW_PROXY_EXPORTS
};

const COMPILE_NATIVE_ARGS = ['--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'compileNative'];
const TASK_TREE_ARGS = ['--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'taskTree'];
const SAFE_CLEAN_PATHS = [
  ['artifacts', 'libcmfa_mihomo.so'],
  ['entry', 'src', 'main', 'libs', 'arm64-v8a', 'libcmfa_mihomo.so'],
  ['entry', '.cxx', 'default', 'default', 'debug', 'arm64-v8a'],
  ['entry', 'build', 'default', 'cache'],
  ['entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a'],
  ['entry', 'build', 'default', 'outputs', 'default']
];
const SIGNING_TOKEN_PATTERN = /(^|[\s"'(=\[])([^\s"'<>]*\.(?:p12|cer|p7b|pem|pfx))(?=$|[\s"'<>)}\]])/giu;
const REDACTED_SIGNING_TOKEN_PATTERN = /(^|[\s"'(=\[])(?:(?:file:\/\/)?(?:<[^>]+>\/)+[^\s"'<>]*\.(?:p12|cer|p7b|pem|pfx))(?=$|[\s"'<>)}\]])/giu;
const RAW_CORE_RELATIVE_PATH = path.join('artifacts', 'libcmfa_mihomo.so');
const PRE_PACKAGE_DIRECTORY = path.join('entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a');
const PRE_PACKAGE_CORE_NAME = 'libcmfa_mihomo.so';
const PRE_PACKAGE_ADDON_NAME = 'libentry.so';
const CANONICAL_HAP_IDENTITY_PATTERN = /^harmony\/entry\/build\/default\/outputs\/default\/[^/]+\.hap$/u;
const GEODATA_LOCK_PATH = path.join(HARMONY_ROOT, 'geodata.lock.json');
const CANONICAL_GEODATA_RAWFILE_DIRECTORY = 'harmony/entry/src/main/resources/rawfile';

let cachedCanonicalGeodataAsset = null;

function isoTimestamp(date) {
  return date.toISOString();
}

function sanitizeSigningTokens(raw) {
  return String(raw ?? '')
    .replace(SIGNING_TOKEN_PATTERN, (_, prefix) => `${prefix}<signing-material>`)
    .replace(REDACTED_SIGNING_TOKEN_PATTERN, (_, prefix) => `${prefix}<signing-material>`);
}

function sanitizePersistedString(raw, replacements) {
  return sanitizeSigningTokens(sanitizeText(sanitizeSigningTokens(raw), replacements));
}

function sanitizeForPersistenceWithSigning(value, replacements) {
  if (typeof value === 'string') {
    return sanitizePersistedString(value, replacements);
  }

  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeForPersistenceWithSigning(entry, replacements));
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, sanitizeForPersistenceWithSigning(entry, replacements)])
    );
  }

  return value;
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

function createFailure(code, detail, stage) {
  return {
    code,
    detail: sanitizeSigningTokens(detail),
    stage
  };
}

function createBuildStep(result = 'not-run', command = null, exitCode = null, stdout = '', stderr = '') {
  return { result, command, exitCode, stdout, stderr };
}

function createPhase2SelfTestEvidence(enabled) {
  return {
    enabled: Boolean(enabled),
    activation: enabled ? 'explicit' : 'default',
    purpose: enabled ? 'test-only' : 'production',
    releaseStatus: enabled ? 'not-releasable' : 'releasable'
  };
}

function createPhase2SelfTestEnv(env, enabled) {
  const nextEnv = { ...env };
  delete nextEnv.CMFA_ENABLE_PHASE2_SELFTEST;
  delete nextEnv.CMFA_TEST_BUILD_ABI;

  if (enabled) {
    nextEnv.CMFA_ENABLE_PHASE2_SELFTEST = '1';
    nextEnv.CMFA_TEST_BUILD_ABI = '1';
  }

  return nextEnv;
}

function createBaseManifest({ repoRoot, outputPath, startedAt, runId }) {
  return {
    schemaVersion: PHASE1_NATIVE_SCHEMA_VERSION,
    phase: PHASE1_NATIVE_PHASE,
    runId,
    result: 'fail',
    nativeBuildResult: 'fail',
    timestamps: {
      startedAt: isoTimestamp(startedAt),
      completedAt: null
    },
    toolchainLock: {
      path: normalizePathForReport(repoRoot, path.join(HARMONY_ROOT, 'toolchain.lock.json')),
      sha256: null
    },
    phase2SelfTest: createPhase2SelfTestEvidence(false),
    builds: {
      core: createBuildStep(),
      addonConfigure: createBuildStep(),
      addon: createBuildStep(),
      hap: createBuildStep()
    },
    artifacts: {
      rawCore: null,
      prePackageCore: null,
      prePackageAddon: null,
      hap: null,
      hapCore: null,
      hapAddon: null
    },
    archive: {
      entryCount: null,
      occurrences: {
        core: null,
        addon: null
      }
    },
    signing: {
      result: 'not-run'
    },
    device: {
      result: 'not-run',
      targetCount: null,
      identityMasked: null,
      proofResult: 'not-run'
    },
    failures: []
  };
}

function readCanonicalGeodataAsset() {
  if (cachedCanonicalGeodataAsset !== null) {
    return cachedCanonicalGeodataAsset;
  }

  let parsed;
  try {
    parsed = JSON.parse(readFileSync(GEODATA_LOCK_PATH, 'utf8'));
  } catch {
    throw new Error('canonical geodata lock authority is invalid');
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('canonical geodata lock authority is invalid');
  }
  if (parsed.schemaVersion !== '1.0.0' || !Array.isArray(parsed.assets) || parsed.assets.length !== 1) {
    throw new Error('canonical geodata lock authority is invalid');
  }

  const [asset] = parsed.assets;
  if (
    !asset ||
    typeof asset !== 'object' ||
    Array.isArray(asset) ||
    asset.name !== 'geoip.metadb' ||
    !Number.isInteger(asset.sizeBytes) ||
    asset.sizeBytes <= 0 ||
    !isLowerHexDigest(asset.sha256)
  ) {
    throw new Error('canonical geodata lock authority is invalid');
  }

  cachedCanonicalGeodataAsset = Object.freeze({
    name: asset.name,
    path: `${CANONICAL_GEODATA_RAWFILE_DIRECTORY}/${asset.name}`,
    sizeBytes: asset.sizeBytes,
    sha256: asset.sha256
  });
  return cachedCanonicalGeodataAsset;
}

function pushFailure(manifest, failure) {
  if (manifest.failures.some((entry) => entry.code === failure.code && entry.detail === failure.detail && entry.stage === failure.stage)) {
    return;
  }

  manifest.failures.push(failure);
}

function createNowProvider(options = {}) {
  const nowSequence = Array.isArray(options.nowSequence) ? [...options.nowSequence] : null;
  const now = typeof options.now === 'function' ? options.now : () => new Date();

  return function getNow() {
    if (nowSequence && nowSequence.length > 0) {
      return nowSequence.shift();
    }

    return now();
  };
}

function emit(options, eventName) {
  options.onEvent?.(eventName);
}

function resolveRunCommandImpl(runCommandImpl) {
  if (runCommandImpl) {
    return runCommandImpl;
  }

  return async function defaultRunCommand({ command, args, cwd, env = process.env }) {
    return await new Promise((resolve) => {
      const child = spawnChild(command, args, {
        cwd,
        env,
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe']
      });

      let stdout = '';
      let stderr = '';
      let settled = false;

      const finalize = ({ exitCode = null, error = null, signal = null } = {}) => {
        if (settled) {
          return;
        }

        settled = true;
        resolve({
          command,
          args: [...args],
          exitCode,
          stdout,
          stderr,
          error,
          signal
        });
      };

      child.stdout?.on('data', (chunk) => {
        stdout += chunk.toString();
      });
      child.stderr?.on('data', (chunk) => {
        stderr += chunk.toString();
      });
      child.on('error', (error) => finalize({ error }));
      child.on('close', (exitCode, signal) => finalize({ exitCode, signal }));
    });
  };
}

function buildStepFromCommand(commandResult, repoRoot, replacements, { commandOverride = null } = {}) {
  return {
    result: commandResult.error || commandResult.exitCode !== 0 ? 'fail' : 'pass',
    command: (commandOverride ?? [commandResult.command, ...commandResult.args])
      .map((entry) => sanitizePersistedString(path.isAbsolute(entry) ? normalizePathForReport(repoRoot, entry) : entry, replacements)),
    exitCode: commandResult.exitCode,
    stdout: sanitizePersistedString(commandResult.stdout, replacements),
    stderr: sanitizePersistedString(commandResult.stderr, replacements)
  };
}

async function cleanupPhase1Outputs(harmonyRoot, fsApi) {
  for (const segments of SAFE_CLEAN_PATHS) {
    const absolutePath = path.resolve(harmonyRoot, ...segments);
    if (!absolutePath.startsWith(`${path.resolve(harmonyRoot)}${path.sep}`)) {
      throw Object.assign(new Error(`Refusing to clean outside harmony root: ${absolutePath}`), { code: 'PATH_OUTSIDE_REPO' });
    }
    await fsApi.rm(absolutePath, { recursive: true, force: true });
  }
}

async function statFreshFile(fsApi, absolutePath, startedAt) {
  const stats = await fsApi.stat(absolutePath);
  return stats.mtimeMs >= startedAt.getTime();
}

async function hashArtifact({ absolutePath, identity, hashFileImpl = hashFile, elf = null }) {
  const digest = await hashFileImpl(absolutePath);
  return {
    identity,
    sha256: digest.sha256,
    sizeBytes: digest.sizeBytes,
    elf
  };
}

async function ensureDurablePrePackageCore({
  manifest,
  repoRoot,
  rawCorePath,
  prePackageCorePath,
  inspectNativeLibraryImpl,
  fsApi
}) {
  if (!manifest.artifacts.rawCore || !manifest.artifacts.prePackageCore) {
    return;
  }

  let restoreRequired = false;
  try {
    const liveDigest = await hashFile(prePackageCorePath);
    restoreRequired =
      liveDigest.sha256 !== manifest.artifacts.rawCore.sha256 ||
      liveDigest.sizeBytes !== manifest.artifacts.rawCore.sizeBytes;
  } catch {
    restoreRequired = true;
  }

  if (!restoreRequired) {
    return;
  }

  try {
    await fsApi.mkdir(path.dirname(prePackageCorePath), { recursive: true });
    await fsApi.copyFile(rawCorePath, prePackageCorePath);
  } catch (error) {
    pushFailure(
      manifest,
      createFailure(
        'PRE_PACKAGE_CORE_RESTORE_FAILED',
        error?.message ?? 'Failed to restore the durable pre-package core artifact.',
        'restore-pre-package-core'
      )
    );
    return;
  }

  const refreshedDigest = await hashArtifact({
    absolutePath: prePackageCorePath,
    identity: normalizePathForReport(repoRoot, prePackageCorePath)
  });
  const refreshedElf = await inspectElfWithContract({
    manifest,
    artifactKey: 'prePackageCore',
    libPath: prePackageCorePath,
    component: 'mihomoCore',
    inspectNativeLibraryImpl
  });
  if (refreshedElf) {
    manifest.artifacts.prePackageCore = {
      ...refreshedDigest,
      elf: refreshedElf
    };
  }

  if (
    manifest.artifacts.rawCore &&
    manifest.artifacts.prePackageCore &&
    (manifest.artifacts.rawCore.sha256 !== manifest.artifacts.prePackageCore.sha256 ||
      manifest.artifacts.rawCore.sizeBytes !== manifest.artifacts.prePackageCore.sizeBytes)
  ) {
    pushFailure(manifest, createFailure('PRE_PACKAGE_CORE_MISMATCH', 'Pre-package core must byte-match the raw core artifact.', 'restore-pre-package-core'));
  }
}

function classifyNativeFailureCode(code) {
  return code === 'SIGNING_REQUIRED' || code === 'DEVICE_TARGET_MISSING' || code === 'DEVICE_TARGET_AMBIGUOUS';
}

function shouldContinueArchive(buildReport) {
  return Boolean(
    buildReport?.hap?.path &&
    buildReport?.result === 'incomplete' &&
    Array.isArray(buildReport?.failures) &&
    buildReport.failures.length > 0 &&
    buildReport.failures.every((entry) => entry.code === 'SIGNING_REQUIRED')
  );
}

async function inspectCompileNativeTask({
  harmonyRoot,
  hvigorPath,
  runCommandImpl
}) {
  const commandResult = await runCommandImpl({
    command: hvigorPath,
    args: TASK_TREE_ARGS,
    cwd: harmonyRoot
  });

  const lines = String(commandResult.stdout ?? '').split(/\r?\n/u);
  const strippedLines = lines.map((line) => stripVTControlCharacters(line));
  const rootIndex = strippedLines.findIndex((line) => /^:entry:compileNative$/u.test(line.trim()) && !/^\s/u.test(line));
  const branchLines = [];

  if (rootIndex !== -1) {
    branchLines.push(strippedLines[rootIndex].trim());
    for (let index = rootIndex + 1; index < lines.length; index += 1) {
      const line = strippedLines[index];
      if (!line.trim()) {
        continue;
      }
      if (/^:entry:\S/u.test(line)) {
        break;
      }
      branchLines.push(line);
    }
  }

  return {
    rootTask: rootIndex === -1 ? null : ':entry:compileNative',
    hasBuildNativeWithCmake: branchLines.some((line) => line.includes('BuildNativeWithCmake')),
    hasPackageHap: branchLines.some((line) => line.includes('PackageHap')),
    command: [hvigorPath, ...TASK_TREE_ARGS],
    stdout: commandResult.stdout ?? '',
    stderr: commandResult.stderr ?? '',
    exitCode: commandResult.exitCode,
    error: commandResult.error ?? null
  };
}

async function readJsonFile(fsApi, targetPath) {
  const raw = await fsApi.readFile(targetPath, 'utf8');
  return JSON.parse(raw);
}

function hasMatchingStageFailure(failures, stage) {
  return failures.some((failure) => failure.stage === stage || failure.stage === 'phase1');
}

function updateSigningState(manifest, buildReport) {
  if (!buildReport?.hap?.path) {
    manifest.signing.result = 'not-run';
    return;
  }

  if (shouldContinueArchive(buildReport)) {
    manifest.signing.result = 'incomplete';
    return;
  }

  manifest.signing.result = 'pass';
}

function mergeBuildHapFailures(manifest, buildReport) {
  for (const failure of buildReport?.failures ?? []) {
    pushFailure(manifest, createFailure(failure.code, failure.detail, failure.stage ?? 'signing'));
  }
}

async function resolveSelectedHapPath(repoRoot, buildReport, fsApi = fs) {
  if (!buildReport?.hap?.path) {
    return null;
  }

  const rawPath = String(buildReport.hap.path);
  const rawIdentity = rawPath.replaceAll('\\', '/');
  const absolutePath = path.resolve(repoRoot, rawPath);
  const normalizedRepoRoot = path.resolve(repoRoot);
  if (absolutePath === normalizedRepoRoot || !absolutePath.startsWith(`${normalizedRepoRoot}${path.sep}`)) {
    const error = new Error(`Selected hap path escapes the repository: ${buildReport.hap.path}`);
    error.code = 'HAP_PATH_OUTSIDE_REPO';
    throw error;
  }

  const relativeIdentity = path.relative(repoRoot, absolutePath).split(path.sep).join('/');
  if (
    path.posix.isAbsolute(rawIdentity) ||
    rawIdentity !== path.posix.normalize(rawIdentity) ||
    rawIdentity !== relativeIdentity ||
    !CANONICAL_HAP_IDENTITY_PATTERN.test(relativeIdentity)
  ) {
    const error = new Error(`Selected hap path is not the canonical outputs/default direct-child .hap: ${buildReport.hap.path}`);
    error.code = 'HAP_PATH_INVALID';
    throw error;
  }

  await resolveLiveRepoPath(repoRoot, absolutePath, {
    fsApi,
    displayPath: relativeIdentity
  });
  return absolutePath;
}

function sameFileIdentity(left, right) {
  return Boolean(
    left &&
    right &&
    Number.isInteger(left.dev) &&
    Number.isInteger(left.ino) &&
    left.dev === right.dev &&
    left.ino === right.ino
  );
}

async function openStableRepoFileHandle({ repoRoot, absolutePath, displayPath, fsApi }) {
  const validated = await resolveLiveRepoPath(repoRoot, absolutePath, {
    fsApi,
    displayPath
  });
  const beforeStats = await fsApi.stat(absolutePath);
  let fileHandle = null;

  try {
    if (typeof FS_CONSTANTS.O_NOFOLLOW === 'number') {
      fileHandle = await fsApi.open(absolutePath, FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_NOFOLLOW);
      const handleStats = await fileHandle.stat();
      if (!handleStats.isFile()) {
        throw Object.assign(new Error(`Selected hap path is not a regular file: ${displayPath}`), { code: 'HAP_PATH_INVALID' });
      }
      if (!sameFileIdentity(beforeStats, handleStats)) {
        throw Object.assign(new Error(`Selected hap path changed during snapshot creation: ${displayPath}`), { code: 'HAP_PATH_RACE' });
      }
      return fileHandle;
    }

    fileHandle = await fsApi.open(absolutePath, FS_CONSTANTS.O_RDONLY);
    const handleStats = await fileHandle.stat();
    const afterStats = await fsApi.lstat(absolutePath);
    const afterValidated = await resolveLiveRepoPath(repoRoot, absolutePath, {
      fsApi,
      displayPath
    });
    if (
      afterStats.isSymbolicLink() ||
      !handleStats.isFile() ||
      !sameFileIdentity(beforeStats, handleStats) ||
      validated.realPath !== afterValidated.realPath
    ) {
      throw Object.assign(new Error(`Selected hap path changed during snapshot creation: ${displayPath}`), { code: 'HAP_PATH_RACE' });
    }
    return fileHandle;
  } catch (error) {
    if ((error?.code === 'ELOOP' || error?.code === 'EMLINK') && typeof FS_CONSTANTS.O_NOFOLLOW === 'number') {
      throw Object.assign(new Error(`Selected hap path must not resolve through a symbolic link: ${displayPath}`), { code: 'HAP_PATH_SYMLINK' });
    }
    await fileHandle?.close().catch(() => {});
    throw error;
  }
}

async function createSelectedHapSnapshot({ repoRoot, absolutePath, runId, fsApi }) {
  const displayPath = normalizePathForReport(repoRoot, absolutePath) ?? path.basename(absolutePath);
  const snapshotRoot = await fsApi.mkdtemp(path.join(os.tmpdir(), `phase1-native-hap-${runId}-`));
  const snapshotPath = path.join(snapshotRoot, 'selected.hap');
  const sourceHandle = await openStableRepoFileHandle({
    repoRoot,
    absolutePath,
    displayPath,
    fsApi
  });
  let snapshotHandle = null;

  const cleanup = async () => {
    await snapshotHandle?.close().catch(() => {});
    await sourceHandle?.close().catch(() => {});
    await fsApi.rm(snapshotRoot, { recursive: true, force: true }).catch(() => {});
  };

  try {
    snapshotHandle = await fsApi.open(snapshotPath, FS_CONSTANTS.O_CREAT | FS_CONSTANTS.O_EXCL | FS_CONSTANTS.O_WRONLY, 0o600);
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    while (true) {
      const { bytesRead } = await sourceHandle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) {
        break;
      }
      await snapshotHandle.write(buffer.subarray(0, bytesRead));
    }
    await snapshotHandle.close();
    snapshotHandle = null;
    await sourceHandle.close();
    return {
      snapshotPath,
      cleanup
    };
  } catch (error) {
    await cleanup();
    throw error;
  }
}

function normalizeArchiveOccurrences(occurrences = {}) {
  return {
    core: occurrences.core ?? occurrences[HAP_NATIVE_ENTRIES.core] ?? 0,
    addon: occurrences.addon ?? occurrences[HAP_NATIVE_ENTRIES.addon] ?? 0
  };
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((entry) => typeof entry === 'string');
}

function isNonNegativeInteger(value) {
  return Number.isInteger(value) && value >= 0;
}

function isLowerHexDigest(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
}

function isAbsoluteNonEmptyString(value) {
  return typeof value === 'string' && value.length > 0 && path.isAbsolute(value);
}

function normalizeValidToolchainFailures(failures) {
  if (!Array.isArray(failures)) {
    return null;
  }

  const normalized = [];
  for (const failure of failures) {
    if (!failure || typeof failure !== 'object' || Array.isArray(failure)) {
      return null;
    }
    if (
      typeof failure.code !== 'string' ||
      failure.code.length === 0 ||
      typeof failure.detail !== 'string' ||
      failure.detail.length === 0
    ) {
      return null;
    }
    normalized.push({
      code: failure.code,
      detail: failure.detail
    });
  }

  return normalized;
}

function validateToolchainInspectionShape(inspection) {
  const errors = [];
  const report = inspection?.report;
  if (!report || typeof report !== 'object' || Array.isArray(report)) {
    errors.push('report must be an object');
  }

  const validResult = ['pass', 'fail', 'incomplete'].includes(report?.result);
  if (!validResult) {
    errors.push('report.result must be pass, fail, or incomplete');
  }

  const failures = normalizeValidToolchainFailures(report?.failures);
  if (failures === null) {
    errors.push('report.failures must be an array of { code, detail } objects');
  }

  return {
    valid: errors.length === 0,
    errors,
    result: validResult ? report.result : null,
    failures: Array.isArray(failures) ? failures : []
  };
}

function normalizeValidFailureEntries(failures) {
  if (!Array.isArray(failures)) {
    return null;
  }

  const normalized = [];
  for (const failure of failures) {
    if (!failure || typeof failure !== 'object' || Array.isArray(failure)) {
      return null;
    }
    if (typeof failure.code !== 'string' || typeof failure.detail !== 'string') {
      return null;
    }
    normalized.push({
      code: failure.code,
      detail: failure.detail,
      stage: typeof failure.stage === 'string' && failure.stage.length > 0 ? failure.stage : null
    });
  }

  return normalized;
}

function validateBuildHapReport(report) {
  const errors = [];
  const result = report?.result;
  const hasValidResult = ['pass', 'fail', 'incomplete'].includes(result);
  if (!hasValidResult) {
    errors.push('result must be pass, fail, or incomplete');
  }

  const phase2SelfTest = report?.phase2SelfTest;
  const requiresStrictPhase2SelfTest = Object.hasOwn(report ?? {}, 'schemaVersion') ||
    Object.hasOwn(report ?? {}, 'phase') ||
    Object.hasOwn(report ?? {}, 'toolchain') ||
    Object.hasOwn(report ?? {}, 'wrapper');
  const hasPhase2Shape = phase2SelfTest &&
    typeof phase2SelfTest === 'object' &&
    !Array.isArray(phase2SelfTest) &&
    typeof phase2SelfTest.enabled === 'boolean' &&
    ['default', 'explicit'].includes(phase2SelfTest.activation) &&
    ['production', 'test-only'].includes(phase2SelfTest.purpose) &&
    ['releasable', 'not-releasable'].includes(phase2SelfTest.releaseStatus);
  if (requiresStrictPhase2SelfTest && !hasPhase2Shape) {
    errors.push('phase2SelfTest must be a strict self-test evidence object');
  } else if (hasPhase2Shape) {
    const expected = createPhase2SelfTestEvidence(phase2SelfTest.enabled);
    if (
      phase2SelfTest.activation !== expected.activation ||
      phase2SelfTest.purpose !== expected.purpose ||
      phase2SelfTest.releaseStatus !== expected.releaseStatus
    ) {
      errors.push('phase2SelfTest must use canonical production/self-test combinations');
    }
  }

  let hapPath = null;
  if (report?.hap !== undefined && report?.hap !== null) {
    if (!report.hap || typeof report.hap !== 'object' || Array.isArray(report.hap)) {
      errors.push('hap must be an object when present');
    } else {
      if (typeof report.hap.path === 'string' && report.hap.path.length > 0) {
        hapPath = report.hap.path;
      } else if (report.hap.path !== null) {
        errors.push('hap.path must be a non-empty string or null when hap is present');
      }

      if (!(report.hap.sha256 === null || isLowerHexDigest(report.hap.sha256))) {
        errors.push('hap.sha256 must be a lowercase sha256 digest or null');
      }
      if (!(report.hap.sizeBytes === null || isNonNegativeInteger(report.hap.sizeBytes))) {
        errors.push('hap.sizeBytes must be a non-negative integer or null');
      }
      if (hapPath === null && (report.hap.sha256 !== null || report.hap.sizeBytes !== null)) {
        errors.push('hap.sha256 and hap.sizeBytes must stay null when hap.path is null');
      }
    }
  }

  const normalizedFailures = normalizeValidFailureEntries(report?.failures);
  if (normalizedFailures === null) {
    errors.push('failures must be an array of { code, detail, stage? } objects');
  }

  const commands = Array.isArray(report?.commands) ? report.commands : null;
  if (commands === null || commands.length === 0) {
    errors.push('commands must be a non-empty array');
  }

  const firstCommand = commands?.[0];
  const safeCommand = isStringArray(firstCommand?.command) ? [...firstCommand.command] : null;
  const safeExitCode = Number.isInteger(firstCommand?.exitCode) ? firstCommand.exitCode : null;
  const safeStdout = typeof firstCommand?.stdout === 'string' ? firstCommand.stdout : '';
  const safeStderr = typeof firstCommand?.stderr === 'string' ? firstCommand.stderr : '';

  if (firstCommand && (!firstCommand || typeof firstCommand !== 'object' || Array.isArray(firstCommand))) {
    errors.push('commands[0] must be an object');
  }
  if (firstCommand && safeCommand === null) {
    errors.push('commands[0].command must be a string[]');
  }
  if (firstCommand && safeExitCode === null) {
    errors.push('commands[0].exitCode must be an integer');
  }
  if (firstCommand && typeof firstCommand.stdout !== 'string') {
    errors.push('commands[0].stdout must be a string');
  }
  if (firstCommand && typeof firstCommand.stderr !== 'string') {
    errors.push('commands[0].stderr must be a string');
  }

  const geodata = report?.geodata;
  let canonicalGeodataAsset = null;
  try {
    canonicalGeodataAsset = readCanonicalGeodataAsset();
  } catch {
    errors.push('canonical geodata lock authority is invalid');
  }
  const canonicalGeodataPath = canonicalGeodataAsset?.path ?? `${CANONICAL_GEODATA_RAWFILE_DIRECTORY}/geoip.metadb`;
  const hasGeodataShape = geodata &&
    typeof geodata === 'object' &&
    !Array.isArray(geodata) &&
    ['pass', 'fail'].includes(geodata.result) &&
    geodata.path === canonicalGeodataPath;
  if (!hasGeodataShape) {
    errors.push('geodata must be a strict { result, path, sha256, sizeBytes } object for the canonical rawfile asset');
  } else if (geodata.result === 'pass') {
    if (!isLowerHexDigest(geodata.sha256)) {
      errors.push('geodata pass evidence requires a lowercase sha256 digest');
    }
    if (!isNonNegativeInteger(geodata.sizeBytes) || geodata.sizeBytes <= 0) {
      errors.push('geodata pass evidence requires a positive sizeBytes value');
    }
    if (canonicalGeodataAsset !== null) {
      if (geodata.sha256 !== canonicalGeodataAsset.sha256) {
        errors.push('geodata pass evidence requires the canonical pinned sha256 digest');
      }
      if (geodata.sizeBytes !== canonicalGeodataAsset.sizeBytes) {
        errors.push('geodata pass evidence requires the canonical pinned sizeBytes value');
      }
    }
  } else {
    const hasTypedFailure = Array.isArray(normalizedFailures) &&
      normalizedFailures.some((failure) => failure.code === 'GEODATA_PREPARE_FAILED' && failure.stage === 'prepare-geodata');
    if (result !== 'fail') {
      errors.push('geodata fail evidence requires report.result = fail');
    }
    if (geodata.sha256 !== null) {
      errors.push('geodata fail evidence requires sha256 = null');
    }
    if (geodata.sizeBytes !== null) {
      errors.push('geodata fail evidence requires sizeBytes = null');
    }
    if (hapPath !== null || report?.hap?.sha256 !== null || report?.hap?.sizeBytes !== null) {
      errors.push('geodata fail evidence requires hap path, sha256, and sizeBytes to stay null');
    }
    if (!hasTypedFailure) {
      errors.push('geodata fail evidence requires a GEODATA_PREPARE_FAILED failure at stage prepare-geodata');
    }
    if (firstCommand?.stage !== 'prepare-geodata') {
      errors.push('geodata fail evidence requires commands[0].stage = prepare-geodata');
    }
    if (firstCommand?.result !== 'fail') {
      errors.push('geodata fail evidence requires commands[0].result = fail');
    }
    if (safeCommand?.[0] !== 'prepare-geodata') {
      errors.push('geodata fail evidence requires commands[0].command[0] = prepare-geodata');
    }
    if (!(Number.isInteger(safeExitCode) && safeExitCode !== 0)) {
      errors.push('geodata fail evidence requires a non-zero commands[0].exitCode');
    }
    if (safeStdout !== '' || safeStderr !== '') {
      errors.push('geodata fail evidence requires empty commands[0] stdout/stderr');
    }
  }

  const selectionOnlyIncomplete = hasValidResult &&
    result === 'incomplete' &&
    hapPath !== null &&
    Array.isArray(normalizedFailures) &&
    normalizedFailures.length > 0 &&
    normalizedFailures.every((failure) => failure.code === 'SIGNING_REQUIRED');

  return {
    valid: errors.length === 0,
    errors,
    result: hasValidResult ? result : null,
    hapPath,
    phase2SelfTest: hasPhase2Shape ? createPhase2SelfTestEvidence(phase2SelfTest.enabled) : createPhase2SelfTestEvidence(false),
    failures: Array.isArray(normalizedFailures) ? normalizedFailures : [],
    command: safeCommand,
    exitCode: safeExitCode,
    stdout: safeStdout,
    stderr: safeStderr,
    signingResult: selectionOnlyIncomplete ? 'incomplete' : 'not-run'
  };
}

function validateArchiveArtifactShape(artifact, expectedIdentity, artifactKey) {
  const errors = [];
  if (!artifact || typeof artifact !== 'object' || Array.isArray(artifact)) {
    errors.push(`${artifactKey} must be an object`);
    return { valid: false, errors, normalized: null };
  }
  if (artifact.identity !== expectedIdentity) {
    errors.push(`${artifactKey}.identity must equal ${expectedIdentity}`);
  }
  if (!isLowerHexDigest(artifact.sha256)) {
    errors.push(`${artifactKey}.sha256 must be a lowercase sha256 digest`);
  }
  if (!isNonNegativeInteger(artifact.sizeBytes)) {
    errors.push(`${artifactKey}.sizeBytes must be a non-negative integer`);
  }
  if (!artifact.elf || typeof artifact.elf !== 'object' || Array.isArray(artifact.elf)) {
    errors.push(`${artifactKey}.elf must be an object`);
  }

  const normalizedElf = artifact.elf && typeof artifact.elf === 'object' && !Array.isArray(artifact.elf)
    ? normalizeElfReport(artifact.elf, artifactKey === 'core' ? 'mihomoCore' : 'nodeAddon')
    : null;
  if (normalizedElf) {
    if (typeof normalizedElf.result !== 'string') {
      errors.push(`${artifactKey}.elf.result must be a string`);
    }
    if (typeof normalizedElf.component !== 'string') {
      errors.push(`${artifactKey}.elf.component must be a string`);
    }
    if (typeof normalizedElf.architecture !== 'string') {
      errors.push(`${artifactKey}.elf.architecture must be a string`);
    }
    if (!isStringArray(normalizedElf.neededLibraries)) {
      errors.push(`${artifactKey}.elf.neededLibraries must be a string[]`);
    }
    if (!isStringArray(normalizedElf.allowedNeededLibraries)) {
      errors.push(`${artifactKey}.elf.allowedNeededLibraries must be a string[]`);
    }
    if (!isStringArray(normalizedElf.exportedSymbols)) {
      errors.push(`${artifactKey}.elf.exportedSymbols must be a string[]`);
    }
    if (!isStringArray(normalizedElf.requiredExports)) {
      errors.push(`${artifactKey}.elf.requiredExports must be a string[]`);
    }
    if (!Array.isArray(normalizedElf.failures)) {
      errors.push(`${artifactKey}.elf.failures must be an array`);
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    normalized: errors.length === 0
      ? {
        identity: expectedIdentity,
        sha256: artifact.sha256,
        sizeBytes: artifact.sizeBytes,
        elf: normalizedElf
      }
      : null
  };
}

function validateArchiveInspectionReport(report) {
  const errors = [];
  if (!report || typeof report !== 'object' || Array.isArray(report)) {
    return { valid: false, errors: ['archive report must be an object'], normalized: null };
  }

  if (!isNonNegativeInteger(report.entryCount)) {
    errors.push('entryCount must be a non-negative integer');
  }

  const occurrences = report.occurrences;
  if (!occurrences || typeof occurrences !== 'object' || Array.isArray(occurrences)) {
    errors.push('occurrences must be an object');
  } else {
    if (!isNonNegativeInteger(occurrences.core)) {
      errors.push('occurrences.core must be a non-negative integer');
    }
    if (!isNonNegativeInteger(occurrences.addon)) {
      errors.push('occurrences.addon must be a non-negative integer');
    }
  }

  const failures = normalizeValidFailureEntries(report.failures);
  if (failures === null) {
    errors.push('failures must be an array of { code, detail, stage? } objects');
  }

  const artifacts = report.artifacts;
  if (!artifacts || typeof artifacts !== 'object' || Array.isArray(artifacts)) {
    errors.push('artifacts must be an object');
  }

  let coreArtifact = null;
  let addonArtifact = null;
  if (artifacts && typeof artifacts === 'object' && !Array.isArray(artifacts)) {
    if (artifacts.core !== undefined && artifacts.core !== null) {
      const validated = validateArchiveArtifactShape(artifacts.core, HAP_NATIVE_ENTRIES.core, 'core');
      if (!validated.valid) {
        errors.push(...validated.errors);
      } else {
        coreArtifact = validated.normalized;
      }
    }
    if (artifacts.addon !== undefined && artifacts.addon !== null) {
      const validated = validateArchiveArtifactShape(artifacts.addon, HAP_NATIVE_ENTRIES.addon, 'addon');
      if (!validated.valid) {
        errors.push(...validated.errors);
      } else {
        addonArtifact = validated.normalized;
      }
    }
  }

  const coreOccurrence = isNonNegativeInteger(report?.occurrences?.core) ? report.occurrences.core : null;
  const addonOccurrence = isNonNegativeInteger(report?.occurrences?.addon) ? report.occurrences.addon : null;
  if (coreOccurrence === 1 && coreArtifact === null) {
    errors.push('occurrences.core = 1 requires a complete core artifact');
  }
  if (addonOccurrence === 1 && addonArtifact === null) {
    errors.push('occurrences.addon = 1 requires a complete addon artifact');
  }
  if (coreOccurrence === 0 && artifacts?.core !== undefined && artifacts.core !== null) {
    errors.push('occurrences.core = 0 cannot provide a core artifact');
  }
  if (addonOccurrence === 0 && artifacts?.addon !== undefined && artifacts.addon !== null) {
    errors.push('occurrences.addon = 0 cannot provide an addon artifact');
  }
  if (
    isNonNegativeInteger(report.entryCount) &&
    coreOccurrence !== null &&
    addonOccurrence !== null &&
    report.entryCount < (coreOccurrence + addonOccurrence)
  ) {
    errors.push('entryCount cannot be smaller than the sum of core/addon occurrences');
  }

  return {
    valid: errors.length === 0,
    errors,
    normalized: errors.length === 0
      ? {
        entryCount: report.entryCount,
        occurrences: {
          core: report.occurrences.core,
          addon: report.occurrences.addon
        },
        failures: Array.isArray(failures) ? failures : [],
        artifacts: {
          core: coreArtifact,
          addon: addonArtifact
        }
      }
      : null
  };
}

function createElfFailureDescriptor(artifactKey) {
  switch (artifactKey) {
    case 'rawCore':
      return { code: 'RAW_CORE_ELF_INVALID', stage: 'build-core', label: 'Raw core' };
    case 'prePackageCore':
      return { code: 'PRE_PACKAGE_CORE_ELF_INVALID', stage: 'stage-pre-package-core', label: 'Pre-package core' };
    case 'prePackageAddon':
      return { code: 'PRE_PACKAGE_ADDON_ELF_INVALID', stage: 'stage-pre-package-core', label: 'Pre-package addon' };
    case 'hapCore':
      return { code: 'HAP_CORE_ELF_INVALID', stage: 'archive', label: 'HAP core' };
    case 'hapAddon':
      return { code: 'HAP_ADDON_ELF_INVALID', stage: 'archive', label: 'HAP addon' };
    default:
      return { code: 'PHASE1_NATIVE_FATAL', stage: 'phase1', label: 'Native artifact' };
  }
}

function recordElfContractFailure(manifest, artifactKey, detail) {
  const descriptor = createElfFailureDescriptor(artifactKey);
  pushFailure(manifest, createFailure(descriptor.code, detail, descriptor.stage));
}

function normalizeElfContractDetail(artifactKey, errors) {
  const { label } = createElfFailureDescriptor(artifactKey);
  return `${label} ELF contract failed: ${errors.join('; ')}`;
}

function acceptElfArtifact(manifest, artifactKey, artifact) {
  const errors = collectArtifactElfContractErrors(artifact?.elf, artifactKey);
  if (errors.length > 0) {
    recordElfContractFailure(manifest, artifactKey, normalizeElfContractDetail(artifactKey, errors));
    return false;
  }

  manifest.artifacts[artifactKey] = artifact;
  return true;
}

async function inspectElfWithContract({
  manifest,
  artifactKey,
  libPath,
  component,
  inspectNativeLibraryImpl
}) {
  try {
    const elf = normalizeElfReport(await inspectNativeLibraryImpl({
      libPath: path.resolve(libPath),
      component
    }), component);
    const errors = collectArtifactElfContractErrors(elf, artifactKey);
    if (errors.length > 0) {
      recordElfContractFailure(manifest, artifactKey, normalizeElfContractDetail(artifactKey, errors));
      return null;
    }
    return elf;
  } catch (error) {
    recordElfContractFailure(manifest, artifactKey, error?.message ?? `${artifactKey} ELF inspection failed.`);
    return null;
  }
}

export async function writeManifest(manifest, outputPath = DEFAULT_OUTPUT_PATH, {
  fsApi = fs,
  replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: process.env })
} = {}) {
  const sanitized = sanitizeForPersistenceWithSigning(manifest, replacements);
  await fsApi.mkdir(path.dirname(outputPath), { recursive: true });
  const tempPath = path.join(path.dirname(outputPath), `.tmp-${path.basename(outputPath)}-${Date.now()}`);
  await fsApi.writeFile(tempPath, `${JSON.stringify(sanitized, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, outputPath);
  return sanitized;
}

export async function buildPhase1Native(options = {}) {
  const harmonyRoot = options.harmonyRoot ?? HARMONY_ROOT;
  const repoRoot = options.repoRoot ?? path.resolve(harmonyRoot, '..');
  const outputPath = options.outputPath ?? DEFAULT_OUTPUT_PATH;
  const fsApi = options.fsApi ?? fs;
  const env = options.env ?? process.env;
  const getNow = createNowProvider(options);
  const startedAt = getNow();
  const runId = (options.randomUuidImpl ?? randomUUID)();
  const manifest = createBaseManifest({ repoRoot, outputPath, startedAt, runId });
  const runCommandImpl = resolveRunCommandImpl(options.runCommandImpl);
  const replacements = createRedactionReplacements({ repoRoot, env });
  const phase2SelfTestEnv = createPhase2SelfTestEnv(env, options.phase2SelfTestEnabled);
  const toolchainLockPath = path.join(harmonyRoot, 'toolchain.lock.json');
  const rawCorePath = path.join(harmonyRoot, RAW_CORE_RELATIVE_PATH);
  const prePackageDirectory = path.join(harmonyRoot, PRE_PACKAGE_DIRECTORY);
  const prePackageCorePath = path.join(prePackageDirectory, PRE_PACKAGE_CORE_NAME);
  const prePackageAddonPath = path.join(prePackageDirectory, PRE_PACKAGE_ADDON_NAME);
  let persisted = null;
  let serialToMask = new Map();

  manifest.phase2SelfTest = createPhase2SelfTestEvidence(options.phase2SelfTestEnabled);

  try {
    emit(options, 'clean');
    await cleanupPhase1Outputs(harmonyRoot, fsApi);

    emit(options, 'toolchain-lock');
    manifest.toolchainLock.path = normalizePathForReport(repoRoot, toolchainLockPath);
    try {
      manifest.toolchainLock.sha256 = (await hashFile(toolchainLockPath)).sha256;
    } catch (error) {
      pushFailure(manifest, createFailure('TOOLCHAIN_LOCK_FAILED', error?.message ?? 'toolchain.lock.json could not be hashed.', 'toolchain-lock'));
      manifest.toolchainLock.sha256 = null;
    }

    if (manifest.toolchainLock.sha256 === null) {
      throw Object.assign(new Error('toolchain lock unavailable'), { code: 'STOP_AFTER_TOOLCHAIN_LOCK' });
    }

    emit(options, 'inspect-toolchain');
    const inspection = await (options.inspectToolchainImpl ?? inspectToolchain)({
      cwd: harmonyRoot,
      env,
      fs: fsApi
    });
    const validatedInspection = validateToolchainInspectionShape(inspection);

    for (const failure of validatedInspection.failures) {
      pushFailure(manifest, createFailure(failure.code, failure.detail, 'toolchain'));
    }

    if (!validatedInspection.valid) {
      pushFailure(
        manifest,
        createFailure('TOOLCHAIN_REPORT_INVALID', `Integrated HarmonyOS toolchain inspection returned a malformed report: ${validatedInspection.errors.join('; ')}`, 'toolchain')
      );
    }

    const hvigorPath = path.join(harmonyRoot, 'hvigorw');
    const cmakeExecutable = inspection?.resolved?.paths?.cmakeExecutable ?? null;
    const hdcPath = inspection?.resolved?.paths?.hdc ?? null;

    if (!validatedInspection.valid || validatedInspection.result !== 'pass') {
      pushFailure(manifest, createFailure('TOOLCHAIN_INSPECTION_FAILED', 'Integrated HarmonyOS toolchain inspection did not pass.', 'toolchain'));
    }
    if (!isAbsoluteNonEmptyString(cmakeExecutable)) {
      pushFailure(manifest, createFailure('TOOLCHAIN_CMAKE_PATH_INVALID', 'Integrated HarmonyOS toolchain inspection did not resolve a usable SDK cmake path.', 'toolchain'));
    }
    if (!isAbsoluteNonEmptyString(hdcPath)) {
      pushFailure(manifest, createFailure('TOOLCHAIN_HDC_PATH_INVALID', 'Integrated HarmonyOS toolchain inspection did not resolve a usable SDK hdc path.', 'toolchain'));
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      emit(options, 'verify-native-task');
      const taskTree = await (options.inspectTaskTreeImpl ?? inspectCompileNativeTask)({
        harmonyRoot,
        hvigorPath,
        runCommandImpl
      });
      if (taskTree.error || taskTree.exitCode !== 0) {
        pushFailure(manifest, createFailure('NATIVE_TASK_TREE_FAILED', taskTree.error?.message ?? 'hvigor taskTree failed.', 'toolchain'));
      } else {
        if (taskTree.rootTask !== ':entry:compileNative') {
          pushFailure(manifest, createFailure('NATIVE_TASK_ROOT_MISSING', 'Expected :entry:compileNative in hvigor taskTree output.', 'toolchain'));
        }
        if (!taskTree.hasBuildNativeWithCmake) {
          pushFailure(manifest, createFailure('NATIVE_TASK_BUILD_NATIVE_MISSING', 'compileNative task tree must include BuildNativeWithCmake.', 'toolchain'));
        }
        if (taskTree.hasPackageHap) {
          pushFailure(manifest, createFailure('NATIVE_TASK_PACKAGE_HAP_FORBIDDEN', 'compileNative task tree must not reach PackageHap.', 'toolchain'));
        }
      }
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      emit(options, 'build-core');
      const coreProof = await (options.buildMihomoOhosImpl ?? buildMihomoOhos)({
        harmonyRoot,
        env: phase2SelfTestEnv,
        fsApi
      });
      const reportedCoreCommand = Array.isArray(coreProof?.components?.mihomoCore?.build?.command) &&
        coreProof.components.mihomoCore.build.command.length > 0
        ? coreProof.components.mihomoCore.build.command
        : ['node', 'harmony/tools/build-mihomo-ohos.mjs'];
      manifest.builds.core = createBuildStep(
        coreProof?.result === 'pass' ? 'pass' : 'fail',
        reportedCoreCommand,
        coreProof?.result === 'pass' ? 0 : 1,
        '',
        ''
      );

      if (coreProof?.result !== 'pass') {
        for (const failure of coreProof?.failures ?? []) {
          pushFailure(manifest, createFailure(failure.code, failure.detail, failure.stage ?? 'build-core'));
        }
        if (!hasMatchingStageFailure(manifest.failures, 'build-core')) {
          pushFailure(manifest, createFailure('CORE_BUILD_FAILED', 'The phase1 core build aggregate proof failed.', 'build-core'));
        }
      } else {
        if (!await statFreshFile(fsApi, rawCorePath, startedAt)) {
          pushFailure(manifest, createFailure('RAW_CORE_STALE', 'Canonical libcmfa_mihomo.so must be rebuilt after the phase1 start time.', 'build-core'));
        } else {
          emit(options, 'hash-raw-core');
          const rawCoreDigest = await hashArtifact({
            absolutePath: rawCorePath,
            identity: normalizePathForReport(repoRoot, rawCorePath)
          });
          emit(options, 'inspect-raw-core');
          const rawCoreElf = await inspectElfWithContract({
            manifest,
            artifactKey: 'rawCore',
            libPath: rawCorePath,
            component: 'mihomoCore',
            inspectNativeLibraryImpl: options.inspectNativeLibraryImpl ?? inspectNativeLibrary
          });
          if (rawCoreElf) {
            manifest.artifacts.rawCore = {
              ...rawCoreDigest,
              elf: rawCoreElf
            };
          }
        }
      }
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      emit(options, 'prepare-addon');
      const configureResult = await runCommandImpl({
        command: hvigorPath,
        args: COMPILE_NATIVE_ARGS,
        cwd: harmonyRoot,
        env: phase2SelfTestEnv
      });
      manifest.builds.addonConfigure = buildStepFromCommand(configureResult, repoRoot, replacements);
      if (configureResult.error || configureResult.exitCode !== 0) {
        pushFailure(manifest, createFailure('ADDON_CONFIGURE_FAILED', configureResult.error?.message ?? `compileNative exited with ${configureResult.exitCode}`, 'prepare-addon'));
      }
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      const cmakeCommand = cmakeExecutable;
      if (!cmakeCommand) {
        pushFailure(manifest, createFailure('TOOL_MISSING', 'nativeCmake', 'build-addon'));
      } else {
        emit(options, 'build-addon');
        const addonBuildResult = await runCommandImpl({
          command: cmakeCommand,
          args: ['--build', 'entry/.cxx/default/default/debug/arm64-v8a', '--target', 'entry'],
          cwd: harmonyRoot,
          env: phase2SelfTestEnv
        });
        manifest.builds.addon = buildStepFromCommand(addonBuildResult, repoRoot, replacements);
        if (addonBuildResult.error || addonBuildResult.exitCode !== 0) {
          pushFailure(manifest, createFailure('ADDON_BUILD_FAILED', addonBuildResult.error?.message ?? `cmake --build exited with ${addonBuildResult.exitCode}`, 'build-addon'));
        } else if (!await statFreshFile(fsApi, prePackageAddonPath, startedAt)) {
          pushFailure(manifest, createFailure('ADDON_OUTPUT_STALE', 'The fresh addon output must be newer than the phase1 start time.', 'build-addon'));
        }
      }
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      emit(options, 'stage-pre-package-core');
      await fsApi.mkdir(prePackageDirectory, { recursive: true });
      await fsApi.copyFile(rawCorePath, prePackageCorePath);

      emit(options, 'hash-pre-package-core');
      emit(options, 'hash-pre-package-addon');
      const preCoreDigest = await hashArtifact({
        absolutePath: prePackageCorePath,
        identity: normalizePathForReport(repoRoot, prePackageCorePath)
      });
      const preAddonDigest = await hashArtifact({
        absolutePath: prePackageAddonPath,
        identity: normalizePathForReport(repoRoot, prePackageAddonPath)
      });
      emit(options, 'inspect-pre-package-core');
      const preCoreElf = await inspectElfWithContract({
        manifest,
        artifactKey: 'prePackageCore',
        libPath: prePackageCorePath,
        component: 'mihomoCore',
        inspectNativeLibraryImpl: options.inspectNativeLibraryImpl ?? inspectNativeLibrary
      });
      emit(options, 'inspect-pre-package-addon');
      const preAddonElf = await inspectElfWithContract({
        manifest,
        artifactKey: 'prePackageAddon',
        libPath: prePackageAddonPath,
        component: 'nodeAddon',
        inspectNativeLibraryImpl: options.inspectNativeLibraryImpl ?? inspectNativeLibrary
      });
      if (preCoreElf) {
        manifest.artifacts.prePackageCore = {
          ...preCoreDigest,
          elf: preCoreElf
        };
      }
      if (preAddonElf) {
        manifest.artifacts.prePackageAddon = {
          ...preAddonDigest,
          elf: preAddonElf
        };
      }

      if (
        manifest.artifacts.rawCore &&
        manifest.artifacts.prePackageCore &&
        (manifest.artifacts.rawCore.sha256 !== manifest.artifacts.prePackageCore.sha256 ||
          manifest.artifacts.rawCore.sizeBytes !== manifest.artifacts.prePackageCore.sizeBytes)
      ) {
        pushFailure(manifest, createFailure('PRE_PACKAGE_CORE_MISMATCH', 'Pre-package core must byte-match the raw core artifact.', 'stage-pre-package-core'));
      }
    }

    if (!manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code))) {
      emit(options, 'package-hap');
      const buildReport = await (options.buildHapImpl ?? buildHap)({
        harmonyRoot,
        env: phase2SelfTestEnv,
        phase2SelfTestEnabled: Boolean(options.phase2SelfTestEnabled)
      });
      const normalizedBuildReport = validateBuildHapReport(buildReport);
      if (!normalizedBuildReport.valid) {
        manifest.signing.result = normalizedBuildReport.signingResult;
        for (const failure of normalizedBuildReport.failures) {
          pushFailure(manifest, createFailure(failure.code, failure.detail, failure.stage ?? 'signing'));
        }
        pushFailure(
          manifest,
          createFailure(
            'PACKAGE_HAP_REPORT_INVALID',
            `buildHap returned a malformed report: ${normalizedBuildReport.errors.join('; ')}`,
            'package-hap'
          )
        );
      } else {
        if (normalizedBuildReport.phase2SelfTest.enabled !== Boolean(options.phase2SelfTestEnabled)) {
          pushFailure(
            manifest,
            createFailure(
              'PACKAGE_HAP_REPORT_INVALID',
              `buildHap reported phase2SelfTest.enabled=${normalizedBuildReport.phase2SelfTest.enabled} but the requested lane was ${Boolean(options.phase2SelfTestEnabled)}.`,
              'package-hap'
            )
          );
        }
        updateSigningState(manifest, buildReport);
        mergeBuildHapFailures(manifest, buildReport);
        manifest.phase2SelfTest = normalizedBuildReport.phase2SelfTest;
      }

      const hapCommandFailed = Number.isInteger(normalizedBuildReport.exitCode) && normalizedBuildReport.exitCode !== 0;
      const hapStepFailed = !normalizedBuildReport.valid || normalizedBuildReport.result === 'fail' || hapCommandFailed;
      const hapStepPassed = !hapStepFailed && Boolean(normalizedBuildReport.hapPath);
      const persistedHapCommand = normalizedBuildReport.valid ? normalizedBuildReport.command : null;
      const persistedHapExitCode = normalizedBuildReport.valid
        ? (hapStepPassed ? (normalizedBuildReport.exitCode ?? 0) : (normalizedBuildReport.exitCode === 0 ? null : normalizedBuildReport.exitCode))
        : null;
      manifest.builds.hap = createBuildStep(
        hapStepFailed ? 'fail' : (hapStepPassed ? 'pass' : 'fail'),
        persistedHapCommand,
        persistedHapExitCode,
        normalizedBuildReport.stdout,
        normalizedBuildReport.stderr
      );

      await ensureDurablePrePackageCore({
        manifest,
        repoRoot,
        rawCorePath,
        prePackageCorePath,
        inspectNativeLibraryImpl: options.inspectNativeLibraryImpl ?? inspectNativeLibrary,
        fsApi
      });

      let selectedHapPath = null;
      let selectedHapPathRejected = false;
      if (normalizedBuildReport.valid) {
        try {
          selectedHapPath = await resolveSelectedHapPath(repoRoot, buildReport, fsApi);
        } catch (error) {
          selectedHapPathRejected = true;
          pushFailure(manifest, createFailure(error?.code ?? 'PATH_OUTSIDE_REPO', error?.message ?? 'Selected hap path escaped the repository.', 'package-hap'));
        }
      }

      if (!normalizedBuildReport.valid) {
        // malformed reports stop before path/hash/archive evaluation
      } else if (buildReport?.result === 'fail' || (buildReport?.result === 'incomplete' && !shouldContinueArchive(buildReport))) {
        pushFailure(manifest, createFailure('PACKAGE_HAP_FAILED', 'Phase1 packaging did not finish in an archive-verifiable state.', 'package-hap'));
      } else if (!selectedHapPath && !selectedHapPathRejected) {
        pushFailure(manifest, createFailure('HAP_NOT_FOUND', 'Phase1 packaging did not produce a deterministic HAP path.', 'package-hap'));
      } else if (selectedHapPath) {
        let hapSnapshot = null;
        try {
          hapSnapshot = await createSelectedHapSnapshot({
            repoRoot,
            absolutePath: selectedHapPath,
            runId,
            fsApi
          });
          emit(options, 'hash-hap');
          manifest.artifacts.hap = await hashArtifact({
            absolutePath: hapSnapshot.snapshotPath,
            identity: normalizePathForReport(repoRoot, selectedHapPath),
            elf: null
          });

          const archive = await (options.inspectHapNativeEntriesImpl ?? inspectHapNativeEntries)({
            hapPath: hapSnapshot.snapshotPath,
            runId
          }, {
            captureInspectErrors: true,
            inspectNativeLibraryImpl: options.inspectNativeLibraryImpl ?? inspectNativeLibrary,
            onEvent(eventName) {
              emit(options, eventName);
            }
          });

          const normalizedArchiveReport = validateArchiveInspectionReport(archive);
          if (!normalizedArchiveReport.valid) {
            pushFailure(
              manifest,
              createFailure(
                'HAP_ARCHIVE_REPORT_INVALID',
                `inspectHapNativeEntries returned a malformed report: ${normalizedArchiveReport.errors.join('; ')}`,
                'archive'
              )
            );
          } else {
            manifest.archive.entryCount = normalizedArchiveReport.normalized.entryCount;
            manifest.archive.occurrences = normalizeArchiveOccurrences(normalizedArchiveReport.normalized.occurrences);

            for (const failure of normalizedArchiveReport.normalized.failures) {
              pushFailure(manifest, createFailure(failure.code, failure.detail, failure.stage ?? 'archive'));
            }

            if (normalizedArchiveReport.normalized.artifacts.core) {
              acceptElfArtifact(manifest, 'hapCore', normalizedArchiveReport.normalized.artifacts.core);
            }
            if (normalizedArchiveReport.normalized.artifacts.addon) {
              acceptElfArtifact(manifest, 'hapAddon', normalizedArchiveReport.normalized.artifacts.addon);
            }
          }

          if (
            manifest.artifacts.rawCore &&
            manifest.artifacts.hapCore &&
            (manifest.artifacts.rawCore.sha256 !== manifest.artifacts.hapCore.sha256 ||
              manifest.artifacts.rawCore.sizeBytes !== manifest.artifacts.hapCore.sizeBytes)
          ) {
            pushFailure(manifest, createFailure('PROVENANCE_HASH_MISMATCH', 'HAP core must byte-match the raw core artifact.', 'archive'));
          }

          if (
            manifest.artifacts.prePackageAddon &&
            manifest.artifacts.hapAddon &&
            (manifest.artifacts.prePackageAddon.sha256 !== manifest.artifacts.hapAddon.sha256 ||
              manifest.artifacts.prePackageAddon.sizeBytes !== manifest.artifacts.hapAddon.sizeBytes)
          ) {
            pushFailure(manifest, createFailure('PROVENANCE_HASH_MISMATCH', 'HAP addon must byte-match the pre-package addon artifact.', 'archive'));
          }
        } catch (error) {
          pushFailure(manifest, createFailure(error?.code ?? 'HAP_ARCHIVE_INSPECTION_FAILED', error?.message ?? 'Failed to inspect HAP native entries.', 'archive'));
        } finally {
          await hapSnapshot?.cleanup();
        }
      }
    }

    if (
      manifest.builds.core.result !== 'fail' &&
      manifest.builds.addonConfigure.result !== 'fail' &&
      manifest.builds.addon.result !== 'fail' &&
      manifest.builds.hap.result !== 'fail' &&
      !manifest.failures.some((entry) => !classifyNativeFailureCode(entry.code) && entry.stage !== 'signing')
    ) {
      emit(options, 'discover-device');
      const targetResult = await runCommandImpl({
        command: hdcPath,
        args: ['list', 'targets'],
        cwd: harmonyRoot,
        env
      });
      const analysis = analyzeTargetDiscovery({
        stdout: targetResult.stdout ?? '',
        stderr: targetResult.stderr ?? '',
        exitCode: targetResult.exitCode
      });

      manifest.device.targetCount = analysis.targets.length;
      if (analysis.kind === 'selected') {
        const masked = createMaskedDeviceIdentity(analysis.targets[0]);
        serialToMask = new Map([[analysis.targets[0], masked]]);
        manifest.device.identityMasked = masked;
        manifest.device.result = 'pass';
      } else if (analysis.kind === 'ambiguous') {
        manifest.device.result = 'incomplete';
        pushFailure(manifest, createFailure('DEVICE_TARGET_AMBIGUOUS', 'Exactly one HarmonyOS arm64 target is required for the phase1 discovery lane.', 'device'));
      } else {
        manifest.device.result = 'incomplete';
        pushFailure(manifest, createFailure('DEVICE_TARGET_MISSING', 'No HarmonyOS arm64 target was available during the phase1 discovery lane.', 'device'));
      }
    }
  } catch (error) {
    if (error?.code === 'STOP_AFTER_TOOLCHAIN_LOCK') {
      // The lock failure was already recorded as honest evidence.
    } else {
      pushFailure(manifest, createFailure(error?.code ?? 'PHASE1_NATIVE_FATAL', error?.message ?? 'Unknown phase1 native failure.', 'phase1'));
    }
  } finally {
    const completedAt = getNow();
    manifest.timestamps.completedAt = isoTimestamp(completedAt);
    const derived = derivePhase1Result(manifest);
    manifest.nativeBuildResult = derived.nativeBuildResult;
    manifest.result = derived.result;

    const finalReplacements = createRedactionReplacements({ repoRoot, env });
    for (const [serial, masked] of serialToMask.entries()) {
      finalReplacements.set(serial, masked);
    }

    let sanitizedManifest = sanitizeForPersistenceWithSigning(manifest, finalReplacements);
    const validation = validatePhase1NativeManifest(sanitizedManifest);
    if (!validation.valid) {
      sanitizedManifest = {
        ...sanitizedManifest,
        nativeBuildResult: 'fail',
        result: 'fail',
        failures: [
          ...sanitizedManifest.failures,
          ...validation.errors.map((error) => createFailure('PHASE1_MANIFEST_INVALID', error, 'persist'))
        ]
      };
    }

    emit(options, 'persist');
    persisted = await writeManifest(sanitizedManifest, outputPath, {
      fsApi,
      replacements: finalReplacements
    });
  }

  return persisted;
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let outputPath = DEFAULT_OUTPUT_PATH;
  let validatePath = null;
  let phase2SelfTestEnabled = false;
  const seen = new Set();

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--validate') {
      if (seen.has('--validate')) {
        throw Object.assign(new Error('--validate may only be provided once.'), { code: 'ARGUMENT_INVALID' });
      }
      if (seen.has('--out')) {
        throw Object.assign(new Error('--validate cannot be combined with --out.'), { code: 'ARGUMENT_INVALID' });
      }
      if (phase2SelfTestEnabled) {
        throw Object.assign(new Error('--validate cannot be combined with --phase2-self-test.'), { code: 'ARGUMENT_INVALID' });
      }
      const next = argv[index + 1];
      if (!next) {
        throw Object.assign(new Error('--validate requires a manifest path.'), { code: 'ARGUMENT_INVALID' });
      }
      const resolved = path.isAbsolute(next) ? next : path.resolve(repoRoot, next);
      const relative = path.relative(repoRoot, resolved);
      if (relative.startsWith('..') || path.isAbsolute(relative)) {
        throw Object.assign(new Error('--validate must point at a manifest inside the repository root.'), { code: 'PATH_OUTSIDE_REPO' });
      }
      seen.add('--validate');
      validatePath = resolved;
      index += 1;
      continue;
    }

    if (arg === '--out') {
      if (validatePath) {
        throw Object.assign(new Error('--out cannot be combined with --validate.'), { code: 'ARGUMENT_INVALID' });
      }
      if (seen.has('--out')) {
        throw Object.assign(new Error('--out may only be provided once.'), { code: 'ARGUMENT_INVALID' });
      }
      const next = argv[index + 1];
      if (!next) {
        throw Object.assign(new Error('--out requires a value.'), { code: 'ARGUMENT_INVALID' });
      }
      const resolved = path.isAbsolute(next) ? next : path.resolve(repoRoot, next);
      const relative = path.relative(repoRoot, resolved);
      if (relative.startsWith('..') || path.isAbsolute(relative)) {
        throw Object.assign(new Error('--out must stay inside the repository root.'), { code: 'PATH_OUTSIDE_REPO' });
      }
      seen.add('--out');
      outputPath = resolved;
      index += 1;
      continue;
    }

    if (arg === '--phase2-self-test') {
      if (validatePath) {
        throw Object.assign(new Error('--phase2-self-test cannot be combined with --validate.'), { code: 'ARGUMENT_INVALID' });
      }
      if (phase2SelfTestEnabled) {
        throw Object.assign(new Error('--phase2-self-test may only be provided once.'), { code: 'ARGUMENT_INVALID' });
      }
      phase2SelfTestEnabled = true;
      continue;
    }

    throw Object.assign(new Error(`Unknown argument: ${arg}`), { code: 'ARGUMENT_INVALID' });
  }

  return {
    outputPath,
    validatePath,
    phase2SelfTestEnabled
  };
}

export async function runCli({
  argv = process.argv.slice(2),
  stdout = process.stdout,
  buildPhase1NativeImpl = buildPhase1Native,
  verifyManifestImpl
} = {}) {
  const parsed = parseCliArguments(argv, REPO_ROOT);

  if (parsed.validatePath) {
    const manifest = verifyManifestImpl
      ? null
      : await readJsonFile(fs, parsed.validatePath);
    const verification = verifyManifestImpl
      ? await verifyManifestImpl({
        manifestPath: parsed.validatePath
      })
      : {
        manifest,
        ...await verifyPhase1NativeManifest(manifest, {
          repoRoot: REPO_ROOT,
          verifyToolchainLock: true
        })
      };

    stdout.write(`${JSON.stringify(verification.manifest ?? manifest, null, 2)}\n`);
    return verification.valid ? 0 : 2;
  }

  const manifest = await buildPhase1NativeImpl({
    outputPath: parsed.outputPath,
    phase2SelfTestEnabled: parsed.phase2SelfTestEnabled
  });
  stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
  if (manifest.result === 'pass') {
    return 0;
  }
  if (manifest.result === 'incomplete') {
    return 1;
  }
  return 2;
}

function isDirectExecution() {
  if (!process.argv[1]) {
    return false;
  }

  return pathToFileURL(process.argv[1]).href === import.meta.url;
}

if (isDirectExecution()) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  }).catch((error) => {
    process.stderr.write(`${error?.stack ?? error?.message ?? String(error)}\n`);
    process.exitCode = 2;
  });
}
