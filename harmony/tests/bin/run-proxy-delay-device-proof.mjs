#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { ensureRepoScopedExistingFile, ensureRepoScopedOutputFile } from './repo-path-safety.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  execCommand
} from './run-phase0-device-proof.mjs';
import {
  buildBundleEvidencePullArgs,
  buildProductionLaunchArgs,
  clickLayoutNode,
  dumpLayoutToHost,
  normalizePhase4RuntimeJournal,
  pullBundleEvidenceJson,
  selectUniqueActionableLayoutNode,
  validateValueAgainstSchema,
  waitForVpnConsentAction
} from './run-phase4-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-delay-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'proxy-delay-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const ENTRY_ABILITY = 'EntryAbility';
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const UI_POLL_INTERVAL_MS = 250;
const COMPLETE_POLL_ATTEMPTS = 80;
const LIVE_POLL_ATTEMPTS = 24;
const VPN_STATE_POLL_ATTEMPTS = 80;
const QUIET_WINDOW_ATTEMPTS = 4;
const CANCEL_RETRY_LIMIT = 3;
const VPN_QUIET_RETRY_LIMIT = 3;
const ZERO_SHA256 = '0'.repeat(64);
const HASH_PATTERN = /^[a-f0-9]{64}$/u;
const POSITIVE_DELAY_TEXT = /^([1-9]\d*) ms$/u;
const ROOT_ALLOWED_KEYS = new Set([
  'schemaVersion',
  'result',
  'packageSha256',
  'measurement',
  'cancellationState'
]);
const MEASUREMENT_ALLOWED_KEYS = new Set([
  'totalCount',
  'testableCount',
  'availableCount',
  'timeoutCount',
  'failedCount',
  'minDelayMs',
  'medianDelayMs',
  'maxDelayMs'
]);
const HOME_PROFILE_SELECTOR = Object.freeze({ ids: Object.freeze(['home.profile.manage']) });
const HOME_VPN_SELECTOR = Object.freeze({ ids: Object.freeze(['home.vpn.action']) });
const DETAIL_PROXY_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.proxy.toggle']) });
const DETAIL_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.back']) });
const PROFILES_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['profiles.back']) });
const DELAY_BUTTON_SELECTOR = Object.freeze({ ids: Object.freeze(['proxies.delay-test']) });
const COMPLETION_LABELS = Object.freeze({
  waiting: '等待',
  testing: '测速中',
  timeout: '超时',
  failed: '不可用',
  cancelled: '已取消',
  unsupported: '不支持'
});
const SAFE_ERROR_CODES = Object.freeze({
  arguments: 'ARGUMENT_INVALID',
  toolchain: 'PROXY_DELAY_TOOLCHAIN_UNAVAILABLE',
  target: 'PROXY_DELAY_TARGET_UNAVAILABLE',
  install: 'PROXY_DELAY_INSTALL_FAILED',
  launch: 'PROXY_DELAY_LAUNCH_FAILED',
  layout: 'PROXY_DELAY_LAYOUT_NOT_READY',
  complete: 'PROXY_DELAY_COMPLETE_NOT_PROVEN',
  cancel: 'PROXY_DELAY_CANCEL_NOT_PROVEN',
  vpn: 'PROXY_DELAY_VPN_NOT_PROVEN',
  cleanup: 'PROXY_DELAY_CLEANUP_FAILED',
  output: 'PROXY_DELAY_OUTPUT_INVALID',
  failedState: 'PROXY_DELAY_FAILED_STATE'
});

function createMeasurement() {
  return {
    totalCount: 0,
    testableCount: 0,
    availableCount: 0,
    timeoutCount: 0,
    failedCount: 0,
    minDelayMs: 0,
    medianDelayMs: 0,
    maxDelayMs: 0
  };
}

function createBaseProof() {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    packageSha256: ZERO_SHA256,
    measurement: createMeasurement(),
    cancellationState: 'NOT_PROVEN'
  };
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function median(values) {
  const ordered = [...values].sort((left, right) => left - right);
  const center = Math.floor(ordered.length / 2);
  if (ordered.length === 0) {
    return 0;
  }
  if (ordered.length % 2 === 1) {
    return ordered[center];
  }
  return Math.floor((ordered[center - 1] + ordered[center]) / 2);
}

