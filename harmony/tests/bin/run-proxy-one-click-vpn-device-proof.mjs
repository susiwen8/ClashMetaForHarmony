#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { ensureRepoScopedExistingFile, ensureRepoScopedOutputFile } from './repo-path-safety.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  execCommand
} from './run-phase0-device-proof.mjs';
import { classifyHarmonyTarget } from './run-phase2-device-proof.mjs';
import {
  buildProductionLaunchArgs,
  clickLayoutNode,
  dumpLayoutToHost,
  isLayoutSelectionWithinViewport,
  normalizePhase4RuntimeJournal,
  pullBundleEvidenceJson,
  scrollLayoutNodeForward,
  selectUniqueActionableLayoutNode,
  selectUniqueScrollableLayoutNode,
  validateValueAgainstSchema,
  waitForVpnConsentAction
} from './run-phase4-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-one-click-vpn-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-vpn-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const ENTRY_ABILITY_NAME = 'EntryAbility';
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const ZERO_SHA256 = '0'.repeat(64);
const HASH_PATTERN = /^[a-f0-9]{64}$/u;
const UI_POLL_INTERVAL_MS = 250;
const UI_POLL_ATTEMPTS = 32;
const HOME_RUNTIME_ATTEMPTS = 40;
const APP_HOME_PROFILE_SELECTOR = Object.freeze({ ids: Object.freeze(['home.profile.manage']) });
const APP_HOME_VPN_SELECTOR = Object.freeze({ ids: Object.freeze(['home.vpn.action']) });
const APP_DETAIL_PROXY_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.proxy.toggle']) });
const APP_DETAIL_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.back']) });
const APP_PROFILES_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['profiles.back']) });
const DEFAULT_PROOF_SCHEMA = Object.freeze(JSON.parse(await fs.readFile(SCHEMA_PATH, 'utf8')));
const TRANSIENT_SELECTION_CODES = new Set([
  'PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH',
  'PROXY_ONE_CLICK_SAVED_INTENT_STILL_VISIBLE',
  'PROXY_ONE_CLICK_TERMINAL_NOT_FOUND'
]);

function sha256Hex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function createBaseProof() {
  return {
    schemaVersion: '2.0.0',
    result: 'incomplete',
    packageSha256: ZERO_SHA256,
    stoppedToVpnState: 'NOT_PROVEN',
    runningSwitchState: 'NOT_PROVEN',
    recreationState: 'NOT_PROVEN',
    cleanupState: 'NOT_PROVEN'
  };
}

function createFixedError(code) {
  return Object.assign(new Error(code), { code });
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function normalizePackageSha256(value) {
  if (typeof value === 'string' && HASH_PATTERN.test(value)) {
    return value;
  }
  if (isObject(value) && HASH_PATTERN.test(`${value.sha256 ?? ''}`)) {
    return `${value.sha256}`;
  }
  return ZERO_SHA256;
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
    throw createFixedError('PROXY_ONE_CLICK_ACTIVE_PROFILE_UNAVAILABLE');
  }
  return selectUniqueActionableLayoutNode(layout, { ids: [matches[0].attributes.id] });
}

function createLayoutSelection(node) {
  const parsedBounds = parseBounds(node);
  return {
    node,
    bounds: parsedBounds,
    centerX: Math.floor(((parsedBounds.left ?? 0) + (parsedBounds.right ?? 0)) / 2),
    centerY: Math.floor(((parsedBounds.top ?? 0) + (parsedBounds.bottom ?? 0)) / 2)
  };
}

function parseBounds(node) {
  const rawBounds = node?.bounds;
  if (isObject(rawBounds)) {
    return rawBounds;
  }
  const textBounds = `${node?.attributes?.bounds ?? ''}`;
  const match = textBounds.match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/u);
  if (!match) {
    return {};
  }
  return {
    left: Number.parseInt(match[1], 10),
    top: Number.parseInt(match[2], 10),
    right: Number.parseInt(match[3], 10),
    bottom: Number.parseInt(match[4], 10)
  };
}

function analyzeOneClickRows(layout) {
  const rows = new Map();
  const runtimeSelected = new Set();
  const savedIntent = new Set();
  const nestedGroups = new Set();
  const activation = new Set();
  const rowOccurrences = new Map();
  const markerOccurrences = new Map();

  for (const node of collectLayoutNodes(layout?.root ?? layout)) {
    const id = `${node?.attributes?.id ?? ''}`;
    const baseMatch = id.match(/^proxies\.node\.(\d+)$/u);
    if (baseMatch) {
      const index = Number.parseInt(baseMatch[1], 10);
      rowOccurrences.set(index, (rowOccurrences.get(index) ?? 0) + 1);
      rows.set(index, node);
      continue;
    }
    const suffixMatch = id.match(/^(proxies\.node\.(\d+))\.(runtime-selected|saved-intent|nested-group|activation)$/u);
    if (!suffixMatch) {
      continue;
    }
    const index = Number.parseInt(suffixMatch[2], 10);
    const markerKey = `${index}:${suffixMatch[3]}`;
    markerOccurrences.set(markerKey, (markerOccurrences.get(markerKey) ?? 0) + 1);
    if (suffixMatch[3] === 'runtime-selected') {
      runtimeSelected.add(index);
    } else if (suffixMatch[3] === 'saved-intent') {
      savedIntent.add(index);
    } else if (suffixMatch[3] === 'nested-group') {
      nestedGroups.add(index);
    } else {
      activation.add(index);
    }
  }

  const orderedIndexes = [...rows.keys()].sort((left, right) => left - right);
  if ([...rowOccurrences.values()].some((count) => count !== 1) ||
    [...markerOccurrences.values()].some((count) => count !== 1)) {
    throw createFixedError('PROXY_ONE_CLICK_LAYOUT_ROW_AMBIGUOUS');
  }

  return {
    orderedIndexes,
    rows,
    runtimeSelected,
    savedIntent,
    nestedGroups,
    activation
  };
}

