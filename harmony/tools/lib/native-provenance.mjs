import { execFile as execFileCallback, spawn as spawnChild } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsPromises from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { inspectNativeLibrary } from '../../tests/bin/inspect-native-lib.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const SIGNING_TOKEN_PATTERN = /(^|[\s"'(=\[])([^\s"'<>]*\.(?:p12|cer|p7b|pem|pfx))(?=$|[\s"'<>)}\]])/giu;
const CORE_EXPORTS = [
  'cmfa_mihomo_core_build_info_json_cstr_v1',
  'cmfa_mihomo_core_version_cstr_v1',
  'cmfa_mihomo_runtime_state_v1',
  'cmfa_mihomo_start_local_v1',
  'cmfa_mihomo_stop_v1'
];
const NODE_ADDON_ALLOWED_NEEDED = ['libace_napi.z.so', 'libc.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so'];
const CORE_ALLOWED_NEEDED = ['libc.so'];
const TOOLCHAIN_LOCK_IDENTITY = 'harmony/toolchain.lock.json';
const EXTRACTION_RUN_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/u;
const ALLOWED_TOP_LEVEL_KEYS = Object.freeze([
  'schemaVersion',
  'phase',
  'runId',
  'result',
  'nativeBuildResult',
  'timestamps',
  'toolchainLock',
  'builds',
  'artifacts',
  'archive',
  'signing',
  'device',
  'failures'
]);
const ALLOWED_BUILD_STEP_KEYS = Object.freeze(['result', 'command', 'exitCode', 'stdout', 'stderr']);
const ALLOWED_ARTIFACT_KEYS = Object.freeze(['identity', 'sha256', 'sizeBytes', 'elf']);
const ALLOWED_ELF_KEYS = Object.freeze([
  'result',
  'component',
  'architecture',
  'neededLibraries',
  'allowedNeededLibraries',
  'exportedSymbols',
  'requiredExports',
  'failures'
]);
const ALLOWED_TOOLCHAIN_LOCK_KEYS = Object.freeze(['path', 'sha256']);
const ALLOWED_ARCHIVE_KEYS = Object.freeze(['entryCount', 'occurrences']);
const ALLOWED_OCCURRENCES_KEYS = Object.freeze(['core', 'addon']);
const ALLOWED_SIGNING_KEYS = Object.freeze(['result']);
const ALLOWED_DEVICE_KEYS = Object.freeze(['result', 'targetCount', 'identityMasked', 'proofResult']);
const ALLOWED_FAILURE_KEYS = Object.freeze(['code', 'detail', 'stage']);

export const PHASE1_NATIVE_SCHEMA_VERSION = '1.0.0';
export const PHASE1_NATIVE_PHASE = 1;
export const HAP_NATIVE_ENTRIES = Object.freeze({
  addon: 'libs/arm64-v8a/libentry.so',
  core: 'libs/arm64-v8a/libcmfa_mihomo.so'
});
const EXPECTED_ARTIFACT_IDENTITIES = Object.freeze({
  rawCore: 'harmony/artifacts/libcmfa_mihomo.so',
  prePackageCore: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so',
  prePackageAddon: 'harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so',
  hapCore: HAP_NATIVE_ENTRIES.core,
  hapAddon: HAP_NATIVE_ENTRIES.addon
});

function sanitizeSigningTokens(raw) {
  return String(raw ?? '').replace(SIGNING_TOKEN_PATTERN, (_, prefix) => `${prefix}<signing-material>`);
}

function createFailure(code, detail, stage) {
  return {
    code,
    detail: sanitizeSigningTokens(detail),
    stage
  };
}

function pushError(errors, message) {
  if (!errors.includes(message)) {
    errors.push(message);
  }
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(String(value ?? ''));
}

function isLowerHexDigest(value) {
  return /^[a-f0-9]{64}$/u.test(String(value ?? ''));
}

function isCanonicalRepoIdentity(identity) {
  if (typeof identity !== 'string' || !identity.length) {
    return false;
  }

  if (path.posix.isAbsolute(identity)) {
    return false;
  }

  const normalized = path.posix.normalize(identity);
  if (normalized !== identity) {
    return false;
  }

  return !normalized.startsWith('../') && normalized !== '..';
}

function isCanonicalArchiveIdentity(identity) {
  if (typeof identity !== 'string' || !identity.length) {
    return false;
  }

  if (identity !== path.posix.normalize(identity)) {
    return false;
  }

  return !identity.startsWith('/') && !identity.startsWith('../') && !identity.includes('/../');
}

function inferArtifactKind(identity) {
  if (identity === HAP_NATIVE_ENTRIES.core) {
    return 'hapCore';
  }
  if (identity === HAP_NATIVE_ENTRIES.addon) {
    return 'hapAddon';
  }
  if (identity.endsWith('.hap')) {
    return 'hap';
  }
  if (identity.endsWith('/libentry.so')) {
    return 'prePackageAddon';
  }
  if (identity.endsWith('/libcmfa_mihomo.so')) {
    return identity.includes('/artifacts/') ? 'rawCore' : 'prePackageCore';
  }
  return 'unknown';
}

function sameDigest(left, right) {
  return Boolean(left && right && left.sha256 === right.sha256 && left.sizeBytes === right.sizeBytes);
}

function isBlockerFailureCode(code) {
  return code === 'SIGNING_REQUIRED' || code === 'DEVICE_TARGET_MISSING' || code === 'DEVICE_TARGET_AMBIGUOUS';
}

function allBuildsNotRun(builds = {}) {
  return Object.values(builds).every((step) => step?.result === 'not-run');
}

function deriveResultsFromManifest(manifest) {
  const buildSteps = Object.values(manifest?.builds ?? {});
  const stepFailed = buildSteps.some((step) => step?.result === 'fail');
  const failureCodes = new Set((manifest?.failures ?? []).map((entry) => entry.code));
  const nativeFailure = stepFailed || [...failureCodes].some((code) => !isBlockerFailureCode(code));
  const blockerOnly = !nativeFailure && (
    manifest?.signing?.result === 'incomplete' ||
    manifest?.device?.result === 'incomplete' ||
    [...failureCodes].some((code) => isBlockerFailureCode(code))
  );

  return {
    nativeBuildResult: nativeFailure ? 'fail' : 'pass',
    result: nativeFailure ? 'fail' : (blockerOnly ? 'incomplete' : 'pass')
  };
}

function resolveRepoIdentityPath(repoRoot, identity) {
  if (!isCanonicalRepoIdentity(identity)) {
    const error = new Error(`Artifact identity escapes the repository: ${identity}`);
    error.code = 'IDENTITY_PATH_OUTSIDE_REPO';
    throw error;
  }

  const absolutePath = path.resolve(repoRoot, identity);
  const normalizedRoot = path.resolve(repoRoot);
  if (absolutePath === normalizedRoot || !absolutePath.startsWith(`${normalizedRoot}${path.sep}`)) {
    const error = new Error(`Artifact identity escapes the repository: ${identity}`);
    error.code = 'IDENTITY_PATH_OUTSIDE_REPO';
    throw error;
  }

  return absolutePath;
}

export async function resolveLiveRepoPath(repoRoot, candidatePath, options = {}) {
  const fsApi = options.fsApi ?? fsPromises;
  const displayPath = options.displayPath ?? path.basename(candidatePath);
  const normalizedRoot = path.resolve(repoRoot);
  const absoluteCandidatePath = path.resolve(candidatePath);
  if (absoluteCandidatePath === normalizedRoot || !absoluteCandidatePath.startsWith(`${normalizedRoot}${path.sep}`)) {
    const error = new Error(`Artifact path escapes the repository: ${displayPath}`);
    error.code = 'IDENTITY_PATH_OUTSIDE_REPO';
    throw error;
  }

  const stats = await fsApi.lstat(absoluteCandidatePath);
  if (stats.isSymbolicLink()) {
    const error = new Error(`Artifact path must not resolve through a symbolic link: ${displayPath}`);
    error.code = 'IDENTITY_PATH_SYMLINK';
    throw error;
  }

  const [realRepoRoot, realCandidatePath] = await Promise.all([
    fsApi.realpath(normalizedRoot),
    fsApi.realpath(absoluteCandidatePath)
  ]);
  if (realCandidatePath === realRepoRoot || !realCandidatePath.startsWith(`${realRepoRoot}${path.sep}`)) {
    const error = new Error(`Artifact path escapes the repository: ${displayPath}`);
    error.code = 'IDENTITY_PATH_OUTSIDE_REPO';
    throw error;
  }

  return {
    absolutePath: absoluteCandidatePath,
    realPath: realCandidatePath,
    realRepoRoot
  };
}

export async function resolveLiveRepoIdentityPath(repoRoot, identity, options = {}) {
  return await resolveLiveRepoPath(repoRoot, resolveRepoIdentityPath(repoRoot, identity), {
    ...options,
    displayPath: identity
  });
}

function expectedLiveElfComponent(artifactKey) {
  if (artifactKey === 'rawCore' || artifactKey === 'prePackageCore') {
    return 'mihomoCore';
  }
  if (artifactKey === 'prePackageAddon') {
    return 'nodeAddon';
  }
  return null;
}

function normalizedElfReportsMatch(left, right, expectedComponent) {
  return JSON.stringify(normalizeElfReport(left, expectedComponent)) === JSON.stringify(normalizeElfReport(right, expectedComponent));
}

function normalizeFailureArray(failures) {
  return Array.isArray(failures) ? failures : [];
}

function validateExactKeys(value, allowedKeys, requiredKeys, prefix, errors) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    pushError(errors, `${prefix} must be an object.`);
    return false;
  }

  const unknownKeys = Object.keys(value).filter((key) => !allowedKeys.includes(key));
  if (unknownKeys.length > 0) {
    pushError(errors, `${prefix} contains unknown fields: ${unknownKeys.join(', ')}.`);
  }

  for (const key of requiredKeys) {
    if (!Object.hasOwn(value, key)) {
      pushError(errors, `${prefix}.${key} is required.`);
    }
  }

  return true;
}

