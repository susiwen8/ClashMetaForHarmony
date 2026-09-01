#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { ensureRepoScopedExistingFile, ensureRepoScopedOutputFile } from './repo-path-safety.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  execCommand
} from './run-phase0-device-proof.mjs';
import {
  buildProductionLaunchArgs,
  dumpLayoutToHost,
  normalizePhase4RuntimeJournal,
  pullBundleEvidenceJson,
  selectUniqueAppOngoingNotification,
  summarizeSystemUiAnchors,
  validateValueAgainstSchema
} from './run-phase4-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'home-traffic-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'home-traffic-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEFAULT_PROBE_HAP_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
const PROBE_ABILITY_NAME = 'ProbeAbility';
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const HASH_PATTERN = /^[a-f0-9]{64}$/u;
const ZERO_SHA256 = '0'.repeat(64);
const UI_POLL_INTERVAL_MS = 250;
const UI_POLL_ATTEMPTS = 24;
const HOME_TRAFFIC_IDS = Object.freeze({
  card: 'home.traffic.card',
  uploadSpeed: 'home.traffic.upload.speed',
  uploadTotal: 'home.traffic.upload.total',
  downloadSpeed: 'home.traffic.download.speed',
  downloadTotal: 'home.traffic.download.total',
  status: 'home.traffic.status'
});
const ROOT_ALLOWED_KEYS = new Set([
  'schemaVersion',
  'result',
  'packageSha256',
  'traffic'
]);
const TRAFFIC_ALLOWED_KEYS = new Set([
  'uploadRateObserved',
  'downloadRateObserved',
  'uploadTotalMonotonic',
  'downloadTotalMonotonic',
  'homeTrafficCardCount',
  'homeUploadSpeedSelectorCount',
  'homeUploadTotalSelectorCount',
  'homeDownloadSpeedSelectorCount',
  'homeDownloadTotalSelectorCount',
  'notificationTrafficUpdateCount',
  'homeNotificationAgreement'
]);
const NONZERO_NOTIFICATION_DETAILS = new Set([
  'notification-traffic-counters-nonzero',
  'notification-traffic-rate-nonzero'
]);
const SAFE_ERROR_CODES = Object.freeze({
  arguments: 'ARGUMENT_INVALID',
  toolchain: 'HOME_TRAFFIC_TOOLCHAIN_UNAVAILABLE',
  target: 'HOME_TRAFFIC_TARGET_UNAVAILABLE',
  install: 'HOME_TRAFFIC_INSTALL_FAILED',
  launch: 'HOME_TRAFFIC_LAUNCH_FAILED',
  layout: 'HOME_TRAFFIC_LAYOUT_UNAVAILABLE',
  probe: 'HOME_TRAFFIC_PROBE_UNAVAILABLE',
  output: 'HOME_TRAFFIC_OUTPUT_INVALID',
  cleanup: 'HOME_TRAFFIC_CLEANUP_FAILED'
});

function createTraffic() {
  return {
    uploadRateObserved: false,
    downloadRateObserved: false,
    uploadTotalMonotonic: false,
    downloadTotalMonotonic: false,
    homeTrafficCardCount: 0,
    homeUploadSpeedSelectorCount: 0,
    homeUploadTotalSelectorCount: 0,
    homeDownloadSpeedSelectorCount: 0,
    homeDownloadTotalSelectorCount: 0,
    notificationTrafficUpdateCount: 0,
    homeNotificationAgreement: false
  };
}

function createBaseProof() {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    packageSha256: ZERO_SHA256,
    traffic: createTraffic()
  };
}

