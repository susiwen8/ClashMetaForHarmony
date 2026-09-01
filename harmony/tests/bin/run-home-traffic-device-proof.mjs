#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import {
  defaultListArchiveEntries,
  defaultReadSignature,
  defaultVerifySignature
} from './inspect-phase4-packages.mjs';
import {
  createDefaultPhase4ExternalOrigin,
  normalizePhase4ExternalOrigin
} from './phase4-external-origin.mjs';
import { ensureRepoScopedExistingFile, ensureRepoScopedOutputFile } from './repo-path-safety.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  execCommand
} from './run-phase0-device-proof.mjs';
import {
  buildProductionLaunchArgs,
  defaultRunVpnProbeImpl,
  defaultStartOrigin,
  dumpLayoutToHost,
  openNotificationCenter,
  readDeviceLanIpv4Candidates,
  selectUniqueAppOngoingNotification,
  validateValueAgainstSchema,
  waitForUniqueLayoutSelection
} from './run-phase4-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'home-traffic-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'home-traffic-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEFAULT_PROBE_HAP_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
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
const SAFE_ERROR_CODES = Object.freeze({
  arguments: 'ARGUMENT_INVALID',
  toolchain: 'HOME_TRAFFIC_TOOLCHAIN_UNAVAILABLE',
  target: 'HOME_TRAFFIC_TARGET_UNAVAILABLE',
  install: 'HOME_TRAFFIC_INSTALL_FAILED',
  launch: 'HOME_TRAFFIC_LAUNCH_FAILED',
  layout: 'HOME_TRAFFIC_LAYOUT_UNAVAILABLE',
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

export async function defaultVerifySignedHap(hapPath, {
  listArchiveEntriesImpl = defaultListArchiveEntries,
  readSignatureImpl = defaultReadSignature,
  verifySignatureImpl = async (options) => await defaultVerifySignature(options)
} = {}) {
  if (/-unsigned\.hap$/iu.test(path.basename(`${hapPath ?? ''}`))) {
    return false;
  }
  try {
    const archiveListing = await listArchiveEntriesImpl(hapPath);
    const embeddedSignature = await readSignatureImpl(hapPath, archiveListing);
    const verifiedSignature = await verifySignatureImpl({ hapPath });
    return HASH_PATTERN.test(`${embeddedSignature?.signatureSha256 ?? ''}`) &&
      HASH_PATTERN.test(`${verifiedSignature?.signatureSha256 ?? ''}`);
  } catch {
    return false;
  }
}

export async function defaultCloseNotificationCenter({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Back']),
    { cwd }
  );
  return !(result?.error || result?.timedOut || result?.exitCode !== 0);
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
    ? /^(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)\/s$/u
    : /^(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)$/u;
  const match = `${text ?? ''}`.trim().match(pattern);
  if (!match) {
    throw createFixedError('HOME_TRAFFIC_METRIC_TEXT_INVALID');
  }
  const value = Number.parseFloat(match[1]);
  const units = { B: 1, KiB: 1024, MiB: 1024 ** 2, GiB: 1024 ** 3 };
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

function parseNotificationTrafficText(text) {
  const match = `${text ?? ''}`.trim().match(/^↑\s*(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)\/s\s+↓\s*(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB)\/s$/u);
  if (!match) {
    throw createFixedError('HOME_TRAFFIC_NOTIFICATION_TEXT_INVALID');
  }
  return {
    uploadSpeed: parseTrafficDisplayValue(`${match[1]} ${match[2]}/s`, { expectSpeed: true }),
    downloadSpeed: parseTrafficDisplayValue(`${match[3]} ${match[4]}/s`, { expectSpeed: true })
  };
}

function normalizeNotificationLayouts(notificationLayouts) {
  if (Array.isArray(notificationLayouts)) {
    return notificationLayouts;
  }
  return notificationLayouts ? [notificationLayouts] : [];
}

function extractUniqueNotificationPair(notificationLayout) {
  const selection = selectUniqueAppOngoingNotification(notificationLayout);
  const textCandidates = [];
  const joined = collectTextFragments(selection.node).join(' ');
  if (joined.length > 0) {
    textCandidates.push(joined);
  }
  for (const fragment of collectTextFragments(selection.node)) {
    textCandidates.push(fragment);
  }
  const matching = [...new Set(textCandidates.filter((value) => /^↑\s*\d/u.test(value)))];
  if (matching.length !== 1) {
    throw createFixedError(matching.length === 0 ? 'HOME_TRAFFIC_NOTIFICATION_MISSING' : 'HOME_TRAFFIC_NOTIFICATION_AMBIGUOUS');
  }
  return parseNotificationTrafficText(matching[0]);
}

export function trafficRatesAgreeWithinTolerance(leftBytesPerSecond, rightBytesPerSecond) {
  if (!Number.isSafeInteger(leftBytesPerSecond) || !Number.isSafeInteger(rightBytesPerSecond)) {
    return false;
  }
  if (leftBytesPerSecond <= 0 || rightBytesPerSecond <= 0) {
    return false;
  }
  const difference = Math.abs(leftBytesPerSecond - rightBytesPerSecond);
  const tolerance = Math.max(1024, Math.floor(Math.max(leftBytesPerSecond, rightBytesPerSecond) * 0.25));
  return difference <= tolerance;
}

export function analyzeHomeTrafficNotificationEvidence(homeLayout, notificationLayouts) {
  const homeSnapshot = readSnapshot(homeLayout);
  const layouts = normalizeNotificationLayouts(notificationLayouts);
  let distinctNonzeroCount = 0;
  let previousPairKey = '';
  let homeNotificationAgreement = false;
  for (const layout of layouts) {
    const pair = extractUniqueNotificationPair(layout);
    const nonzero = pair.uploadSpeed > 0 || pair.downloadSpeed > 0;
    const pairKey = `${pair.uploadSpeed}:${pair.downloadSpeed}`;
    if (nonzero) {
      if (pairKey !== previousPairKey) {
        distinctNonzeroCount += 1;
        previousPairKey = pairKey;
      }
      if (
        trafficRatesAgreeWithinTolerance(homeSnapshot.uploadSpeed, pair.uploadSpeed) &&
        trafficRatesAgreeWithinTolerance(homeSnapshot.downloadSpeed, pair.downloadSpeed)
      ) {
        homeNotificationAgreement = true;
      }
    }
  }
  return {
    notificationTrafficUpdateCount: distinctNonzeroCount,
    homeNotificationAgreement
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

export async function validateHomeTrafficProofDocument(proof, schemaOrFsApi = null) {
  const schema = isObject(schemaOrFsApi) && '$schema' in schemaOrFsApi
    ? schemaOrFsApi
    : await readSchemaDocument(isObject(schemaOrFsApi) ? schemaOrFsApi : fs);
  const validation = validateValueAgainstSchema(proof, schema, schema);
  const sensitiveErrors = collectSensitiveKeyErrors(proof, 'proof', []);
  const contractErrors = proof.result === 'pass' && !proofPassesContract(proof)
    ? ['proof must satisfy the pass contract']
    : [];
  return {
    valid: validation.valid && sensitiveErrors.length === 0 && contractErrors.length === 0,
    errors: validation.errors.concat(sensitiveErrors, contractErrors)
  };
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

async function launchProduction({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(hdcCommand, buildProductionLaunchArgs(target, ''), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.launch);
  }
}

async function cleanupTempFiles(fsApi, localPaths) {
  await Promise.all(localPaths.map(async (filePath) => {
    if (typeof filePath === 'string' && filePath.length > 0) {
      await fsApi.rm(filePath, { force: true }).catch(() => {});
    }
  }));
}

async function waitForHomeTrafficLayout({
  readLayoutImpl,
  attempts = UI_POLL_ATTEMPTS,
  pollIntervalMs = UI_POLL_INTERVAL_MS,
  delayImpl = async (milliseconds) => await delay(milliseconds)
}) {
  let lastError = createFixedError(SAFE_ERROR_CODES.layout);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      readSnapshot(layout);
      return layout;
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < attempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  throw lastError;
}

function isUploadSample(beforeLayout, currentLayout) {
  const beforeSnapshot = readSnapshot(beforeLayout);
  const currentSnapshot = readSnapshot(currentLayout);
  return currentSnapshot.uploadSpeed > beforeSnapshot.uploadSpeed &&
    currentSnapshot.uploadSpeed > 0 &&
    currentSnapshot.uploadTotal >= beforeSnapshot.uploadTotal;
}

function isDownloadSample(beforeLayout, uploadLayout, currentLayout) {
  const beforeSnapshot = readSnapshot(beforeLayout);
  const uploadSnapshot = readSnapshot(uploadLayout ?? beforeLayout);
  const currentSnapshot = readSnapshot(currentLayout);
  return currentSnapshot.downloadSpeed > beforeSnapshot.downloadSpeed &&
    currentSnapshot.downloadSpeed > 0 &&
    currentSnapshot.downloadTotal >= uploadSnapshot.downloadTotal;
}

function probeResultHasPositiveTraffic(probeResult) {
  const rawRecords = Array.isArray(probeResult?.raw?.records) ? probeResult.raw.records : [];
  const normalizedRecords = Array.isArray(probeResult?.normalized?.records) ? probeResult.normalized.records : [];
  return probeResult?.result === 'pass'
    && normalizedRecords.length > 0
    && rawRecords.some((record) =>
      record?.outcome === 'pass' &&
      Number.isSafeInteger(record?.bytesSent) &&
      Number.isSafeInteger(record?.bytesReceived) &&
      record.bytesSent > 0 &&
      record.bytesReceived > 0
    );
}

export async function defaultCollectEvidence({
  fsApi = fs,
  target,
  hdcCommand,
  execImpl = execCommand,
  cwd = REPO_ROOT,
  tempRoot = os.tmpdir(),
  runId = crypto.randomUUID(),
  launchProductionImpl = async (options) => await launchProduction(options),
  dumpLayoutImpl = async ({ localPath }) => await dumpLayoutToHost({
    execImpl,
    hdcCommand,
    target,
    localPath,
    cwd
  }),
  readDeviceLanIpv4CandidatesImpl = async (options) => await readDeviceLanIpv4Candidates({ execImpl, ...options }),
  createExternalOriginImpl = async () => createDefaultPhase4ExternalOrigin(),
  normalizeExternalOriginImpl = normalizePhase4ExternalOrigin,
  startOriginImpl = async (options) => await defaultStartOrigin(options),
  runVpnProbeImpl = async (options) => await defaultRunVpnProbeImpl(options),
  openNotificationCenterImpl = openNotificationCenter,
  closeNotificationCenterImpl = async (options) => await defaultCloseNotificationCenter(options),
  waitForUniqueLayoutSelectionImpl = waitForUniqueLayoutSelection,
  delayImpl = async (milliseconds) => await delay(milliseconds)
} = {}) {
  const homeLayoutPath = path.join(tempRoot, `home-traffic-home-${process.pid}-${Date.now()}.json`);
  const notificationLayoutPath = path.join(tempRoot, `home-traffic-notification-${process.pid}-${Date.now()}.json`);
  const evidence = {
    beforeLayout: null,
    uploadLayout: null,
    downloadLayout: null,
    notificationHomeLayout: null,
    notificationLayouts: [],
    probeResult: { result: 'fail', raw: null, normalized: null },
    homeLayoutPath,
    notificationLayoutPath
  };
  let originHandle = null;
  let probePromise = null;
  let notificationCenterOpened = false;
  const readHomeLayout = async () => await dumpLayoutImpl({ target, hdcCommand, execImpl, cwd, localPath: homeLayoutPath });
  const readNotificationLayout = async () => await dumpLayoutImpl({ target, hdcCommand, execImpl, cwd, localPath: notificationLayoutPath });
  try {
    await launchProductionImpl({ target, hdcCommand, execImpl, cwd });
    evidence.beforeLayout = await waitForHomeTrafficLayout({
      readLayoutImpl: readHomeLayout,
      delayImpl
    });
    const deviceIpv4Candidates = await readDeviceLanIpv4CandidatesImpl({ target, hdcCommand, cwd });
    const externalOrigin = normalizeExternalOriginImpl(await createExternalOriginImpl());
    originHandle = await startOriginImpl({ runId, deviceIpv4Candidates });

    const probeState = { done: false, result: null };
    probePromise = Promise.resolve(runVpnProbeImpl({
      target,
      hdcCommand,
      execImpl,
      origin: originHandle,
      externalOrigin,
      cwd,
      fsApi,
      tempRoot,
      runId
    })).then((result) => {
      probeState.done = true;
      probeState.result = result;
      return result;
    }).catch((error) => {
      probeState.done = true;
      probeState.result = { result: 'fail', raw: null, normalized: null, error };
      return probeState.result;
    });

    let notificationAttempted = false;
    for (let attempt = 0; attempt < UI_POLL_ATTEMPTS; attempt += 1) {
      if (probeState.done && !probeResultHasPositiveTraffic(probeState.result)) {
        break;
      }
      const currentLayout = await readHomeLayout().catch(() => null);
      if (currentLayout !== null && !probeState.done) {
        if (evidence.uploadLayout === null && isUploadSample(evidence.beforeLayout, currentLayout)) {
          evidence.uploadLayout = currentLayout;
        }
        if (evidence.uploadLayout !== null &&
          evidence.downloadLayout === null &&
          isDownloadSample(evidence.beforeLayout, evidence.uploadLayout, currentLayout)) {
          evidence.downloadLayout = currentLayout;
        }
        if (!notificationAttempted && evidence.uploadLayout !== null && evidence.downloadLayout !== null) {
          notificationAttempted = true;
          evidence.notificationHomeLayout = currentLayout;
          try {
            await openNotificationCenterImpl(currentLayout, { target, hdcCommand, execImpl, cwd });
            notificationCenterOpened = true;
            const notificationEvidence = await waitForUniqueLayoutSelectionImpl({
              readLayoutImpl: readNotificationLayout,
              selectImpl: selectUniqueAppOngoingNotification,
              maxAttempts: UI_POLL_ATTEMPTS,
              delayImpl
            });
            evidence.notificationLayouts.push(notificationEvidence.layout);
            while (!probeState.done && evidence.notificationLayouts.length < 3) {
              await delayImpl(UI_POLL_INTERVAL_MS);
              evidence.notificationLayouts.push(await readNotificationLayout());
            }
          } catch {
            evidence.notificationHomeLayout = null;
            evidence.notificationLayouts = [];
          }
        }
      }
      if (probeState.done) {
        break;
      }
      await delayImpl(UI_POLL_INTERVAL_MS);
    }

    evidence.probeResult = await probePromise;
    if (!probeResultHasPositiveTraffic(evidence.probeResult)) {
      evidence.uploadLayout = null;
      evidence.downloadLayout = null;
      evidence.notificationHomeLayout = null;
      evidence.notificationLayouts = [];
    }
    return evidence;
  } finally {
    if (probePromise !== null) {
      await Promise.allSettled([probePromise]);
    }
    if (notificationCenterOpened) {
      await closeNotificationCenterImpl({ target, hdcCommand, execImpl, cwd }).catch(() => {});
    }
    await originHandle?.close?.().catch(() => {});
    await cleanupTempFiles(fsApi, [homeLayoutPath, notificationLayoutPath]);
  }
}

export async function runHomeTrafficDeviceProof({
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  toolchainInspectorImpl = inspectToolchain,
  hashFileImpl = hashFile,
  verifySignedHapImpl = async (hapPath) => await defaultVerifySignedHap(hapPath),
  collectEvidenceImpl = defaultCollectEvidence,
  writeValidatedProofImpl = writeValidatedHomeTrafficProof,
  serial = null,
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  probeHapPath = DEFAULT_PROBE_HAP_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  tempRoot = os.tmpdir()
} = {}) {
  const proof = createBaseProof();
  const runId = crypto.randomUUID();
  let target = null;
  let hdcCommand = null;
  try {
    const safeProductionHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionHapPath, '--production-hap');
    const safeProbeHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, probeHapPath, '--probe-hap');
    const [productionSigned, probeSigned] = await Promise.all([
      verifySignedHapImpl(safeProductionHapPath).catch(() => false),
      verifySignedHapImpl(safeProbeHapPath).catch(() => false)
    ]);
    if (productionSigned) {
      const packageSha256 = await hashFileImpl(fsApi, safeProductionHapPath);
      if (HASH_PATTERN.test(`${packageSha256 ?? ''}`)) {
        proof.packageSha256 = packageSha256;
      }
    }
    if (!productionSigned || !probeSigned) {
      return await writeValidatedProofImpl(proof, { outputPath, fsApi, repoRoot });
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
      tempRoot,
      runId
    });
    if (probeResultHasPositiveTraffic(evidence?.probeResult) &&
      evidence?.beforeLayout &&
      evidence?.uploadLayout &&
      evidence?.downloadLayout &&
      evidence?.notificationHomeLayout &&
      Array.isArray(evidence?.notificationLayouts) &&
      evidence.notificationLayouts.length > 0) {
      try {
        const traffic = {
          ...analyzeHomeTrafficLayouts(
            evidence.beforeLayout,
            evidence.uploadLayout,
            evidence.downloadLayout
          ),
          ...analyzeHomeTrafficNotificationEvidence(
            evidence.notificationHomeLayout,
            evidence.notificationLayouts
          )
        };
        proof.traffic = traffic;
        proof.result = proofPassesContract({
          ...proof,
          result: 'pass',
          traffic
        })
          ? 'pass'
          : 'incomplete';
      } catch {
        proof.result = 'incomplete';
      }
    }
  } catch (error) {
    if (!String(error?.code ?? '').startsWith(SAFE_ERROR_CODES.arguments)) {
      proof.result = 'incomplete';
    }
  } finally {
    if (target && hdcCommand) {
      await cleanupDeviceState({ target, hdcCommand, execImpl, cwd: repoRoot }).catch(() => {});
    }
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

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  void main();
}