function validateStringArray(value, prefix, errors) {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === 'string')) {
    pushError(errors, `${prefix} must be an array of strings.`);
    return false;
  }
  return true;
}

function validateFailureList(failures, prefix, errors) {
  if (!Array.isArray(failures)) {
    pushError(errors, `${prefix} must be an array.`);
    return;
  }

  for (const [index, failure] of failures.entries()) {
    const itemPrefix = `${prefix}[${index}]`;
    if (!validateExactKeys(failure, ALLOWED_FAILURE_KEYS, ALLOWED_FAILURE_KEYS, itemPrefix, errors)) {
      continue;
    }
    if (typeof failure.code !== 'string' || !failure.code.length) {
      pushError(errors, `${itemPrefix}.code must be a non-empty string.`);
    }
    if (typeof failure.detail !== 'string') {
      pushError(errors, `${itemPrefix}.detail must be a string.`);
    }
    if (typeof failure.stage !== 'string' || !failure.stage.length) {
      pushError(errors, `${itemPrefix}.stage must be a non-empty string.`);
    }
  }
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((entry) => typeof entry === 'string');
}

export function collectArtifactElfContractErrors(elf, artifactKind) {
  const errors = [];

  if (!elf || typeof elf !== 'object' || Array.isArray(elf)) {
    errors.push('elf must be an object');
    return errors;
  }

  if (elf.result !== 'pass') {
    errors.push('result must be pass');
  }
  if (elf.architecture !== 'AArch64') {
    errors.push('architecture must be AArch64');
  }

  for (const [key, value] of [
    ['neededLibraries', elf.neededLibraries],
    ['allowedNeededLibraries', elf.allowedNeededLibraries],
    ['exportedSymbols', elf.exportedSymbols],
    ['requiredExports', elf.requiredExports]
  ]) {
    if (!isStringArray(value)) {
      errors.push(`${key} must be an array of strings`);
    }
  }

  if (!Array.isArray(elf.failures)) {
    errors.push('failures must be an array');
  } else if (elf.failures.length !== 0) {
    errors.push('failures must be empty for pass reports');
  }

  if (artifactKind === 'rawCore' || artifactKind === 'prePackageCore' || artifactKind === 'hapCore') {
    if (elf.component !== 'mihomoCore') {
      errors.push('component must be mihomoCore');
    }
    if (JSON.stringify(elf.neededLibraries) !== JSON.stringify(CORE_ALLOWED_NEEDED)) {
      errors.push('neededLibraries must match the core dependency contract');
    }
    if (JSON.stringify(elf.allowedNeededLibraries) !== JSON.stringify(CORE_ALLOWED_NEEDED)) {
      errors.push('allowedNeededLibraries must match the core dependency contract');
    }
    if (JSON.stringify(elf.requiredExports) !== JSON.stringify(CORE_EXPORTS)) {
      errors.push('requiredExports must match the core export contract');
    }
    if (!Array.isArray(elf.exportedSymbols) || CORE_EXPORTS.some((symbol) => !elf.exportedSymbols.includes(symbol))) {
      errors.push(`exportedSymbols must include ${CORE_EXPORTS.join(', ')}`);
    }
    if (Array.isArray(elf.exportedSymbols) && elf.exportedSymbols.some((symbol) => symbol.startsWith('cmfa_') && !CORE_EXPORTS.includes(symbol))) {
      errors.push('exportedSymbols must not expose extra cmfa_* symbols');
    }
  }

  if (artifactKind === 'prePackageAddon' || artifactKind === 'hapAddon') {
    if (elf.component !== 'nodeAddon') {
      errors.push('component must be nodeAddon');
    }
    if (JSON.stringify(elf.neededLibraries) !== JSON.stringify(NODE_ADDON_ALLOWED_NEEDED)) {
      errors.push('neededLibraries must match the addon dependency contract');
    }
    if (JSON.stringify(elf.allowedNeededLibraries) !== JSON.stringify(NODE_ADDON_ALLOWED_NEEDED)) {
      errors.push('allowedNeededLibraries must match the addon dependency contract');
    }
    if (JSON.stringify(elf.requiredExports) !== JSON.stringify([])) {
      errors.push('requiredExports must stay empty for the addon contract');
    }
    const exported = Array.isArray(elf.exportedSymbols) ? [...elf.exportedSymbols].sort() : null;
    if (JSON.stringify(exported) !== JSON.stringify(['_fini', '_init'])) {
      errors.push('exportedSymbols must only contain _init and _fini');
    }
  }

  return errors;
}

