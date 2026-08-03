import { execFile as execFileCallback } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { normalizeNodeVersion } from '../../tools/lib/toolchain.mjs';
import { buildHap, writeBuildEvidence } from './build-hap.mjs';

export const PROOF_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 0;
export const BUNDLE_NAME = 'com.github.kr328.clash.harmony';
export const ENTRY_ABILITY_NAME = 'EntryAbility';
const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase0-device-proof.json');
export const DEFAULT_BUILD_EVIDENCE_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase0-build-evidence.json');

const STEP_RESULTS = new Set(['pass', 'fail', 'incomplete', 'not-run']);
const FINAL_RESULTS = new Set(['pass', 'fail', 'incomplete']);
const DEFAULT_HDC_COMMAND_TIMEOUT_MS = 60 * 1000;
const DEFAULT_TOOLCHAIN = {
  nodeVersion: normalizeNodeVersion(process.version),
  devecoVersion: null,
  sdkVersion: null,
  ndkVersion: null,
  hvigorVersion: null,
  ohpmVersion: null,
  hdcVersion: null
};
const HOME_DIRECTORY = process.env.HOME ?? process.env.USERPROFILE ?? null;
const FACT_QUERIES = {
  buildVersion: ['const.product.software.version'],
  apiVersion: ['const.ohos.apiversion', 'const.product.apiversion'],
  abi: ['const.product.cpu.abilist'],
  model: ['const.product.model']
};
const HDC_HELP_PATTERNS = [
  /(^|\n)\s*-t\s+connectkey(\s|$)/iu,
  /(^|\n)\s*list\s+targets\s+\[-v\](\s|$)/iu,
  /(^|\n)\s*install\s+\[-r\|-s\|-cwd\|option\]\s+src(\s|$)/iu,
  /(^|\n)\s*shell\s+\[-b\s+bundlename\]\s+\[COMMAND\.\.\.\](\s|$)/iu
];
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

