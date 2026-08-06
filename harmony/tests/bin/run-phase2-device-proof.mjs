import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { normalizeNodeVersion } from '../../tools/lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeForPersistence, sanitizeText } from '../../tools/lib/proof-redaction.mjs';
import { inspectHap } from './inspect-hap.mjs';

export const PROOF_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 2;
export const BUNDLE_NAME = 'com.github.kr328.clash.harmony';
export const ENTRY_ABILITY_NAME = 'EntryAbility';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase2-device-proof.json');
export const DEFAULT_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');
const DEFAULT_FIXTURE_PATHS = Object.freeze({
  matchConfig: path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase2-match-direct.yaml'),
  originBody: path.join(HARMONY_ROOT, 'tests', 'fixtures', 'origin-body.txt')
});
const DIGEST_PATTERN = /^[a-f0-9]{64}$/u;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const FINAL_RESULTS = new Set(['pass', 'fail', 'incomplete']);
const PROBE_RESULTS = new Set(['pass', 'fail', 'incomplete', 'not-run']);

function isoTimestamp(date = new Date()) {
  return date.toISOString();
}

function createFailure(code, detail, stage = 'proof') {
  return { code, detail, stage };
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isUuid(value) {
  return UUID_PATTERN.test(String(value ?? ''));
}

function isDigest(value) {
  return value === null || DIGEST_PATTERN.test(String(value ?? ''));
}

function isWithinRepo(repoRoot, filePath) {
  const relativePath = path.relative(repoRoot, filePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
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

async function resolveExistingRepoScopedPath(fsApi, repoRoot, filePath, option) {
  const resolved = path.resolve(filePath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error(`${option} must stay inside the repository root.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  const [realRepoRoot, realFilePath] = await Promise.all([
    fsApi.realpath(repoRoot),
    fsApi.realpath(resolved)
  ]);
  if (!isWithinRepo(realRepoRoot, realFilePath) || realFilePath === realRepoRoot) {
    throw Object.assign(new Error(`${option} resolves outside the repository through a symlink.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return realFilePath;
}

async function resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath) {
  const resolved = path.resolve(outputPath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error('--out must stay inside the repository root.'), { code: 'PATH_OUTSIDE_REPO' });
  }
  const realRepoRoot = await fsApi.realpath(repoRoot);
  await fsApi.mkdir(path.dirname(resolved), { recursive: true });
  const realParent = await fsApi.realpath(path.dirname(resolved));
  if (!isWithinRepo(realRepoRoot, realParent) || realParent === realRepoRoot) {
    throw Object.assign(new Error('--out resolves outside the repository through a symlink.'), { code: 'PATH_OUTSIDE_REPO' });
  }
  try {
    const stats = await fsApi.lstat(resolved);
    if (stats.isSymbolicLink()) {
      throw Object.assign(new Error('--out must not be a symlink.'), { code: 'PATH_OUTSIDE_REPO' });
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }
  return path.join(realParent, path.basename(resolved));
}

async function hashFile(fsApi, filePath) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

async function hashOptionalRepoFile(fsApi, repoRoot, filePath) {
  try {
    const resolved = await resolveExistingRepoScopedPath(fsApi, repoRoot, filePath, '--fixture');
    const digest = await hashFile(fsApi, resolved);
    return {
      path: normalizePathForReport(repoRoot, resolved),
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes
    };
  } catch {
    return {
      path: normalizePathForReport(repoRoot, path.resolve(filePath)),
      sha256: null,
      sizeBytes: null
    };
  }
}

function createProbe(protocol, runId, errorCode, detail) {
  return {
    protocol,
    status: 'not-run',
    runId,
    probeRunId: null,
    requestId: null,
    originRequestId: null,
    appProbeId: null,
    coreEventId: null,
    originId: null,
    appProcessId: null,
    coreConnectionId: null,
    clientSourcePort: null,
    destination: null,
    upstreamInboundType: null,
    listenerAddress: null,
    tlsPeerSha256: null,
    httpStatus: null,
    responseBytes: null,
    responseSha256: null,
    startedAt: null,
    completedAt: null,
    error: {
      code: errorCode,
      stage: 'target',
      detail
    }
  };
}

function createBaseProof({ repoRoot, outputPath, runId, startedAt }) {
  return {
    schemaVersion: PROOF_SCHEMA_VERSION,
    phase: PHASE_NUMBER,
    result: 'incomplete',
    runId,
    outputPath: normalizePathForReport(repoRoot, outputPath) ?? 'harmony/artifacts/phase2-device-proof.json',
    bundle: BUNDLE_NAME,
    ability: ENTRY_ABILITY_NAME,
    timestamps: {
      runnerStartedAt: isoTimestamp(startedAt),
      appStartedAt: null,
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
    device: {
      targetKind: 'host',
      identityMasked: null,
      model: null,
      product: null,
      buildVersion: null,
      apiVersion: null,
      abi: null
    },
    hap: {
      path: null,
      sha256: null,
      sizeBytes: null
    },
    packaged: {
      core: {
        path: null,
        sha256: null,
        sizeBytes: null
      },
      addon: {
        path: null,
        sha256: null,
        sizeBytes: null
      }
    },
    fixtures: {
      matchConfig: { path: null, sha256: null, sizeBytes: null },
      originBody: { path: null, sha256: null, sizeBytes: null }
    },
    origin: {
      originId: null,
      originUrl: null,
      bindAddress: null,
      tlsCertSha256: null,
      responseSha256: null
    },
    core: {
      version: null,
      httpListenerAddress: null,
      socksListenerAddress: null
    },
    stubDetection: {
      stubDetected: null,
      checks: [
        { id: 'manifestInspection', result: 'not-run', detail: 'A fresh self-test HAP inspection did not run.' },
        { id: 'nativeLibraryInspection', result: 'not-run', detail: 'No packaged AArch64 core was available for inspection.' }
      ]
    },
    appEvidence: {
      path: null,
      sha256: null,
      sizeBytes: null,
      runId: null,
      appProcessId: null,
      stopResult: null
    },
    probes: {
      http: createProbe('HTTP_CONNECT', runId, 'PHYSICAL_DEVICE_REQUIRED', 'Only a physical HarmonyOS 6 device can complete Phase 2.'),
      socks: createProbe('SOCKS5', runId, 'PHYSICAL_DEVICE_REQUIRED', 'Only a physical HarmonyOS 6 device can complete Phase 2.')
    },
    failures: []
  };
}

function pushFailure(proof, code, detail, stage) {
  proof.failures.push(createFailure(code, detail, stage));
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

function resultFromFailures(proof) {
  const hasActionableFailure = proof.failures.some((entry) => !['INPUT_HAP_MISSING', 'INPUT_HAP_UNSIGNED', 'SIGNING_REQUIRED', 'PHYSICAL_DEVICE_REQUIRED', 'DEVICE_TARGET_MISSING'].includes(entry.code));
  if (proof.stubDetection.stubDetected === true || hasActionableFailure) {
    return 'fail';
  }
  return 'incomplete';
}

export function validatePhase2Proof(proof) {
  const errors = [];
  if (proof?.schemaVersion !== PROOF_SCHEMA_VERSION) errors.push(`schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  if (proof?.phase !== PHASE_NUMBER) errors.push('phase must be 2.');
  if (!FINAL_RESULTS.has(proof?.result)) errors.push('result must be pass, fail, or incomplete.');
  if (!isUuid(proof?.runId)) errors.push('runId must be a UUID.');
  if (proof?.bundle !== BUNDLE_NAME || proof?.ability !== ENTRY_ABILITY_NAME) errors.push('bundle/ability identity mismatch.');
  if (typeof proof?.outputPath !== 'string' || proof.outputPath.length === 0) errors.push('outputPath must be non-empty.');

  const timestamps = proof?.timestamps ?? {};
  if (!isIsoTimestamp(timestamps.runnerStartedAt) || !isIsoTimestamp(timestamps.runnerFinishedAt)) {
    errors.push('runner timestamps must be ISO-8601 values.');
  }
  if (timestamps.appStartedAt !== null && !isIsoTimestamp(timestamps.appStartedAt)) {
    errors.push('appStartedAt must be null or ISO-8601.');
  }
  if (timestamps.proofAt !== null && !isIsoTimestamp(timestamps.proofAt)) {
    errors.push('proofAt must be null or ISO-8601.');
  }

  for (const key of ['devecoVersion', 'sdkVersion', 'ndkVersion', 'hvigorVersion', 'nodeVersion', 'hdcVersion']) {
    if (!(typeof proof?.toolchain?.[key] === 'string' || proof?.toolchain?.[key] === null)) {
      errors.push(`toolchain.${key} must be a string or null.`);
    }
  }

  if (!['physical', 'simulator', 'host', 'unknown'].includes(String(proof?.device?.targetKind ?? ''))) {
    errors.push('device.targetKind must be physical, simulator, host, or unknown.');
  }
  for (const artifact of [proof?.hap, proof?.packaged?.core, proof?.packaged?.addon, proof?.fixtures?.matchConfig, proof?.fixtures?.originBody]) {
    if (!artifact || !('path' in artifact) || !('sha256' in artifact) || !('sizeBytes' in artifact)) {
      errors.push('artifact entries must contain path, sha256, and sizeBytes.');
    } else if (!isDigest(artifact.sha256)) {
      errors.push('artifact sha256 values must be null or lower-hex digests.');
    }
  }

  if (![false, true, null].includes(proof?.stubDetection?.stubDetected)) {
    errors.push('stubDetection.stubDetected must be false, true, or null.');
  }
  if (!Array.isArray(proof?.stubDetection?.checks) || proof.stubDetection.checks.length < 1) {
    errors.push('stubDetection.checks must contain at least one check.');
  }
  if (!Array.isArray(proof?.failures)) {
    errors.push('failures must be an array.');
  }

  for (const protocol of ['http', 'socks']) {
    const probe = proof?.probes?.[protocol];
    if (!probe) {
      errors.push(`probes.${protocol} must exist.`);
      continue;
    }
    if (!PROBE_RESULTS.has(probe.status)) {
      errors.push(`probes.${protocol}.status is invalid.`);
    }
    if (probe.protocol !== (protocol === 'http' ? 'HTTP_CONNECT' : 'SOCKS5')) {
      errors.push(`probes.${protocol}.protocol mismatch.`);
    }
    if (probe.runId !== proof.runId) {
      errors.push(`probes.${protocol}.runId must match proof.runId.`);
    }
  }

  const passRequires = proof?.result === 'pass';
  if (passRequires) {
    if (proof?.device?.targetKind !== 'physical') errors.push('pass requires a physical HarmonyOS device.');
    if (proof?.stubDetection?.stubDetected !== false) errors.push('pass requires stubDetection.stubDetected === false.');
    if (proof?.probes?.http?.status !== 'pass' || proof?.probes?.socks?.status !== 'pass') {
      errors.push('pass requires both HTTP and SOCKS probes to pass.');
    }
    if (proof?.timestamps?.appStartedAt === null || proof?.timestamps?.proofAt === null) {
      errors.push('pass requires appStartedAt and proofAt.');
    }
  }
  if (proof?.stubDetection?.stubDetected === null && proof?.result === 'pass') {
    errors.push('stubDetection.stubDetected null can never pass.');
  }
  if (proof?.device?.targetKind !== 'physical' && proof?.result === 'pass') {
    errors.push('host or simulator targets can never pass.');
  }

  return { valid: errors.length === 0, errors };
}

async function writeProof(proof, outputPath, fsApi = fs, repoRoot = REPO_ROOT) {
  const safeOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath);
  const tempPath = `${safeOutputPath}.${process.pid}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, safeOutputPath);
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let hapPath = null;
  let manifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json');
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json');
  const seen = new Set();

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!['--hap', '--manifest', '--out'].includes(option)) {
      throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID' });
    }
    if (seen.has(option)) {
      throw Object.assign(new Error(`${option} may only be provided once.`), { code: 'ARGUMENT_INVALID' });
    }
    seen.add(option);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID' });
    }
    const resolved = path.resolve(repoRoot, value);
    if (option === '--hap') hapPath = resolved;
    if (option === '--manifest') manifestPath = resolved;
    if (option === '--out') outputPath = resolved;
    index += 1;
  }

  return { hapPath, manifestPath, outputPath };
}

export async function runPhase2DeviceProof({
  hapPath = null,
  manifestPath = DEFAULT_MANIFEST_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  inspectHapImpl = inspectHap,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date()
} = {}) {
  const startedAt = now();
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  const proof = createBaseProof({
    repoRoot,
    outputPath,
    runId: randomUUID(),
    startedAt
  });

  proof.toolchain = await readToolchainVersions(fsApi, path.join(repoRoot, 'harmony'));
  proof.fixtures.matchConfig = await hashOptionalRepoFile(fsApi, repoRoot, path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase2-match-direct.yaml'));
  proof.fixtures.originBody = await hashOptionalRepoFile(fsApi, repoRoot, path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'origin-body.txt'));
  proof.origin.responseSha256 = proof.fixtures.originBody.sha256;

  if (!hapPath) {
    pushFailure(proof, 'INPUT_HAP_MISSING', 'A signed self-test HAP was not supplied.', 'input');
  } else {
    try {
      const resolvedHapPath = await resolveExistingRepoScopedPath(fsApi, repoRoot, hapPath, '--hap');
      const digest = await hashFile(fsApi, resolvedHapPath);
      proof.hap = {
        path: normalizePathForReport(repoRoot, resolvedHapPath),
        sha256: digest.sha256,
        sizeBytes: digest.sizeBytes
      };
      if (/-unsigned\.hap$/iu.test(path.basename(resolvedHapPath))) {
        pushFailure(proof, 'INPUT_HAP_UNSIGNED', 'Unsigned HAPs cannot enter the Phase 2 proof lane.', 'input');
        pushFailure(proof, 'SIGNING_REQUIRED', 'A valid developer-signed debug HAP is required.', 'signing');
      } else {
        try {
          const inspection = await inspectHapImpl({
            hapPath: resolvedHapPath,
            manifestPath,
            repoRoot,
            fsApi
          });
          proof.packaged.core = inspection.packaged?.core
            ? {
              path: inspection.packaged.core.identity ?? HAP_CORE_ENTRY,
              sha256: inspection.packaged.core.sha256,
              sizeBytes: inspection.packaged.core.sizeBytes
            }
            : proof.packaged.core;
          proof.packaged.addon = inspection.packaged?.addon
            ? {
              path: inspection.packaged.addon.identity ?? HAP_ADDON_ENTRY,
              sha256: inspection.packaged.addon.sha256,
              sizeBytes: inspection.packaged.addon.sizeBytes
            }
            : proof.packaged.addon;
          proof.stubDetection.stubDetected = inspection.stubDetected;
          proof.stubDetection.checks = [
            {
              id: 'manifestInspection',
              result: inspection.result === 'pass' ? 'pass' : 'fail',
              detail: inspection.result === 'pass' ? 'Packaged HAP matched the fresh build manifest.' : 'Packaged HAP failed fresh-manifest inspection.'
            },
            {
              id: 'nativeLibraryInspection',
              result: inspection.packaged?.core?.elf?.result === 'pass' ? 'pass' : 'fail',
              detail: inspection.packaged?.core?.elf?.result === 'pass'
                ? 'Packaged core satisfies the real-core-only ELF contract.'
                : 'Packaged core failed the real-core-only ELF contract.'
            }
          ];
          proof.core.version = inspection.provenance?.observed?.version ?? null;
          for (const failure of inspection.failures ?? []) {
            pushFailure(proof, failure.code, failure.detail, failure.stage);
          }
        } catch (error) {
          proof.stubDetection.stubDetected = null;
          pushFailure(proof, error?.code ?? 'HAP_INSPECTION_FAILED', sanitizeText(error?.message ?? 'Failed to inspect the supplied HAP.', replacements), 'archive');
        }
      }
    } catch (error) {
      pushFailure(proof, error?.code ?? 'INPUT_HAP_INVALID', sanitizeText(error?.message ?? 'Unable to access the supplied HAP.', replacements), 'input');
    }
  }

  pushFailure(proof, 'PHYSICAL_DEVICE_REQUIRED', 'Only a physical HarmonyOS 6 device can complete Phase 2.', 'target');
  proof.timestamps.runnerFinishedAt = isoTimestamp(now());
  proof.result = resultFromFailures(proof);

  const sanitized = sanitizeForPersistence(proof, replacements);
  const validation = validatePhase2Proof(sanitized);
  if (!validation.valid) {
    sanitized.result = 'fail';
    sanitized.failures.push(createFailure('PHASE2_PROOF_INVALID', validation.errors.join('; '), 'proof'));
  }
  await writeProof(sanitized, outputPath, fsApi, repoRoot);
  return sanitized;
}

export async function runCli({
  argv = process.argv.slice(2),
  repoRoot = REPO_ROOT,
  fsApi = fs,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date(),
  inspectHapImpl = inspectHap
} = {}) {
  let parsed = {
    hapPath: null,
    manifestPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json'),
    outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json')
  };

  try {
    parsed = parseCliArguments(argv, repoRoot);
  } catch (error) {
    const proof = await runPhase2DeviceProof({
      ...parsed,
      repoRoot,
      fsApi,
      randomUUID,
      now,
      inspectHapImpl
    });
    proof.failures.push(createFailure(error?.code ?? 'ARGUMENT_INVALID', error?.message ?? 'Invalid CLI arguments.', 'cli'));
    proof.result = resultFromFailures(proof);
    await writeProof(proof, parsed.outputPath, fsApi, repoRoot);
    return proof.result === 'fail' ? 1 : 0;
  }

  const proof = await runPhase2DeviceProof({
    ...parsed,
    repoRoot,
    fsApi,
    randomUUID,
    now,
    inspectHapImpl
  });
  return proof.result === 'fail' ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