async function delay(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function createFixedError(code) {
  return Object.assign(new Error(code), { code });
}

function normalizeProxyDelayLifecycle(rawLifecycle) {
  const state = typeof rawLifecycle?.state === 'string'
    ? rawLifecycle.state.toLowerCase()
    : '';
  const recoveryAttempt = Number.isInteger(rawLifecycle?.recoveryAttempt) && rawLifecycle.recoveryAttempt >= 0
    ? rawLifecycle.recoveryAttempt
    : 0;
  return { state, recoveryAttempt };
}

function normalizeProxyDelayRuntimeRecord(rawRecord) {
  return {
    sequence: Number.isInteger(rawRecord?.sequence) ? rawRecord.sequence : 0,
    kind: typeof rawRecord?.kind === 'string' ? rawRecord.kind : '',
    ingress: typeof rawRecord?.ingress === 'string' ? rawRecord.ingress : '',
    detail: typeof rawRecord?.detail === 'string' ? rawRecord.detail : ''
  };
}

export function normalizeProxyDelayRuntimeJournal(raw) {
  const normalized = normalizePhase4RuntimeJournal(raw);
  return {
    ...normalized,
    records: Array.isArray(normalized.records)
      ? normalized.records.map((record) => normalizeProxyDelayRuntimeRecord(record))
      : [],
    lifecycle: normalizeProxyDelayLifecycle(raw?.lifecycle)
  };
}

function parseDelayStateText(text) {
  if (text === COMPLETION_LABELS.waiting) {
    return { state: 'WAITING', delayMs: null };
  }
  if (text === COMPLETION_LABELS.testing) {
    return { state: 'TESTING', delayMs: null };
  }
  const delayMatch = text.match(POSITIVE_DELAY_TEXT);
  if (delayMatch) {
    return { state: 'AVAILABLE', delayMs: Number.parseInt(delayMatch[1], 10) };
  }
  if (text === COMPLETION_LABELS.timeout) {
    return { state: 'TIMEOUT', delayMs: null };
  }
  if (text === COMPLETION_LABELS.failed) {
    return { state: 'FAILED', delayMs: null };
  }
  if (text === COMPLETION_LABELS.cancelled) {
    return { state: 'CANCELLED', delayMs: null };
  }
  if (text === COMPLETION_LABELS.unsupported) {
    return { state: 'UNSUPPORTED', delayMs: null };
  }
  throw createFixedError('PROXY_DELAY_ROW_STATE_INVALID');
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

function selectUniqueActiveProfileRow(layout) {
  const matches = collectLayoutNodes(layout?.root ?? layout).filter((node) => {
    const id = `${node?.attributes?.id ?? ''}`;
    const text = collectTextFragments(node).join(' ');
    return id.startsWith('profiles.row.') && (text.includes('当前') || /\bactive\b/iu.test(text));
  });
  if (matches.length !== 1) {
    throw createFixedError(SAFE_ERROR_CODES.layout);
  }
  return selectUniqueActionableLayoutNode(layout, { ids: [matches[0].attributes.id] });
}

function buildRowBaseId(index) {
  return `proxies.node.${index}`;
}

function indexRows(layout) {
  const rowMap = new Map();
  for (const node of collectLayoutNodes(layout?.root ?? layout)) {
    const id = `${node?.attributes?.id ?? ''}`;
    const match = id.match(/^proxies\.node\.(\d+)$/u);
    if (!match) {
      continue;
    }
    rowMap.set(Number.parseInt(match[1], 10), node);
  }
  const indexes = [...rowMap.keys()].sort((left, right) => left - right);
  indexes.forEach((value, expected) => {
    if (value !== expected) {
      throw createFixedError('PROXY_DELAY_LAYOUT_ORDER_INVALID');
    }
  });
  return indexes.map((index) => ({ index, node: rowMap.get(index) }));
}

function findDirectChildrenByIdPrefix(node, prefix) {
  const matches = [];
  const queue = [node];
  while (queue.length > 0) {
    const current = queue.shift();
    if (!isObject(current)) {
      continue;
    }
    const id = `${current.attributes?.id ?? ''}`;
    if (id.startsWith(prefix)) {
      matches.push(current);
    }
    for (const child of current.children ?? []) {
      queue.push(child);
    }
  }
  return matches;
}

export function calculateDelayMeasurement(rows) {
  const measurement = createMeasurement();
  measurement.totalCount = rows.length;
  measurement.testableCount = rows.filter((row) => row.state !== 'UNSUPPORTED').length;
  measurement.availableCount = rows.filter((row) => row.state === 'AVAILABLE').length;
  measurement.timeoutCount = rows.filter((row) => row.state === 'TIMEOUT').length;
  measurement.failedCount = rows.filter((row) => row.state === 'FAILED').length;
  const delays = rows
    .filter((row) => row.state === 'AVAILABLE' && Number.isInteger(row.delayMs) && row.delayMs > 0)
    .map((row) => row.delayMs);
  if (delays.length > 0) {
    const ordered = [...delays].sort((left, right) => left - right);
    measurement.minDelayMs = ordered[0];
    measurement.medianDelayMs = median(ordered);
    measurement.maxDelayMs = ordered[ordered.length - 1];
  }
  return measurement;
}

export function analyzeProxyDelayLayout(layout) {
  const root = layout?.root ?? layout;
  const nodes = collectLayoutNodes(root);
  const rowEntries = indexRows(layout);
  const rows = [];
  let fastestCount = 0;
  for (const { index, node } of rowEntries) {
    const baseId = buildRowBaseId(index);
    const delayMatches = findDirectChildrenByIdPrefix(node, `${baseId}.delay`);
    if (delayMatches.length !== 1) {
      throw createFixedError(delayMatches.length === 0 ? 'PROXY_DELAY_ROW_STATE_MISSING' : 'PROXY_DELAY_ROW_STATE_AMBIGUOUS');
    }
    const texts = collectTextFragments(delayMatches[0]);
    if (texts.length !== 1) {
      throw createFixedError('PROXY_DELAY_ROW_STATE_AMBIGUOUS');
    }
    const fastestMatches = findDirectChildrenByIdPrefix(node, `${baseId}.fastest`);
    if (fastestMatches.length > 1) {
      throw createFixedError('PROXY_DELAY_FASTEST_AMBIGUOUS');
    }
    const parsed = parseDelayStateText(texts[0]);
    const row = {
      index,
      state: parsed.state,
      delayMs: parsed.delayMs,
      fastest: fastestMatches.length === 1
    };
    if (row.fastest) {
      fastestCount += 1;
      if (row.state !== 'AVAILABLE') {
        throw createFixedError('PROXY_DELAY_FASTEST_AMBIGUOUS');
      }
    }
    rows.push(row);
  }
  const hasProgress = nodes.some((node) => node?.attributes?.id === 'proxies.delay-progress');
  const hasSummary = nodes.some((node) => node?.attributes?.id === 'proxies.delay-summary');
  const hasLiveRows = rows.some((row) => row.state === 'WAITING' || row.state === 'TESTING');
  const hasTerminalRows = rows.some((row) => row.state !== 'WAITING' && row.state !== 'TESTING');
  if (fastestCount > 1) {
    throw createFixedError('PROXY_DELAY_FASTEST_AMBIGUOUS');
  }
  const phase = hasProgress || hasLiveRows
    ? 'live'
    : (hasSummary && rows.every((row) => row.state !== 'WAITING' && row.state !== 'TESTING') ? 'terminal' : 'idle');
  return {
    rows,
    totalCount: rows.length,
    testableCount: rows.filter((row) => row.state !== 'UNSUPPORTED').length,
    availableCount: rows.filter((row) => row.state === 'AVAILABLE').length,
    timeoutCount: rows.filter((row) => row.state === 'TIMEOUT').length,
    failedCount: rows.filter((row) => row.state === 'FAILED').length,
    hasProgress,
    hasSummary,
    hasTerminalRows,
    phase,
    measurement: calculateDelayMeasurement(rows)
  };
}

export function compareCancellationRetention(previousRows, cancelledRows) {
  if (!Array.isArray(previousRows) || !Array.isArray(cancelledRows) || previousRows.length !== cancelledRows.length) {
    throw createFixedError('PROXY_DELAY_CANCELLATION_RETENTION_INVALID');
  }
  for (let index = 0; index < previousRows.length; index += 1) {
    const left = previousRows[index];
    const right = cancelledRows[index];
    if (left.index !== right.index) {
      throw createFixedError('PROXY_DELAY_CANCELLATION_RETENTION_INVALID');
    }
    const preservedState = left.state === 'AVAILABLE' || left.state === 'TIMEOUT' || left.state === 'FAILED' || left.state === 'UNSUPPORTED';
    if (!preservedState) {
      continue;
    }
    if (left.state !== right.state ||
      left.delayMs !== right.delayMs) {
      throw createFixedError('PROXY_DELAY_CANCELLATION_RETENTION_INVALID');
    }
  }
  return true;
}

async function readSchemaDocument(fsApi = fs) {
  return JSON.parse(await fsApi.readFile(SCHEMA_PATH, 'utf8'));
}

function collectSensitiveKeyErrors(value, pathTrail = 'proof', errors = []) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectSensitiveKeyErrors(entry, `${pathTrail}[${index}]`, errors));
    return errors;
  }
  if (!isObject(value)) {
    return errors;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (pathTrail === 'proof' && !ROOT_ALLOWED_KEYS.has(key)) {
      errors.push(`${pathTrail}.${key} is not allowed`);
    }
    if (pathTrail === 'proof.measurement' && !MEASUREMENT_ALLOWED_KEYS.has(key)) {
      errors.push(`${pathTrail}.${key} is not allowed`);
    }
    collectSensitiveKeyErrors(entry, `${pathTrail}.${key}`, errors);
  }
  return errors;
}