function createFailure(code, detail, extra = {}) {
  return {
    code,
    detail,
    ...extra
  };
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

function createStep(result = 'not-run') {
  return {
    result,
    command: null,
    exitCode: null,
    stdout: '',
    stderr: ''
  };
}

function isTimedOutCommandResult(result) {
  return result?.timedOut === true || result?.error?.code === 'HDC_TIMEOUT';
}

function createHdcTimeoutFailure(stage, detail = `hdc ${stage} exceeded the timeout and was terminated.`) {
  return createFailure('HDC_TIMEOUT', detail, { stage });
}

function createBaseProof({ repoRoot, outputPath, startedAt }) {
  return {
    schemaVersion: PROOF_SCHEMA_VERSION,
    phase: PHASE_NUMBER,
    result: 'incomplete',
    outputPath: normalizePathForReport(repoRoot, outputPath),
    bundle: BUNDLE_NAME,
    ability: ENTRY_ABILITY_NAME,
    timestamps: {
      startedAt: isoTimestamp(startedAt),
      completedAt: null
    },
    toolchain: { ...DEFAULT_TOOLCHAIN },
    hap: {
      path: null,
      sha256: null,
      sizeBytes: null
    },
    device: {
      identityMasked: null,
      buildVersion: null,
      apiVersion: null,
      abi: null,
      model: null
    },
    build: createStep('incomplete'),
    install: createStep('not-run'),
    launch: createStep('not-run'),
    cleanup: {
      forceStop: createStep('pass')
    },
    targetDiscovery: {
      command: ['hdc', 'list', 'targets'],
      count: 0,
      identitiesMasked: []
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
      ...DEFAULT_TOOLCHAIN,
      devecoVersion: lock?.installed?.devecoVersion ?? null,
      sdkVersion: lock?.installed?.sdkVersion ?? null,
      ndkVersion: lock?.installed?.ndkVersion ?? null,
      hvigorVersion: lock?.installed?.hvigorVersion ?? null,
      ohpmVersion: lock?.installed?.ohpmVersion ?? null,
      hdcVersion: lock?.installed?.hdcVersion ?? null
    };
  } catch {
    return { ...DEFAULT_TOOLCHAIN };
  }
}

export function createMaskedDeviceIdentity(serial) {
  return `target-${crypto.createHash('sha256').update(String(serial)).digest('hex').slice(0, 8)}`;
}

function sanitizeOutput(raw, replacements = new Map()) {
  let sanitized = String(raw ?? '');
  for (const [value, replacement] of replacements.entries()) {
    if (!value) {
      continue;
    }

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
    return sanitizeOutput(normalizePathForReport(repoRoot, value), replacements);
  }

  return sanitizeOutput(value, replacements);
}

function sanitizeForPersistence(value, replacements = new Map()) {
  if (typeof value === 'string') {
    return sanitizeOutput(value, replacements);
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

async function hashFile(fsApi, filePath) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

function isUnsignedHapPath(filePath) {
  return /-unsigned\.hap$/iu.test(path.basename(filePath));
}

function matchesFailureMarker(text) {
  return /\b(fail(?:ed|ure)?|error|invalid|denied|not found|exception|unable to|missing)\b/iu.test(text);
}

function matchesInstallSuccessMarker(text) {
  return /\b(success|successfully)\b/iu.test(text);
}

function matchesLaunchSuccessMarker(text) {
  return /\b(start ability successfully|successfully started|ability started successfully|start success)\b/iu.test(text);
}

export async function execCommand(
  command,
  args,
  {
    cwd,
    env = process.env,
    timeoutMs = DEFAULT_HDC_COMMAND_TIMEOUT_MS,
    execFileImpl = execFileCallback
  } = {}
) {
  return await new Promise((resolve) => {
    let settled = false;
    let timeoutId = null;

    const cleanup = () => {
      if (timeoutId) {
        clearTimeout(timeoutId);
        timeoutId = null;
      }
    };

    const finalize = ({
      exitCode = null,
      stdout = '',
      stderr = '',
      error = null,
      signal = null,
      timedOut = false
    }) => {
      if (settled) {
        return;
      }

      settled = true;
      cleanup();
      resolve({
        command,
        args: [...args],
        exitCode,
        stdout,
        stderr,
        error,
        signal,
        timedOut
      });
    };

    let child;
    try {
      child = execFileImpl(command, args, {
        cwd,
        env,
        shell: false,
        windowsHide: true,
        maxBuffer: 10 * 1024 * 1024
      }, (error, stdout, stderr) => {
        finalize({
          exitCode: error && typeof error.code === 'number' ? error.code : 0,
          stdout: stdout ?? error?.stdout ?? '',
          stderr: stderr ?? error?.stderr ?? '',
          error: error ?? null,
          signal: error?.signal ?? null,
          timedOut: error?.code === 'HDC_TIMEOUT'
        });
      });
    } catch (error) {
      finalize({
        exitCode: typeof error.code === 'number' ? error.code : null,
        stdout: error.stdout ?? '',
        stderr: error.stderr ?? '',
        error
      });
      return;
    }

    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      timeoutId = setTimeout(() => {
        const timeoutError = new Error(`Command timed out after ${timeoutMs} ms.`);
        timeoutError.code = 'HDC_TIMEOUT';
        try {
          child?.kill?.('SIGTERM');
        } catch {
          // Best effort only; timeout should still resolve deterministically.
        }

        finalize({
          exitCode: null,
          stdout: '',
          stderr: '',
          error: timeoutError,
          signal: 'SIGTERM',
          timedOut: true
        });
      }, timeoutMs);
    }
  });
}

async function resolveHdcCommand({ harmonyRoot, fsApi = fs }) {
  const requirementsPath = path.join(harmonyRoot, 'toolchain.requirements.json');

  try {
    const requirements = JSON.parse(await fsApi.readFile(requirementsPath, 'utf8'));
    const hdcRelativePath = requirements?.files?.hdc;
    for (const sdkRoot of requirements?.defaults?.sdkRoots ?? []) {
      const candidatePath = path.join(sdkRoot, hdcRelativePath);

      try {
        await fsApi.access(candidatePath);
        return candidatePath;
      } catch {
        continue;
      }
    }
  } catch {
    // Fall back to PATH lookup below.
  }

  return 'hdc';
}

async function discoverHdcHelp({ hdcCommand, cwd, execImpl = execCommand }) {
  for (const args of [['help'], ['-h'], ['--help']]) {
    const result = await execImpl(hdcCommand, args, { cwd });
    if (isTimedOutCommandResult(result)) {
      return {
        ok: false,
        failure: createHdcTimeoutFailure('toolchain', 'hdc help exceeded the timeout and was terminated.'),
        result
      };
    }

    const combined = `${result.stdout}\n${result.stderr}`;
    if (result.error && result.error.code === 'ENOENT') {
      return {
        ok: false,
        failure: createFailure('TOOL_MISSING', 'hdc is not installed or not on PATH.', { stage: 'toolchain' }),
        result
      };
    }

    if (HDC_HELP_PATTERNS.every((pattern) => pattern.test(combined))) {
      return {
        ok: true,
        result
      };
    }
  }

  return {
    ok: false,
    failure: createFailure('HDC_HELP_UNSUPPORTED', 'Installed hdc help output does not confirm the required Phase 0 commands.', { stage: 'toolchain' }),
    result: null
  };
}

function parseTargetList(raw) {
  return String(raw ?? '')
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line && !/^list targets/iu.test(line) && !/^attached devices/iu.test(line) && !/^found /iu.test(line) && !/^\[?empty\]?$/iu.test(line));
}

export function analyzeTargetDiscovery({ stdout = '', stderr = '', exitCode = null }) {
  const combined = `${stdout}\n${stderr}`.trim();
  if (/connect server failed/iu.test(combined)) {
    return {
      kind: 'connection-failed',
      targets: []
    };
  }

  const targets = parseTargetList(stdout);
  if (exitCode !== 0 || targets.length === 0) {
    return {
      kind: 'missing',
      targets: []
    };
  }

  if (targets.length === 1) {
    return {
      kind: 'selected',
      targets
    };
  }

  return {
    kind: 'ambiguous',
    targets
  };
}

export function buildTargetedHdcArgs(target, args) {
  if (!target) {
    return [...args];
  }

  return ['-t', target, ...args];
}

async function readDeviceFact({ hdcCommand, target, cwd, keyCandidates, execImpl = execCommand, replacements }) {
  for (const key of keyCandidates) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    if (isTimedOutCommandResult(result)) {
      return {
        timedOut: true,
        command: [hdcCommand, ...buildTargetedHdcArgs(target, ['shell', 'param', 'get', key])],
        exitCode: result.exitCode,
        stdout: sanitizeOutput(result.stdout, replacements),
        stderr: sanitizeOutput(result.stderr, replacements)
      };
    }

    const value = sanitizeOutput(result.stdout, replacements).trim();

    if (!result.error && value && !/^unknown$/iu.test(value) && !/^null$/iu.test(value)) {
      return {
        value,
        command: [hdcCommand, ...buildTargetedHdcArgs(target, ['shell', 'param', 'get', key])],
        exitCode: result.exitCode,
        stdout: sanitizeOutput(result.stdout, replacements),
        stderr: sanitizeOutput(result.stderr, replacements)
      };
    }
  }

  return null;
}

