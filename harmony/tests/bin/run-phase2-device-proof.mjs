import crypto from 'node:crypto';
import { spawn as spawnChild } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildPhase1Native } from './build-phase1-native.mjs';
import { inspectHap } from './inspect-hap.mjs';
import { inspectToolchain, normalizeNodeVersion } from '../../tools/lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeForPersistence, sanitizeText } from '../../tools/lib/proof-redaction.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  createMaskedDeviceIdentity,
  execCommand
} from './run-phase0-device-proof.mjs';

export const PROOF_SCHEMA_VERSION = '1.0.0';
export const PHASE_NUMBER = 2;
export const BUNDLE_NAME = 'com.github.kr328.clash.harmony';
export const ENTRY_ABILITY_NAME = 'EntryAbility';
export const APP_PROOF_REMOTE_PATH = '/data/storage/el2/base/files/phase2-device-proof.json';
export const MAX_PHASE2_APP_EVIDENCE_BYTES = 1024 * 1024;

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const ORIGIN_SCRIPT_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'phase2-origin.mjs');
export const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase2-device-proof.json');
export const DEFAULT_BUILD_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase2-build-manifest.json');

const DIGEST_PATTERN = /^[a-f0-9]{64}$/u;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const FINAL_RESULTS = new Set(['pass', 'fail', 'incomplete']);
const PROBE_RESULTS = new Set(['pass', 'fail', 'incomplete', 'not-run']);
const PHYSICAL_INCOMPLETE_CODES = new Set([
  'INPUT_HAP_MISSING',
  'INPUT_HAP_UNSIGNED',
  'SIGNING_REQUIRED',
  'DEVICE_TARGET_MISSING',
  'DEVICE_TARGET_AMBIGUOUS',
  'DEVICE_TARGET_UNSUPPORTED',
  'DEVICE_FACT_MISSING',
  'PHYSICAL_DEVICE_REQUIRED',
  'ORIGIN_BIND_BLOCKED'
]);

function isoTimestamp(date = new Date()) {
  return date.toISOString();
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}

function isUuid(value) {
  return UUID_PATTERN.test(String(value ?? ''));
}