function createFixedError(code) {
  return Object.assign(new Error(code), { code });
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function readSchemaDocument(fsApi = fs) {
  return JSON.parse(await fsApi.readFile(SCHEMA_PATH, 'utf8'));
}

function collectLayoutNodes(root, nodes = []) {
  if (Array.isArray(root)) {
    for (const entry of root) {
      collectLayoutNodes(entry, nodes);
    }
    return nodes;
  }
  if (!isObject(root)) {
    return nodes;
  }
  nodes.push(root);
  for (const child of root.children ?? []) {
    collectLayoutNodes(child, nodes);
  }
  return nodes;
}

function collectTextFragments(node, output = []) {
  if (!isObject(node)) {
    return output;
  }
  for (const value of [node.attributes?.text, node.attributes?.accessibilityText]) {
    if (typeof value === 'string' && value.trim().length > 0) {
      output.push(value.trim());
    }
  }
  for (const child of node.children ?? []) {
    collectTextFragments(child, output);
  }
  return output;
}

function countSemanticNodes(layout, semanticId) {
  return collectLayoutNodes(layout?.root ?? layout).filter((node) => `${node?.attributes?.id ?? ''}` === semanticId).length;
}

function selectUniqueSemanticNode(layout, semanticId) {
  const matches = collectLayoutNodes(layout?.root ?? layout).filter((node) => `${node?.attributes?.id ?? ''}` === semanticId);
  if (matches.length === 0) {
    throw createFixedError('HOME_TRAFFIC_SELECTOR_MISSING');
  }
  if (matches.length > 1) {
    throw createFixedError('HOME_TRAFFIC_SELECTOR_AMBIGUOUS');
  }
  return matches[0];
}

function parseTrafficDisplayValue(text, { expectSpeed }) {
  const pattern = expectSpeed
    ? /^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)\/s$/u
    : /^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)$/u;
  const match = `${text ?? ''}`.trim().match(pattern);
  if (!match) {
    throw createFixedError('HOME_TRAFFIC_METRIC_TEXT_INVALID');
  }
  const value = Number.parseFloat(match[1]);
  const units = { B: 1, KB: 1024, MB: 1024 ** 2, GB: 1024 ** 3, TB: 1024 ** 4 };
  return Math.floor(value * units[match[2]]);
}

function readSnapshot(layout) {
  selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.card);
  selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.status);
  return {
    homeTrafficCardCount: countSemanticNodes(layout, HOME_TRAFFIC_IDS.card),
    homeUploadSpeedSelectorCount: countSemanticNodes(layout, HOME_TRAFFIC_IDS.uploadSpeed),
    homeUploadTotalSelectorCount: countSemanticNodes(layout, HOME_TRAFFIC_IDS.uploadTotal),
    homeDownloadSpeedSelectorCount: countSemanticNodes(layout, HOME_TRAFFIC_IDS.downloadSpeed),
    homeDownloadTotalSelectorCount: countSemanticNodes(layout, HOME_TRAFFIC_IDS.downloadTotal),
    uploadSpeed: parseTrafficDisplayValue(
      collectTextFragments(selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.uploadSpeed)).join(' '),
      { expectSpeed: true }
    ),
    uploadTotal: parseTrafficDisplayValue(
      collectTextFragments(selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.uploadTotal)).join(' '),
      { expectSpeed: false }
    ),
    downloadSpeed: parseTrafficDisplayValue(
      collectTextFragments(selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.downloadSpeed)).join(' '),
      { expectSpeed: true }
    ),
    downloadTotal: parseTrafficDisplayValue(
      collectTextFragments(selectUniqueSemanticNode(layout, HOME_TRAFFIC_IDS.downloadTotal)).join(' '),
      { expectSpeed: false }
    )
  };
}

function assertStableSelectorCounts(...snapshots) {
  const keys = [
    'homeTrafficCardCount',
    'homeUploadSpeedSelectorCount',
    'homeUploadTotalSelectorCount',
    'homeDownloadSpeedSelectorCount',
    'homeDownloadTotalSelectorCount'
  ];
  for (const key of keys) {
    const expected = snapshots[0][key];
    if (!snapshots.every((snapshot) => snapshot[key] === expected && snapshot[key] === 1)) {
      throw createFixedError('HOME_TRAFFIC_LAYOUT_INVALID');
    }
  }
}

export function analyzeHomeTrafficLayouts(beforeLayout, uploadLayout, downloadLayout) {
  const beforeSnapshot = readSnapshot(beforeLayout);
  const uploadSnapshot = readSnapshot(uploadLayout);
  const downloadSnapshot = readSnapshot(downloadLayout);
  assertStableSelectorCounts(beforeSnapshot, uploadSnapshot, downloadSnapshot);

  return {
    uploadRateObserved: uploadSnapshot.uploadSpeed > beforeSnapshot.uploadSpeed && uploadSnapshot.uploadSpeed > 0,
    downloadRateObserved: downloadSnapshot.downloadSpeed > beforeSnapshot.downloadSpeed && downloadSnapshot.downloadSpeed > 0,
    uploadTotalMonotonic: beforeSnapshot.uploadTotal <= uploadSnapshot.uploadTotal &&
      uploadSnapshot.uploadTotal <= downloadSnapshot.uploadTotal,
    downloadTotalMonotonic: beforeSnapshot.downloadTotal <= uploadSnapshot.downloadTotal &&
      uploadSnapshot.downloadTotal <= downloadSnapshot.downloadTotal,
    homeTrafficCardCount: downloadSnapshot.homeTrafficCardCount,
    homeUploadSpeedSelectorCount: downloadSnapshot.homeUploadSpeedSelectorCount,
    homeUploadTotalSelectorCount: downloadSnapshot.homeUploadTotalSelectorCount,
    homeDownloadSpeedSelectorCount: downloadSnapshot.homeDownloadSpeedSelectorCount,
    homeDownloadTotalSelectorCount: downloadSnapshot.homeDownloadTotalSelectorCount,
    notificationTrafficUpdateCount: 0,
    homeNotificationAgreement: false
  };
}