function buildStepFromCommand(result, repoRoot, replacements = new Map(), stepKind = 'generic') {
  const combined = sanitizeOutput(`${result.stdout}\n${result.stderr}`, replacements);
  let stepResult = 'pass';

  if (/connect server failed/iu.test(combined)) {
    stepResult = 'incomplete';
  } else if (isTimedOutCommandResult(result)) {
    stepResult = 'incomplete';
  } else if (stepKind === 'install' && matchesFailureMarker(combined) && !matchesInstallSuccessMarker(combined)) {
    stepResult = 'fail';
  } else if (stepKind === 'launch' && matchesFailureMarker(combined) && !matchesLaunchSuccessMarker(combined)) {
    stepResult = 'fail';
  } else if (stepKind === 'cleanup' && matchesFailureMarker(combined)) {
    stepResult = 'fail';
  } else if (result.error || result.exitCode !== 0) {
    stepResult = 'fail';
  }

  return {
    result: stepResult,
    command: [result.command, ...result.args].map((entry) => sanitizeCommandValue(entry, repoRoot, replacements)),
    exitCode: result.exitCode,
    stdout: sanitizeOutput(result.stdout, replacements),
    stderr: sanitizeOutput(result.stderr, replacements)
  };
}

function classifyInstallFailure(step, commandResult) {
  const combined = `${step.stdout}\n${step.stderr}`.toLowerCase();
  if (isTimedOutCommandResult(commandResult)) {
    return {
      result: 'incomplete',
      failure: createHdcTimeoutFailure('install', 'hdc install exceeded the timeout and was terminated.')
    };
  }

  if (/\bconnect server failed\b/u.test(combined)) {
    return {
      result: 'incomplete',
      failure: createFailure('DEVICE_CONNECTION_FAILED', 'hdc lost its connection to the device server during install.', { stage: 'install' })
    };
  }

  if (/\bsign(?:ing|ature)?\b/u.test(combined) || /\bcertificate\b/u.test(combined)) {
    return {
      result: 'incomplete',
      failure: createFailure('SIGNING_REQUIRED', 'A signed debug HAP is required before the device install step can pass.', { stage: 'install' })
    };
  }

  if (/\bno target\b/u.test(combined) || /\bdevice\b/u.test(combined) && /\bnot\b/u.test(combined)) {
    return {
      result: 'incomplete',
      failure: createFailure('DEVICE_TARGET_MISSING', 'No authorized HarmonyOS device target was available during install.', { stage: 'install' })
    };
  }

  return {
    result: 'fail',
    failure: createFailure('INSTALL_FAILED', 'hdc app install -r failed.', { stage: 'install' })
  };
}

