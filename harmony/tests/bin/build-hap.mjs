import { spawn as spawnChild } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { normalizeNodeVersion } from '../../tools/lib/toolchain.mjs';

export const BUILD_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 0;
const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_EVIDENCE_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase0-build-evidence.json');

const MODULE_BUILD_ARGS = ['--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default', '-p', 'buildMode=debug', 'assembleHap'];
const PROJECT_BUILD_ARGS = ['--mode', 'project', '-p', 'product=default', '-p', 'buildMode=debug', 'assembleApp'];
const EXECUTABLE_BITS = 0o111;
const MODULE_DEBUG_OUTPUT_DIRECTORY = ['entry', 'build', 'default', 'outputs', 'default'];
const NATIVE_BUILD_OUTPUT_DIRECTORIES = [
  ['entry', '.cxx', 'default', 'default', 'debug', 'arm64-v8a'],
  ['entry', 'build', 'default', 'intermediates', 'cmake', 'default', 'obj', 'arm64-v8a']
];
const RAW_CORE_RELATIVE_PATH = ['artifacts', 'libcmfa_mihomo.so'];
const PACKAGED_CORE_STAGE_RELATIVE_PATH = ['entry', 'src', 'main', 'libs', 'arm64-v8a', 'libcmfa_mihomo.so'];
const DEFAULT_COMMAND_TIMEOUT_MS = 10 * 60 * 1000;
const HOME_DIRECTORY = process.env.HOME ?? process.env.USERPROFILE ?? null;
const FILE_URL_PATTERN = /\bfile:\/\/[^\s"'<>]+/giu;
const SIGNING_TOKEN_PATTERN = /(^|[\s"'(=\[])([^\s"'<>]*\.(?:p12|cer|p7b|pem|pfx))(?=$|[\s"'<>)}\]])/giu;
const POSIX_PATH_PATTERN = /(^|[\s"'(=\[])(\/(?!\/)[^\s"'<>]+)(?=$|[\s"'<>)}\]])/gu;
const WINDOWS_PATH_PATTERN = /(^|[\s"'(=\[])([A-Za-z]:\\[^\s"'<>]+)(?=$|[\s"'<>)}\]])/gu;

function isoTimestamp(date) {
  return date.toISOString();
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

function createReplacements(repoRoot, extraEntries = []) {
  const replacements = new Map();

  if (repoRoot) {
    replacements.set(repoRoot, '<repo>');
  }

  if (HOME_DIRECTORY) {
    replacements.set(HOME_DIRECTORY, '<home>');
  }

  for (const [value, replacement] of extraEntries) {
    if (value) {
      replacements.set(value, replacement);
    }
  }

  return replacements;
}

function sanitizeText(raw, replacements = new Map()) {
  let sanitized = String(raw ?? '');

  for (const [value, replacement] of replacements.entries()) {
    sanitized = sanitized.split(value).join(replacement);
  }

  sanitized = sanitized.replace(FILE_URL_PATTERN, 'file://<redacted>');
  sanitized = sanitized.replace(SIGNING_TOKEN_PATTERN, (_, prefix) => `${prefix}<signing-material>`);
  sanitized = sanitized.replace(POSIX_PATH_PATTERN, (_, prefix, pathToken) => {
    if (pathToken.startsWith('/<')) {
      return `${prefix}${pathToken}`;
    }

    return `${prefix}<path>`;
  });
  sanitized = sanitized.replace(WINDOWS_PATH_PATTERN, (_, prefix) => `${prefix}<path>`);

  return sanitized;
}

function sanitizeCommandValue(value, repoRoot, replacements = new Map()) {
  if (typeof value !== 'string') {
    return value;
  }

  if (path.isAbsolute(value)) {
    return sanitizeText(normalizePathForReport(repoRoot, value), replacements);
  }

  return sanitizeText(value, replacements);
}

function sanitizeForPersistence(value, replacements = new Map()) {
  if (typeof value === 'string') {
    return sanitizeText(value, replacements);
  }

  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeForPersistence(entry, replacements));
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, sanitizeForPersistence(entry, replacements)])
    );
  }

  return value;
}