function validateElfReport(elf, artifactKind, prefix, errors) {
  if (!validateExactKeys(elf, ALLOWED_ELF_KEYS, ALLOWED_ELF_KEYS, prefix, errors)) {
    return;
  }
  validateStringArray(elf.neededLibraries, `${prefix}.neededLibraries`, errors);
  validateStringArray(elf.allowedNeededLibraries, `${prefix}.allowedNeededLibraries`, errors);
  validateStringArray(elf.exportedSymbols, `${prefix}.exportedSymbols`, errors);
  validateStringArray(elf.requiredExports, `${prefix}.requiredExports`, errors);
  validateFailureList(elf.failures, `${prefix}.failures`, errors);

  for (const message of collectArtifactElfContractErrors(elf, artifactKind)) {
    pushError(errors, `${prefix}.${message}.`);
  }
}

function validateArtifact(artifact, key, errors) {
  const prefix = `artifacts.${key}`;
  if (artifact === null) {
    return;
  }

  if (!validateExactKeys(artifact, ALLOWED_ARTIFACT_KEYS, ALLOWED_ARTIFACT_KEYS, prefix, errors)) {
    return;
  }

  if (typeof artifact.identity !== 'string' || !artifact.identity.length) {
    pushError(errors, `${prefix}.identity must be a non-empty string.`);
  }
  if (!isLowerHexDigest(artifact.sha256)) {
    pushError(errors, `${prefix}.sha256 must be a lowercase SHA-256 digest.`);
  }
  if (!Number.isInteger(artifact.sizeBytes) || artifact.sizeBytes < 0) {
    pushError(errors, `${prefix}.sizeBytes must be a non-negative integer.`);
  }

  const artifactKind = inferArtifactKind(artifact.identity);
  if (EXPECTED_ARTIFACT_IDENTITIES[key] && artifact.identity !== EXPECTED_ARTIFACT_IDENTITIES[key]) {
    pushError(errors, `${prefix}.identity must exactly equal ${EXPECTED_ARTIFACT_IDENTITIES[key]}.`);
  }
  if (key === 'hap' && !/^harmony\/entry\/build\/default\/outputs\/default\/[^/]+\.hap$/u.test(artifact.identity)) {
    pushError(errors, `${prefix}.identity must be the canonical outputs/default HAP path.`);
  }
  if (key === 'rawCore' || key === 'prePackageCore' || key === 'prePackageAddon' || key === 'hap') {
    if (!isCanonicalRepoIdentity(artifact.identity)) {
      pushError(errors, `${prefix}.identity must be a canonical repo-relative path and must not escape the repository.`);
    }
  } else if (!isCanonicalArchiveIdentity(artifact.identity)) {
    pushError(errors, `${prefix}.identity must be a canonical archive entry path.`);
  }

  if (artifactKind === 'unknown') {
    pushError(errors, `${prefix}.identity does not map to a known artifact slot.`);
  }

  if (key === 'hap') {
    if (artifact.elf !== null) {
      pushError(errors, `${prefix}.elf must be null for the HAP archive artifact.`);
    }
    return;
  }

  if (!artifact.elf || typeof artifact.elf !== 'object' || Array.isArray(artifact.elf)) {
    pushError(errors, `${prefix}.elf must be an object.`);
    return;
  }

  validateElfReport(artifact.elf, key, `${prefix}.elf`, errors);
}