export function analyzeProxyOneClickLayout(layout) {
  const analysis = analyzeOneClickRows(layout);
  if (analysis.runtimeSelected.size > 1) {
    throw createFixedError('PROXY_ONE_CLICK_RUNTIME_SELECTED_AMBIGUOUS');
  }
  return analysis;
}

export function selectNextTerminalSelection(layout, excludedIndexes = []) {
  const analysis = analyzeProxyOneClickLayout(layout);
  const excluded = new Set(excludedIndexes);
  const activeIndex = analysis.runtimeSelected.size === 1 ? [...analysis.runtimeSelected][0] : null;
  for (const index of analysis.orderedIndexes) {
    if (analysis.nestedGroups.has(index) || analysis.activation.has(index) || excluded.has(index) || index === activeIndex) {
      continue;
    }
    return {
      index,
      selection: createLayoutSelection(analysis.rows.get(index))
    };
  }
  throw createFixedError('PROXY_ONE_CLICK_TERMINAL_NOT_FOUND');
}

export function verifyRuntimeSelectedIndex(layout, expectedIndex, { allowSavedIntent = false } = {}) {
  const analysis = analyzeProxyOneClickLayout(layout);
  if (analysis.runtimeSelected.size !== 1 || !analysis.runtimeSelected.has(expectedIndex)) {
    throw createFixedError('PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH');
  }
  if (!allowSavedIntent && analysis.savedIntent.size > 0) {
    throw createFixedError('PROXY_ONE_CLICK_SAVED_INTENT_STILL_VISIBLE');
  }
  return true;
}

function proofPassesContract(proof) {
  return proof.result === 'pass'
    && HASH_PATTERN.test(`${proof.packageSha256 ?? ''}`)
    && proof.stoppedToVpnState === 'RUNNING_SELECTED'
    && proof.runningSwitchState === 'HOT_SWITCHED_SAME_SESSION'
    && proof.recreationState === 'RESTORED_RUNNING_SELECTED'
    && proof.cleanupState === 'CLEAN';
}

function proofIncompletePassesContract(proof) {
  return proof.result === 'incomplete'
    && HASH_PATTERN.test(`${proof.packageSha256 ?? ''}`)
    && proof.stoppedToVpnState === 'NOT_PROVEN'
    && proof.runningSwitchState === 'NOT_PROVEN'
    && proof.recreationState === 'NOT_PROVEN'
    && proof.cleanupState === 'NOT_PROVEN';
}