function isSigningWarning(text) {
  return /\bwill skip sign\b/iu.test(text) || /\bno signingconfigs? profile\b/iu.test(text) || /\bno signingconfig found\b/iu.test(text);
}

function isUnsignedHapPath(filePath) {
  return /-unsigned\.hap$/iu.test(path.basename(filePath));
}

function createFailure(code, detail, extra = {}) {
  return {
    code,
    detail,
    ...extra
  };
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

function createBuildEvidence({ repoRoot, harmonyRoot, outputPath, startedAt }) {
  return {
    schemaVersion: BUILD_SCHEMA_VERSION,
    phase: PHASE_NUMBER,
    result: 'fail',
    harmonyRoot: normalizePathForReport(repoRoot, harmonyRoot),
    outputPath: normalizePathForReport(repoRoot, outputPath),
    timestamps: {
      startedAt: isoTimestamp(startedAt),
      completedAt: null
    },
    toolchain: {
      nodeVersion: normalizeNodeVersion(process.version),
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hvigorVersion: null,
      ohpmVersion: null,
      hdcVersion: null
    },
    wrapper: {
      path: null,
      executable: false
    },
    phase2SelfTest: createPhase2SelfTestEvidence(false),
    commands: [],
    hap: {
      path: null,
      sha256: null,
      sizeBytes: null
    },
    failures: []
  };
}

async function readToolchainVersions({ fsApi, harmonyRoot }) {
  const lockPath = path.join(harmonyRoot, 'toolchain.lock.json');

  try {
    const raw = await fsApi.readFile(lockPath, 'utf8');
    const lock = JSON.parse(raw);
    return {
      devecoVersion: lock?.installed?.devecoVersion ?? null,
      sdkVersion: lock?.installed?.sdkVersion ?? null,
      ndkVersion: lock?.installed?.ndkVersion ?? null,
      hvigorVersion: lock?.installed?.hvigorVersion ?? null,
      ohpmVersion: lock?.installed?.ohpmVersion ?? null,
      hdcVersion: lock?.installed?.hdcVersion ?? null
    };
  } catch {
    return {
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hvigorVersion: null,
      ohpmVersion: null,
      hdcVersion: null
    };
  }
}

export async function findHvigorWrapper({ fsApi = fs, harmonyRoot }) {
  const wrapperPath = path.join(harmonyRoot, 'hvigorw');

  try {
    const stats = await fsApi.stat(wrapperPath);
    if ((stats.mode & EXECUTABLE_BITS) === 0) {
      return null;
    }

    return wrapperPath;
  } catch {
    return null;
  }
}

async function runCommand({
  command,
  args,
  cwd,
  env = process.env,
  spawnImpl = spawnChild,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS
}) {
  return await new Promise((resolve) => {
    const child = spawnImpl(command, args, {
      cwd,
      env,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let spawnError = null;
    let settled = false;
    let timedOut = false;
    let timeoutId = null;

    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId);
        timeoutId = null;
      }
    };

    const finalize = ({ exitCode = null, signal = null, error = spawnError, forceTimedOut = timedOut } = {}) => {
      if (settled) {
        return;
      }

      settled = true;
      cleanup();
      resolve({
        command,
        args: [...args],
        cwd,
        stdout,
        stderr,
        exitCode,
        signal,
        error,
        timedOut: forceTimedOut
      });
    };

    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (error) => {
      spawnError = error;
    });
    child.on('close', (code, signal) => {
      finalize({
        exitCode: typeof code === 'number' ? code : null,
        signal
      });
    });

    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      timeoutId = setTimeout(() => {
        timedOut = true;
        const timeoutError = new Error(`Command timed out after ${timeoutMs} ms.`);
        timeoutError.code = 'BUILD_TIMEOUT';
        spawnError = timeoutError;

        try {
          child.kill?.('SIGTERM');
        } catch {
          // Best effort only; timeout should still resolve deterministically.
        }

        finalize({
          exitCode: null,
          signal: 'SIGTERM',
          error: timeoutError,
          forceTimedOut: true
        });
      }, timeoutMs);
    }
  });
}