function validateBuildStep(step, key, errors, manifest) {
  const prefix = `builds.${key}`;
  if (!validateExactKeys(step, ALLOWED_BUILD_STEP_KEYS, ALLOWED_BUILD_STEP_KEYS, prefix, errors)) {
    return;
  }

  if (!['pass', 'fail', 'not-run'].includes(step.result)) {
    pushError(errors, `${prefix}.result must be pass, fail, or not-run.`);
  }
  if (step.command !== null) {
    validateStringArray(step.command, `${prefix}.command`, errors);
  }
  if (step.exitCode !== null && !Number.isInteger(step.exitCode)) {
    pushError(errors, `${prefix}.exitCode must be an integer or null.`);
  }
  if (typeof step.stdout !== 'string' || typeof step.stderr !== 'string') {
    pushError(errors, `${prefix}.stdout and ${prefix}.stderr must be strings.`);
  }

  if (step.result === 'not-run') {
    if (step.command !== null || step.exitCode !== null || step.stdout !== '' || step.stderr !== '') {
      pushError(errors, `${prefix} BuildStep must keep command/exitCode/stdout/stderr empty when result is not-run.`);
    }
  }

  if (step.result === 'pass' && step.exitCode !== 0) {
    pushError(errors, `${prefix} BuildStep exitCode must be 0 when result is pass.`);
  }

  if (step.result === 'fail' && step.exitCode === 0) {
    pushError(errors, `${prefix} BuildStep exitCode must be non-zero or null when result is fail.`);
  }

  if (step.result === 'fail') {
    const stageMap = {
      core: 'build-core',
      addonConfigure: 'prepare-addon',
      addon: 'build-addon',
      hap: 'package-hap'
    };
    const matchingFailure = normalizeFailureArray(manifest.failures).some((failure) => failure.stage === stageMap[key] || failure.stage === 'phase1');
    if (!matchingFailure) {
      pushError(errors, `${prefix} must have a matching failure entry when result is fail.`);
    }
  }
}

function validateBlockerConsistency(manifest, errors) {
  const failureCodes = new Set(normalizeFailureArray(manifest.failures).map((entry) => entry.code));
  const derived = deriveResultsFromManifest(manifest);
  if (manifest.nativeBuildResult !== derived.nativeBuildResult) {
    pushError(errors, `nativeBuildResult ${derived.nativeBuildResult} is required for the current failure set.`);
  }
  if (manifest.result !== derived.result) {
    pushError(errors, `result ${derived.result} is required for the current failure set.`);
  }

  if (manifest.signing.result === 'incomplete' && !failureCodes.has('SIGNING_REQUIRED')) {
    pushError(errors, 'signing.result incomplete requires a SIGNING_REQUIRED failure.');
  }
  if (manifest.signing.result === 'pass' && failureCodes.has('SIGNING_REQUIRED')) {
    pushError(errors, 'signing.result pass cannot coexist with SIGNING_REQUIRED.');
  }

  if (manifest.device.result === 'pass') {
    if (manifest.device.targetCount !== 1 || !/^target-[0-9a-f]{8}$/u.test(String(manifest.device.identityMasked ?? ''))) {
      pushError(errors, 'device.result pass requires targetCount 1 and a masked identity.');
    }
  }
  if (manifest.device.result === 'incomplete') {
    const missing = failureCodes.has('DEVICE_TARGET_MISSING');
    const ambiguous = failureCodes.has('DEVICE_TARGET_AMBIGUOUS');
    if (missing && !(manifest.device.targetCount === 0 && manifest.device.identityMasked === null)) {
      pushError(errors, 'device incomplete for DEVICE_TARGET_MISSING requires targetCount 0 and identityMasked null.');
    }
    if (ambiguous && !(Number.isInteger(manifest.device.targetCount) && manifest.device.targetCount > 1 && manifest.device.identityMasked === null)) {
      pushError(errors, 'device incomplete for DEVICE_TARGET_AMBIGUOUS requires targetCount >1 and identityMasked null.');
    }
    if (!missing && !ambiguous) {
      pushError(errors, 'device.result incomplete requires DEVICE_TARGET_MISSING or DEVICE_TARGET_AMBIGUOUS.');
    }
  }
  if (manifest.device.result === 'not-run') {
    if (manifest.device.targetCount !== null || manifest.device.identityMasked !== null) {
      pushError(errors, 'device.result not-run requires targetCount and identityMasked to stay null.');
    }
  }
}

function validateArchive(manifest, errors) {
  const archive = manifest.archive;
  if (!validateExactKeys(archive, ALLOWED_ARCHIVE_KEYS, ALLOWED_ARCHIVE_KEYS, 'archive', errors)) {
    return;
  }
  if (!validateExactKeys(archive.occurrences, ALLOWED_OCCURRENCES_KEYS, ALLOWED_OCCURRENCES_KEYS, 'archive.occurrences', errors)) {
    return;
  }

  const allNotRun = allBuildsNotRun(manifest.builds);
  const entryCountIsValid = archive.entryCount === null || (Number.isInteger(archive.entryCount) && archive.entryCount >= 0);
  const coreCountIsValid = archive.occurrences.core === null || (Number.isInteger(archive.occurrences.core) && archive.occurrences.core >= 0);
  const addonCountIsValid = archive.occurrences.addon === null || (Number.isInteger(archive.occurrences.addon) && archive.occurrences.addon >= 0);

  if (!entryCountIsValid || !coreCountIsValid || !addonCountIsValid) {
    pushError(errors, 'archive entryCount and occurrence counts must be null-before-run or non-negative integers.');
  }

  if (allNotRun) {
    if (archive.entryCount !== null || archive.occurrences.core !== null || archive.occurrences.addon !== null) {
      pushError(errors, 'archive counts must stay null before HAP archive inspection runs.');
    }
  }
}