function collectSensitiveKeyErrors(value, trail = 'proof', errors = []) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectSensitiveKeyErrors(entry, `${trail}[${index}]`, errors));
    return errors;
  }
  if (!isObject(value)) {
    return errors;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (trail === 'proof' && !ROOT_ALLOWED_KEYS.has(key)) {
      errors.push(`${trail}.${key} is not allowed`);
    }
    if (trail === 'proof.traffic' && !TRAFFIC_ALLOWED_KEYS.has(key)) {
      errors.push(`${trail}.${key} is not allowed`);
    }
    if (/(?:serial|secret|token|password|profile|node|subscription|host|path|url)/iu.test(key)) {
      errors.push(`${trail}.${key} is not allowed`);
    }
    collectSensitiveKeyErrors(entry, `${trail}.${key}`, errors);
  }
  return errors;
}

export async function validateHomeTrafficProofDocument(proof, schemaOrFsApi = null) {
  const schema = isObject(schemaOrFsApi) && '$schema' in schemaOrFsApi
    ? schemaOrFsApi
    : await readSchemaDocument(isObject(schemaOrFsApi) ? schemaOrFsApi : fs);
  const validation = validateValueAgainstSchema(proof, schema, schema);
  const sensitiveErrors = collectSensitiveKeyErrors(proof, 'proof', []);
  return {
    valid: validation.valid && sensitiveErrors.length === 0,
    errors: validation.errors.concat(sensitiveErrors)
  };
}

function proofPassesContract(proof) {
  const traffic = proof?.traffic ?? {};
  return proof?.result === 'pass'
    && HASH_PATTERN.test(`${proof.packageSha256 ?? ''}`)
    && proof.packageSha256 !== ZERO_SHA256
    && traffic.uploadRateObserved === true
    && traffic.downloadRateObserved === true
    && traffic.uploadTotalMonotonic === true
    && traffic.downloadTotalMonotonic === true
    && traffic.homeTrafficCardCount === 1
    && traffic.homeUploadSpeedSelectorCount === 1
    && traffic.homeUploadTotalSelectorCount === 1
    && traffic.homeDownloadSpeedSelectorCount === 1
    && traffic.homeDownloadTotalSelectorCount === 1
    && Number.isInteger(traffic.notificationTrafficUpdateCount)
    && traffic.notificationTrafficUpdateCount > 0
    && traffic.homeNotificationAgreement === true;
}

function canonicalizeIncompleteProof() {
  return createBaseProof();
}

function normalizeWriteOptions(optionsOrPath, fsApi, repoRoot) {
  if (typeof optionsOrPath === 'string') {
    return {
      schema: null,
      outputPath: optionsOrPath,
      fsApi,
      repoRoot
    };
  }
  if (isObject(optionsOrPath)) {
    return {
      schema: optionsOrPath.schema ?? null,
      outputPath: optionsOrPath.outputPath ?? DEFAULT_OUTPUT_PATH,
      fsApi: optionsOrPath.fsApi ?? fsApi,
      repoRoot: optionsOrPath.repoRoot ?? repoRoot
    };
  }
  return {
    schema: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    fsApi,
    repoRoot
  };
}