export function parseCliArguments(argv = process.argv.slice(2), _repoRoot = REPO_ROOT) {
  const parsed = {
    productionHapPath: DEFAULT_PRODUCTION_HAP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--production-hap' || option === '--out') {
      const value = argv[index + 1];
      if (typeof value !== 'string' || value.startsWith('--')) {
        throw new Error(`${option} requires a value.`);
      }
      if (option === '--production-hap') {
        parsed.productionHapPath = value;
      } else {
        parsed.outputPath = value;
      }
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${option}`);
  }
  return parsed;
}

function extractSafeOutputPathFromArgv(argv = process.argv.slice(2)) {
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--out') {
      continue;
    }
    const value = argv[index + 1];
    if (typeof value === 'string' && value.length > 0 && !value.startsWith('--')) {
      return value;
    }
  }
  return DEFAULT_OUTPUT_PATH;
}

async function delay(milliseconds) {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function hashFile(filePath, fsApi = fs) {
  const buffer = await fsApi.readFile(filePath);
  return sha256Hex(buffer);
}

async function resolveToolchainAndTarget({
  repoRoot,
  execImpl,
  toolchainInspectorImpl
}) {
  const toolchain = await toolchainInspectorImpl({ cwd: repoRoot });
  if (toolchain?.report?.result !== 'pass' || !toolchain?.resolved?.paths?.hdc) {
    throw createFixedError('PROXY_ONE_CLICK_TOOLCHAIN_UNAVAILABLE');
  }
  const hdcCommand = toolchain.resolved.paths.hdc;
  const listed = await execImpl(hdcCommand, ['list', 'targets', '-v'], { cwd: repoRoot });
  const analysis = analyzeTargetDiscovery(listed);
  if (analysis.kind !== 'selected' || analysis.targets.length !== 1) {
    throw createFixedError('PROXY_ONE_CLICK_TARGET_UNAVAILABLE');
  }
  const target = analysis.targets[0];
  const facts = {
    model: await readTargetFact({ hdcCommand, target, cwd: repoRoot, keyCandidates: ['const.product.model'], execImpl }),
    product: await readTargetFact({ hdcCommand, target, cwd: repoRoot, keyCandidates: ['const.product.name'], execImpl }),
    buildVersion: await readTargetFact({ hdcCommand, target, cwd: repoRoot, keyCandidates: ['const.product.software.version'], execImpl }),
    apiVersion: await readTargetFact({ hdcCommand, target, cwd: repoRoot, keyCandidates: ['const.ohos.apiversion', 'const.product.apiversion'], execImpl }),
    abi: await readTargetFact({ hdcCommand, target, cwd: repoRoot, keyCandidates: ['const.product.cpu.abilist'], execImpl })
  };
  const classification = classifyHarmonyTarget(facts);
  if (classification.kind !== 'physical') {
    throw createFixedError(classification.code ?? 'PROXY_ONE_CLICK_TARGET_UNAVAILABLE');
  }
  return {
    hdcCommand,
    target
  };
}

async function readTargetFact({
  hdcCommand,
  target,
  cwd,
  keyCandidates,
  execImpl = execCommand
}) {
  for (const key of keyCandidates) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    const value = `${result?.stdout ?? ''}`.trim();
    if (!result?.error && result?.exitCode === 0 && value.length > 0 && !/^unknown$/iu.test(value) && !/^null$/iu.test(value)) {
      return value;
    }
  }
  return '';
}

async function installProductionHap({ target, hdcCommand, execImpl, cwd, productionHapPath }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['install', '-r', productionHapPath]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_INSTALL_FAILED');
  }
}

async function launchProductionApp({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, buildProductionLaunchArgs(target, '')),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_LAUNCH_FAILED');
  }
}

async function forceStopBundle({ target, hdcCommand, execImpl, bundleName, cwd = REPO_ROOT }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', bundleName]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
}

async function forceStopProductionApp(targetContext) {
  const result = await targetContext.execImpl(
    targetContext.hdcCommand,
    buildTargetedHdcArgs(targetContext.target, ['shell', 'aa', 'force-stop', APP_BUNDLE]),
    { cwd: targetContext.cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
}

async function forceStopProbeApp(targetContext) {
  const result = await targetContext.execImpl(
    targetContext.hdcCommand,
    buildTargetedHdcArgs(targetContext.target, ['shell', 'aa', 'force-stop', PROBE_BUNDLE]),
    { cwd: targetContext.cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
}

export function buildProxyOneClickVpnRuntimeJournalDeleteArgs(target) {
  return buildTargetedHdcArgs(target, ['shell', '-b', APP_BUNDLE, 'rm', '-f', RUNTIME_REMOTE_PATH]);
}

export async function deleteProxyOneClickVpnRuntimeJournal({
  target,
  hdcCommand,
  execImpl,
  cwd = REPO_ROOT
}) {
  const removeResult = await execImpl(
    hdcCommand,
    buildProxyOneClickVpnRuntimeJournalDeleteArgs(target),
    { cwd }
  );
  if (removeResult?.error || removeResult?.exitCode !== 0 || removeResult?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
  const assertResult = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', '-b', APP_BUNDLE, 'test', '!', '-e', RUNTIME_REMOTE_PATH]),
    { cwd }
  );
  if (assertResult?.error || assertResult?.exitCode !== 0 || assertResult?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
}

async function pullRuntimeJournal(targetContext, fileLabel = 'runtime.json') {
  const localPath = path.join(targetContext.runtimeRoot, fileLabel);
  const pulled = await pullBundleEvidenceJson({
    fsApi: targetContext.fsApi,
    execImpl: targetContext.execImpl,
    hdcCommand: targetContext.hdcCommand,
    target: targetContext.target,
    bundleName: APP_BUNDLE,
    remotePath: RUNTIME_REMOTE_PATH,
    localPath,
    cwd: targetContext.cwd
  });
  if (!pulled.ok) {
    throw createFixedError('PROXY_ONE_CLICK_RUNTIME_JOURNAL_MISSING');
  }
  return normalizePhase4RuntimeJournal(pulled.proof);
}

async function pullPrivateSessionIdentity(targetContext) {
  const runtimeJournal = await pullRuntimeJournal(targetContext, 'runtime-session.json');
  const sessionId = `${runtimeJournal?.activeRequest?.sessionId ?? runtimeJournal?.sessionId ?? ''}`.trim();
  if (sessionId.length === 0) {
    throw createFixedError('PROXY_ONE_CLICK_SESSION_IDENTITY_MISSING');
  }
  return sessionId;
}

async function readLayout(targetContext, fileLabel) {
  return await dumpLayoutToHost({
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    localPath: path.join(targetContext.layoutRoot, fileLabel),
    cwd: targetContext.cwd
  });
}

async function openProxyPage(targetContext) {
  const homeLayout = await waitForProxyNavigationLayout(
    targetContext,
    'home-profile',
    (layout) => selectUniqueActionableLayoutNode(layout, APP_HOME_PROFILE_SELECTOR)
  );
  await clickLayoutNode(selectUniqueActionableLayoutNode(homeLayout, APP_HOME_PROFILE_SELECTOR), {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });

  const profilesLayout = await waitForProxyNavigationLayout(targetContext, 'active-profile', selectUniqueActiveProfileRow);
  await clickLayoutNode(selectUniqueActiveProfileRow(profilesLayout), {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });

  const detailLayout = await waitForProxyNavigationLayout(
    targetContext,
    'detail-proxy',
    (layout) => selectUniqueActionableLayoutNode(layout, APP_DETAIL_PROXY_SELECTOR)
  );
  await clickLayoutNode(selectUniqueActionableLayoutNode(detailLayout, APP_DETAIL_PROXY_SELECTOR), {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });
}

async function waitForProxyNavigationLayout(targetContext, label, select) {
  let lastError = createFixedError('PROXY_ONE_CLICK_LAYOUT_UNAVAILABLE');
  for (let attempt = 0; attempt < UI_POLL_ATTEMPTS; attempt += 1) {
    const layout = await readLayout(targetContext, `${label}-${attempt}.json`);
    try {
      select(layout);
      return layout;
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < UI_POLL_ATTEMPTS) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw lastError;
}

async function tapHomeAction(targetContext, selector, layoutLabel) {
  const homeLayout = await readLayout(targetContext, layoutLabel);
  const selection = selectUniqueActionableLayoutNode(homeLayout, selector);
  await clickLayoutNode(selection, {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });
}

function readActionModeFromSelection(selection, kind) {
  const text = collectTextFragments(selection.node).join(' ').toLowerCase();
  if (text.includes('stop') || text.includes('停止')) {
    return 'stop';
  }
  if (text.includes('start') || text.includes('启动')) {
    return 'start';
  }
  if (text.includes('处理中') || text.includes('busy')) {
    return 'busy';
  }
  throw createFixedError(`PROXY_ONE_CLICK_${kind}_ACTION_UNKNOWN`);
}

function readVpnActionMode(layout) {
  return readActionModeFromSelection(selectUniqueActionableLayoutNode(layout, APP_HOME_VPN_SELECTOR), 'VPN');
}

function isZeroMatchSelectionError(error) {
  return error?.selectionMatchCount === 0;
}

function toCleanupFailure(error) {
  if (error?.code === 'PROXY_ONE_CLICK_CLEANUP_FAILED') {
    return error;
  }
  return createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
}

export function selectVpnCleanupNavigationAction(layout) {
  try {
    return {
      kind: 'home',
      selection: selectUniqueActionableLayoutNode(layout, APP_HOME_VPN_SELECTOR)
    };
  } catch (homeError) {
    if (!isZeroMatchSelectionError(homeError)) {
      throw toCleanupFailure(homeError);
    }
    for (const [kind, selector] of [
      ['detail-back', APP_DETAIL_BACK_SELECTOR],
      ['profiles-back', APP_PROFILES_BACK_SELECTOR]
    ]) {
      try {
        return {
          kind,
          selection: selectUniqueActionableLayoutNode(layout, selector)
        };
      } catch (backError) {
        if (!isZeroMatchSelectionError(backError)) {
          throw toCleanupFailure(backError);
        }
      }
    }
    try {
      return {
        kind: 'scroll',
        selection: selectUniqueScrollableLayoutNode(layout)
      };
    } catch (scrollError) {
      throw toCleanupFailure(scrollError);
    }
  }
}

export async function navigateToVpnCleanupHome({
  readLayoutImpl,
  clickLayoutNodeImpl,
  scrollBackwardImpl,
  delayImpl,
  target,
  hdcCommand,
  execImpl,
  cwd,
  localLayoutPath,
  attempts = UI_POLL_ATTEMPTS
}) {
  const readLayoutForCleanup = readLayoutImpl ?? (async () => await dumpLayoutToHost({
    target,
    hdcCommand,
    execImpl,
    localPath: localLayoutPath,
    cwd
  }));
  const clickLayoutNodeForCleanup = clickLayoutNodeImpl ?? (async (selection) => await clickLayoutNode(selection, {
    target,
    hdcCommand,
    execImpl,
    cwd
  }));
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const currentLayout = await readLayoutForCleanup();
    const navigationAction = selectVpnCleanupNavigationAction(currentLayout);
    if (navigationAction.kind === 'home') {
      return currentLayout;
    }
    if (navigationAction.kind === 'detail-back' || navigationAction.kind === 'profiles-back') {
      await clickLayoutNodeForCleanup(navigationAction.selection);
      await (delayImpl ?? delay)(UI_POLL_INTERVAL_MS);
      continue;
    }
    if (attempt + 1 < attempts) {
      await (scrollBackwardImpl ?? (async (selection) => await scrollLayoutNodeBackward(selection, {
        target,
        hdcCommand,
        execImpl,
        cwd
      })))(navigationAction.selection);
      await (delayImpl ?? delay)(UI_POLL_INTERVAL_MS);
      continue;
    }
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
  throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
}

async function ensureVpnStopped(targetContext) {
  const homeLayout = await navigateToVpnCleanupHome({
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd,
    localLayoutPath: path.join(targetContext.layoutRoot, 'cleanup-home.json')
  });
  if (readVpnActionMode(homeLayout) === 'start') {
    return false;
  }
  const stopSelection = selectUniqueActionableLayoutNode(homeLayout, APP_HOME_VPN_SELECTOR);
  await clickLayoutNode(stopSelection, {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });
  for (let attempt = 0; attempt < HOME_RUNTIME_ATTEMPTS; attempt += 1) {
    const nextLayout = await readLayout(targetContext, 'cleanup-vpn-stop.json').catch(() => null);
    if (nextLayout !== null) {
      try {
        if (readVpnActionMode(nextLayout) === 'start') {
          return true;
        }
      } catch {
      }
    }
    if (attempt + 1 < HOME_RUNTIME_ATTEMPTS) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
}

async function waitForVisibleTerminalSelection(targetContext, excludedIndexes = [], fileLabel = 'proxy-visible.json') {
  let lastError = createFixedError('PROXY_ONE_CLICK_TERMINAL_NOT_FOUND');
  for (let attempt = 0; attempt < UI_POLL_ATTEMPTS; attempt += 1) {
    const layout = await readLayout(targetContext, fileLabel);
    try {
      const selection = selectNextTerminalSelection(layout, excludedIndexes);
      const viewport = selectUniqueScrollableLayoutNode(layout);
      if (isLayoutSelectionWithinViewport(selection.selection, viewport)) {
        return { layout, ...selection };
      }
      lastError = createFixedError('PROXY_ONE_CLICK_TERMINAL_NOT_FOUND');
      await scrollLayoutNodeForward(viewport, {
        target: targetContext.target,
        hdcCommand: targetContext.hdcCommand,
        execImpl: targetContext.execImpl,
        cwd: targetContext.cwd
      });
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < UI_POLL_ATTEMPTS) {
      await delay(UI_POLL_INTERVAL_MS);
    }
  }
  throw lastError;
}

async function scrollLayoutNodeBackward(nodeSelection, { target, hdcCommand, execImpl, cwd }) {
  const { left, top, right, bottom } = nodeSelection.bounds;
  const height = bottom - top;
  if (height <= 0 || right <= left) {
    throw createFixedError('PROXY_ONE_CLICK_SCROLL_BOUNDS_INVALID');
  }
  const inset = Math.max(40, Math.floor(height * 0.12));
  const startY = top + inset;
  const endY = bottom - inset;
  if (endY <= startY) {
    throw createFixedError('PROXY_ONE_CLICK_SCROLL_BOUNDS_INVALID');
  }
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, [
      'shell', 'uinput', '-T', '-m',
      `${nodeSelection.centerX}`, `${startY}`,
      `${nodeSelection.centerX}`, `${endY}`,
      '600'
    ]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_SCROLL_BACKWARD_FAILED');
  }
}

function createLayoutFingerprint(layout) {
  const analysis = analyzeProxyOneClickLayout(layout);
  const ordered = analysis.orderedIndexes.join(',');
  const active = [...analysis.runtimeSelected].sort((left, right) => left - right).join(',');
  const saved = [...analysis.savedIntent].sort((left, right) => left - right).join(',');
  const activation = [...analysis.activation].sort((left, right) => left - right).join(',');
  const rootBounds = parseBounds(layout?.root ?? layout);
  return `${ordered}|${active}|${saved}|${activation}|${rootBounds.top ?? ''}:${rootBounds.bottom ?? ''}`;
}

function resolveExpectedRowScrollDirection(layout, expectedIndex) {
  const analysis = analyzeProxyOneClickLayout(layout);
  const viewport = selectUniqueScrollableLayoutNode(layout);
  if (analysis.rows.has(expectedIndex)) {
    const expectedSelection = createLayoutSelection(analysis.rows.get(expectedIndex));
    if ((expectedSelection.bounds.bottom ?? 0) < (viewport.bounds.top ?? 0) ||
      (expectedSelection.bounds.top ?? 0) < (viewport.bounds.top ?? 0)) {
      return 'backward';
    }
    if ((expectedSelection.bounds.top ?? 0) > (viewport.bounds.bottom ?? 0) ||
      (expectedSelection.bounds.bottom ?? 0) > (viewport.bounds.bottom ?? 0)) {
      return 'forward';
    }
    return 'visible';
  }
  const visibleIndexes = analysis.orderedIndexes;
  if (visibleIndexes.length === 0) {
    return 'unknown';
  }
  const visibleMin = Math.min(...visibleIndexes);
  const visibleMax = Math.max(...visibleIndexes);
  if (expectedIndex < visibleMin) {
    return 'backward';
  }
  if (expectedIndex > visibleMax) {
    return 'forward';
  }
  return 'unknown';
}

export async function waitForExpectedRuntimeSelectedIndex(targetContext, expectedIndex, {
  attempts = UI_POLL_ATTEMPTS,
  allowSavedIntentTransient = true,
  fileLabel = 'proxy-expected-runtime.json'
} = {}) {
  const readLayoutImpl = typeof targetContext?.readLayoutImpl === 'function'
    ? targetContext.readLayoutImpl
    : async () => await readLayout(targetContext, fileLabel);
  const scrollForwardImpl = typeof targetContext?.scrollForwardImpl === 'function'
    ? targetContext.scrollForwardImpl
    : async (selection) => await scrollLayoutNodeForward(selection, {
      target: targetContext.target,
      hdcCommand: targetContext.hdcCommand,
      execImpl: targetContext.execImpl,
      cwd: targetContext.cwd
    });
  const scrollBackwardImpl = typeof targetContext?.scrollBackwardImpl === 'function'
    ? targetContext.scrollBackwardImpl
    : async (selection) => await scrollLayoutNodeBackward(selection, {
      target: targetContext.target,
      hdcCommand: targetContext.hdcCommand,
      execImpl: targetContext.execImpl,
      cwd: targetContext.cwd
    });
  let lastError = createFixedError('PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH');
  let previousFingerprint = '';
  let previousDirection = '';
  let stalledCount = 0;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      verifyRuntimeSelectedIndex(layout, expectedIndex, { allowSavedIntent: false });
      return layout;
    } catch (error) {
      let scrollDirection = attempt % 2 === 0 ? 'forward' : 'backward';
      try {
        const resolvedDirection = resolveExpectedRowScrollDirection(layout, expectedIndex);
        if (resolvedDirection === 'visible') {
          scrollDirection = 'forward';
        } else if (resolvedDirection !== 'unknown') {
          scrollDirection = resolvedDirection;
        }
        const fingerprint = createLayoutFingerprint(layout);
        if (fingerprint === previousFingerprint && scrollDirection === previousDirection) {
          stalledCount += 1;
          if (stalledCount >= 2) {
            throw createFixedError('PROXY_ONE_CLICK_SCROLL_STALLED');
          }
        } else {
          stalledCount = 0;
        }
        previousFingerprint = fingerprint;
        previousDirection = scrollDirection;
        const viewport = selectUniqueScrollableLayoutNode(layout);
        if (scrollDirection === 'backward') {
          await scrollBackwardImpl(viewport);
        } else {
          await scrollForwardImpl(viewport);
        }
      } catch (scrollError) {
        if (`${scrollError?.code ?? ''}` === 'PROXY_ONE_CLICK_SCROLL_STALLED') {
          throw scrollError;
        }
      }
      if (!(allowSavedIntentTransient && TRANSIENT_SELECTION_CODES.has(`${error?.code ?? ''}`))) {
        throw error;
      }
      lastError = error;
      if (attempt + 1 < attempts) {
        await delay(UI_POLL_INTERVAL_MS);
      }
    }
  }
  throw lastError;
}

async function confirmConsentIfNeeded(targetContext) {
  const consentEvidence = await (
    waitForVpnConsentAction({
      readLayoutImpl: async () => await readLayout(targetContext, 'vpn-consent.json'),
      maxAttempts: 8
    })
  );
  if (consentEvidence !== null) {
    await clickLayoutNode(consentEvidence.selection, {
      target: targetContext.target,
      hdcCommand: targetContext.hdcCommand,
      execImpl: targetContext.execImpl,
      cwd: targetContext.cwd
    });
  }
}

export async function verifyVpnRunning({
  targetContext,
  navigateToVpnCleanupHomeImpl = async () => await navigateToVpnCleanupHome({
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd,
    localLayoutPath: path.join(targetContext.layoutRoot, 'verify-vpn-home.json')
  })
}) {
  const homeLayout = await navigateToVpnCleanupHomeImpl();
  let actionMode = 'start';
  try {
    actionMode = readVpnActionMode(homeLayout);
  } catch {
    throw createFixedError('PROXY_ONE_CLICK_VPN_NOT_RUNNING');
  }
  if (actionMode !== 'stop') {
    throw createFixedError('PROXY_ONE_CLICK_VPN_NOT_RUNNING');
  }
  return true;
}

function entryAbilityMissionPattern() {
  const escapedBundle = APP_BUNDLE.replaceAll('.', '\\.');
  const escapedAbility = ENTRY_ABILITY_NAME.replaceAll('.', '\\.');
  return new RegExp(
    String.raw`mission name \[#${escapedBundle}:entry:${escapedAbility}\]|bundle name \[${escapedBundle}\][\s\S]{0,400}main name \[${escapedAbility}\]|main name \[${escapedAbility}\][\s\S]{0,400}bundle name \[${escapedBundle}\]`,
    'u'
  );
}

function isRecognizedEmptyMissionDump(rawDump) {
  return /^Mission List:\s*\[\]\s*$/iu.test(rawDump) || /^mission records:\s*none\s*$/iu.test(rawDump);
}

function hasBalancedMissionBraces(rawDump) {
  const openIndex = rawDump.indexOf('{');
  if (openIndex === -1) {
    return false;
  }
  let depth = 0;
  for (let index = openIndex; index < rawDump.length; index += 1) {
    const char = rawDump[index];
    if (char === '{') {
      depth += 1;
      continue;
    }
    if (char === '}') {
      depth -= 1;
      if (depth < 0) {
        return false;
      }
    }
  }
  return depth === 0;
}

function isRecognizedActualMissionGrammar(rawDump) {
  if (!/^User ID #\d+\s*$/mu.test(rawDump)) {
    return false;
  }
  const missionHeaderIndex = rawDump.indexOf('current mission lists:{');
  if (missionHeaderIndex === -1) {
    return false;
  }
  if (!hasBalancedMissionBraces(rawDump)) {
    return false;
  }
  return /\}\s*$/u.test(rawDump.trimEnd());
}