function validateToolchainLock(manifest, errors) {
  if (!validateExactKeys(manifest.toolchainLock, ALLOWED_TOOLCHAIN_LOCK_KEYS, ALLOWED_TOOLCHAIN_LOCK_KEYS, 'toolchainLock', errors)) {
    return;
  }
  if (manifest.toolchainLock.path !== TOOLCHAIN_LOCK_IDENTITY) {
    pushError(errors, `toolchainLock.path must exactly equal ${TOOLCHAIN_LOCK_IDENTITY}.`);
  }

  if (manifest.toolchainLock.sha256 === null) {
    const lockFailure = normalizeFailureArray(manifest.failures).some((failure) => failure.stage === 'toolchain-lock');
    if (!lockFailure || !allBuildsNotRun(manifest.builds)) {
      pushError(errors, 'toolchainLock.sha256 may be null only for lock failures before any build step runs.');
    }
    return;
  }

  if (!isLowerHexDigest(manifest.toolchainLock.sha256)) {
    pushError(errors, 'toolchainLock.sha256 must be a lowercase SHA-256 digest or null.');
  }
}

export async function hashFile(filePath, {
  createReadStreamImpl = fs.createReadStream
} = {}) {
  return await new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    let sizeBytes = 0;
    const stream = createReadStreamImpl(filePath);

    stream.on('data', (chunk) => {
      hash.update(chunk);
      sizeBytes += chunk.byteLength;
    });
    stream.on('error', reject);
    stream.on('end', () => {
      resolve({
        sha256: hash.digest('hex'),
        sizeBytes
      });
    });
  });
}

function execFileList(command, args, {
  repoRoot = REPO_ROOT,
  execFileImpl = execFileCallback,
  env = process.env
} = {}) {
  return new Promise((resolve, reject) => {
    execFileImpl(command, args, {
      cwd: repoRoot,
      env,
      shell: false,
      windowsHide: true,
      maxBuffer: 10 * 1024 * 1024
    }, (error, stdout, stderr) => {
      if (error) {
        reject(Object.assign(error, {
          stdout: stdout ?? error.stdout ?? '',
          stderr: stderr ?? error.stderr ?? ''
        }));
        return;
      }

      resolve({
        stdout: stdout ?? '',
        stderr: stderr ?? ''
      });
    });
  });
}

async function extractHapEntryBinary(hapPath, entryPath, options = {}) {
  const {
    tempRoot = os.tmpdir(),
    repoRoot = REPO_ROOT,
    fsApi = fsPromises,
    spawnImpl = spawnChild,
    hashFileImpl = hashFile
  } = options;
  const extractionRoot = options.extractionRoot;
  const ownsExtractionRoot = options.ownsExtractionRoot !== false;
  const tempFilePath = path.join(
    extractionRoot,
    options.tempFileName ?? `${path.basename(entryPath, '.so')}-${Date.now()}.so`
  );

  const cleanup = async () => {
    await fsApi.rm(tempFilePath, { force: true }).catch(() => {});
    if (ownsExtractionRoot) {
      await fsApi.rm(extractionRoot, { recursive: true, force: true }).catch(() => {});
    }
  };

  try {
    await new Promise((resolve, reject) => {
      const output = fs.createWriteStream(tempFilePath, { flags: 'w' });
      const child = spawnImpl('/usr/bin/unzip', ['-p', hapPath, entryPath], {
        cwd: repoRoot,
        env: process.env,
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe']
      });

      let stderr = '';
      let finished = false;
      let childDone = false;
      let childCode = null;
      let childError = null;
      let rejected = false;

      const rejectOnce = (error) => {
        if (rejected) {
          return;
        }
        rejected = true;
        reject(error);
      };

      const finalizeIfReady = () => {
        if (!finished || !childDone) {
          return;
        }
        if (childError) {
          rejectOnce(childError);
          return;
        }
        if (childCode !== 0) {
          const error = new Error(stderr || `unzip -p exited with ${childCode}`);
          error.code = 'HAP_NATIVE_EXTRACTION_FAILED';
          rejectOnce(error);
          return;
        }
        resolve();
      };

      child.stdout?.pipe(output);
      child.stderr?.setEncoding?.('utf8');
      child.stderr?.on('data', (chunk) => {
        stderr += chunk;
      });
      child.on('error', (error) => {
        childError = Object.assign(error, { stderr });
        childDone = true;
        output.destroy(childError);
        finalizeIfReady();
      });
      output.on('error', (error) => {
        rejectOnce(error);
      });
      output.on('finish', () => {
        finished = true;
        finalizeIfReady();
      });
      child.on('close', (exitCode) => {
        childCode = exitCode;
        childDone = true;
        finalizeIfReady();
      });
    });

    const digest = await hashFileImpl(tempFilePath, {
      createReadStreamImpl: options.createReadStreamImpl
    });
    return {
      tempFilePath,
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes,
      cleanup
    };
  } catch (error) {
    await cleanup();
    throw error;
  }
}

async function createExclusiveExtractionRoot(options = {}) {
  const {
    runId = 'phase1-native',
    tempRoot = os.tmpdir(),
    fsApi = fsPromises
  } = options;
  if (typeof runId !== 'string' || !EXTRACTION_RUN_ID_PATTERN.test(runId)) {
    const error = new Error('Extraction runId must be a non-empty ASCII token containing only letters, digits, underscores, or hyphens.');
    error.code = 'HAP_NATIVE_EXTRACTION_ROOT_INVALID';
    throw error;
  }

  const resolvedTempRoot = path.resolve(tempRoot);
  const extractionRoot = path.resolve(resolvedTempRoot, `phase1-native-${runId}`);
  if (extractionRoot === resolvedTempRoot || !extractionRoot.startsWith(`${resolvedTempRoot}${path.sep}`)) {
    const error = new Error(`Extraction root escapes tempRoot for run ${runId}`);
    error.code = 'HAP_NATIVE_EXTRACTION_ROOT_INVALID';
    throw error;
  }

  try {
    await fsApi.mkdir(extractionRoot);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      const conflict = new Error(`Extraction root already exists for run ${runId}`);
      conflict.code = 'HAP_NATIVE_EXTRACTION_ROOT_CONFLICT';
      throw conflict;
    }
    throw error;
  }
  return extractionRoot;
}

function stripElfReport(report) {
  if (!report || typeof report !== 'object') {
    return report;
  }

  const {
    result,
    component,
    architecture,
    neededLibraries,
    allowedNeededLibraries,
    exportedSymbols,
    requiredExports,
    failures
  } = report;

  return {
    result,
    component,
    architecture,
    neededLibraries,
    allowedNeededLibraries,
    exportedSymbols,
    requiredExports,
    failures
  };
}