export async function writeValidatedHomeTrafficProof(proof, optionsOrPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const resolved = normalizeWriteOptions(optionsOrPath, fsApi, repoRoot);
  const candidate = structuredClone(proof);
  if (!proofPassesContract(candidate)) {
    candidate.result = 'incomplete';
  }
  const validation = await validateHomeTrafficProofDocument(candidate, resolved.schema ?? resolved.fsApi).catch(() => ({
    valid: false,
    errors: [SAFE_ERROR_CODES.output]
  }));
  const persisted = validation.valid && candidate.result === 'pass'
    ? candidate
    : canonicalizeIncompleteProof();
  const safeOutputPath = await ensureRepoScopedOutputFile(resolved.fsApi, resolved.repoRoot, resolved.outputPath, '--out');
  const tempPath = `${safeOutputPath}.${process.pid}.${Date.now()}.tmp`;
  await resolved.fsApi.writeFile(tempPath, `${JSON.stringify(persisted, null, 2)}\n`, 'utf8');
  await resolved.fsApi.rename(tempPath, safeOutputPath);
  return persisted;
}

export async function writeArgumentErrorProof({
  outputPath = DEFAULT_OUTPUT_PATH,
  fsApi = fs,
  repoRoot = REPO_ROOT
} = {}) {
  return await writeValidatedHomeTrafficProof(createBaseProof(), { outputPath, fsApi, repoRoot });
}

function parseOptionValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw createFixedError(`${SAFE_ERROR_CODES.arguments}:${option}`);
  }
  return value;
}

export function parseCliArguments(argv = process.argv.slice(2)) {
  const parsed = {
    serial: null,
    productionHapPath: DEFAULT_PRODUCTION_HAP_PATH,
    probeHapPath: DEFAULT_PROBE_HAP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!option.startsWith('--')) {
      throw createFixedError(SAFE_ERROR_CODES.arguments);
    }
    const value = parseOptionValue(argv, index, option);
    if (option === '--serial') {
      parsed.serial = value;
    } else if (option === '--production-hap') {
      parsed.productionHapPath = path.resolve(value);
    } else if (option === '--probe-hap') {
      parsed.probeHapPath = path.resolve(value);
    } else if (option === '--out') {
      parsed.outputPath = path.resolve(value);
    } else {
      throw createFixedError(SAFE_ERROR_CODES.arguments);
    }
    index += 1;
  }
  return parsed;
}

async function hashFile(fsApi, filePath) {
  const buffer = await fsApi.readFile(filePath);
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

async function resolveToolchainAndTarget({
  repoRoot,
  execImpl,
  toolchainInspectorImpl = inspectToolchain,
  serial = null
}) {
  const toolchain = await toolchainInspectorImpl({ cwd: repoRoot });
  if (toolchain?.report?.result !== 'pass' || !toolchain?.resolved?.paths?.hdc) {
    throw createFixedError(SAFE_ERROR_CODES.toolchain);
  }
  const hdcCommand = toolchain.resolved.paths.hdc;
  if (typeof serial === 'string' && serial.trim().length > 0) {
    return { hdcCommand, target: serial.trim() };
  }
  const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
  const analysis = analyzeTargetDiscovery(targetsResult);
  if (analysis.kind !== 'selected' || analysis.targets.length !== 1) {
    throw createFixedError(SAFE_ERROR_CODES.target);
  }
  return { hdcCommand, target: analysis.targets[0] };
}

async function installHap({ target, hdcCommand, execImpl, cwd, hapPath }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['install', '-r', hapPath]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.install);
  }
}

async function forceStopBundle({ target, hdcCommand, execImpl, cwd, bundleName }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', bundleName]),
    { cwd }
  ).catch(() => null);
  if (result === null) {
    return false;
  }
  return !(result?.error || result?.timedOut || result?.exitCode !== 0);
}

async function launchProduction({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(hdcCommand, buildProductionLaunchArgs(target, ''), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.launch);
  }
}

async function dumpLayout({ target, hdcCommand, execImpl, cwd, localPath }) {
  return await dumpLayoutToHost({
    execImpl,
    hdcCommand,
    target,
    localPath,
    cwd
  });
}

async function waitForHomeTrafficLayout({ target, hdcCommand, execImpl, cwd, localPath, attempts = UI_POLL_ATTEMPTS }) {
  let lastError = createFixedError(SAFE_ERROR_CODES.layout);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await dumpLayout({ target, hdcCommand, execImpl, cwd, localPath });
    try {
      readSnapshot(layout);
      return layout;
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < attempts) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw lastError;
}

function buildProbeStageLaunchArgs(target, mode, marker) {
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', PROBE_ABILITY_NAME,
    '-b', PROBE_BUNDLE,
    '--ps', 'runId', marker,
    '--ps', 'captureMode', mode
  ]);
}