function classifyForceStopFailure(step, commandResult) {
  if (isTimedOutCommandResult(commandResult)) {
    return createHdcTimeoutFailure('cleanup', 'hdc shell aa force-stop exceeded the timeout and was terminated.');
  }

  const combined = `${step.stdout}\n${step.stderr}`.toLowerCase();
  if (/\bconnect server failed\b/u.test(combined)) {
    return createFailure('DEVICE_CONNECTION_FAILED', 'hdc lost its connection to the device server during force-stop.', { stage: 'cleanup' });
  }

  return createFailure('FORCE_STOP_FAILED', 'hdc shell aa force-stop failed.', { stage: 'cleanup' });
}

function buildBuildStepFromEvidence(evidence) {
  const moduleCommand = evidence?.commands?.find((entry) => entry.stage === 'module') ?? evidence?.commands?.[0] ?? null;

  return {
    result: evidence?.result === 'pass' ? 'pass' : 'incomplete',
    command: moduleCommand?.command ?? null,
    exitCode: moduleCommand?.exitCode ?? null,
    stdout: moduleCommand?.stdout ?? '',
    stderr: moduleCommand?.stderr ?? ''
  };
}

function validateBuildEvidenceObject({
  evidence,
  buildEvidencePath,
  repoRoot,
  expectedHapPath,
  expectedSha256
}) {
  if (evidence?.result !== 'pass' || evidence?.schemaVersion !== '1.0.0' || evidence?.phase !== 0) {
    return {
      ok: false,
      failure: createFailure('BUILD_EVIDENCE_INVALID', 'Build evidence must be a verified Phase 0 pass report before device proof can continue.', { stage: 'build' })
    };
  }

  if (evidence?.hap?.path !== expectedHapPath || evidence?.hap?.sha256 !== expectedSha256) {
    return {
      ok: false,
      failure: createFailure('BUILD_EVIDENCE_MISMATCH', 'Build evidence does not match the requested HAP path and SHA-256 digest.', { stage: 'build' })
    };
  }

  return {
    ok: true,
    evidence,
    buildStep: buildBuildStepFromEvidence(evidence),
    persistedPath: normalizePathForReport(repoRoot, buildEvidencePath)
  };
}

async function loadBuildEvidence({
  fsApi = fs,
  buildEvidencePath = DEFAULT_BUILD_EVIDENCE_PATH,
  repoRoot,
  expectedHapPath,
  expectedSha256
}) {
  let raw;

  try {
    raw = await fsApi.readFile(buildEvidencePath, 'utf8');
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return {
        ok: false,
        failure: createFailure('BUILD_EVIDENCE_MISSING', 'The verified Phase 0 build evidence file is missing.', { stage: 'build' })
      };
    }

    return {
      ok: false,
      failure: createFailure('BUILD_EVIDENCE_INVALID', `Unable to read build evidence: ${error?.message ?? 'unknown error'}`, { stage: 'build' })
    };
  }

  let evidence;
  try {
    evidence = JSON.parse(raw);
  } catch (error) {
    return {
      ok: false,
      failure: createFailure('BUILD_EVIDENCE_INVALID', `Build evidence is not valid JSON: ${error?.message ?? 'unknown error'}`, { stage: 'build' })
    };
  }

  return validateBuildEvidenceObject({
    evidence,
    buildEvidencePath,
    repoRoot,
    expectedHapPath,
    expectedSha256
  });
}