export function normalizeElfReport(report, expectedComponent = null) {
  const stripped = stripElfReport(report);
  if (!stripped || typeof stripped !== 'object') {
    return stripped;
  }

  return {
    result: stripped.result ?? 'fail',
    component: stripped.component ?? expectedComponent ?? null,
    architecture: stripped.architecture ?? null,
    neededLibraries: Array.isArray(stripped.neededLibraries) ? [...stripped.neededLibraries] : [],
    allowedNeededLibraries: Array.isArray(stripped.allowedNeededLibraries) ? [...stripped.allowedNeededLibraries] : [],
    exportedSymbols: Array.isArray(stripped.exportedSymbols) ? [...stripped.exportedSymbols] : [],
    requiredExports: Array.isArray(stripped.requiredExports) ? [...stripped.requiredExports] : [],
    failures: Array.isArray(stripped.failures)
      ? stripped.failures.map((failure) => ({
        code: failure.code,
        detail: failure.detail,
        stage: failure.stage
      }))
      : []
  };
}

export async function listHapEntries(hapPath, options = {}) {
  const { stdout } = await execFileList('/usr/bin/unzip', ['-Z1', hapPath], options);
  const entries = String(stdout)
    .split(/\r?\n/u)
    .filter((line) => line.length > 0);
  const occurrences = {};
  for (const entry of entries) {
    occurrences[entry] = (occurrences[entry] ?? 0) + 1;
  }
  return {
    entries,
    entryCount: entries.length,
    occurrences
  };
}

export async function extractAndHashHapEntry(hapPath, entryPath, options = {}) {
  const extractionRoot = await createExclusiveExtractionRoot(options);
  const extraction = await extractHapEntryBinary(hapPath, entryPath, {
    ...options,
    extractionRoot
  });

  try {
    options.onEvent?.();
    const expectedComponent = options.component ?? (entryPath === HAP_NATIVE_ENTRIES.addon ? 'nodeAddon' : 'mihomoCore');
    const elf = normalizeElfReport(await (options.inspectNativeLibraryImpl ?? inspectNativeLibrary)({
      libPath: path.resolve(extraction.tempFilePath),
      component: expectedComponent
    }), expectedComponent);
    return {
      identity: entryPath,
      sha256: extraction.sha256,
      sizeBytes: extraction.sizeBytes,
      elf
    };
  } finally {
    await extraction.cleanup();
  }
}

export async function inspectHapNativeEntries(input, options = {}) {
  const {
    hapPath,
    runId = 'phase1-native',
    entries = HAP_NATIVE_ENTRIES
  } = input ?? {};
  const listHapEntriesImpl = options.listHapEntriesImpl ?? listHapEntries;
  const failures = [];
  const artifacts = {
    core: null,
    addon: null
  };
  let extractionRoot = null;
  let listed = null;
  const extractedArtifacts = new Map();

  try {
    extractionRoot = await createExclusiveExtractionRoot({
      runId,
      tempRoot: options.tempRoot,
      fsApi: options.fsApi
    });

    listed = await listHapEntriesImpl(hapPath, options);
    options.onEvent?.('list-hap');

    for (const [componentKey, entryPath] of [['core', entries.core], ['addon', entries.addon]]) {
      const exactCount = listed.occurrences[entryPath] ?? 0;
      const baseName = path.posix.basename(entryPath);
      const basenameMatches = listed.entries.filter((candidate) => path.posix.basename(candidate) === baseName);

      if (exactCount === 0) {
        failures.push(createFailure('HAP_NATIVE_ENTRY_MISSING', entryPath, 'archive'));
        if (basenameMatches.length > 0) {
          failures.push(createFailure('HAP_NATIVE_ENTRY_WRONG_PATH', baseName, 'archive'));
        }
        continue;
      }
      if (exactCount !== 1) {
        failures.push(createFailure('HAP_NATIVE_ENTRY_AMBIGUOUS', entryPath, 'archive'));
        continue;
      }
      if (basenameMatches.some((candidate) => candidate !== entryPath)) {
        failures.push(createFailure('HAP_NATIVE_ENTRY_WRONG_PATH', baseName, 'archive'));
        continue;
      }

      try {
        const extraction = await extractHapEntryBinary(hapPath, entryPath, {
          ...options,
          extractionRoot,
          ownsExtractionRoot: false,
          tempFileName: componentKey === 'core' ? 'core.so' : 'addon.so'
        });
        options.onEvent?.(componentKey === 'core' ? 'extract-hap-core' : 'extract-hap-addon');
        extractedArtifacts.set(componentKey, extraction);
      } catch (error) {
        failures.push(createFailure(error?.code ?? 'HAP_NATIVE_EXTRACTION_FAILED', error?.message ?? `Failed to extract ${entryPath}`, 'archive'));
        throw error;
      }
    }

    for (const [componentKey, extraction] of extractedArtifacts.entries()) {
      const entryPath = componentKey === 'core' ? entries.core : entries.addon;
      options.onEvent?.(componentKey === 'core' ? 'inspect-hap-core' : 'inspect-hap-addon');
      const expectedComponent = componentKey === 'core' ? 'mihomoCore' : 'nodeAddon';
      try {
        const elf = normalizeElfReport(await (options.inspectNativeLibraryImpl ?? inspectNativeLibrary)({
          libPath: path.resolve(extraction.tempFilePath),
          component: expectedComponent
        }), expectedComponent);
        artifacts[componentKey] = {
          identity: entryPath,
          sha256: extraction.sha256,
          sizeBytes: extraction.sizeBytes,
          elf
        };
      } catch (error) {
        if (!options.captureInspectErrors) {
          throw error;
        }
        failures.push(createFailure(
          componentKey === 'core' ? 'HAP_CORE_ELF_INVALID' : 'HAP_ADDON_ELF_INVALID',
          error?.message ?? `Failed to inspect ${entryPath}`,
          'archive'
        ));
      }
    }
  } finally {
    await Promise.all([...extractedArtifacts.values()].map(async (extraction) => await extraction.cleanup()));
    if (extractionRoot) {
      await (options.fsApi ?? fsPromises).rm(extractionRoot, { recursive: true, force: true }).catch(() => {});
    }
  }

  return {
    entryCount: listed.entryCount,
    occurrences: {
      core: listed.occurrences[entries.core] ?? 0,
      addon: listed.occurrences[entries.addon] ?? 0
    },
    artifacts,
    failures
  };
}