export function analyzeEntryAbilityMissionDump(rawDump) {
  const normalizedDump = `${rawDump ?? ''}`.trim();
  if (normalizedDump.length === 0) {
    return 'UNRECOGNIZED';
  }
  if (isRecognizedEmptyMissionDump(normalizedDump)) {
    return 'ABSENT';
  }
  if (isRecognizedActualMissionGrammar(normalizedDump)) {
    return entryAbilityMissionPattern().test(normalizedDump) ? 'PRESENT' : 'ABSENT';
  }
  return 'UNRECOGNIZED';
}

async function readAbilityMissionDump(targetContext) {
  const result = await targetContext.execImpl(
    targetContext.hdcCommand,
    buildTargetedHdcArgs(targetContext.target, ['shell', 'aa', 'dump', '-l']),
    { cwd: targetContext.cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_UI_EXIT_NOT_PROVEN');
  }
  return `${result.stdout ?? ''}${result.stderr ?? ''}`;
}

export async function exitUiAbilityOnly(targetContext) {
  const result = await targetContext.execImpl(
    targetContext.hdcCommand,
    buildTargetedHdcArgs(targetContext.target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Back']),
    { cwd: targetContext.cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw createFixedError('PROXY_ONE_CLICK_UI_EXIT_NOT_PROVEN');
  }
}

export async function waitForUiGone(targetContext, {
  attempts = UI_POLL_ATTEMPTS,
  delayImpl = delay,
  readAbilityMissionDumpImpl = readAbilityMissionDump
} = {}) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const dump = await readAbilityMissionDumpImpl(targetContext);
    const analysis = analyzeEntryAbilityMissionDump(dump);
    if (analysis === 'ABSENT') {
      return true;
    }
    if (attempt + 1 < attempts) {
      await delayImpl(UI_POLL_INTERVAL_MS);
    }
  }
  throw createFixedError('PROXY_ONE_CLICK_UI_EXIT_NOT_PROVEN');
}

export async function verifyRuntimeStillRunningWithoutUi(targetContext) {
  const localPath = path.join(targetContext.runtimeRoot, 'recreation-runtime.json');
  const pulled = await pullBundleEvidenceJson({
    fsApi: targetContext.fsApi,
    execImpl: targetContext.execImpl,
    hdcCommand: targetContext.hdcCommand,
    target: targetContext.target,
    bundleName: APP_BUNDLE,
    remotePath: RUNTIME_REMOTE_PATH,
    localPath,
    cwd: targetContext.cwd
  });
  const lifecycleState = `${pulled?.proof?.lifecycle?.state ?? ''}`.trim().toLowerCase();
  if (!pulled.ok || lifecycleState !== 'running') {
    throw createFixedError('PROXY_ONE_CLICK_UI_EXIT_NOT_PROVEN');
  }
  return true;
}

export async function verifyProxyOneClickVpnRecreation({
  targetContext,
  selectedIndex,
  navigateToVpnCleanupHomeImpl = async (context) => await navigateToVpnCleanupHome({
    target: context.target,
    hdcCommand: context.hdcCommand,
    execImpl: context.execImpl,
    cwd: context.cwd,
    localLayoutPath: path.join(context.layoutRoot, 'recreation-home.json')
  }),
  exitUiAbilityOnlyImpl = exitUiAbilityOnly,
  waitForUiGoneImpl = async (context) => await waitForUiGone(context),
  verifyRuntimeStillRunningWithoutUiImpl = verifyRuntimeStillRunningWithoutUi,
  launchProductionAppImpl = async ({ targetContext: context }) => await launchProductionApp({
    target: context.target,
    hdcCommand: context.hdcCommand,
    execImpl: context.execImpl,
    cwd: context.cwd
  }),
  openProxyPageImpl = openProxyPage,
  waitForExpectedRuntimeSelectedIndexImpl = async (context, expectedIndex, options) =>
    await waitForExpectedRuntimeSelectedIndex(context, expectedIndex, options),
  waitForVisibleTerminalSelectionImpl = async (context, excludedIndexes, fileLabel) =>
    await waitForVisibleTerminalSelection(context, excludedIndexes, fileLabel),
  clickLayoutNodeImpl = async (selection, context) => await clickLayoutNode(selection, {
    target: context.target,
    hdcCommand: context.hdcCommand,
    execImpl: context.execImpl,
    cwd: context.cwd
  })
}) {
  await navigateToVpnCleanupHomeImpl(targetContext);
  await exitUiAbilityOnlyImpl(targetContext);
  await waitForUiGoneImpl(targetContext);
  await verifyRuntimeStillRunningWithoutUiImpl(targetContext);
  await launchProductionAppImpl({ targetContext });
  await openProxyPageImpl(targetContext);
  await waitForExpectedRuntimeSelectedIndexImpl(targetContext, selectedIndex, {
    fileLabel: 'recreation-expected-runtime.json'
  });
  const recreationSelection = await waitForVisibleTerminalSelectionImpl(targetContext, [selectedIndex], 'recreation-visible.json');
  await clickLayoutNodeImpl(recreationSelection.selection, targetContext);
  await waitForExpectedRuntimeSelectedIndexImpl(targetContext, recreationSelection.index, {
    fileLabel: 'recreation-after-switch-runtime.json'
  });
  return 'RESTORED_RUNNING_SELECTED';
}

export async function orchestrateProxyOneClickVpnDeviceProof({
  targetContext,
  ensureVpnStoppedImpl = ensureVpnStopped,
  pullPrivateSessionIdentityImpl = pullPrivateSessionIdentity,
  verifyVpnRunningImpl = async (context) => await verifyVpnRunning({ targetContext: context }),
  launchProductionAppImpl = async ({ targetContext: context }) => await launchProductionApp({
    target: context.target,
    hdcCommand: context.hdcCommand,
    execImpl: context.execImpl,
    cwd: context.cwd
  })
}) {
  await ensureVpnStoppedImpl(
    targetContext
  );
  await openProxyPage(targetContext);
  const stoppedSelection = await waitForVisibleTerminalSelection(targetContext, [], 'stopped-visible.json');
  await clickLayoutNode(stoppedSelection.selection, {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });
  await confirmConsentIfNeeded(targetContext);
  await waitForExpectedRuntimeSelectedIndex(targetContext, stoppedSelection.index, {
    fileLabel: 'stopped-expected-runtime.json'
  });
  await verifyVpnRunningImpl(targetContext);

  const stoppedToVpnState = 'RUNNING_SELECTED';

  await openProxyPage(targetContext);
  const beforeSwitchSessionIdentity = await pullPrivateSessionIdentityImpl(targetContext);
  const runningSelection = await waitForVisibleTerminalSelection(targetContext, [stoppedSelection.index], 'running-visible.json');
  await clickLayoutNode(runningSelection.selection, {
    target: targetContext.target,
    hdcCommand: targetContext.hdcCommand,
    execImpl: targetContext.execImpl,
    cwd: targetContext.cwd
  });
  await waitForExpectedRuntimeSelectedIndex(targetContext, runningSelection.index, {
    fileLabel: 'running-expected-runtime.json'
  });
  const afterSwitchSessionIdentity = await pullPrivateSessionIdentityImpl(targetContext);
  if (beforeSwitchSessionIdentity !== afterSwitchSessionIdentity) {
    throw createFixedError('PROXY_ONE_CLICK_SESSION_CHANGED');
  }
  const recreationState = await verifyProxyOneClickVpnRecreation({
    targetContext,
    selectedIndex: runningSelection.index,
    launchProductionAppImpl
  });

  return {
    stoppedToVpnState,
    runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
    recreationState,
    vpnOwned: true
  };
}

export async function performProxyOneClickVpnCleanup({
  targetContext,
  ensureVpnStoppedImpl = ensureVpnStopped,
  forceStopProductionAppImpl = forceStopProductionApp,
  forceStopProbeAppImpl = forceStopProbeApp,
  deleteProxyOneClickVpnRuntimeJournalImpl = async (context) =>
    await deleteProxyOneClickVpnRuntimeJournal({
      target: context.target,
      hdcCommand: context.hdcCommand,
      execImpl: context.execImpl,
      cwd: context.cwd
    })
}) {
  if (!targetContext || !targetContext.target || !targetContext.hdcCommand || typeof targetContext.execImpl !== 'function') {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
  let cleanupFailed = false;
  try {
    await ensureVpnStoppedImpl(
      targetContext
    );
  } catch {
    cleanupFailed = true;
  }
  try {
    await deleteProxyOneClickVpnRuntimeJournalImpl(targetContext);
  } catch {
    cleanupFailed = true;
  }
  try {
    await forceStopProductionAppImpl(targetContext);
  } catch {
    cleanupFailed = true;
  }
  try {
    await forceStopProbeAppImpl(targetContext);
  } catch {
    cleanupFailed = true;
  }
  if (cleanupFailed) {
    throw createFixedError('PROXY_ONE_CLICK_CLEANUP_FAILED');
  }
  return 'CLEAN';
}

export async function validateProxyOneClickVpnProofDocument(proof, schema = DEFAULT_PROOF_SCHEMA) {
  const validation = validateValueAgainstSchema(proof, schema, schema, 'proof');
  const schemaValidation = typeof validation?.valid === 'boolean' && Array.isArray(validation?.errors)
    ? validation
    : {
      valid: Array.isArray(validation) ? validation.length === 0 : false,
      errors: Array.isArray(validation) ? validation : ['proof validation returned an unexpected shape']
    };
  if (!schemaValidation.valid) {
    return schemaValidation;
  }
  if (!proofPassesContract(proof) && !proofIncompletePassesContract(proof)) {
    return {
      valid: false,
      errors: ['proof must be an exact aggregate pass or incomplete shape']
    };
  }
  return {
    valid: true,
    errors: []
  };
}

export async function writeValidatedProxyOneClickVpnProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const resolvedOutputPath = await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, '--out');
  const candidate = structuredClone(proof);
  const validation = await validateProxyOneClickVpnProofDocument(candidate, DEFAULT_PROOF_SCHEMA);
  const persisted = validation.valid ? candidate : createBaseProof();
  await fsApi.mkdir(path.dirname(resolvedOutputPath), { recursive: true });
  const tempPath = `${resolvedOutputPath}.${process.pid}.${Date.now()}.${crypto.randomUUID()}.tmp`;
  try {
    await fsApi.writeFile(tempPath, `${JSON.stringify(persisted, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
    await fsApi.rename(tempPath, resolvedOutputPath);
  } finally {
    await fsApi.rm(tempPath, { force: true }).catch(() => {});
  }
  return persisted;
}

export async function runProxyOneClickVpnDeviceProof({
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  toolchainInspectorImpl = inspectToolchain,
  hashFileImpl = async (filePath) => await hashFile(filePath, fsApi),
  orchestrationImpl = orchestrateProxyOneClickVpnDeviceProof,
  cleanupImpl = performProxyOneClickVpnCleanup,
  ensureVpnStoppedImpl = ensureVpnStopped,
  pullPrivateSessionIdentityImpl = pullPrivateSessionIdentity,
  launchProductionAppImpl = async ({ targetContext: context }) => await launchProductionApp({
    target: context.target,
    hdcCommand: context.hdcCommand,
    execImpl: context.execImpl,
    cwd: context.cwd
  }),
  forceStopProductionAppImpl = forceStopProductionApp,
  forceStopProbeAppImpl = forceStopProbeApp,
  deleteProxyOneClickVpnRuntimeJournalImpl = async (targetContext) =>
    await deleteProxyOneClickVpnRuntimeJournal({
      target: targetContext.target,
      hdcCommand: targetContext.hdcCommand,
      execImpl: targetContext.execImpl,
      cwd: targetContext.cwd
    }),
  writeValidatedProofImpl = async (proof, resolvedOutputPath) =>
    await writeValidatedProxyOneClickVpnProof(proof, resolvedOutputPath, fsApi, repoRoot),
  tempRoot = os.tmpdir(),
  requiresDeviceSetup = orchestrationImpl === orchestrateProxyOneClickVpnDeviceProof
} = {}) {
  const resolvedProductionHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionHapPath, '--production-hap');
  const resolvedOutputPath = await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, '--out');
  const proof = createBaseProof();
  const layoutRoot = await fsApi.mkdtemp(path.join(tempRoot, 'proxy-one-click-vpn-layout-'));
  const runtimeRoot = await fsApi.mkdtemp(path.join(tempRoot, 'proxy-one-click-vpn-runtime-'));
  let targetContext = {
    fsApi,
    target: null,
    hdcCommand: null,
    execImpl,
    cwd: repoRoot,
    layoutRoot,
    runtimeRoot
  };
  let failureCode = null;

  try {
    proof.packageSha256 = normalizePackageSha256(await hashFileImpl(resolvedProductionHapPath));
    if (requiresDeviceSetup) {
      const resolvedTarget = await resolveToolchainAndTarget({
        repoRoot,
        execImpl,
        toolchainInspectorImpl
      });
      targetContext = {
        ...targetContext,
        target: resolvedTarget.target,
        hdcCommand: resolvedTarget.hdcCommand
      };
      await installProductionHap({
        target: targetContext.target,
        hdcCommand: targetContext.hdcCommand,
        execImpl: targetContext.execImpl,
        cwd: repoRoot,
        productionHapPath: resolvedProductionHapPath
      });
      await launchProductionApp({
        target: targetContext.target,
        hdcCommand: targetContext.hdcCommand,
        execImpl: targetContext.execImpl,
        cwd: repoRoot
      });
    }

    const orchestration = await orchestrationImpl({
      targetContext,
      ensureVpnStoppedImpl,
      pullPrivateSessionIdentityImpl,
      launchProductionAppImpl
    });
    proof.stoppedToVpnState = orchestration.stoppedToVpnState;
    proof.runningSwitchState = orchestration.runningSwitchState;
    proof.recreationState = orchestration.recreationState;
    proof.result = 'pass';
  } catch (error) {
    proof.result = 'incomplete';
    proof.stoppedToVpnState = 'NOT_PROVEN';
    proof.runningSwitchState = 'NOT_PROVEN';
    proof.recreationState = 'NOT_PROVEN';
    proof.cleanupState = 'NOT_PROVEN';
    if (error?.code) {
      failureCode = error.code;
    }
  } finally {
    let cleanupFailed = false;
    try {
      try {
            proof.cleanupState = await cleanupImpl({
              targetContext,
              ensureVpnStoppedImpl,
              forceStopProductionAppImpl,
              forceStopProbeAppImpl,
              deleteProxyOneClickVpnRuntimeJournalImpl
            });
          } catch {
            cleanupFailed = true;
          }
        } finally {
          try {
            await fsApi.rm(layoutRoot, { recursive: true, force: true });
          } catch {
            cleanupFailed = true;
          }
          try {
            await fsApi.rm(runtimeRoot, { recursive: true, force: true });
          } catch {
            cleanupFailed = true;
          }
      }
      if (proof.result !== 'pass') {
        proof.cleanupState = 'NOT_PROVEN';
      }
      if (cleanupFailed) {
        proof.result = 'incomplete';
        proof.stoppedToVpnState = 'NOT_PROVEN';
        proof.runningSwitchState = 'NOT_PROVEN';
        proof.recreationState = 'NOT_PROVEN';
        proof.cleanupState = 'NOT_PROVEN';
        failureCode = 'PROXY_ONE_CLICK_CLEANUP_FAILED';
      }
  }

  return await writeValidatedProofImpl(proof, resolvedOutputPath);
}

async function main(argv = process.argv.slice(2)) {
  const args = parseCliArguments(argv, REPO_ROOT);
  await runProxyOneClickVpnDeviceProof({
    productionHapPath: args.productionHapPath,
    outputPath: args.outputPath
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(async () => {
    const safeOutputPath = extractSafeOutputPathFromArgv(process.argv.slice(2));
    await writeValidatedProxyOneClickVpnProof(createBaseProof(), safeOutputPath).catch(() => {});
    process.exitCode = 1;
  });
}