function finalizeProof(proof) {
  if (proof.result === 'pass') {
    return proof;
  }

  const failureCodes = new Set(proof.failures.map((entry) => entry.code));
  if (
    failureCodes.has('BUILD_EVIDENCE_MISSING') ||
    failureCodes.has('BUILD_EVIDENCE_INVALID') ||
    failureCodes.has('BUILD_EVIDENCE_MISMATCH') ||
    failureCodes.has('INPUT_HAP_MISSING') ||
    failureCodes.has('INPUT_HAP_INVALID') ||
    failureCodes.has('INPUT_HAP_UNSIGNED') ||
    failureCodes.has('DEVICE_CONNECTION_FAILED') ||
    failureCodes.has('DEVICE_TARGET_MISSING') ||
    failureCodes.has('DEVICE_TARGET_AMBIGUOUS') ||
    failureCodes.has('SIGNING_REQUIRED') ||
    failureCodes.has('TOOL_MISSING') ||
    failureCodes.has('HDC_HELP_UNSUPPORTED') ||
    failureCodes.has('HDC_TIMEOUT') ||
    failureCodes.has('DEVICE_BUILD_VERSION_MISSING')
  ) {
    proof.result = 'incomplete';
    return proof;
  }

  proof.result = 'fail';
  return proof;
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

export function validatePhase0Proof(proof, options = {}) {
  const errors = [];
  const schema = options.schema ?? null;

  if (schema && schema.schemaVersion && schema.schemaVersion !== proof?.schemaVersion) {
    errors.push('schemaVersion does not match the provided schema.');
  }

  if (proof?.schemaVersion !== PROOF_SCHEMA_VERSION) {
    errors.push(`schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  }

  if (proof?.phase !== PHASE_NUMBER) {
    errors.push('phase must be 0.');
  }

  if (!FINAL_RESULTS.has(proof?.result)) {
    errors.push('result must be pass, fail, or incomplete.');
  }

  if (proof?.bundle !== BUNDLE_NAME) {
    errors.push(`bundle must be ${BUNDLE_NAME}.`);
  }

  if (proof?.ability !== ENTRY_ABILITY_NAME) {
    errors.push(`ability must be ${ENTRY_ABILITY_NAME}.`);
  }

  const startedAt = proof?.timestamps?.startedAt;
  const completedAt = proof?.timestamps?.completedAt;
  if (!isIsoTimestamp(startedAt) || !isIsoTimestamp(completedAt)) {
    errors.push('timestamps.startedAt and timestamps.completedAt must be ISO-8601 strings.');
  } else if (Date.parse(completedAt) < Date.parse(startedAt)) {
    errors.push('timestamps.completedAt must not be earlier than timestamps.startedAt.');
  }

  for (const key of ['nodeVersion', 'hvigorVersion', 'ohpmVersion', 'hdcVersion', 'devecoVersion', 'sdkVersion', 'ndkVersion']) {
    if (!isNonEmptyString(proof?.toolchain?.[key])) {
      errors.push(`toolchain.${key} must be a non-empty string.`);
    }
  }

  const requiresConcreteHap = proof?.result === 'pass' || proof?.build?.result === 'pass';
  if (requiresConcreteHap) {
    if (!isNonEmptyString(proof?.hap?.path)) {
      errors.push('hap.path must be present.');
    }

    if (!/^[a-f0-9]{64}$/u.test(String(proof?.hap?.sha256 ?? ''))) {
      errors.push('hap.sha256 must be a 64-character lowercase hex digest.');
    }
  } else {
    if (proof?.hap?.path !== null && !isNonEmptyString(proof?.hap?.path)) {
      errors.push('hap.path must be null or a non-empty string.');
    }

    if (proof?.hap?.sha256 !== null && !/^[a-f0-9]{64}$/u.test(String(proof?.hap?.sha256 ?? ''))) {
      errors.push('hap.sha256 must be null or a 64-character lowercase hex digest.');
    }
  }

  if ('serial' in (proof?.device ?? {})) {
    errors.push('device.serial must not be present in the proof.');
  }

  if (proof?.device?.identityMasked !== null && !/^target-[a-f0-9]{8}$/u.test(String(proof?.device?.identityMasked ?? ''))) {
    errors.push('device.identityMasked must be null or a deterministic masked target hash.');
  }

  for (const key of ['build', 'install', 'launch']) {
    if (!STEP_RESULTS.has(proof?.[key]?.result)) {
      errors.push(`${key}.result must be pass, fail, incomplete, or not-run.`);
    }
  }

  if (!['pass', 'fail', 'incomplete'].includes(String(proof?.cleanup?.forceStop?.result ?? ''))) {
    errors.push('cleanup.forceStop.result must be pass, fail, or incomplete.');
  }

  const requiresIncomplete = new Set(['BUILD_EVIDENCE_MISSING', 'BUILD_EVIDENCE_INVALID', 'BUILD_EVIDENCE_MISMATCH', 'INPUT_HAP_MISSING', 'INPUT_HAP_INVALID', 'INPUT_HAP_UNSIGNED', 'DEVICE_CONNECTION_FAILED', 'DEVICE_TARGET_MISSING', 'DEVICE_TARGET_AMBIGUOUS', 'SIGNING_REQUIRED', 'TOOL_MISSING', 'HDC_HELP_UNSUPPORTED', 'HDC_TIMEOUT', 'DEVICE_BUILD_VERSION_MISSING']);
  const failureCodes = new Set((proof?.failures ?? []).map((entry) => entry.code));

  if (proof?.result === 'pass') {
    if (proof?.build?.result !== 'pass' || proof?.install?.result !== 'pass' || proof?.launch?.result !== 'pass') {
      errors.push('result pass requires build, install, and launch to all be pass.');
    }

    if (proof?.cleanup?.forceStop?.result !== 'pass') {
      errors.push('result pass requires cleanup.forceStop to be pass.');
    }

    if (!isNonEmptyString(proof?.device?.identityMasked) || !isNonEmptyString(proof?.device?.buildVersion)) {
      errors.push('result pass requires a masked device identity and exact device build version.');
    }

    if ((proof?.failures ?? []).length > 0) {
      errors.push('result pass must not include failures.');
    }
  }

  if (proof?.result !== 'incomplete' && [...failureCodes].some((code) => requiresIncomplete.has(code))) {
    errors.push('device/signing/input/tool availability blockers must produce result incomplete.');
  }

  if (!Array.isArray(proof?.failures)) {
    errors.push('failures must be an array.');
  }

  return {
    valid: errors.length === 0,
    errors
  };
}

export async function writeProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs) {
  await fsApi.mkdir(path.dirname(outputPath), { recursive: true });
  await fsApi.writeFile(outputPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
}

export async function runPhase0DeviceProof({
  hapPath,
  outputPath = DEFAULT_OUTPUT_PATH,
  buildEvidencePath = null,
  buildEvidence = null,
  harmonyRoot = HARMONY_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  now = () => new Date()
} = {}) {
  const repoRoot = path.resolve(harmonyRoot, '..');
  const resolvedBuildEvidencePath = buildEvidencePath ?? path.join(harmonyRoot, 'artifacts', 'phase0-build-evidence.json');
  const startedAt = now();
  const proof = createBaseProof({ repoRoot, outputPath, startedAt });
  const baseReplacements = createReplacements(repoRoot);
  proof.toolchain = await readToolchainVersions({ fsApi, harmonyRoot });
  const hdcCommand = await resolveHdcCommand({ harmonyRoot, fsApi });

  const absoluteHapPath = hapPath
    ? (path.isAbsolute(hapPath) ? hapPath : path.resolve(repoRoot, hapPath))
    : null;

  if (!absoluteHapPath) {
    proof.failures.push(createFailure('INPUT_HAP_MISSING', 'The --hap argument must point to an actual signed debug HAP.', { stage: 'build' }));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  proof.hap.path = normalizePathForReport(repoRoot, absoluteHapPath);

  try {
    const digest = await hashFile(fsApi, absoluteHapPath);
    proof.hap.sha256 = digest.sha256;
    proof.hap.sizeBytes = digest.sizeBytes;
  } catch (error) {
    proof.failures.push(createFailure(
      'INPUT_HAP_INVALID',
      sanitizeOutput(`Unable to read HAP input: ${error?.message ?? 'unknown error'}`, baseReplacements),
      { stage: 'build' }
    ));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  if (isUnsignedHapPath(absoluteHapPath)) {
    proof.build.result = 'incomplete';
    proof.failures.push(createFailure('INPUT_HAP_UNSIGNED', 'The provided HAP is unsigned and cannot be installed on a device proof lane.', { stage: 'build' }));
    proof.failures.push(createFailure('SIGNING_REQUIRED', 'A signed debug HAP is required before the device proof runner can attempt install.', { stage: 'build' }));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  const buildEvidenceCheck = buildEvidence
    ? validateBuildEvidenceObject({
      evidence: buildEvidence,
      buildEvidencePath: resolvedBuildEvidencePath,
      repoRoot,
      expectedHapPath: proof.hap.path,
      expectedSha256: proof.hap.sha256
    })
    : await loadBuildEvidence({
      fsApi,
      buildEvidencePath: resolvedBuildEvidencePath,
      repoRoot,
      expectedHapPath: proof.hap.path,
      expectedSha256: proof.hap.sha256
    });

  if (!buildEvidenceCheck.ok) {
    proof.failures.push(createFailure(
      buildEvidenceCheck.failure.code,
      sanitizeOutput(buildEvidenceCheck.failure.detail, baseReplacements),
      { stage: buildEvidenceCheck.failure.stage }
    ));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  proof.build = buildEvidenceCheck.buildStep;

  const help = await discoverHdcHelp({ hdcCommand, cwd: harmonyRoot, execImpl });
  if (!help.ok) {
    proof.failures.push(help.failure);
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: harmonyRoot });
  if (isTimedOutCommandResult(targetsResult)) {
    proof.failures.push(createHdcTimeoutFailure('device', 'hdc list targets exceeded the timeout and was terminated.'));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), baseReplacements);
  }

  const analysis = analyzeTargetDiscovery(targetsResult);
  const maskedTargets = analysis.targets.map((serial) => createMaskedDeviceIdentity(serial));
  const replacements = createReplacements(repoRoot, analysis.targets.map((serial, index) => [serial, maskedTargets[index]]));

  proof.targetDiscovery = {
    command: [hdcCommand, 'list', 'targets'].map((entry) => sanitizeCommandValue(entry, repoRoot, replacements)),
    count: analysis.targets.length,
    identitiesMasked: maskedTargets
  };

  if (analysis.kind === 'connection-failed') {
    proof.failures.push(createFailure('DEVICE_CONNECTION_FAILED', 'hdc could not connect to its server; the device proof is incomplete.', { stage: 'device' }));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), replacements);
  }

  if (targetsResult.error || analysis.kind === 'missing') {
    proof.failures.push(createFailure('DEVICE_TARGET_MISSING', 'hdc list targets failed to enumerate an authorized device target.', { stage: 'device' }));
    proof.timestamps.completedAt = isoTimestamp(now());
    return sanitizeForPersistence(finalizeProof(proof), replacements);
  }

  if (analysis.kind === 'ambiguous') {
    proof.failures.push(createFailure('DEVICE_TARGET_AMBIGUOUS', 'Exactly one authorized HarmonyOS device target is required.', { stage: 'device' }));
    proof.timestamps.completedAt = isoTimestamp(now());
    return finalizeProof(proof);
  }

  const rawTarget = analysis.targets[0];
  proof.device.identityMasked = maskedTargets[0];

  const buildVersionFact = await readDeviceFact({ hdcCommand, target: rawTarget, cwd: harmonyRoot, keyCandidates: FACT_QUERIES.buildVersion, execImpl, replacements });
  const apiVersionFact = await readDeviceFact({ hdcCommand, target: rawTarget, cwd: harmonyRoot, keyCandidates: FACT_QUERIES.apiVersion, execImpl, replacements });
  const abiFact = await readDeviceFact({ hdcCommand, target: rawTarget, cwd: harmonyRoot, keyCandidates: FACT_QUERIES.abi, execImpl, replacements });
  const modelFact = await readDeviceFact({ hdcCommand, target: rawTarget, cwd: harmonyRoot, keyCandidates: FACT_QUERIES.model, execImpl, replacements });

  proof.device.buildVersion = buildVersionFact?.value ?? null;
  proof.device.apiVersion = apiVersionFact?.value ?? null;
  proof.device.abi = abiFact?.value ?? null;
  proof.device.model = modelFact?.value ?? null;

  if (buildVersionFact?.timedOut || apiVersionFact?.timedOut || abiFact?.timedOut || modelFact?.timedOut) {
    proof.failures.push(createHdcTimeoutFailure('device', 'hdc device fact queries exceeded the timeout and were terminated.'));
  }

  if (!isNonEmptyString(proof.device.buildVersion)) {
    proof.failures.push(createFailure('DEVICE_BUILD_VERSION_MISSING', 'Unable to query the exact HarmonyOS device build version.', { stage: 'device' }));
  }

  const installResult = await execImpl(hdcCommand, buildTargetedHdcArgs(rawTarget, ['install', '-r', absoluteHapPath]), { cwd: harmonyRoot });
  proof.install = buildStepFromCommand(installResult, repoRoot, replacements, 'install');

  if (proof.install.result !== 'pass') {
    const classification = classifyInstallFailure(proof.install, installResult);
    proof.install.result = classification.result === 'fail' ? 'fail' : 'incomplete';
    proof.failures.push(classification.failure);
    proof.timestamps.completedAt = isoTimestamp(now());

    const forceStopResult = await execImpl(hdcCommand, buildTargetedHdcArgs(rawTarget, ['shell', 'aa', 'force-stop', BUNDLE_NAME]), { cwd: harmonyRoot });
    proof.cleanup.forceStop = buildStepFromCommand(forceStopResult, repoRoot, replacements, 'cleanup');
    return finalizeProof(proof);
  }

  const launchResult = await execImpl(hdcCommand, buildTargetedHdcArgs(rawTarget, ['shell', 'aa', 'start', '-a', ENTRY_ABILITY_NAME, '-b', BUNDLE_NAME]), { cwd: harmonyRoot });
  proof.launch = buildStepFromCommand(launchResult, repoRoot, replacements, 'launch');

  const forceStopResult = await execImpl(hdcCommand, buildTargetedHdcArgs(rawTarget, ['shell', 'aa', 'force-stop', BUNDLE_NAME]), { cwd: harmonyRoot });
  proof.cleanup.forceStop = buildStepFromCommand(forceStopResult, repoRoot, replacements, 'cleanup');

  if (proof.launch.result !== 'pass') {
    const combined = `${proof.launch.stdout}\n${proof.launch.stderr}`.toLowerCase();
    if (isTimedOutCommandResult(launchResult)) {
      proof.failures.push(createHdcTimeoutFailure('launch', 'hdc shell aa start exceeded the timeout and was terminated.'));
    } else if (/\bconnect server failed\b/u.test(combined)) {
      proof.failures.push(createFailure('DEVICE_CONNECTION_FAILED', 'hdc lost its connection to the device server during launch.', { stage: 'launch' }));
    } else {
      proof.failures.push(createFailure('LAUNCH_FAILED', 'hdc shell aa start failed.', { stage: 'launch' }));
    }
    proof.timestamps.completedAt = isoTimestamp(now());
    return finalizeProof(proof);
  }

  if (proof.cleanup.forceStop.result !== 'pass') {
    proof.failures.push(classifyForceStopFailure(proof.cleanup.forceStop, forceStopResult));
    proof.timestamps.completedAt = isoTimestamp(now());
    return finalizeProof(proof);
  }

  proof.timestamps.completedAt = isoTimestamp(now());
  proof.result = proof.failures.length === 0 ? 'pass' : 'incomplete';
  return sanitizeForPersistence(finalizeProof(proof), replacements);
}

export function parseCliArguments(argv, repoRoot) {
  let hapPath = null;
  let outputPath = DEFAULT_OUTPUT_PATH;
  let buildEvidencePath = DEFAULT_BUILD_EVIDENCE_PATH;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--hap') {
      hapPath = argv[index + 1] ?? null;
      index += 1;
      continue;
    }

    if (arg === '--out') {
      const next = argv[index + 1] ?? null;
      outputPath = next ? (path.isAbsolute(next) ? next : path.resolve(repoRoot, next)) : outputPath;
      index += 1;
      continue;
    }

    if (arg === '--build-evidence') {
      const next = argv[index + 1] ?? null;
      buildEvidencePath = next ? (path.isAbsolute(next) ? next : path.resolve(repoRoot, next)) : buildEvidencePath;
      index += 1;
    }
  }

  return { hapPath, outputPath, buildEvidencePath };
}

function isDirectExecution() {
  if (!process.argv[1]) {
    return false;
  }

  return pathToFileURL(process.argv[1]).href === import.meta.url;
}

function createFatalProof({ repoRoot, outputPath, error, startedAt = new Date() }) {
  const proof = createBaseProof({
    repoRoot,
    outputPath,
    startedAt
  });

  proof.failures.push(createFailure(error?.code ?? 'PHASE0_PROOF_FATAL', error?.message ?? 'Unknown fatal proof error', { stage: 'proof' }));
  proof.timestamps.completedAt = isoTimestamp(new Date());
  return proof;
}

export async function runCli({
  argv = process.argv.slice(2),
  repoRoot = REPO_ROOT,
  buildHapImpl = buildHap,
  writeBuildEvidenceImpl = writeBuildEvidence,
  runPhase0DeviceProofImpl = runPhase0DeviceProof,
  writeProofImpl = writeProof
} = {}) {
  const { hapPath, outputPath, buildEvidencePath } = parseCliArguments(argv, repoRoot);
  const harmonyRoot = path.join(repoRoot, 'harmony');

  try {
    const buildEvidence = await buildHapImpl({ harmonyRoot, outputPath: buildEvidencePath });
    await writeBuildEvidenceImpl(buildEvidence, buildEvidencePath);
    const proof = await runPhase0DeviceProofImpl({ hapPath, outputPath, buildEvidencePath, buildEvidence, harmonyRoot });
    await writeProofImpl(proof, outputPath);
    return proof.result === 'pass' ? 0 : 2;
  } catch (error) {
    const proof = createFatalProof({ repoRoot, outputPath, error });
    await writeProofImpl(proof, outputPath);
    return 2;
  }
}

async function main() {
  process.exitCode = await runCli();
}

if (isDirectExecution()) {
  main();
}