async function walkFiles(fsApi, rootPath) {
  const entries = await fsApi.readdir(rootPath, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const absolutePath = path.join(rootPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...await walkFiles(fsApi, absolutePath));
      continue;
    }

    if (entry.isFile()) {
      files.push(absolutePath);
    }
  }

  return files;
}

function isDeterministicDebugHapCandidate(harmonyRoot, absolutePath) {
  const normalized = path.relative(harmonyRoot, absolutePath).split(path.sep).join('/');
  if (!normalized.endsWith('.hap')) {
    return false;
  }

  if (!/^entry\/build\/default\/outputs\/default\/[^/]+\.hap$/u.test(normalized)) {
    return false;
  }

  return !normalized.includes('/release/');
}

export async function findDebugHapCandidates({ harmonyRoot, fsApi = fs }) {
  const candidateRoots = [
    path.join(harmonyRoot, 'entry', 'build')
  ];
  const candidates = [];

  for (const candidateRoot of candidateRoots) {
    try {
      const files = await walkFiles(fsApi, candidateRoot);
      for (const filePath of files) {
        if (isDeterministicDebugHapCandidate(harmonyRoot, filePath)) {
          candidates.push(filePath);
        }
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw error;
      }
    }
  }

  return [...new Set(candidates)].sort();
}

export function selectDebugHapCandidate(candidates) {
  if (candidates.length === 0) {
    const error = new Error('No deterministic debug HAP was found.');
    error.code = 'HAP_NOT_FOUND';
    throw error;
  }

  if (candidates.length === 2) {
    const signedCandidates = candidates.filter((candidate) => !isUnsignedHapPath(candidate));
    const unsignedCandidates = candidates.filter((candidate) => isUnsignedHapPath(candidate));

    if (signedCandidates.length === 1 && unsignedCandidates.length === 1) {
      return signedCandidates[0];
    }
  }

  if (candidates.length > 1) {
    const error = new Error('Multiple deterministic debug HAP candidates were found.');
    error.code = 'HAP_AMBIGUOUS';
    throw error;
  }

  return candidates[0];
}

async function sha256File({ fsApi, filePath }) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

async function stagePackagedCore({ harmonyRoot, fsApi }) {
  const rawCorePath = path.join(harmonyRoot, ...RAW_CORE_RELATIVE_PATH);
  const stagedCorePath = path.join(harmonyRoot, ...PACKAGED_CORE_STAGE_RELATIVE_PATH);
  const stageDirectories = [
    path.join(harmonyRoot, 'entry', 'src', 'main', 'libs', 'arm64-v8a'),
    path.join(harmonyRoot, 'entry', 'src', 'main', 'libs')
  ];

  await fsApi.rm(stagedCorePath, { force: true }).catch(() => {});

  try {
    await fsApi.access(rawCorePath);
  } catch {
    return {
      stagedCorePath,
      cleanup: async () => {
        await fsApi.rm(stagedCorePath, { force: true }).catch(() => {});
        for (const directoryPath of stageDirectories) {
          await fsApi.rmdir(directoryPath).catch(() => {});
        }
      }
    };
  }

  await fsApi.mkdir(path.dirname(stagedCorePath), { recursive: true });
  await fsApi.copyFile(rawCorePath, stagedCorePath);

  return {
    stagedCorePath,
    cleanup: async () => {
      await fsApi.rm(stagedCorePath, { force: true }).catch(() => {});
      for (const directoryPath of stageDirectories) {
        await fsApi.rmdir(directoryPath).catch(() => {});
      }
    }
  };
}