export async function validateProxyDelayProofDocument(proof, schemaOrFsApi = null) {
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
  const measurement = proof.measurement ?? {};
  return proof.result === 'pass'
    && HASH_PATTERN.test(`${proof.packageSha256 ?? ''}`)
    && proof.packageSha256 !== ZERO_SHA256
    && Number.isInteger(measurement.totalCount)
    && Number.isInteger(measurement.testableCount)
    && Number.isInteger(measurement.availableCount)
    && Number.isInteger(measurement.timeoutCount)
    && Number.isInteger(measurement.failedCount)
    && Number.isInteger(measurement.minDelayMs)
    && Number.isInteger(measurement.medianDelayMs)
    && Number.isInteger(measurement.maxDelayMs)
    && measurement.totalCount > 1
    && measurement.testableCount > 1
    && measurement.availableCount >= 1
    && measurement.minDelayMs > 0
    && measurement.minDelayMs <= measurement.medianDelayMs
    && measurement.medianDelayMs <= measurement.maxDelayMs
    && proof.cancellationState === 'CANCELLED';
}

function canonicalizeIncompleteProof(candidate) {
  const proof = createBaseProof();
  if (HASH_PATTERN.test(`${candidate?.packageSha256 ?? ''}`) && candidate.packageSha256 === ZERO_SHA256) {
    proof.packageSha256 = ZERO_SHA256;
  }
  return proof;
}

export async function writeValidatedProxyDelayProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const schema = await readSchemaDocument(fsApi).catch(() => null);
  const candidate = structuredClone(proof);
  if (!proofPassesContract(candidate)) {
    candidate.result = 'incomplete';
  }
  const validation = await validateProxyDelayProofDocument(candidate, schema ?? fsApi);
  const persisted = validation.valid
    ? (candidate.result === 'pass' ? candidate : canonicalizeIncompleteProof(candidate))
    : canonicalizeIncompleteProof(candidate);
  const safeOutputPath = await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, '--out');
  const tempPath = `${safeOutputPath}.${process.pid}.${Date.now()}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(persisted, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, safeOutputPath);
  return persisted;
}

export async function writeArgumentErrorProof({
  outputPath = DEFAULT_OUTPUT_PATH,
  fsApi = fs,
  repoRoot = REPO_ROOT
} = {}) {
  return await writeValidatedProxyDelayProof(createBaseProof(), outputPath, fsApi, repoRoot);
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
    productionHapPath: DEFAULT_PRODUCTION_HAP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!option.startsWith('--')) {
      throw createFixedError(SAFE_ERROR_CODES.arguments);
    }
    const value = parseOptionValue(argv, index, option);
    if (option === '--production-hap') {
      parsed.productionHapPath = path.resolve(value);
    } else if (option === '--out') {
      parsed.outputPath = path.resolve(value);
    } else {
      throw createFixedError(SAFE_ERROR_CODES.arguments);
    }
    index += 1;
  }
  return parsed;
}

async function resolveToolchainAndTarget({
  repoRoot,
  execImpl,
  toolchainInspectorImpl = inspectToolchain
}) {
  const toolchain = await toolchainInspectorImpl({ cwd: repoRoot });
  if (toolchain?.report?.result !== 'pass' || !toolchain?.resolved?.paths?.hdc) {
    throw createFixedError(SAFE_ERROR_CODES.toolchain);
  }
  const hdcCommand = toolchain.resolved.paths.hdc;
  const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
  const analysis = analyzeTargetDiscovery(targetsResult);
  if (analysis.kind !== 'selected' || analysis.targets.length !== 1) {
    throw createFixedError(SAFE_ERROR_CODES.target);
  }
  return { hdcCommand, target: analysis.targets[0] };
}

async function hashFile(fsApi, filePath) {
  const buffer = await fsApi.readFile(filePath);
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function normalizePackageSha256(value) {
  if (typeof value === 'string') {
    return value;
  }
  if (isObject(value) && typeof value.sha256 === 'string') {
    return value.sha256;
  }
  return ZERO_SHA256;
}

export function buildProxyDelayRuntimeJournalDeleteArgs(target) {
  return buildTargetedHdcArgs(target, ['shell', '-b', APP_BUNDLE, 'rm', '-f', RUNTIME_REMOTE_PATH]);
}

export async function deleteProxyDelayRuntimeJournal({
  target,
  hdcCommand,
  execImpl,
  cwd
}) {
  const result = await execImpl(hdcCommand, buildProxyDelayRuntimeJournalDeleteArgs(target), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.cleanup);
  }
  return true;
}

async function installProductionHap({ target, hdcCommand, execImpl, cwd, productionHapPath }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['install', '-r', productionHapPath]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.install);
  }
}

async function launchProductionApp({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(hdcCommand, buildProductionLaunchArgs(target, ''), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError(SAFE_ERROR_CODES.launch);
  }
}

async function readLayout({
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath
}) {
  return await dumpLayoutToHost({
    execImpl,
    hdcCommand,
    target,
    localPath: localLayoutPath,
    cwd
  });
}

async function waitForLayout({
  readLayoutImpl,
  acceptLayoutImpl,
  attempts
}) {
  let lastError = createFixedError(SAFE_ERROR_CODES.layout);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      return {
        layout,
        accepted: acceptLayoutImpl(layout)
      };
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < attempts) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw lastError;
}

async function openProxyPage({
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath
}) {
  await launchProductionApp({ target, hdcCommand, execImpl, cwd });
  const homeLayout = await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: (layout) => selectUniqueActionableLayoutNode(layout, HOME_PROFILE_SELECTOR),
    attempts: LIVE_POLL_ATTEMPTS
  });
  const openSelection = selectUniqueActionableLayoutNode(homeLayout.layout, HOME_PROFILE_SELECTOR);
  await clickLayoutNode(openSelection, { target, hdcCommand, execImpl, cwd });

  const profilesLayout = await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: selectUniqueActiveProfileRow,
    attempts: LIVE_POLL_ATTEMPTS
  });
  await clickLayoutNode(selectUniqueActiveProfileRow(profilesLayout.layout), { target, hdcCommand, execImpl, cwd });

  const detailLayout = await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: (layout) => selectUniqueActionableLayoutNode(layout, DETAIL_PROXY_SELECTOR),
    attempts: LIVE_POLL_ATTEMPTS
  });
  await clickLayoutNode(selectUniqueActionableLayoutNode(detailLayout.layout, DETAIL_PROXY_SELECTOR), { target, hdcCommand, execImpl, cwd });
  return await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: (layout) => {
      selectUniqueActionableLayoutNode(layout, DELAY_BUTTON_SELECTOR);
      const rows = indexRows(layout);
      if (rows.length < 2) {
        throw createFixedError(SAFE_ERROR_CODES.layout);
      }
      return { rowCount: rows.length };
    },
    attempts: LIVE_POLL_ATTEMPTS
  });
}

function readVpnActionMode(layout) {
  const selection = selectUniqueActionableLayoutNode(layout, HOME_VPN_SELECTOR);
  const text = collectTextFragments(selection.node).join(' ');
  if (/\bStop\b|停止/u.test(text)) {
    return 'stop';
  }
  if (/\bStart\b|启动/u.test(text)) {
    return 'start';
  }
  return 'unknown';
}

async function pullRuntimeJournal({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  runtimeJournalPath
}) {
  const pulled = await pullBundleEvidenceJson({
    fsApi,
    execImpl,
    hdcCommand,
    target,
    bundleName: APP_BUNDLE,
    remotePath: RUNTIME_REMOTE_PATH,
    localPath: runtimeJournalPath,
    cwd
  });
  if (!pulled.ok) {
    throw createFixedError(SAFE_ERROR_CODES.vpn);
  }
  return normalizeProxyDelayRuntimeJournal(pulled.proof);
}

function hasLifecycleDetail(runtimeJournal, detail) {
  return runtimeJournal.records.some((record) => record?.kind === 'lifecycle' && record?.detail === detail);
}

function summarizeTunEvidence(runtimeJournal) {
  let highestTunSequence = 0;
  for (const record of runtimeJournal.records) {
    if (record?.ingress === 'tun' && Number.isInteger(record.sequence)) {
      highestTunSequence = Math.max(highestTunSequence, record.sequence);
    }
    if (record?.kind === 'lifecycle' && typeof record.detail === 'string' && record.detail.startsWith('tun-') && Number.isInteger(record.sequence)) {
      highestTunSequence = Math.max(highestTunSequence, record.sequence);
    }
  }
  return {
    highestTunSequence,
    counterTotal: Number(runtimeJournal.counters?.rxPackets ?? 0) + Number(runtimeJournal.counters?.txPackets ?? 0)
  };
}

export function selectVpnCleanupNavigationAction(layout) {
  try {
    return {
      kind: 'home',
      selection: selectUniqueActionableLayoutNode(layout, HOME_VPN_SELECTOR)
    };
  } catch (error) {
    if (error?.selectionMatchCount !== 0) {
      throw createFixedError(SAFE_ERROR_CODES.cleanup);
    }
  }
  for (const [kind, selector] of [
    ['detail-back', DETAIL_BACK_SELECTOR],
    ['profiles-back', PROFILES_BACK_SELECTOR]
  ]) {
    try {
      return {
        kind,
        selection: selectUniqueActionableLayoutNode(layout, selector)
      };
    } catch (error) {
      if (error?.selectionMatchCount !== 0) {
        throw createFixedError(SAFE_ERROR_CODES.cleanup);
      }
    }
  }
  throw createFixedError(SAFE_ERROR_CODES.cleanup);
}

export async function navigateToVpnCleanupHome({
  readLayoutImpl,
  clickLayoutNodeImpl,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  attempts = LIVE_POLL_ATTEMPTS
}) {
  const readLayoutForCleanup = readLayoutImpl ?? (async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }));
  const clickLayoutNodeForCleanup = clickLayoutNodeImpl ?? (async (selection) => await clickLayoutNode(selection, { target, hdcCommand, execImpl, cwd }));
  let currentLayout = await readLayoutForCleanup();
  for (let navigationStep = 0; navigationStep < 3; navigationStep += 1) {
    const navigationAction = selectVpnCleanupNavigationAction(currentLayout);
    if (navigationAction.kind === 'home') {
      return currentLayout;
    }
    await clickLayoutNodeForCleanup(navigationAction.selection);
    const nextLayout = await waitForLayout({
      readLayoutImpl: readLayoutForCleanup,
      acceptLayoutImpl: selectVpnCleanupNavigationAction,
      attempts
    });
    currentLayout = nextLayout.layout;
  }
  throw createFixedError(SAFE_ERROR_CODES.cleanup);
}

async function ensureVpnStopped({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  runtimeJournalPath
}) {
  const homeLayout = await navigateToVpnCleanupHome({
    target,
    hdcCommand,
    execImpl,
    cwd,
    localLayoutPath
  });
  if (readVpnActionMode(homeLayout) !== 'stop') {
    return false;
  }
  const stopSelection = selectUniqueActionableLayoutNode(homeLayout, HOME_VPN_SELECTOR);
  await clickLayoutNode(stopSelection, { target, hdcCommand, execImpl, cwd });
  for (let attempt = 0; attempt < VPN_STATE_POLL_ATTEMPTS; attempt += 1) {
    const runtimeJournal = await pullRuntimeJournal({ fsApi, target, hdcCommand, execImpl, cwd, runtimeJournalPath }).catch(() => null);
    if (runtimeJournal !== null && hasLifecycleDetail(runtimeJournal, 'STATE_CHANGED:STOPPED')) {
      return true;
    }
    const nextLayout = await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }).catch(() => null);
    if (nextLayout !== null && readVpnActionMode(nextLayout) === 'start') {
      return true;
    }
    if (attempt + 1 < VPN_STATE_POLL_ATTEMPTS) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw createFixedError(SAFE_ERROR_CODES.cleanup);
}

async function clickDelayButton({
  target,
  hdcCommand,
  execImpl,
  cwd,
  layout
}) {
  const selection = selectUniqueActionableLayoutNode(layout, DELAY_BUTTON_SELECTOR);
  await clickLayoutNode(selection, { target, hdcCommand, execImpl, cwd });
}

async function runCompletedDelayCapture({
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath
}) {
  const opened = await openProxyPage({ target, hdcCommand, execImpl, cwd, localLayoutPath });
  await clickDelayButton({ target, hdcCommand, execImpl, cwd, layout: opened.layout });
  let sawLive = false;
  const terminal = await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: (layout) => {
      const analysis = analyzeProxyDelayLayout(layout);
      if (analysis.phase === 'live') {
        sawLive = true;
        throw createFixedError('PROXY_DELAY_STILL_RUNNING');
      }
      if (analysis.phase !== 'terminal' || !analysis.hasSummary) {
        throw createFixedError('PROXY_DELAY_STILL_RUNNING');
      }
      if (analysis.availableCount < 1) {
        throw createFixedError(SAFE_ERROR_CODES.complete);
      }
      return analysis;
    },
    attempts: COMPLETE_POLL_ATTEMPTS
  });
  if (!sawLive) {
    throw createFixedError(SAFE_ERROR_CODES.complete);
  }
  return terminal.accepted.rows;
}

async function runCancellationCapture({
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath
}) {
  for (let attempt = 0; attempt < CANCEL_RETRY_LIMIT; attempt += 1) {
    const opened = await openProxyPage({ target, hdcCommand, execImpl, cwd, localLayoutPath });
    await clickDelayButton({ target, hdcCommand, execImpl, cwd, layout: opened.layout });
    let liveRows = null;
    for (let poll = 0; poll < LIVE_POLL_ATTEMPTS; poll += 1) {
      const layout = await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath });
      const analysis = analyzeProxyDelayLayout(layout);
      if (analysis.phase === 'terminal') {
        liveRows = null;
        break;
      }
      if (analysis.phase === 'live') {
        liveRows = analysis.rows;
        break;
      }
      await delay(UI_POLL_INTERVAL_MS);
    }
    if (liveRows === null) {
      continue;
    }
    const layout = await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath });
    await clickDelayButton({ target, hdcCommand, execImpl, cwd, layout });
    const cancelled = await waitForLayout({
      readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
      acceptLayoutImpl: (nextLayout) => {
        const analysis = analyzeProxyDelayLayout(nextLayout);
        if (analysis.phase !== 'terminal') {
          throw createFixedError('PROXY_DELAY_CANCEL_PENDING');
        }
        if (!analysis.rows.some((row) => row.state === 'CANCELLED')) {
          throw createFixedError('PROXY_DELAY_CANCEL_PENDING');
        }
        compareCancellationRetention(liveRows, analysis.rows);
        return analysis;
      },
      attempts: COMPLETE_POLL_ATTEMPTS
    });
    return cancelled.accepted.rows;
  }
  throw createFixedError(SAFE_ERROR_CODES.cancel);
}

async function startVpnCapture({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  runtimeJournalPath
}) {
  await launchProductionApp({ target, hdcCommand, execImpl, cwd });
  const homeLayout = await waitForLayout({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    acceptLayoutImpl: (layout) => selectUniqueActionableLayoutNode(layout, HOME_VPN_SELECTOR),
    attempts: LIVE_POLL_ATTEMPTS
  });
  const action = selectUniqueActionableLayoutNode(homeLayout.layout, HOME_VPN_SELECTOR);
  await clickLayoutNode(action, { target, hdcCommand, execImpl, cwd });
  const consent = await waitForVpnConsentAction({
    readLayoutImpl: async () => await readLayout({ target, hdcCommand, execImpl, cwd, localLayoutPath }),
    maxAttempts: LIVE_POLL_ATTEMPTS
  });
  if (consent !== null) {
    await clickLayoutNode(consent.selection, { target, hdcCommand, execImpl, cwd });
  }
  for (let attempt = 0; attempt < VPN_STATE_POLL_ATTEMPTS; attempt += 1) {
    const runtimeJournal = await pullRuntimeJournal({ fsApi, target, hdcCommand, execImpl, cwd, runtimeJournalPath }).catch(() => null);
    if (runtimeJournal !== null &&
      hasLifecycleDetail(runtimeJournal, 'platform-protect-ok') &&
      hasLifecycleDetail(runtimeJournal, 'STATE_CHANGED:RUNNING')) {
      return runtimeJournal;
    }
    if (attempt + 1 < VPN_STATE_POLL_ATTEMPTS) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw createFixedError(SAFE_ERROR_CODES.vpn);
}

async function forceStopProductionApp({ target, hdcCommand, execImpl, cwd }) {
  await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', APP_BUNDLE]), { cwd }).catch(() => {});
}

async function forceStopProbeApp({ target, hdcCommand, execImpl, cwd }) {
  await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', PROBE_BUNDLE]), { cwd }).catch(() => {});
}

async function waitForQuietRuntimeWindow({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  runtimeJournalPath
}) {
  let baseline = await pullRuntimeJournal({ fsApi, target, hdcCommand, execImpl, cwd, runtimeJournalPath });
  for (let attempt = 0; attempt < QUIET_WINDOW_ATTEMPTS; attempt += 1) {
    await delay(UI_POLL_INTERVAL_MS);
    const next = await pullRuntimeJournal({ fsApi, target, hdcCommand, execImpl, cwd, runtimeJournalPath });
    const previousSummary = summarizeTunEvidence(baseline);
    const nextSummary = summarizeTunEvidence(next);
    if (nextSummary.counterTotal === previousSummary.counterTotal &&
      nextSummary.highestTunSequence === previousSummary.highestTunSequence) {
      return {
        runtimeJournal: next,
        quietSummary: nextSummary
      };
    }
    baseline = next;
  }
  throw createFixedError(SAFE_ERROR_CODES.vpn);
}

async function verifyVpnQuietDelayRun({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  runtimeJournalPath
    }) {
      for (let attempt = 0; attempt < VPN_QUIET_RETRY_LIMIT; attempt += 1) {
        await forceStopProbeApp({ target, hdcCommand, execImpl, cwd });
        const baseline = await waitForQuietRuntimeWindow({
          fsApi,
          target,
      hdcCommand,
      execImpl,
          cwd,
          runtimeJournalPath
    });
    const rows = await runCompletedDelayCapture({ target, hdcCommand, execImpl, cwd, localLayoutPath });
    const after = await pullRuntimeJournal({ fsApi, target, hdcCommand, execImpl, cwd, runtimeJournalPath });
    const afterSummary = summarizeTunEvidence(after);
    if (after.lifecycle?.state !== 'running') {
      throw createFixedError(SAFE_ERROR_CODES.vpn);
    }
    if (Number(after.lifecycle?.recoveryAttempt ?? 0) !== Number(baseline.runtimeJournal.lifecycle?.recoveryAttempt ?? 0)) {
      if (attempt + 1 < VPN_QUIET_RETRY_LIMIT) {
        continue;
      }
      throw createFixedError(SAFE_ERROR_CODES.vpn);
    }
    if (afterSummary.counterTotal !== baseline.quietSummary.counterTotal ||
      afterSummary.highestTunSequence !== baseline.quietSummary.highestTunSequence) {
      if (attempt + 1 < VPN_QUIET_RETRY_LIMIT) {
        continue;
      }
      throw createFixedError(SAFE_ERROR_CODES.vpn);
    }
    return {
      rows,
      vpnQuiet: true
    };
  }
  throw createFixedError(SAFE_ERROR_CODES.vpn);
}

async function defaultOrchestration({
  fsApi,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  runtimeJournalPath
}) {
  await ensureVpnStopped({ fsApi, target, hdcCommand, execImpl, cwd, localLayoutPath, runtimeJournalPath }).catch(() => false);
  const completedRows = await runCompletedDelayCapture({ target, hdcCommand, execImpl, cwd, localLayoutPath });
  const cancelledRows = await runCancellationCapture({ target, hdcCommand, execImpl, cwd, localLayoutPath });
  await startVpnCapture({ fsApi, target, hdcCommand, execImpl, cwd, localLayoutPath, runtimeJournalPath });
  const vpnQuiet = await verifyVpnQuietDelayRun({ fsApi, target, hdcCommand, execImpl, cwd, localLayoutPath, runtimeJournalPath });
  return {
    completedRows,
    cancelledRows,
    cancellationState: 'CANCELLED',
    vpnQuiet: vpnQuiet.vpnQuiet === true
  };
}

export async function runProxyDelayDeviceProof({
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  toolchainInspectorImpl = inspectToolchain,
  hashFileImpl = async (filePath) => await hashFile(fsApi, filePath),
  orchestrationImpl = defaultOrchestration,
  ensureVpnStoppedImpl = ensureVpnStopped,
  forceStopProductionAppImpl = forceStopProductionApp,
  forceStopProbeAppImpl = forceStopProbeApp,
  deleteProxyDelayRuntimeJournalImpl = deleteProxyDelayRuntimeJournal,
  writeValidatedProofImpl = async (proof, resolvedOutputPath) =>
    await writeValidatedProxyDelayProof(proof, resolvedOutputPath, fsApi, repoRoot),
  tempRoot = os.tmpdir(),
  requiresDeviceSetup = orchestrationImpl === defaultOrchestration
} = {}) {
  const resolvedProductionHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionHapPath, '--production-hap');
  const resolvedOutputPath = await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, '--out');
  const proof = createBaseProof();
  const localLayoutPath = path.join(await fsApi.mkdtemp(path.join(tempRoot, 'proxy-delay-layout-')), 'layout.json');
  const runtimeJournalPath = path.join(await fsApi.mkdtemp(path.join(tempRoot, 'proxy-delay-runtime-')), 'runtime.json');
  let target = null;
  let hdcCommand = null;
  let vpnOwned = false;
  let failureCode = null;
  try {
    proof.packageSha256 = normalizePackageSha256(await hashFileImpl(resolvedProductionHapPath));
    if (requiresDeviceSetup) {
      ({ hdcCommand, target } = await resolveToolchainAndTarget({
        repoRoot,
        execImpl,
        toolchainInspectorImpl
      }));
      await installProductionHap({ target, hdcCommand, execImpl, cwd: repoRoot, productionHapPath: resolvedProductionHapPath });
    }
    const orchestration = await orchestrationImpl({
      fsApi,
      target,
      hdcCommand,
      execImpl,
      cwd: repoRoot,
      localLayoutPath,
      runtimeJournalPath
    });
    vpnOwned = orchestration.vpnQuiet === true;
    proof.measurement = calculateDelayMeasurement(orchestration.completedRows);
    if (orchestration.vpnQuiet !== true || orchestration.cancellationState !== 'CANCELLED') {
      throw createFixedError(SAFE_ERROR_CODES.vpn);
    }
    proof.cancellationState = orchestration.cancellationState;
    proof.result = 'pass';
  } catch (error) {
    proof.result = 'incomplete';
    proof.cancellationState = 'NOT_PROVEN';
    proof.measurement = createMeasurement();
    if (error?.code) {
      failureCode = error.code;
    }
  } finally {
    let cleanupFailed = false;
    try {
      if (vpnOwned && target !== null && hdcCommand !== null) {
        try {
          await ensureVpnStoppedImpl({ fsApi, target, hdcCommand, execImpl, cwd: repoRoot, localLayoutPath, runtimeJournalPath });
        } catch {
          cleanupFailed = true;
        }
      }
      if (target !== null && hdcCommand !== null) {
        try {
          await forceStopProductionAppImpl({ target, hdcCommand, execImpl, cwd: repoRoot });
        } catch {
          cleanupFailed = true;
        }
        try {
          await forceStopProbeAppImpl({ target, hdcCommand, execImpl, cwd: repoRoot });
        } catch {
          cleanupFailed = true;
        }
        try {
          await deleteProxyDelayRuntimeJournalImpl({ target, hdcCommand, execImpl, cwd: repoRoot });
        } catch {
          cleanupFailed = true;
        }
      }
    } finally {
      await fsApi.rm(localLayoutPath, { force: true }).catch(() => {});
      await fsApi.rm(path.dirname(localLayoutPath), { recursive: true, force: true }).catch(() => {});
      await fsApi.rm(runtimeJournalPath, { force: true }).catch(() => {});
      await fsApi.rm(path.dirname(runtimeJournalPath), { recursive: true, force: true }).catch(() => {});
    }
    if (cleanupFailed) {
      proof.result = 'incomplete';
      proof.cancellationState = 'NOT_PROVEN';
      proof.measurement = createMeasurement();
      failureCode = SAFE_ERROR_CODES.cleanup;
    }
  }
  if (failureCode !== null) {
    process.stderr.write(`${failureCode}\n`);
  }
  return await writeValidatedProofImpl(proof, resolvedOutputPath);
}

async function main() {
  const parsed = parseCliArguments();
  await runProxyDelayDeviceProof(parsed);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(async () => {
    await writeArgumentErrorProof({
      outputPath: process.argv.includes('--out') ? path.resolve(process.argv[process.argv.indexOf('--out') + 1]) : DEFAULT_OUTPUT_PATH
    }).catch(() => {});
    process.exitCode = 1;
  });
}