export function derivePhase1Result(manifest) {
  return deriveResultsFromManifest(manifest);
}

export function validatePhase1NativeManifest(manifest) {
  const errors = [];

  if (!validateExactKeys(manifest, ALLOWED_TOP_LEVEL_KEYS, ALLOWED_TOP_LEVEL_KEYS, 'manifest', errors)) {
    return { valid: false, errors };
  }

  if (manifest.schemaVersion !== PHASE1_NATIVE_SCHEMA_VERSION) {
    pushError(errors, `schemaVersion must be ${PHASE1_NATIVE_SCHEMA_VERSION}.`);
  }
  if (manifest.phase !== PHASE1_NATIVE_PHASE) {
    pushError(errors, `phase must be ${PHASE1_NATIVE_PHASE}.`);
  }
  if (!['pass', 'fail', 'incomplete'].includes(manifest.result)) {
    pushError(errors, 'result must be pass, fail, or incomplete.');
  }
  if (!['pass', 'fail'].includes(manifest.nativeBuildResult)) {
    pushError(errors, 'nativeBuildResult must be pass or fail.');
  }
  if (!isUuid(manifest.runId)) {
    pushError(errors, 'runId must be a UUID.');
  }

  if (!validateExactKeys(manifest.timestamps, ['startedAt', 'completedAt'], ['startedAt', 'completedAt'], 'timestamps', errors)) {
    return { valid: false, errors };
  }
  if (!isIsoTimestamp(manifest.timestamps.startedAt) || !isIsoTimestamp(manifest.timestamps.completedAt)) {
    pushError(errors, 'timestamps.startedAt and timestamps.completedAt must be ISO-8601 strings.');
  } else if (Date.parse(manifest.timestamps.completedAt) < Date.parse(manifest.timestamps.startedAt)) {
    pushError(errors, 'timestamps.completedAt must not be earlier than timestamps.startedAt.');
  }

  validateToolchainLock(manifest, errors);

  if (!validateExactKeys(manifest.builds, ['core', 'addonConfigure', 'addon', 'hap'], ['core', 'addonConfigure', 'addon', 'hap'], 'builds', errors)) {
    return { valid: false, errors };
  }
  for (const key of ['core', 'addonConfigure', 'addon', 'hap']) {
    validateBuildStep(manifest.builds[key], key, errors, manifest);
  }

  if (!validateExactKeys(manifest.artifacts, ['rawCore', 'prePackageCore', 'prePackageAddon', 'hap', 'hapCore', 'hapAddon'], ['rawCore', 'prePackageCore', 'prePackageAddon', 'hap', 'hapCore', 'hapAddon'], 'artifacts', errors)) {
    return { valid: false, errors };
  }
  for (const key of ['rawCore', 'prePackageCore', 'prePackageAddon', 'hap', 'hapCore', 'hapAddon']) {
    validateArtifact(manifest.artifacts[key], key, errors);
  }

  validateArchive(manifest, errors);

  if (!validateExactKeys(manifest.signing, ALLOWED_SIGNING_KEYS, ALLOWED_SIGNING_KEYS, 'signing', errors)) {
    return { valid: false, errors };
  }
  if (!['pass', 'incomplete', 'not-run'].includes(manifest.signing.result)) {
    pushError(errors, 'signing.result must be pass, incomplete, or not-run.');
  }

  if (!validateExactKeys(manifest.device, ALLOWED_DEVICE_KEYS, ALLOWED_DEVICE_KEYS, 'device', errors)) {
    return { valid: false, errors };
  }
  if (!['pass', 'incomplete', 'not-run'].includes(manifest.device.result)) {
    pushError(errors, 'device.result must be pass, incomplete, or not-run.');
  }
  if (!(manifest.device.targetCount === null || (Number.isInteger(manifest.device.targetCount) && manifest.device.targetCount >= 0))) {
    pushError(errors, 'device.targetCount must be null-before-run or a non-negative integer.');
  }
  if (!(manifest.device.identityMasked === null || typeof manifest.device.identityMasked === 'string')) {
    pushError(errors, 'device.identityMasked must be null or a string.');
  }
  if (manifest.device.proofResult !== 'not-run') {
    pushError(errors, 'device.proofResult must remain not-run.');
  }

  validateFailureList(manifest.failures, 'failures', errors);

  if (manifest.nativeBuildResult === 'pass') {
    for (const key of ['rawCore', 'prePackageCore', 'prePackageAddon', 'hap', 'hapCore', 'hapAddon']) {
      if (manifest.artifacts[key] === null) {
        pushError(errors, `artifacts.${key} must be present when nativeBuildResult is pass.`);
      }
    }
    for (const key of ['core', 'addonConfigure', 'addon', 'hap']) {
      if (manifest.builds[key].result !== 'pass') {
        pushError(errors, `builds.${key} must be pass when nativeBuildResult is pass.`);
      }
    }
    if (manifest.archive.entryCount === null || manifest.archive.entryCount < 2) {
      pushError(errors, 'archive.entryCount must be >= 2 when nativeBuildResult is pass.');
    }
    if (manifest.archive.occurrences.core !== 1 || manifest.archive.occurrences.addon !== 1) {
      pushError(errors, 'archive.occurrences core/addon must both equal 1 when nativeBuildResult is pass.');
    }
  }

  if (manifest.artifacts.rawCore && manifest.artifacts.prePackageCore && !sameDigest(manifest.artifacts.rawCore, manifest.artifacts.prePackageCore)) {
    pushError(errors, 'artifacts.prePackageCore must match artifacts.rawCore.');
  }
  if (manifest.artifacts.rawCore && manifest.artifacts.hapCore && !sameDigest(manifest.artifacts.rawCore, manifest.artifacts.hapCore)) {
    pushError(errors, 'artifacts.hapCore must match artifacts.rawCore.');
  }
  if (manifest.artifacts.prePackageAddon && manifest.artifacts.hapAddon && !sameDigest(manifest.artifacts.prePackageAddon, manifest.artifacts.hapAddon)) {
    pushError(errors, 'artifacts.hapAddon must match artifacts.prePackageAddon.');
  }

  validateBlockerConsistency(manifest, errors);
  return {
    valid: errors.length === 0,
    errors
  };
}