function isDigest(value) {
  return DIGEST_PATTERN.test(String(value ?? ''));
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

function isWithinRepo(repoRoot, filePath) {
  const relativePath = path.relative(repoRoot, filePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
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

async function hashRepoFile(fsApi, repoRoot, filePath, option) {
  const logicalPath = path.resolve(filePath);
  const resolved = await resolveExistingRepoScopedPath(fsApi, repoRoot, filePath, option);
  const digest = await hashFile(fsApi, resolved);
  return {
    path: normalizePathForReport(repoRoot, logicalPath),
    sha256: digest.sha256,
    sizeBytes: digest.sizeBytes,
    absolutePath: resolved
  };
}

async function readJson(fsApi, filePath, code) {
  try {
    return JSON.parse(await fsApi.readFile(filePath, 'utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? `Unable to read ${filePath}`), { code });
  }
}

function createProbe(protocol, runId) {
  return {
    protocol,
    status: 'not-run',
    runId,
    probeRunId: null,
    requestId: null,
    originRequestId: null,
    appProbeId: null,
    coreEventId: null,
    originEventRunId: null,
    appEventRunId: null,
    coreEventRunId: null,
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
    error: null
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
    hap: { path: null, sha256: null, sizeBytes: null },
    packaged: {
      rawCore: { path: null, sha256: null, sizeBytes: null },
      prePackageCore: { path: null, sha256: null, sizeBytes: null },
      prePackageAddon: { path: null, sha256: null, sizeBytes: null },
      core: { path: null, sha256: null, sizeBytes: null },
      addon: { path: null, sha256: null, sizeBytes: null }
    },
    fixtures: {
      matchConfig: { path: null, sha256: null, sizeBytes: null },
      originBody: { path: null, sha256: null, sizeBytes: null }
    },
    origin: {
      originRunId: null,
      originId: null,
      originUrl: null,
      bindAddress: null,
      tlsCertSha256: null,
      responseSha256: null,
      requestObservations: []
    },
    core: {
      version: null,
      httpListenerAddress: null,
      socksListenerAddress: null,
      provenance: {
        expected: { version: null, commit: null, buildInfo: null, buildId: null },
        observed: { version: null, commit: null, buildInfo: null, buildId: null },
        verified: 'not-run'
      }
    },
    stubDetection: {
      stubDetected: null,
      checks: [
        { id: 'manifestInspection', result: 'not-run', detail: 'No self-test build manifest was inspected.' },
        { id: 'nativeLibraryInspection', result: 'not-run', detail: 'No packaged core was inspected.' }
      ]
    },
    appEvidence: {
      path: null,
      sha256: null,
      sizeBytes: null,
      runId: null,
      originRunId: null,
      appProcessId: null,
      stopResult: null,
      fixturePath: null,
      fixtureSha256: null,
      coreVersion: null,
      httpListenerAddress: null,
      socksListenerAddress: null
    },
    probes: {
      http: createProbe('HTTP_CONNECT', runId),
      socks: createProbe('SOCKS5', runId)
    },
    stop: {
      result: 'not-run',
      forceStopResult: 'not-run'
    },
    failures: []
  };
}

function defaultFixturePathForRepo(repoRoot) {
  return path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase2-match-direct.yaml');
}

function defaultOriginBodyPathForRepo(repoRoot) {
  return path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'origin-body.txt');
}

function pushFailure(proof, code, detail, stage) {
  if (proof.failures.some((entry) => entry.code === code && entry.detail === detail && entry.stage === stage)) {
    return;
  }
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

function allStubChecksPass(checks) {
  return Array.isArray(checks) && checks.length > 0 && checks.every((entry) => entry?.result === 'pass');
}

function deviceLooksPhysical(device) {
  if (device?.targetKind !== 'physical') {
    return false;
  }
  if (!/arm64|aarch64/iu.test(String(device?.abi ?? ''))) {
    return false;
  }
  if (Number.parseInt(String(device?.apiVersion ?? ''), 10) < 20) {
    return false;
  }
  const matchedVersion = String(device?.buildVersion ?? '').match(/\b(\d+)(?:\.\d+){0,3}\b/u);
  if (!matchedVersion || matchedVersion[1] !== '6') {
    return false;
  }
  if (/simulator|emulator/iu.test(`${device?.model ?? ''} ${device?.product ?? ''}`)) {
    return false;
  }
  return isNonEmptyString(device?.identityMasked) && isNonEmptyString(device?.model) && isNonEmptyString(device?.product);
}

function originObservationMap(origin) {
  const map = new Map();
  for (const entry of origin?.requestObservations ?? []) {
    if (isNonEmptyString(entry?.requestId)) {
      map.set(entry.requestId, entry);
    }
  }
  return map;
}

function canPass(proof) {
  if (!['devecoVersion', 'sdkVersion', 'ndkVersion', 'hvigorVersion', 'nodeVersion', 'hdcVersion'].every((key) => isNonEmptyString(proof.toolchain?.[key]))) {
    return false;
  }
  if (!deviceLooksPhysical(proof.device)) {
    return false;
  }
  for (const artifact of [proof.hap, proof.packaged?.rawCore, proof.packaged?.prePackageCore, proof.packaged?.prePackageAddon, proof.packaged?.core, proof.packaged?.addon, proof.fixtures?.matchConfig, proof.fixtures?.originBody]) {
    if (!isNonEmptyString(artifact?.path) || !isDigest(artifact?.sha256) || !Number.isInteger(artifact?.sizeBytes) || artifact.sizeBytes < 1) {
      return false;
    }
  }
  if (proof.stubDetection?.stubDetected !== false || !allStubChecksPass(proof.stubDetection?.checks)) {
    return false;
  }
  if (!isNonEmptyString(proof.origin?.originRunId) || proof.origin.originRunId !== proof.runId) {
    return false;
  }
  if (!isNonEmptyString(proof.origin?.originId) || !isNonEmptyString(proof.origin?.originUrl) || !isNonEmptyString(proof.origin?.bindAddress) || !isDigest(proof.origin?.tlsCertSha256) || !isDigest(proof.origin?.responseSha256)) {
    return false;
  }
  if (!Array.isArray(proof.origin?.requestObservations) || proof.origin.requestObservations.length !== 2) {
    return false;
  }
  if (!isNonEmptyString(proof.core?.version) || !isNonEmptyString(proof.core?.httpListenerAddress) || !isNonEmptyString(proof.core?.socksListenerAddress)) {
    return false;
  }
  if (proof.core?.provenance?.verified !== 'pass') {
    return false;
  }
  for (const key of ['version', 'commit', 'buildInfo', 'buildId']) {
    if (!isNonEmptyString(proof.core?.provenance?.expected?.[key]) || !isNonEmptyString(proof.core?.provenance?.observed?.[key])) {
      return false;
    }
  }
  if (!isDigest(proof.appEvidence?.sha256) || !Number.isInteger(proof.appEvidence?.sizeBytes) || proof.appEvidence.sizeBytes < 1) {
    return false;
  }
  if (proof.appEvidence?.runId !== proof.runId || proof.appEvidence?.originRunId !== proof.runId || !Number.isInteger(proof.appEvidence?.appProcessId) || proof.appEvidence.appProcessId < 1 || proof.appEvidence?.stopResult !== 'pass') {
    return false;
  }
  if (proof.appEvidence?.fixturePath !== proof.fixtures?.matchConfig?.path || proof.appEvidence?.fixtureSha256 !== proof.fixtures?.matchConfig?.sha256) {
    return false;
  }
  if (proof.stop?.result !== 'pass' || proof.stop?.forceStopResult !== 'pass') {
    return false;
  }
  if (!Array.isArray(proof.failures) || proof.failures.length > 0) {
    return false;
  }
  const observations = originObservationMap(proof.origin);
  for (const protocol of ['http', 'socks']) {
    const probe = proof.probes?.[protocol];
    const expectedProtocol = protocol === 'http' ? 'HTTP_CONNECT' : 'SOCKS5';
    const observation = observations.get(probe.requestId);
    if (!probe || probe.protocol !== expectedProtocol || probe.status !== 'pass') {
      return false;
    }
    if (
      probe.runId !== proof.runId ||
      probe.originEventRunId !== proof.runId ||
      probe.appEventRunId !== proof.runId ||
      probe.coreEventRunId !== proof.runId ||
      probe.originId !== proof.origin.originId ||
      probe.appProcessId !== proof.appEvidence.appProcessId ||
      !isNonEmptyString(probe.probeRunId) ||
      !isNonEmptyString(probe.requestId) ||
      !isNonEmptyString(probe.originRequestId) ||
      !isNonEmptyString(probe.appProbeId) ||
      !isNonEmptyString(probe.coreEventId) ||
      !isNonEmptyString(probe.coreConnectionId) ||
      !Number.isInteger(probe.clientSourcePort) ||
      !isNonEmptyString(probe.destination) ||
      !isNonEmptyString(probe.upstreamInboundType) ||
      !isNonEmptyString(probe.listenerAddress) ||
      !isDigest(probe.tlsPeerSha256) ||
      probe.httpStatus !== 200 ||
      !Number.isInteger(probe.responseBytes) || probe.responseBytes < 1 ||
      !isDigest(probe.responseSha256) ||
      !isIsoTimestamp(probe.startedAt) ||
      !isIsoTimestamp(probe.completedAt) ||
      probe.error !== null
    ) {
      return false;
    }
    if (!observation || observation.originEventRunId !== proof.runId || observation.originRequestId !== probe.originRequestId || observation.requestId !== probe.requestId) {
      return false;
    }
  }
  return true;
}

export function validatePhase2Proof(proof) {
  const errors = [];
  if (proof?.schemaVersion !== PROOF_SCHEMA_VERSION) errors.push(`schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  if (proof?.phase !== PHASE_NUMBER) errors.push('phase must be 2.');
  if (!FINAL_RESULTS.has(proof?.result)) errors.push('result must be pass, fail, or incomplete.');
  if (!isUuid(proof?.runId)) errors.push('runId must be a UUID.');
  if (proof?.bundle !== BUNDLE_NAME || proof?.ability !== ENTRY_ABILITY_NAME) errors.push('bundle/ability identity mismatch.');
  if (!isNonEmptyString(proof?.outputPath)) errors.push('outputPath must be non-empty.');

  if (!isIsoTimestamp(proof?.timestamps?.runnerStartedAt) || !isIsoTimestamp(proof?.timestamps?.runnerFinishedAt)) {
    errors.push('runner timestamps must be ISO-8601 values.');
  }
  if (proof?.timestamps?.appStartedAt !== null && !isIsoTimestamp(proof.timestamps.appStartedAt)) {
    errors.push('appStartedAt must be null or ISO-8601.');
  }
  if (proof?.timestamps?.proofAt !== null && !isIsoTimestamp(proof.timestamps.proofAt)) {
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

  const allArtifacts = [
    ['hap', proof?.hap],
    ['packaged.rawCore', proof?.packaged?.rawCore],
    ['packaged.prePackageCore', proof?.packaged?.prePackageCore],
    ['packaged.prePackageAddon', proof?.packaged?.prePackageAddon],
    ['packaged.core', proof?.packaged?.core],
    ['packaged.addon', proof?.packaged?.addon],
    ['fixtures.matchConfig', proof?.fixtures?.matchConfig],
    ['fixtures.originBody', proof?.fixtures?.originBody]
  ];
  for (const [label, artifact] of allArtifacts) {
    if (!artifact || !('path' in artifact) || !('sha256' in artifact) || !('sizeBytes' in artifact)) {
      errors.push(`${label} must contain path, sha256, and sizeBytes.`);
      continue;
    }
    if (artifact.path !== null && !isNonEmptyString(artifact.path)) {
      errors.push(`${label}.path must be null or a non-empty string.`);
    }
    if (artifact.sha256 !== null && !isDigest(artifact.sha256)) {
      errors.push(`${label}.sha256 must be null or a lower-hex digest.`);
    }
    if (artifact.sizeBytes !== null && (!Number.isInteger(artifact.sizeBytes) || artifact.sizeBytes < 0)) {
      errors.push(`${label}.sizeBytes must be null or a non-negative integer.`);
    }
  }

  if (![false, true, null].includes(proof?.stubDetection?.stubDetected)) {
    errors.push('stubDetection.stubDetected must be false, true, or null.');
  }
  if (!Array.isArray(proof?.stubDetection?.checks) || proof.stubDetection.checks.length < 1) {
    errors.push('stubDetection.checks must contain at least one check.');
  }
  if (!Array.isArray(proof?.origin?.requestObservations)) {
    errors.push('origin.requestObservations must be an array.');
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
    const expectedProtocol = protocol === 'http' ? 'HTTP_CONNECT' : 'SOCKS5';
    if (probe.protocol !== expectedProtocol) {
      errors.push(`probes.${protocol}.protocol mismatch.`);
    }
    if (probe.runId !== proof.runId) {
      errors.push(`probes.${protocol}.runId must match proof.runId.`);
    }
  }

  if (proof?.result === 'pass') {
    if (!canPass(proof)) {
      if (!['devecoVersion', 'sdkVersion', 'ndkVersion', 'hvigorVersion', 'nodeVersion', 'hdcVersion'].every((key) => isNonEmptyString(proof.toolchain?.[key]))) {
        errors.push('pass requires exact non-null toolchain versions including hdcVersion.');
      }
      for (const [label, artifact] of allArtifacts) {
        if (!artifact || !isNonEmptyString(artifact.path) || !isDigest(artifact.sha256) || !Number.isInteger(artifact.sizeBytes) || artifact.sizeBytes < 1) {
          errors.push(`pass requires exact non-null ${label} path/hash/sizeBytes.`);
        }
      }
      if (!deviceLooksPhysical(proof.device)) {
        errors.push('pass requires a physical HarmonyOS 6 API>=20 AArch64 target, never simulator/host.');
      }
      if (proof.stubDetection?.stubDetected !== false) {
        errors.push('pass requires stubDetected === false.');
      }
      if (!allStubChecksPass(proof.stubDetection?.checks)) {
        errors.push('pass requires every stubDetection check to pass.');
      }
      if (proof.stop?.result !== 'pass' || proof.stop?.forceStopResult !== 'pass') {
        errors.push('pass requires stop.result and stop.forceStopResult pass.');
      }
      if (!Array.isArray(proof.failures) || proof.failures.length !== 0) {
        errors.push('pass requires failures to stay empty.');
      }
      if (proof.appEvidence?.runId !== proof.runId || proof.appEvidence?.originRunId !== proof.runId || !Number.isInteger(proof.appEvidence?.appProcessId) || proof.appEvidence?.stopResult !== 'pass') {
        errors.push('pass requires exact appEvidence runId/originRunId/appProcessId/stopResult.');
      }
      if (proof.appEvidence?.fixturePath !== proof.fixtures?.matchConfig?.path || proof.appEvidence?.fixtureSha256 !== proof.fixtures?.matchConfig?.sha256) {
        errors.push('pass requires app evidence fixture path/hash to match proof.fixtures.matchConfig.');
      }
      if (!isNonEmptyString(proof.origin?.originRunId) || proof.origin.originRunId !== proof.runId) {
        errors.push('pass requires explicit origin/app/core run correlation to equal proof.runId.');
      }
      if (proof.core?.provenance?.verified !== 'pass') {
        errors.push('pass requires provenance verified pass.');
      }
      const observations = originObservationMap(proof.origin);
      for (const protocol of ['http', 'socks']) {
        const probe = proof?.probes?.[protocol];
        const expectedProtocol = protocol === 'http' ? 'HTTP_CONNECT' : 'SOCKS5';
      const observation = observations.get(probe.requestId);
        if (!probe || probe.status !== 'pass') {
          errors.push(`pass requires probes.${protocol}.status pass.`);
          continue;
        }
        if (
          probe.originEventRunId !== proof.runId ||
          probe.appEventRunId !== proof.runId ||
          probe.coreEventRunId !== proof.runId
        ) {
          errors.push(`pass requires probes.${protocol} run correlation fields to equal proof.runId.`);
        }
        if (!observation || observation.originRequestId !== probe.originRequestId || observation.requestId !== probe.requestId) {
          errors.push(`pass requires probes.${protocol} request correlation to match origin observations.`);
        }
        if (!Number.isInteger(probe.clientSourcePort)) {
          errors.push(`pass requires probes.${protocol}.clientSourcePort.`);
        }
        if (!isNonEmptyString(probe.destination) || !isNonEmptyString(probe.upstreamInboundType)) {
          errors.push(`pass requires probes.${protocol} destination and inbound type.`);
        }
        if (probe.httpStatus !== 200 || !isDigest(probe.tlsPeerSha256) || !isDigest(probe.responseSha256) || probe.error !== null) {
          errors.push(`pass requires probes.${protocol} TLS/hash/200/error-null fields.`);
        }
      }
    }
  }

  return { valid: errors.length === 0, errors };
}

async function writeProof(proof, outputPath, fsApi = fs, repoRoot = REPO_ROOT) {
  const safeOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath);
  const tempPath = `${safeOutputPath}.${process.pid}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, safeOutputPath);
}

export async function writeArgumentErrorProof({
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date(),
  detail = 'Invalid CLI arguments.'
} = {}) {
  const startedAt = now();
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  const proof = createBaseProof({ repoRoot, outputPath, runId: randomUUID(), startedAt });
  proof.toolchain = await readToolchainVersions(fsApi, path.join(repoRoot, 'harmony'));
  proof.timestamps.runnerFinishedAt = isoTimestamp(now());
  pushFailure(proof, 'ARGUMENT_INVALID', sanitizeText(detail, replacements), 'cli');
  const sanitized = sanitizeForPersistence(finalizeResult(proof), replacements);
  const validation = validatePhase2Proof(sanitized);
  if (!validation.valid) {
    sanitized.result = 'fail';
    sanitized.failures.push(createFailure('PHASE2_PROOF_INVALID', validation.errors.join('; '), 'proof'));
  }
  await writeProof(sanitized, outputPath, fsApi, repoRoot);
  return sanitized;
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID' });
  }
  return value;
}

function resolveRepoScopedValue(repoRoot, value, option) {
  const resolved = path.isAbsolute(value) ? value : path.resolve(repoRoot, value);
  const relativePath = path.relative(repoRoot, resolved);
  if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    throw Object.assign(new Error(`${option} must stay inside the repository root.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return resolved;
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let buildManifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-build-manifest.json');
  let fixturePath = defaultFixturePathForRepo(repoRoot);
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json');
  const seen = new Set();

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!['--build-manifest', '--fixture', '--out'].includes(option)) {
      throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID' });
    }
    if (seen.has(option)) {
      throw Object.assign(new Error(`${option} may only be provided once.`), { code: 'ARGUMENT_INVALID' });
    }
    seen.add(option);
    const value = requireValue(argv, index, option);
    const resolved = resolveRepoScopedValue(repoRoot, value, option);
    if (option === '--build-manifest') buildManifestPath = resolved;
    if (option === '--fixture') fixturePath = resolved;
    if (option === '--out') outputPath = resolved;
    index += 1;
  }

  return { buildManifestPath, fixturePath, outputPath };
}

function parseCliArgumentsPartial(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let buildManifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-build-manifest.json');
  let fixturePath = defaultFixturePathForRepo(repoRoot);
  let outputPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json');
  const seen = new Set();

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!['--build-manifest', '--fixture', '--out'].includes(option)) {
      throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID', partial: { buildManifestPath, fixturePath, outputPath } });
    }
    if (seen.has(option)) {
      throw Object.assign(new Error(`${option} may only be provided once.`), { code: 'ARGUMENT_INVALID', partial: { buildManifestPath, fixturePath, outputPath } });
    }
    seen.add(option);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID', partial: { buildManifestPath, fixturePath, outputPath } });
    }
    const resolved = resolveRepoScopedValue(repoRoot, value, option);
    if (option === '--build-manifest') buildManifestPath = resolved;
    if (option === '--fixture') fixturePath = resolved;
    if (option === '--out') outputPath = resolved;
    index += 1;
  }

  return { buildManifestPath, fixturePath, outputPath };
}

async function resolveHdcCommand(toolchainInspectorImpl, repoRoot) {
  const inspection = await toolchainInspectorImpl({ cwd: repoRoot });
  if (inspection?.report?.result !== 'pass' || !inspection?.resolved?.paths?.hdc) {
    throw Object.assign(new Error('The integrated hdc command is unavailable.'), { code: 'TOOL_MISSING' });
  }
  return inspection.resolved.paths.hdc;
}

async function verifyHdcHelp(execImpl, hdcCommand, cwd) {
  for (const args of [['help'], ['-h'], ['--help']]) {
    const result = await execImpl(hdcCommand, args, { cwd });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    if (result?.timedOut) {
      return { ok: false, failure: createFailure('HDC_TIMEOUT', 'hdc help timed out.', 'toolchain') };
    }
    if (result?.error?.code === 'ENOENT') {
      return { ok: false, failure: createFailure('TOOL_MISSING', 'The integrated hdc command is unavailable.', 'toolchain') };
    }
    if (/list\s+targets/iu.test(output) && /install/iu.test(output) && /shell/iu.test(output)) {
      return { ok: true };
    }
  }
  return { ok: false, failure: createFailure('HDC_HELP_UNSUPPORTED', 'hdc help does not confirm the required command surface.', 'toolchain') };
}

async function readDeviceFact({ execImpl, hdcCommand, target, candidates, cwd }) {
  for (const key of candidates) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    if (result?.timedOut) {
      return { value: null, timedOut: true };
    }
    const value = String(result.stdout ?? '').trim();
    if (!result?.error && result?.exitCode === 0 && value && !/^(?:unknown|null)$/iu.test(value)) {
      return { value, timedOut: false };
    }
  }
  return { value: null, timedOut: false };
}

function classifyTarget(device) {
  if (!isNonEmptyString(device.model) || !isNonEmptyString(device.product) || !isNonEmptyString(device.buildVersion) || !isNonEmptyString(device.apiVersion) || !isNonEmptyString(device.abi)) {
    return { kind: 'incomplete', code: 'DEVICE_FACT_MISSING', detail: 'The selected target did not expose all required device facts.' };
  }
  if (/simulator|emulator/iu.test(`${device.model} ${device.product}`)) {
    return { kind: 'incomplete', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Simulator targets cannot satisfy Phase 2.' };
  }
  if (!/arm64|aarch64/iu.test(device.abi)) {
    return { kind: 'incomplete', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Only AArch64 physical devices can satisfy Phase 2.' };
  }
  if (Number.parseInt(device.apiVersion, 10) < 20) {
    return { kind: 'incomplete', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Phase 2 requires API 20 or later.' };
  }
  const matchedVersion = device.buildVersion.match(/\b(\d+)(?:\.\d+){0,3}\b/u);
  if (!matchedVersion || matchedVersion[1] !== '6') {
    return { kind: 'incomplete', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Phase 2 requires a HarmonyOS 6 physical device.' };
  }
  return { kind: 'physical' };
}

function buildLaunchArgs(target, runId, runnerStartedAt, originPayload) {
  const wantParameters = {
    'cmfa.phase1.selfTest': true,
    'cmfa.phase1.runId': runId,
    'cmfa.phase1.runnerStartedAt': runnerStartedAt,
    'cmfa.phase2.originRunId': originPayload.originRunId ?? runId,
    'cmfa.phase2.originUrl': originPayload.originUrl,
    'cmfa.phase2.caPem': originPayload.caPem,
    'cmfa.phase2.expectedBodySha256': originPayload.bodySha256,
    'cmfa.phase2.fixturePath': originPayload.fixturePath ?? '',
    'cmfa.phase2.fixtureSha256': originPayload.fixtureSha256 ?? ''
  };
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', ENTRY_ABILITY_NAME,
    '-b', BUNDLE_NAME,
    '-p', JSON.stringify(wantParameters)
  ]);
}

function buildPullArgs(target, localPath) {
  return buildTargetedHdcArgs(target, [
    'file', 'recv', '-b', BUNDLE_NAME,
    APP_PROOF_REMOTE_PATH,
    localPath
  ]);
}

export function createOriginStdoutParser(expectedRunId) {
  let buffer = '';
  const started = [];
  const requests = [];
  const invalid = [];

  function handleRecord(rawLine) {
    let record;
    try {
      record = JSON.parse(rawLine);
    } catch (error) {
      invalid.push({ line: rawLine, error: error?.message ?? 'invalid json' });
      return;
    }
    if (record?.runId !== expectedRunId || record?.originRunId !== expectedRunId) {
      invalid.push({ line: rawLine, error: 'runId mismatch' });
      return;
    }
    if (record?.type === 'started') {
      started.push(record);
      return;
    }
    if (record?.type === 'request') {
      requests.push(record);
      return;
    }
    invalid.push({ line: rawLine, error: 'unsupported record type' });
  }

  return {
    push(chunk) {
      buffer += String(chunk ?? '');
      while (true) {
        const newlineIndex = buffer.indexOf('\n');
        if (newlineIndex < 0) {
          break;
        }
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        if (line.length === 0) {
          continue;
        }
        handleRecord(line);
      }
    },
    snapshot() {
      return {
        started: [...started],
        requests: [...requests],
        invalid: [...invalid]
      };
    }
  };
}

export async function startOriginProcess({ repoRoot, originBodyPath, runId, spawnImpl = spawnChild, now = () => Date.now() }) {
  const child = spawnImpl('node', [ORIGIN_SCRIPT_PATH, '--bind', '127.0.0.1:0', '--body-file', originBodyPath, '--run-id', runId], {
    cwd: repoRoot,
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let stderr = '';
  const parser = createOriginStdoutParser(runId);
  let exited = false;
  let exitPayload = { code: null, signal: null };
  child.stdout?.setEncoding('utf8');
  child.stderr?.setEncoding('utf8');
  child.stderr?.on('data', (chunk) => {
    stderr += chunk;
  });
  child.once('exit', (code, signal) => {
    exited = true;
    exitPayload = { code, signal };
  });
  const payload = await new Promise((resolve, reject) => {
    let settled = false;
    const onData = (chunk) => {
      parser.push(chunk);
      const startedRecord = parser.snapshot().started.at(0);
      if (startedRecord && !settled) {
        settled = true;
        child.stdout?.off?.('data', onData);
        child.off?.('error', onError);
        child.off?.('exit', onExitBeforeStart);
        resolve(startedRecord);
      }
    };
    const onError = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      child.stdout?.off?.('data', onData);
      child.off?.('exit', onExitBeforeStart);
      reject(error);
    };
    const onExitBeforeStart = () => {
      if (settled) {
        return;
      }
      settled = true;
      child.stdout?.off?.('data', onData);
      child.off?.('error', onError);
      reject(Object.assign(new Error(stderr || 'phase2-origin exited before startup'), { code: /EPERM/u.test(stderr) ? 'ORIGIN_BIND_BLOCKED' : 'ORIGIN_START_FAILED' }));
    };
    child.stdout?.on('data', onData);
    child.once('error', onError);
    child.once('exit', onExitBeforeStart);
  });

  async function waitForRequestObservations(expectedCount, timeoutMs = 5_000) {
    const deadline = now() + timeoutMs;
    while (now() < deadline) {
      const snapshot = parser.snapshot();
      if (snapshot.requests.length >= expectedCount) {
        return snapshot.requests.slice(0, expectedCount);
      }
      if (exited) {
        return snapshot.requests;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    return parser.snapshot().requests;
  }

  return {
    ...payload,
    originRunId: payload.originRunId ?? runId,
    tlsCertSha256: crypto.createHash('sha256').update(String(payload.caPem ?? '')).digest('hex'),
    requestObservations: [],
    waitForRequestObservations,
    getInvalidRecords() {
      return parser.snapshot().invalid;
    },
    async stop() {
      if (exited) {
        this.requestObservations = parser.snapshot().requests;
        return;
      }
      child.kill('SIGTERM');
      await new Promise((resolve) => {
        child.once('exit', () => resolve());
      });
      this.requestObservations = parser.snapshot().requests;
    }
  };
}

export function parsePhase2AppEvidence(raw, options = {}) {
  const errors = [];
  const expectedRunId = options.expectedRunId ?? null;
  const expectedFixturePath = options.expectedFixturePath ?? null;
  const expectedFixtureSha256 = options.expectedFixtureSha256 ?? null;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    errors.push('app evidence must be an object.');
    return { valid: false, errors, normalized: null };
  }
  if (raw.schemaVersion !== PROOF_SCHEMA_VERSION) {
    errors.push(`app evidence schemaVersion must be ${PROOF_SCHEMA_VERSION}.`);
  }
  if (raw.phase !== PHASE_NUMBER) {
    errors.push('app evidence phase must be 2.');
  }
  if (raw.runId !== expectedRunId) {
    errors.push('app evidence runId mismatch.');
  }
  if (raw.originRunId !== expectedRunId) {
    errors.push('app evidence originRunId mismatch.');
  }
  if (!Number.isInteger(raw.appProcessId) || raw.appProcessId < 1) {
    errors.push('app evidence appProcessId must be a positive integer.');
  }
  for (const key of ['fixturePath', 'fixtureSha256', 'coreVersion', 'httpListenerAddress', 'socksListenerAddress']) {
    if (!isNonEmptyString(raw[key])) {
      errors.push(`app evidence ${key} must be non-empty.`);
    }
  }
  if (expectedFixturePath !== null && raw.fixturePath !== expectedFixturePath) {
    errors.push('app evidence fixturePath mismatch.');
  }
  if (expectedFixtureSha256 !== null && raw.fixtureSha256 !== expectedFixtureSha256) {
    errors.push('app evidence fixtureSha256 mismatch.');
  }
  if (!isDigest(raw.fixtureSha256 ?? '')) {
    errors.push('app evidence fixtureSha256 must be a digest.');
  }
  if (!raw.stop || raw.stop.result !== 'pass') {
    errors.push('app evidence stop.result must be pass.');
  }
  if (!raw.probes || typeof raw.probes !== 'object' || Array.isArray(raw.probes)) {
    errors.push('app evidence probes must be an object with http and socks entries.');
  } else {
    for (const [key, expectedProtocol] of [['http', 'HTTP_CONNECT'], ['socks', 'SOCKS5']]) {
      const probe = raw.probes[key];
      if (!probe || typeof probe !== 'object' || Array.isArray(probe)) {
        errors.push(`app evidence probes.${key} must be an object.`);
        continue;
      }
      for (const requiredKey of ['probeRunId', 'requestId', 'originRequestId', 'appProbeId', 'coreEventId', 'originEventRunId', 'appEventRunId', 'coreEventRunId', 'originId', 'coreConnectionId', 'destination', 'upstreamInboundType', 'listenerAddress', 'tlsPeerSha256', 'responseSha256', 'startedAt', 'completedAt']) {
        if (!isNonEmptyString(probe[requiredKey])) {
          errors.push(`app evidence probes.${key}.${requiredKey} must be non-empty.`);
        }
      }
      if (probe.protocol !== expectedProtocol) {
        errors.push(`app evidence probes.${key}.protocol mismatch.`);
      }
      if (!PROBE_RESULTS.has(probe.status)) {
        errors.push(`app evidence probes.${key}.status must be pass/fail/incomplete/not-run.`);
      }
      if (probe.originEventRunId !== expectedRunId || probe.appEventRunId !== expectedRunId || probe.coreEventRunId !== expectedRunId) {
        errors.push(`app evidence probes.${key} run correlation mismatch.`);
      }
      if (!isDigest(probe.tlsPeerSha256 ?? '')) {
        errors.push(`app evidence probes.${key}.tlsPeerSha256 must be a digest.`);
      }
      if (!isDigest(probe.responseSha256 ?? '')) {
        errors.push(`app evidence probes.${key}.responseSha256 must be a digest.`);
      }
      if (!isIsoTimestamp(probe.startedAt) || !isIsoTimestamp(probe.completedAt) || Date.parse(probe.completedAt) < Date.parse(probe.startedAt)) {
        errors.push(`app evidence probes.${key} timestamps must be ordered ISO-8601 values.`);
      }
      if (!Number.isInteger(probe.clientSourcePort) || probe.clientSourcePort < 1) {
        errors.push(`app evidence probes.${key}.clientSourcePort must be a positive integer.`);
      }
      if (probe.httpStatus !== 200) {
        errors.push(`app evidence probes.${key}.httpStatus must be 200.`);
      }
      if (!Number.isInteger(probe.responseBytes) || probe.responseBytes < 1) {
        errors.push(`app evidence probes.${key}.responseBytes must be positive.`);
      }
      if (probe.error !== null) {
        errors.push(`app evidence probes.${key}.error must be null.`);
      }
    }
  }
  return { valid: errors.length === 0, errors, normalized: errors.length === 0 ? raw : null };
}

async function ensureRepoScopedPullPath(fsApi, repoRoot, localPath) {
  const resolved = path.resolve(localPath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error('pull path must stay inside the repository root.'), { code: 'APP_EVIDENCE_PATH_OUTSIDE_REPO' });
  }
  const realRepoRoot = await fsApi.realpath(repoRoot);
  let existingAncestor = path.dirname(resolved);
  while (true) {
    try {
      const stats = await fsApi.lstat(existingAncestor);
      if (stats.isSymbolicLink()) {
        throw Object.assign(new Error('pull path parent must not be a symlink.'), { code: 'APP_EVIDENCE_PATH_SYMLINK' });
      }
      const realAncestor = await fsApi.realpath(existingAncestor);
      if (!isWithinRepo(realRepoRoot, realAncestor)) {
        throw Object.assign(new Error('pull path parent resolves outside the repository.'), { code: 'APP_EVIDENCE_PATH_OUTSIDE_REPO' });
      }
      break;
    } catch (error) {
      if (error?.code === 'ENOENT') {
        const parent = path.dirname(existingAncestor);
        if (parent === existingAncestor) {
          throw error;
        }
        existingAncestor = parent;
        continue;
      }
      throw error;
    }
  }
  await fsApi.mkdir(path.dirname(resolved), { recursive: true });
  const realParent = await fsApi.realpath(path.dirname(resolved));
  if (!isWithinRepo(realRepoRoot, realParent)) {
    throw Object.assign(new Error('pull path parent resolves outside the repository.'), { code: 'APP_EVIDENCE_PATH_OUTSIDE_REPO' });
  }
  try {
    const stats = await fsApi.lstat(resolved);
    if (stats.isSymbolicLink()) {
      throw Object.assign(new Error('pull path target must not be a symlink.'), { code: 'APP_EVIDENCE_PATH_SYMLINK' });
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }
  return path.join(realParent, path.basename(resolved));
}

export async function pullPhase2AppEvidence({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  localPath,
  cwd,
  expectedRunId,
  waitImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
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
  let lastFailure = null;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const result = await execImpl(hdcCommand, buildPullArgs(target, safeLocalPath), { cwd });
    if (!result?.error && result?.exitCode === 0 && !result?.timedOut) {
      try {
        const fileStats = await fsApi.lstat(safeLocalPath);
        if (fileStats.isSymbolicLink()) {
          throw Object.assign(new Error('Pulled app evidence must not be a symlink.'), { code: 'APP_EVIDENCE_PATH_SYMLINK' });
        }
        const regularStats = await fsApi.stat(safeLocalPath);
        if (!regularStats.isFile()) {
          throw Object.assign(new Error('Pulled app evidence must be a regular file.'), { code: 'APP_EVIDENCE_NOT_REGULAR' });
        }
        if (regularStats.size < 1) {
          throw Object.assign(new Error('Pulled app evidence must not be empty.'), { code: 'APP_EVIDENCE_SIZE_INVALID' });
        }
        if (regularStats.size > MAX_PHASE2_APP_EVIDENCE_BYTES) {
          throw Object.assign(new Error(`Pulled app evidence exceeds ${MAX_PHASE2_APP_EVIDENCE_BYTES} bytes.`), { code: 'APP_EVIDENCE_SIZE_INVALID' });
        }
        const validation = parsePhase2AppEvidence(await readJson(fsApi, safeLocalPath, 'APP_EVIDENCE_INVALID'), { expectedRunId });
        if (validation.valid) {
          return { ok: true, result, proof: validation.normalized, localPath: safeLocalPath };
        }
        lastFailure = createFailure('APP_EVIDENCE_INVALID', validation.errors.join('; '), 'app-proof');
        return { ok: false, result, invalid: lastFailure };
      } catch (error) {
        lastFailure = createFailure(error?.code ?? 'APP_EVIDENCE_INVALID', error?.message ?? 'Unable to parse app evidence.', 'app-proof');
        return { ok: false, result, invalid: lastFailure };
      }
    }
    await waitImpl(250);
  }
  return { ok: false, invalid: lastFailure };
}

function copyArtifact(target, source) {
  target.path = source?.identity ?? source?.path ?? null;
  target.sha256 = source?.sha256 ?? null;
  target.sizeBytes = source?.sizeBytes ?? null;
}

function normalizeInspectionCheck(id, passed, passDetail, failDetail) {
  return {
    id,
    result: passed ? 'pass' : 'fail',
    detail: passed ? passDetail : failDetail
  };
}

function correlateProbe({ protocol, proof, appProbe, originObservation, expectedListenerAddress }) {
  const target = proof.probes[protocol === 'HTTP_CONNECT' ? 'http' : 'socks'];
  if (!appProbe) {
    target.status = 'fail';
    target.error = { code: 'APP_PROBE_MISSING', stage: protocol, detail: `App evidence did not include the ${protocol} probe.` };
    return createFailure('APP_PROBE_MISSING', `App evidence did not include the ${protocol} probe.`, protocol);
  }

  Object.assign(target, {
    status: appProbe.status,
    probeRunId: appProbe.probeRunId ?? null,
    requestId: appProbe.requestId ?? null,
    originRequestId: appProbe.originRequestId ?? null,
    appProbeId: appProbe.appProbeId ?? null,
    coreEventId: appProbe.coreEventId ?? null,
    originEventRunId: appProbe.originEventRunId ?? null,
    appEventRunId: appProbe.appEventRunId ?? null,
    coreEventRunId: appProbe.coreEventRunId ?? null,
    originId: appProbe.originId ?? null,
    appProcessId: proof.appEvidence.appProcessId,
    coreConnectionId: appProbe.coreConnectionId ?? null,
    clientSourcePort: appProbe.clientSourcePort ?? null,
    destination: appProbe.destination ?? null,
    upstreamInboundType: appProbe.upstreamInboundType ?? null,
    listenerAddress: appProbe.listenerAddress ?? null,
    tlsPeerSha256: appProbe.tlsPeerSha256 ?? null,
    httpStatus: appProbe.httpStatus ?? null,
    responseBytes: appProbe.responseBytes ?? null,
    responseSha256: appProbe.responseSha256 ?? null,
    startedAt: appProbe.startedAt ?? null,
    completedAt: appProbe.completedAt ?? null,
    error: appProbe.error ?? null
  });

  if (!originObservation) {
    return createFailure('ORIGIN_OBSERVATION_MISSING', `Origin did not observe the ${protocol} probe.`, protocol);
  }
  if (
    appProbe.originEventRunId !== proof.runId ||
    appProbe.appEventRunId !== proof.runId ||
    appProbe.coreEventRunId !== proof.runId ||
    originObservation.originEventRunId !== proof.runId
  ) {
    return createFailure('PROBE_RUN_ID_MISMATCH', `${protocol} run correlation did not match proof.runId.`, protocol);
  }
  if (appProbe.requestId !== originObservation.requestId || appProbe.originRequestId !== originObservation.originRequestId) {
    return createFailure('PROBE_REQUEST_MISMATCH', `${protocol} request correlation did not match origin observations.`, protocol);
  }
  if (appProbe.originId !== proof.origin.originId) {
    return createFailure('PROBE_ORIGIN_ID_MISMATCH', `${protocol} originId did not match the origin process.`, protocol);
  }
  if (appProbe.listenerAddress !== expectedListenerAddress) {
    return createFailure('PROBE_LISTENER_MISMATCH', `${protocol} listener address did not match the app evidence listener.`, protocol);
  }
  if (appProbe.responseSha256 !== originObservation.responseSha256 || appProbe.responseBytes !== originObservation.responseBytes || appProbe.httpStatus !== originObservation.httpStatus) {
    return createFailure('PROBE_RESPONSE_MISMATCH', `${protocol} response fields did not match the origin observations.`, protocol);
  }
  if (appProbe.status !== 'pass' || appProbe.error !== null || appProbe.httpStatus !== 200 || !Number.isInteger(appProbe.clientSourcePort) || !isNonEmptyString(appProbe.destination) || !isNonEmptyString(appProbe.upstreamInboundType)) {
    return createFailure('PROBE_CONTRACT_INVALID', `${protocol} probe did not satisfy the Phase 2 success contract.`, protocol);
  }
  return null;
}

function finalizeResult(proof) {
  if (canPass(proof)) {
    proof.result = 'pass';
    return proof;
  }
  proof.result = proof.failures.some((entry) => !PHYSICAL_INCOMPLETE_CODES.has(entry.code)) ? 'fail' : 'incomplete';
  return proof;
}

export async function runPhase2DeviceProof({
  buildManifestPath = DEFAULT_BUILD_MANIFEST_PATH,
  fixturePath = null,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  buildPhase1NativeImpl = buildPhase1Native,
  inspectHapImpl = inspectHap,
  toolchainInspectorImpl = inspectToolchain,
  execImpl = execCommand,
  startOriginImpl = startOriginProcess,
  pullPhase2AppEvidenceImpl = pullPhase2AppEvidence,
  randomUUID = () => crypto.randomUUID(),
  now = () => new Date(),
  waitImpl = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
} = {}) {
  const startedAt = now();
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  const proof = createBaseProof({ repoRoot, outputPath, runId: randomUUID(), startedAt });
  let originHandle = null;
  let target = null;
  let hdcCommand = null;
  let installed = false;

  const finish = async () => {
    proof.timestamps.runnerFinishedAt = isoTimestamp(now());
    const sanitized = sanitizeForPersistence(finalizeResult(proof), replacements);
    const validation = validatePhase2Proof(sanitized);
    if (!validation.valid) {
      sanitized.result = 'fail';
      sanitized.failures.push(createFailure('PHASE2_PROOF_INVALID', validation.errors.join('; '), 'proof'));
    }
    await writeProof(sanitized, outputPath, fsApi, repoRoot);
    return sanitized;
  };

  try {
    const effectiveFixturePath = fixturePath ?? defaultFixturePathForRepo(repoRoot);
    const effectiveOriginBodyPath = defaultOriginBodyPathForRepo(repoRoot);
    proof.toolchain = await readToolchainVersions(fsApi, path.join(repoRoot, 'harmony'));
    const [fixtureDigest, originBodyDigest] = await Promise.all([
      hashRepoFile(fsApi, repoRoot, effectiveFixturePath, '--fixture'),
      hashRepoFile(fsApi, repoRoot, effectiveOriginBodyPath, '--origin-body')
    ]);
    proof.fixtures.matchConfig = {
      path: fixtureDigest.path,
      sha256: fixtureDigest.sha256,
      sizeBytes: fixtureDigest.sizeBytes
    };
    proof.fixtures.originBody = {
      path: originBodyDigest.path,
      sha256: originBodyDigest.sha256,
      sizeBytes: originBodyDigest.sizeBytes
    };
    proof.origin.responseSha256 = originBodyDigest.sha256;

    let builtManifest;
    try {
      builtManifest = await buildPhase1NativeImpl({
        outputPath: buildManifestPath,
        phase2SelfTestEnabled: true
      });
    } catch (error) {
      pushFailure(proof, 'INPUT_HAP_MISSING', sanitizeText(error?.message ?? 'The self-test build lane did not produce a signed HAP.', replacements), 'build');
      return await finish();
    }
    const manifest = builtManifest ?? await readJson(fsApi, buildManifestPath, 'BUILD_MANIFEST_INVALID');
    if (manifest?.phase2SelfTest?.enabled !== true) {
      pushFailure(proof, 'PHASE2_SELF_TEST_REQUIRED', 'Phase 2 requires a fresh self-test build lane.', 'build');
      return await finish();
    }
    if (manifest?.signing?.result !== 'pass') {
      pushFailure(proof, 'SIGNING_REQUIRED', 'A developer-signed self-test HAP is required.', 'signing');
      return await finish();
    }
    if (manifest?.nativeBuildResult !== 'pass') {
      pushFailure(proof, 'BUILD_MANIFEST_NOT_PASSING', 'The fresh self-test build manifest did not finish with nativeBuildResult pass.', 'build');
      return await finish();
    }
    if (manifest?.result !== 'pass') {
      pushFailure(proof, 'BUILD_MANIFEST_NOT_PASSING', 'The fresh self-test build manifest did not finish with result pass.', 'build');
      return await finish();
    }

    const hapIdentity = manifest?.artifacts?.hap?.identity;
    if (!isNonEmptyString(hapIdentity)) {
      pushFailure(proof, 'INPUT_HAP_MISSING', 'The self-test build manifest did not expose a signed HAP identity.', 'build');
      return await finish();
    }
    const resolvedHapPath = await resolveExistingRepoScopedPath(fsApi, repoRoot, path.join(repoRoot, hapIdentity), '--hap');
    const hapDigest = await hashFile(fsApi, resolvedHapPath);
    proof.hap = {
      path: normalizePathForReport(repoRoot, resolvedHapPath),
      sha256: hapDigest.sha256,
      sizeBytes: hapDigest.sizeBytes
    };
    if (/-unsigned\.hap$/iu.test(path.basename(resolvedHapPath))) {
      pushFailure(proof, 'INPUT_HAP_UNSIGNED', 'Unsigned HAPs cannot enter the Phase 2 proof lane.', 'input');
      pushFailure(proof, 'SIGNING_REQUIRED', 'A valid developer-signed debug HAP is required.', 'signing');
      return await finish();
    }

    const inspection = await inspectHapImpl({
      hapPath: resolvedHapPath,
      manifest,
      manifestPath: buildManifestPath,
      repoRoot,
      fsApi
    });
    copyArtifact(proof.packaged.rawCore, inspection.packaged?.rawCore);
    copyArtifact(proof.packaged.prePackageCore, inspection.packaged?.prePackageCore);
    copyArtifact(proof.packaged.prePackageAddon, inspection.packaged?.prePackageAddon);
    copyArtifact(proof.packaged.core, inspection.packaged?.core);
    copyArtifact(proof.packaged.addon, inspection.packaged?.addon);
    proof.core.provenance.expected = inspection.provenance?.expected ?? proof.core.provenance.expected;
    proof.core.provenance.observed = inspection.provenance?.observed ?? proof.core.provenance.observed;
    proof.core.provenance.verified = inspection.provenance?.verified ?? 'fail';
    proof.stubDetection.stubDetected = inspection.stubDetected;
    proof.stubDetection.checks = [
      normalizeInspectionCheck('manifestInspection', inspection.result === 'pass', 'Packaged HAP matched the fresh build manifest.', 'Packaged HAP failed fresh-manifest inspection.'),
      normalizeInspectionCheck('nativeLibraryInspection', inspection.packaged?.core?.elf?.result === 'pass', 'Packaged core satisfied the real-core-only ELF contract.', 'Packaged core failed the real-core-only ELF contract.')
    ];
    proof.core.version = inspection.provenance?.observed?.version ?? null;
    for (const failure of inspection.failures ?? []) {
      pushFailure(proof, failure.code, failure.detail, failure.stage ?? 'archive');
    }
    if (inspection.result !== 'pass') {
      return await finish();
    }

    try {
      originHandle = await startOriginImpl({
        repoRoot,
        originBodyPath: originBodyDigest.absolutePath,
        runId: proof.runId
      });
    } catch (error) {
      pushFailure(proof, error?.code ?? 'ORIGIN_START_FAILED', sanitizeText(error?.message ?? 'Unable to start the HTTPS origin.', replacements), 'origin');
      return await finish();
    }

    proof.origin.originRunId = originHandle.originRunId ?? proof.runId;
    proof.origin.originId = originHandle.originId ?? null;
    proof.origin.originUrl = originHandle.originUrl ?? null;
    proof.origin.bindAddress = originHandle.address ?? null;
    proof.origin.tlsCertSha256 = originHandle.tlsCertSha256 ?? null;
    proof.origin.responseSha256 = originHandle.bodySha256 ?? proof.origin.responseSha256;
    proof.origin.requestObservations = originHandle.requestObservations ?? [];
    originHandle.fixturePath = proof.fixtures.matchConfig.path;
    originHandle.fixtureSha256 = proof.fixtures.matchConfig.sha256;

    hdcCommand = await resolveHdcCommand(toolchainInspectorImpl, repoRoot);
    const help = await verifyHdcHelp(execImpl, hdcCommand, repoRoot);
    if (!help.ok) {
      pushFailure(proof, help.failure.code, help.failure.detail, help.failure.stage);
      return await finish();
    }

    const targetResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
    const targetAnalysis = analyzeTargetDiscovery(targetResult);
    if (targetAnalysis.kind === 'missing') {
      pushFailure(proof, 'DEVICE_TARGET_MISSING', 'No HarmonyOS device target is available for Phase 2.', 'target');
      return await finish();
    }
    if (targetAnalysis.kind === 'ambiguous') {
      pushFailure(proof, 'DEVICE_TARGET_AMBIGUOUS', 'Phase 2 requires exactly one selected HarmonyOS device target.', 'target');
      return await finish();
    }
    target = targetAnalysis.targets[0];
    proof.device.identityMasked = createMaskedDeviceIdentity(target);

    const facts = {
      buildVersion: await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.software.version'], cwd: repoRoot }),
      apiVersion: await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.ohos.apiversion', 'const.product.apiversion'], cwd: repoRoot }),
      abi: await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.cpu.abilist'], cwd: repoRoot }),
      model: await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.model'], cwd: repoRoot }),
      product: await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.name', 'const.product.device'], cwd: repoRoot })
    };
    proof.device.buildVersion = facts.buildVersion.value;
    proof.device.apiVersion = facts.apiVersion.value;
    proof.device.abi = facts.abi.value;
    proof.device.model = facts.model.value;
    proof.device.product = facts.product.value;
    const classification = classifyTarget(proof.device);
    if (classification.kind !== 'physical') {
      pushFailure(proof, classification.code, classification.detail, 'target');
      return await finish();
    }
    proof.device.targetKind = 'physical';

    const installResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['install', '-r', resolvedHapPath]), { cwd: repoRoot });
    if (installResult?.timedOut || installResult?.error || installResult?.exitCode !== 0) {
      pushFailure(proof, 'HDC_INSTALL_FAILED', 'hdc install did not complete successfully.', 'install');
      return await finish();
    }
    installed = true;

    const launchResult = await execImpl(hdcCommand, buildLaunchArgs(target, proof.runId, proof.timestamps.runnerStartedAt, originHandle), { cwd: repoRoot });
    if (launchResult?.timedOut || launchResult?.error || launchResult?.exitCode !== 0) {
      pushFailure(proof, 'HDC_LAUNCH_FAILED', 'The self-test ability did not launch successfully.', 'launch');
      return await finish();
    }
    proof.timestamps.appStartedAt = isoTimestamp(now());

    const pullDirectory = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-pull', proof.runId);
    const localEvidencePath = path.join(pullDirectory, 'phase2-device-proof.json');
    const pulled = await pullPhase2AppEvidenceImpl({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      localPath: localEvidencePath,
      cwd: repoRoot,
      expectedRunId: proof.runId,
      waitImpl
    });
    const pulledOk = pulled?.ok === true || (pulled && pulled.proof && pulled.localPath);
    if (!pulledOk) {
      const failure = pulled?.invalid ?? createFailure('APP_EVIDENCE_MISSING', 'The app did not produce a usable Phase 2 evidence file.', 'app-proof');
      pushFailure(proof, failure.code, failure.detail, failure.stage);
      return await finish();
    }

    const evidenceDigest = await hashFile(fsApi, pulled.localPath);
    const appValidation = parsePhase2AppEvidence(pulled.proof, {
      expectedRunId: proof.runId,
      expectedFixturePath: proof.fixtures.matchConfig.path,
      expectedFixtureSha256: proof.fixtures.matchConfig.sha256
    });
    if (!appValidation.valid) {
      pushFailure(proof, 'APP_EVIDENCE_INVALID', appValidation.errors.join('; '), 'app-proof');
      return await finish();
    }
    const appProof = appValidation.normalized;
    proof.timestamps.proofAt = isoTimestamp(now());
    proof.appEvidence = {
      path: normalizePathForReport(repoRoot, pulled.localPath),
      sha256: evidenceDigest.sha256,
      sizeBytes: evidenceDigest.sizeBytes,
      runId: appProof.runId ?? null,
      originRunId: appProof.originRunId ?? null,
      appProcessId: appProof.appProcessId ?? null,
      stopResult: appProof.stop?.result ?? null,
      fixturePath: appProof.fixturePath ?? null,
      fixtureSha256: appProof.fixtureSha256 ?? null,
      coreVersion: appProof.coreVersion ?? null,
      httpListenerAddress: appProof.httpListenerAddress ?? null,
      socksListenerAddress: appProof.socksListenerAddress ?? null
    };
    proof.core.version = appProof.coreVersion ?? proof.core.version;
    proof.core.httpListenerAddress = appProof.httpListenerAddress ?? null;
    proof.core.socksListenerAddress = appProof.socksListenerAddress ?? null;
    proof.stop.result = appProof.stop?.result ?? 'fail';

    if (proof.appEvidence.runId !== proof.runId || proof.appEvidence.originRunId !== proof.runId) {
      pushFailure(proof, 'APP_EVIDENCE_RUN_ID_MISMATCH', 'Pulled app evidence runId/originRunId did not match the runner runId.', 'app-proof');
      return await finish();
    }
    if (proof.appEvidence.fixturePath !== proof.fixtures.matchConfig.path || proof.appEvidence.fixtureSha256 !== proof.fixtures.matchConfig.sha256) {
      pushFailure(proof, 'APP_EVIDENCE_FIXTURE_MISMATCH', 'Pulled app evidence fixture identity/hash did not match the runner fixture.', 'app-proof');
      return await finish();
    }

    if (typeof originHandle?.waitForRequestObservations === 'function') {
      proof.origin.requestObservations = await originHandle.waitForRequestObservations(2);
      if (proof.origin.requestObservations.length !== 2) {
        pushFailure(proof, 'ORIGIN_OBSERVATION_MISSING', 'Origin did not emit the exact two request observations required for Phase 2.', 'origin');
        return await finish();
      }
    }

    const observations = originObservationMap(proof.origin);
    for (const protocol of ['HTTP_CONNECT', 'SOCKS5']) {
      const protocolKey = protocol === 'HTTP_CONNECT' ? 'http' : 'socks';
      const probeFailure = correlateProbe({
        protocol,
        proof,
        appProbe: appProof.probes?.[protocolKey],
        originObservation: observations.get(appProof.probes?.[protocolKey]?.requestId),
        expectedListenerAddress: protocol === 'HTTP_CONNECT' ? proof.core.httpListenerAddress : proof.core.socksListenerAddress
      });
      if (probeFailure) {
        pushFailure(proof, probeFailure.code, probeFailure.detail, probeFailure.stage);
      }
    }
  } catch (error) {
    pushFailure(proof, error?.code ?? 'UNEXPECTED_ERROR', sanitizeText(error?.message ?? String(error), replacements), 'runner');
  } finally {
    if (originHandle?.stop) {
      try {
        await originHandle.stop();
        if (Array.isArray(originHandle.requestObservations) && originHandle.requestObservations.length > 0) {
          proof.origin.requestObservations = originHandle.requestObservations;
        }
        if (typeof originHandle.getInvalidRecords === 'function' && originHandle.getInvalidRecords().length > 0) {
          pushFailure(proof, 'ORIGIN_RECORD_INVALID', 'Origin emitted invalid or mismatched JSONL records.', 'origin');
        }
      } catch (error) {
        pushFailure(proof, 'ORIGIN_STOP_FAILED', sanitizeText(error?.message ?? 'Failed to stop the HTTPS origin.', replacements), 'cleanup');
      }
    }
    await fsApi.rm(path.join(repoRoot, 'harmony', 'artifacts', 'phase2-pull', proof.runId), { recursive: true, force: true }).catch(() => {});
    if (installed && hdcCommand && target) {
      try {
        const stopResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', BUNDLE_NAME]), { cwd: repoRoot });
        proof.stop.forceStopResult = (!stopResult?.timedOut && !stopResult?.error && stopResult?.exitCode === 0) ? 'pass' : 'fail';
        if (proof.stop.forceStopResult !== 'pass') {
          pushFailure(
            proof,
            stopResult?.timedOut ? 'HDC_TIMEOUT' : 'DEVICE_FORCE_STOP_FAILED',
            'The Phase 2 runner could not force-stop the installed proof app.',
            'cleanup'
          );
        }
      } catch {
        proof.stop.forceStopResult = 'fail';
        pushFailure(proof, 'DEVICE_FORCE_STOP_FAILED', 'The Phase 2 runner could not force-stop the installed proof app.', 'cleanup');
      }
    }
  }

  return await finish();
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
  startOriginImpl = startOriginProcess,
  pullPhase2AppEvidenceImpl = pullPhase2AppEvidence
} = {}) {
  let parsed;
  try {
    parsed = parseCliArgumentsPartial(argv, repoRoot);
    parseCliArguments(argv, repoRoot);
  } catch (error) {
    const partial = error?.partial ?? {
      buildManifestPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase2-build-manifest.json'),
      fixturePath: path.join(repoRoot, 'harmony', 'tests', 'fixtures', 'phase2-match-direct.yaml'),
      outputPath: path.join(repoRoot, 'harmony', 'artifacts', 'phase2-device-proof.json')
    };
    await writeArgumentErrorProof({
      outputPath: partial.outputPath,
      repoRoot,
      fsApi,
      randomUUID,
      now,
      detail: error?.message ?? 'Invalid CLI arguments.'
    });
    return 1;
  }

  const proof = await runPhase2DeviceProof({
    ...parsed,
    repoRoot,
    fsApi,
    randomUUID,
    now,
    buildPhase1NativeImpl,
    inspectHapImpl,
    toolchainInspectorImpl,
    execImpl,
    startOriginImpl,
    pullPhase2AppEvidenceImpl
  });
  return proof.result === 'pass' ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