async function defaultRunProbeStage({
  target,
  hdcCommand,
  execImpl,
  cwd,
  stage,
  marker
}) {
  const result = await execImpl(hdcCommand, buildProbeStageLaunchArgs(target, stage, marker), { cwd }).catch(() => null);
  if (result === null || result?.error || result?.timedOut || result?.exitCode !== 0) {
    return { ok: false };
  }
  return { ok: true };
}

async function readRuntimeJournal({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localPath
}) {
  const pulled = await pullBundleEvidenceJson({
    fsApi,
    execImpl,
    hdcCommand,
    target,
    bundleName: APP_BUNDLE,
    remotePath: RUNTIME_REMOTE_PATH,
    localPath,
    cwd
  });
  if (!pulled.ok) {
    return null;
  }
  return normalizePhase4RuntimeJournal(pulled.proof);
}

function analyzeNotificationEvidence(runtimeJournal, notificationLayout = null) {
  const traffic = createTraffic();
  if (!isObject(runtimeJournal)) {
    return traffic;
  }
  traffic.notificationTrafficUpdateCount = runtimeJournal.records.filter((record) =>
    record?.kind === 'lifecycle' &&
    typeof record?.detail === 'string' &&
    NONZERO_NOTIFICATION_DETAILS.has(record.detail)
  ).length;

  if (!notificationLayout) {
    return traffic;
  }
  try {
    selectUniqueAppOngoingNotification(notificationLayout);
    const summary = summarizeSystemUiAnchors(notificationLayout);
    traffic.homeNotificationAgreement = traffic.notificationTrafficUpdateCount > 0 &&
      summary.appBackgroundModeListItemCount === 1 &&
      summary.appBundleListItemCount >= 1;
  } catch {
    traffic.homeNotificationAgreement = false;
  }
  return traffic;
}

async function defaultCollectEvidence({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  tempRoot,
  runProbeStageImpl = defaultRunProbeStage,
  readNotificationLayoutImpl = null
}) {
  const beforeLayoutPath = path.join(tempRoot, `home-traffic-before-${process.pid}-${Date.now()}.json`);
  const runtimePath = path.join(tempRoot, `home-traffic-runtime-${process.pid}-${Date.now()}.json`);
  const evidence = {
    beforeLayout: null,
    uploadLayout: null,
    downloadLayout: null,
    notificationLayout: null,
    runtimeJournal: null,
    beforeLayoutPath,
    uploadLayoutPath: beforeLayoutPath,
    downloadLayoutPath: beforeLayoutPath,
    runtimePath
  };
  await launchProduction({ target, hdcCommand, execImpl, cwd });
  evidence.beforeLayout = await waitForHomeTrafficLayout({
    target,
    hdcCommand,
    execImpl,
    cwd,
    localPath: beforeLayoutPath
  }).catch(() => null);

  if (evidence.beforeLayout !== null) {
    const upload = await runProbeStageImpl({
      target,
      hdcCommand,
      execImpl,
      cwd,
      stage: 'upload',
      marker: `upload-${Date.now()}`
    }).catch(() => ({ ok: false }));
    if (upload?.ok) {
      evidence.uploadLayout = await waitForHomeTrafficLayout({
        target,
        hdcCommand,
        execImpl,
        cwd,
        localPath: beforeLayoutPath
      }).catch(() => null);
    }

    const download = await runProbeStageImpl({
      target,
      hdcCommand,
      execImpl,
      cwd,
      stage: 'download',
      marker: `download-${Date.now()}`
    }).catch(() => ({ ok: false }));
    if (download?.ok) {
      evidence.downloadLayout = await waitForHomeTrafficLayout({
        target,
        hdcCommand,
        execImpl,
        cwd,
        localPath: beforeLayoutPath
      }).catch(() => null);
    }
  }

  evidence.runtimeJournal = await readRuntimeJournal({
    fsApi,
    target,
    hdcCommand,
    execImpl,
    cwd,
    localPath: runtimePath
  }).catch(() => null);

  if (typeof readNotificationLayoutImpl === 'function') {
    evidence.notificationLayout = await readNotificationLayoutImpl().catch(() => null);
  }
  return evidence;
}

async function cleanupTempFiles(fsApi, localPaths) {
  await Promise.all(localPaths.map(async (filePath) => await fsApi.rm(filePath, { force: true }).catch(() => {})));
}