async function injectCoreIntoHap({
  harmonyRoot,
  hapPath,
  fsApi,
  spawnImpl,
  timeoutMs,
  env
}) {
  const rawCorePath = path.join(harmonyRoot, ...RAW_CORE_RELATIVE_PATH);
  try {
    await fsApi.access(rawCorePath);
  } catch {
    return;
  }
  const tempRoot = await fsApi.mkdtemp(path.join(os.tmpdir(), 'cmfa-hap-core-'));
  const archiveRelativePath = path.join('libs', 'arm64-v8a', 'libcmfa_mihomo.so');
  const stagedArchivePath = path.join(tempRoot, archiveRelativePath);

  try {
    await fsApi.mkdir(path.dirname(stagedArchivePath), { recursive: true });
    await fsApi.copyFile(rawCorePath, stagedArchivePath);

    const deleteResult = await runCommand({
      command: '/usr/bin/zip',
      args: ['-q', '-d', hapPath, archiveRelativePath.split(path.sep).join('/')],
      cwd: tempRoot,
      env,
      spawnImpl,
      timeoutMs
    });
    if (deleteResult.error || ![0, 12].includes(deleteResult.exitCode ?? -1)) {
      throw Object.assign(new Error(deleteResult.stderr || deleteResult.stdout || 'Failed to remove stale core entry from HAP.'), {
        code: deleteResult.error?.code ?? 'HAP_PATCH_FAILED'
      });
    }

    const addResult = await runCommand({
      command: '/usr/bin/zip',
      args: ['-q', hapPath, archiveRelativePath.split(path.sep).join('/')],
      cwd: tempRoot,
      env,
      spawnImpl,
      timeoutMs
    });
    if (addResult.error || addResult.exitCode !== 0) {
      throw Object.assign(new Error(addResult.stderr || addResult.stdout || 'Failed to add the real core to the HAP archive.'), {
        code: addResult.error?.code ?? 'HAP_PATCH_FAILED'
      });
    }
  } finally {
    await fsApi.rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}

function classifyBuildFailure(commandResult, stage) {
  if (commandResult.timedOut) {
    return createFailure('BUILD_TIMEOUT', `The ${stage} hvigor build exceeded the timeout and was terminated.`, { stage });
  }

  const combinedOutput = `${commandResult.stdout}\n${commandResult.stderr}`.toLowerCase();
  if (/\bsign(?:ing|ature)?\b/u.test(combinedOutput) || /\bcertificate\b/u.test(combinedOutput)) {
    return createFailure('SIGNING_REQUIRED', 'The HarmonyOS build requires local signing material before a signed debug HAP can be produced.', { stage });
  }

  if (commandResult.error) {
    return createFailure('BUILD_SPAWN_FAILED', commandResult.error.message, { stage });
  }

  return createFailure('BUILD_COMMAND_FAILED', `The ${stage} hvigor build exited with code ${commandResult.exitCode ?? 'unknown'}.`, { stage });
}

function pushFailure(failures, failure) {
  if (failures.some((entry) => entry.code === failure.code && entry.stage === failure.stage && entry.detail === failure.detail)) {
    return;
  }

  failures.push(failure);
}

function finalizeBuildEvidence(evidence) {
  if (evidence.failures.length === 0) {
    evidence.result = 'pass';
    return evidence;
  }

  if (evidence.failures.every((entry) => entry.code === 'SIGNING_REQUIRED')) {
    evidence.result = 'incomplete';
    return evidence;
  }

  evidence.result = 'fail';
  return evidence;
}

export async function buildHap({
  harmonyRoot = HARMONY_ROOT,
  outputPath = DEFAULT_EVIDENCE_PATH,
  fsApi = fs,
  spawnImpl = spawnChild,
  commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
  now = () => new Date(),
  env = process.env,
  phase2SelfTestEnabled = false
} = {}) {
  const repoRoot = path.resolve(harmonyRoot, '..');
  const startedAt = now();
  const evidence = createBuildEvidence({ repoRoot, harmonyRoot, outputPath, startedAt });
  const replacements = createReplacements(repoRoot);
  const laneEnv = createPhase2SelfTestEnv(env, phase2SelfTestEnabled);

  evidence.phase2SelfTest = createPhase2SelfTestEvidence(phase2SelfTestEnabled);

  evidence.toolchain = {
    ...evidence.toolchain,
    ...await readToolchainVersions({ fsApi, harmonyRoot })
  };
  let stagedCore = null;

  try {
    const wrapperPath = await findHvigorWrapper({ fsApi, harmonyRoot });
    if (!wrapperPath) {
      evidence.failures.push(createFailure('WRAPPER_MISSING', 'harmony/hvigorw is missing or not executable.', { stage: 'wrapper' }));
      return evidence;
    }

    evidence.wrapper.path = normalizePathForReport(repoRoot, wrapperPath);
    evidence.wrapper.executable = true;

    stagedCore = await stagePackagedCore({ harmonyRoot, fsApi });

    await fsApi.rm(path.join(harmonyRoot, ...MODULE_DEBUG_OUTPUT_DIRECTORY), {
      recursive: true,
      force: true
    });
    for (const directorySegments of NATIVE_BUILD_OUTPUT_DIRECTORIES) {
      await fsApi.rm(path.join(harmonyRoot, ...directorySegments), {
        recursive: true,
        force: true
      });
    }

    for (const [stage, args] of [
      ['module', MODULE_BUILD_ARGS],
      ['project', PROJECT_BUILD_ARGS]
    ]) {
      const commandResult = await runCommand({
        command: wrapperPath,
        args,
        cwd: harmonyRoot,
        env: laneEnv,
        spawnImpl,
        timeoutMs: commandTimeoutMs
      });

      evidence.commands.push({
        stage,
        command: [normalizePathForReport(repoRoot, wrapperPath), ...args],
        cwd: normalizePathForReport(repoRoot, harmonyRoot),
        exitCode: commandResult.exitCode,
        signal: commandResult.signal,
        stdout: sanitizeText(commandResult.stdout, replacements),
        stderr: sanitizeText(commandResult.stderr, replacements)
      });

      if (commandResult.error || commandResult.exitCode !== 0) {
        pushFailure(evidence.failures, {
          ...classifyBuildFailure(commandResult, stage),
          detail: sanitizeText(classifyBuildFailure(commandResult, stage).detail, replacements)
        });

        if (commandResult.timedOut) {
          break;
        }

        continue;
      }

      if (isSigningWarning(`${commandResult.stdout}\n${commandResult.stderr}`)) {
        pushFailure(evidence.failures, createFailure(
          'SIGNING_REQUIRED',
          'The HarmonyOS build produced only unsigned output because no signing profile is configured.',
          { stage }
        ));
      }
    }

    const candidates = await findDebugHapCandidates({ harmonyRoot, fsApi });
    const selectedHap = selectDebugHapCandidate(candidates);
    await injectCoreIntoHap({
      harmonyRoot,
      hapPath: selectedHap,
      fsApi,
      spawnImpl,
      timeoutMs: commandTimeoutMs,
      env: laneEnv
    });
    const digest = await sha256File({ fsApi, filePath: selectedHap });

    evidence.hap = {
      path: normalizePathForReport(repoRoot, selectedHap),
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes
    };

    if (isUnsignedHapPath(selectedHap)) {
      pushFailure(evidence.failures, createFailure(
        'SIGNING_REQUIRED',
        'The selected debug HAP is unsigned and cannot satisfy the device proof gate.',
        { stage: 'discover' }
      ));
    }
  } catch (error) {
    if (error?.code === 'HAP_NOT_FOUND' || error?.code === 'HAP_AMBIGUOUS') {
      pushFailure(evidence.failures, createFailure(error.code, sanitizeText(error.message, replacements), { stage: 'discover' }));
    } else if (error?.code === 'ENOENT') {
      pushFailure(evidence.failures, createFailure('HAP_NOT_FOUND', sanitizeText(error.message, replacements), { stage: 'discover' }));
    } else {
      pushFailure(evidence.failures, createFailure(
        error?.code ?? 'BUILD_EVIDENCE_ERROR',
        sanitizeText(error?.message ?? 'Unknown build failure', replacements),
        { stage: 'build' }
      ));
    }
  } finally {
    evidence.timestamps.completedAt = isoTimestamp(now());
    await stagedCore?.cleanup();
  }

  return sanitizeForPersistence(finalizeBuildEvidence(evidence), replacements);
}

export async function writeBuildEvidence(
  report,
  outputPath = DEFAULT_EVIDENCE_PATH,
  fsApi = fs,
  options = {}
) {
  const safeOutputPath = options.verifyRepoScope === false
    ? outputPath
    : await resolveRepoScopedOutputPath(fsApi, options.repoRoot ?? REPO_ROOT, outputPath, '--out');
  const tempPath = path.join(
    path.dirname(safeOutputPath),
    `.tmp-${path.basename(safeOutputPath)}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  try {
    await fsApi.writeFile(tempPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
    await fsApi.rename(tempPath, safeOutputPath);
  } finally {
    await fsApi.rm(tempPath, { force: true }).catch(() => {});
  }
}

function resolveRepoPath(repoRoot, candidatePath, argumentName) {
  const resolved = path.isAbsolute(candidatePath) ? candidatePath : path.resolve(repoRoot, candidatePath);
  const relative = path.relative(repoRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw Object.assign(new Error(`${argumentName} must stay inside the repository root.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return resolved;
}

function isWithinRepo(realRepoRoot, candidatePath) {
  const relative = path.relative(realRepoRoot, candidatePath);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function pathOutsideRepoError(option) {
  return Object.assign(new Error(`${option} resolves outside the repository through a symlink.`), {
    code: 'PATH_OUTSIDE_REPO'
  });
}

async function resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath, option = '--out') {
  const resolved = path.resolve(outputPath);
  const lexicalRelative = path.relative(repoRoot, resolved);
  if (lexicalRelative.startsWith('..') || path.isAbsolute(lexicalRelative)) {
    throw pathOutsideRepoError(option);
  }

  const realRepoRoot = await fsApi.realpath(repoRoot);
  let existingAncestor = path.dirname(resolved);
  while (true) {
    try {
      const realAncestor = await fsApi.realpath(existingAncestor);
      if (!isWithinRepo(realRepoRoot, realAncestor)) {
        throw pathOutsideRepoError(option);
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
    throw pathOutsideRepoError(option);
  }

  try {
    const outputStats = await fsApi.lstat(resolved);
    if (outputStats.isSymbolicLink()) {
      throw pathOutsideRepoError(option);
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }

  return path.join(realParent, path.basename(resolved));
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase0-build-evidence.json');
  let phase2SelfTestEnabled = false;
  let outProvided = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') {
      const next = argv[index + 1];
      if (!next) {
        throw Object.assign(new Error('--out requires a value.'), { code: 'ARGUMENT_INVALID' });
      }
      if (outProvided) {
        throw Object.assign(new Error('--out may only be provided once.'), { code: 'ARGUMENT_INVALID' });
      }
      outputPath = resolveRepoPath(repoRoot, next, '--out');
      outProvided = true;
      index += 1;
      continue;
    }
    if (arg === '--phase2-self-test') {
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
    phase2SelfTestEnabled
  };
}

export async function runCli({
  argv = process.argv.slice(2),
  repoRoot = REPO_ROOT,
  stdout = process.stdout,
  stderr = process.stderr,
  fsApi = fs,
  buildHapImpl = buildHap,
  writeBuildEvidenceImpl = writeBuildEvidence
} = {}) {
  let parsed = null;
  let safeOutputPath = null;

  try {
    parsed = parseCliArguments(argv, repoRoot);
    safeOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, parsed.outputPath, '--out');
    const report = await buildHapImpl({
      outputPath: parsed.outputPath,
      phase2SelfTestEnabled: parsed.phase2SelfTestEnabled
    });
    await writeBuildEvidenceImpl(report, safeOutputPath, fsApi, {
      repoRoot,
      verifyRepoScope: false
    });
    stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return report.result === 'pass' ? 0 : 2;
  } catch (error) {
    if (safeOutputPath) {
      const report = createBuildEvidence({
        repoRoot,
        harmonyRoot: path.join(repoRoot, 'harmony'),
        outputPath: parsed?.outputPath ?? safeOutputPath,
        startedAt: new Date()
      });
      report.failures.push(createFailure(error?.code ?? 'BUILD_FATAL', error?.message ?? 'Unknown fatal build error', { stage: 'build' }));
      report.timestamps.completedAt = isoTimestamp(new Date());
      await writeBuildEvidenceImpl(report, safeOutputPath, fsApi, {
        repoRoot,
        verifyRepoScope: false
      });
      stdout.write(`${JSON.stringify(report, null, 2)}\n`);
      return 2;
    }

    stderr.write(`${error?.stack ?? error?.message ?? String(error)}\n`);
    return 2;
  }
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
  });
}