export async function verifyPhase1NativeManifest(manifest, options = {}) {
  const validation = validatePhase1NativeManifest(manifest);
  if (!validation.valid) {
    return validation;
  }

  const errors = [];
  const repoRoot = options.repoRoot ?? REPO_ROOT;
  const hashFileImpl = options.hashFileImpl ?? hashFile;
  const inspectNativeLibraryImpl = options.inspectNativeLibraryImpl ?? inspectNativeLibrary;
  const inspectHapNativeEntriesImpl = options.inspectHapNativeEntriesImpl ?? inspectHapNativeEntries;
  const liveRepoIdentities = new Map();

  try {
    const liveLock = manifest.toolchainLock.sha256 === null
      ? null
      : await hashFileImpl((await resolveLiveRepoIdentityPath(repoRoot, manifest.toolchainLock.path, options)).realPath);
    if (liveLock && liveLock.sha256 !== manifest.toolchainLock.sha256) {
      pushError(errors, 'toolchainLock digest does not match the live file.');
    }
  } catch (error) {
    pushError(errors, ['IDENTITY_PATH_OUTSIDE_REPO', 'IDENTITY_PATH_SYMLINK'].includes(error?.code)
      ? error.message
      : `toolchainLock could not be rehashed: ${error?.message ?? 'unknown error'}`);
  }

  for (const key of ['rawCore', 'prePackageCore', 'prePackageAddon', 'hap']) {
    const artifact = manifest.artifacts[key];
    if (artifact === null) {
      continue;
    }

    try {
      const liveIdentity = await resolveLiveRepoIdentityPath(repoRoot, artifact.identity, options);
      liveRepoIdentities.set(key, liveIdentity);
      const live = await hashFileImpl(liveIdentity.realPath);
      if (live.sha256 !== artifact.sha256 || live.sizeBytes !== artifact.sizeBytes) {
        pushError(errors, `${key} digest does not match the live file.`);
      }
    } catch (error) {
      pushError(errors, ['IDENTITY_PATH_OUTSIDE_REPO', 'IDENTITY_PATH_SYMLINK'].includes(error?.code)
        ? error.message
        : `${key} could not be rehashed: ${error?.message ?? 'unknown error'}`);
    }
  }

  for (const key of ['rawCore', 'prePackageCore', 'prePackageAddon']) {
    const artifact = manifest.artifacts[key];
    if (artifact === null) {
      continue;
    }

    const liveIdentity = liveRepoIdentities.get(key);
    if (!liveIdentity) {
      continue;
    }

    const expectedComponent = expectedLiveElfComponent(key);
    try {
      const liveElf = normalizeElfReport(await inspectNativeLibraryImpl({
        libPath: liveIdentity.realPath,
        component: expectedComponent
      }), expectedComponent);
      for (const contractError of collectArtifactElfContractErrors(liveElf, key)) {
        pushError(errors, `${key} live ELF contract invalid: ${contractError}.`);
      }
      if (!normalizedElfReportsMatch(artifact.elf, liveElf, expectedComponent)) {
        pushError(errors, `${key} persisted ELF report does not match the live artifact inspection.`);
      }
    } catch (error) {
      pushError(errors, `${key} live ELF inspection failed: ${error?.code ?? error?.message ?? 'unknown error'}`);
    }
  }

  const shouldVerifyArchiveLive = (
    manifest.artifacts.hap !== null &&
    manifest.archive.entryCount !== null &&
    manifest.archive.occurrences.core !== null &&
    manifest.archive.occurrences.addon !== null &&
    manifest.artifacts.hapCore !== null &&
    manifest.artifacts.hapAddon !== null
  );

  if (shouldVerifyArchiveLive) {
    try {
      const liveHapIdentity = await resolveLiveRepoIdentityPath(repoRoot, manifest.artifacts.hap.identity, options);
      const archive = await inspectHapNativeEntriesImpl({
        hapPath: liveHapIdentity.realPath,
        runId: manifest.runId
      }, options);
      if (archive.entryCount !== manifest.archive.entryCount) {
        pushError(errors, 'archive.entryCount does not match the live HAP.');
      }
      if ((archive.occurrences.core ?? archive.occurrences[HAP_NATIVE_ENTRIES.core] ?? 0) !== manifest.archive.occurrences.core) {
        pushError(errors, 'archive.occurrences.core does not match the live HAP.');
      }
      if ((archive.occurrences.addon ?? archive.occurrences[HAP_NATIVE_ENTRIES.addon] ?? 0) !== manifest.archive.occurrences.addon) {
        pushError(errors, 'archive.occurrences.addon does not match the live HAP.');
      }
      if (!sameDigest(archive.artifacts.core, manifest.artifacts.hapCore)) {
        pushError(errors, 'hapCore digest does not match the live HAP entry.');
      }
      if (!sameDigest(archive.artifacts.addon, manifest.artifacts.hapAddon)) {
        pushError(errors, 'hapAddon digest does not match the live HAP entry.');
      }
      for (const failure of archive.failures) {
        pushError(errors, `archive live verification failed: ${failure.code} ${failure.detail}`);
      }
    } catch (error) {
      pushError(errors, ['IDENTITY_PATH_OUTSIDE_REPO', 'IDENTITY_PATH_SYMLINK'].includes(error?.code)
        ? error.message
        : `archive live verification failed: ${error?.message ?? 'unknown error'}`);
    }
  }

  return {
    valid: errors.length === 0,
    errors
  };
}