async function cleanupDeviceState({
  target,
  hdcCommand,
  execImpl,
  cwd
}) {
  const results = await Promise.all([
    forceStopBundle({ target, hdcCommand, execImpl, cwd, bundleName: PROBE_BUNDLE }),
    forceStopBundle({ target, hdcCommand, execImpl, cwd, bundleName: APP_BUNDLE })
  ]);
  if (results.includes(false)) {
    throw createFixedError(SAFE_ERROR_CODES.cleanup);
  }
}

function mergeTrafficEvidence(layoutEvidence, notificationEvidence) {
  return {
    ...layoutEvidence,
    notificationTrafficUpdateCount: notificationEvidence.notificationTrafficUpdateCount,
    homeNotificationAgreement: notificationEvidence.homeNotificationAgreement
  };
}

export async function runHomeTrafficDeviceProof({
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  toolchainInspectorImpl = inspectToolchain,
  hashFileImpl = hashFile,
  collectEvidenceImpl = defaultCollectEvidence,
  writeValidatedProofImpl = writeValidatedHomeTrafficProof,
  serial = null,
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  probeHapPath = DEFAULT_PROBE_HAP_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  tempRoot = os.tmpdir()
} = {}) {
  const proof = createBaseProof();
  const localTempPaths = [];
  let target = null;
  let hdcCommand = null;
  try {
    const safeProductionHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionHapPath, '--production-hap');
    const safeProbeHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, probeHapPath, '--probe-hap');
    const packageSha256 = await hashFileImpl(fsApi, safeProductionHapPath);
    if (HASH_PATTERN.test(`${packageSha256 ?? ''}`)) {
      proof.packageSha256 = packageSha256;
    }

    const resolved = await resolveToolchainAndTarget({
      repoRoot,
      execImpl,
      toolchainInspectorImpl,
      serial
    });
    target = resolved.target;
    hdcCommand = resolved.hdcCommand;

    await cleanupDeviceState({ target, hdcCommand, execImpl, cwd: repoRoot }).catch(() => {});
    await installHap({ target, hdcCommand, execImpl, cwd: repoRoot, hapPath: safeProductionHapPath });
    await installHap({ target, hdcCommand, execImpl, cwd: repoRoot, hapPath: safeProbeHapPath });

    const evidence = await collectEvidenceImpl({
      fsApi,
      target,
      hdcCommand,
      execImpl,
      cwd: repoRoot,
      tempRoot
    });
    for (const candidate of [evidence?.beforeLayoutPath, evidence?.uploadLayoutPath, evidence?.downloadLayoutPath, evidence?.runtimePath]) {
      if (typeof candidate === 'string') {
        localTempPaths.push(candidate);
      }
    }

    if (evidence?.beforeLayout && evidence?.uploadLayout && evidence?.downloadLayout) {
      const layoutTraffic = analyzeHomeTrafficLayouts(
        evidence.beforeLayout,
        evidence.uploadLayout,
        evidence.downloadLayout
      );
      const notificationTraffic = analyzeNotificationEvidence(
        evidence.runtimeJournal,
        evidence.notificationLayout
      );
      proof.traffic = mergeTrafficEvidence(layoutTraffic, notificationTraffic);
      proof.result = proofPassesContract({
        ...proof,
        result: 'pass'
      })
        ? 'pass'
        : 'incomplete';
    }
  } catch (error) {
    if (!String(error?.code ?? '').startsWith(SAFE_ERROR_CODES.arguments)) {
      proof.result = 'incomplete';
    }
  } finally {
    if (target && hdcCommand) {
      await cleanupDeviceState({ target, hdcCommand, execImpl, cwd: repoRoot }).catch(() => {});
    }
    await cleanupTempFiles(fsApi, localTempPaths);
  }
  return await writeValidatedProofImpl(proof, { outputPath, fsApi, repoRoot });
}

async function main() {
  try {
    await runHomeTrafficDeviceProof(parseCliArguments());
  } catch (error) {
    const safeOut = (() => {
      try {
        return parseCliArguments(process.argv.slice(2)).outputPath;
      } catch {
        return DEFAULT_OUTPUT_PATH;
      }
    })();
    await writeArgumentErrorProof({ outputPath: safeOut });
    process.stderr.write(`${error?.code ?? SAFE_ERROR_CODES.arguments}\n`);
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileUrl(process.argv[1]).href) {
  void main();
}

function pathToFileUrl(filePath) {
  return pathToFileURL(path.resolve(filePath));
}
