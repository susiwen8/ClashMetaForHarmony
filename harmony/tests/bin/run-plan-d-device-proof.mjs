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
import {
  buildBundleEvidencePullArgs,
  buildProductionLaunchArgs,
  clickLayoutNode as phase4ClickLayoutNode,
  defaultPerformUiAutomation,
  defaultStartOrigin,
  dumpLayoutToHost as phase4DumpLayoutToHost,
  normalizePhase4ProbeEvidence,
  normalizePhase4RuntimeJournal,
  runPhase4DeviceProof,
  isLayoutSelectionWithinViewport,
  scrollLayoutNodeForward,
  selectUniqueLayoutNode,
  validateValueAgainstSchema
} from './run-phase4-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'plan-d-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'plan-d-device-proof.json');
const DEFAULT_PHASE4_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase4-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEFAULT_PRODUCTION_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');
const DEFAULT_PROBE_HAP_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const PROBE_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json';
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const ISO_TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u;
const ZERO_SHA256 = '0'.repeat(64);
const HOME_VPN_SELECTOR = Object.freeze({ ids: Object.freeze(['home.vpn.action']) });
const HOME_PROFILE_SELECTOR = Object.freeze({ ids: Object.freeze(['home.profile.manage']) });
const DETAIL_PROXY_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.proxy.toggle']) });
const DETAIL_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['detail.back']) });
const PROFILES_BACK_SELECTOR = Object.freeze({ ids: Object.freeze(['profiles.back']) });
const VPN_CONSENT_SELECTORS = Object.freeze([
  Object.freeze({ resourceNames: Object.freeze(['vpn_permission_allow', 'permission_allow_button']) }),
  Object.freeze({ ids: Object.freeze(['system.vpn.allow', 'permission_allow']) }),
  Object.freeze({ texts: Object.freeze(['允许', 'Allow']) })
]);
const PASS_RESULT_KINDS = new Set(['changed-terminal', 'relaunch-terminal']);
const EVIDENCE_POLL_ATTEMPTS = 80;
const EVIDENCE_POLL_INTERVAL_MS = 250;
const UI_STATE_POLL_ATTEMPTS = 40;
const UI_STATE_POLL_INTERVAL_MS = 250;
const TRANSIENT_PROXY_LAYOUT_CODES = new Set([
  'PLAN_D_RUNTIME_SELECTION_AMBIGUOUS',
  'PLAN_D_TERMINAL_SELECTION_MISSING',
  'PLAN_D_LABEL_MISSING',
  'PLAN_D_SAVED_INTENT_MISSING',
  'PLAN_D_REPLAY_SELECTION_MISMATCH',
  'PLAN_D_SAVED_INTENT_STILL_VISIBLE'
]);
const DEFAULT_PROOF_SCHEMA = Object.freeze({
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  title: 'Plan D Device Proof',
  type: 'object',
  additionalProperties: false,
  required: ['schemaVersion', 'result', 'runId', 'timestamps', 'packages', 'layout', 'selection', 'network', 'cleanup', 'failures'],
  properties: {
    schemaVersion: { const: '1.0.0' },
    result: { oneOf: [{ const: 'pass' }, { const: 'incomplete' }] },
    runId: { type: 'string', pattern: UUID_PATTERN.source },
    timestamps: {
      type: 'object',
      additionalProperties: false,
      required: ['startedAt', 'completedAt'],
      properties: {
        startedAt: { type: 'string', pattern: ISO_TIMESTAMP_PATTERN.source },
        completedAt: { type: 'string', pattern: ISO_TIMESTAMP_PATTERN.source }
      }
    },
    packages: {
      type: 'object',
      additionalProperties: false,
      required: ['production', 'probe'],
      properties: {
        production: { $ref: '#/$defs/packageProof' },
        probe: { $ref: '#/$defs/packageProof' }
      }
    },
    layout: {
      type: 'object',
      additionalProperties: false,
      required: ['groupCount', 'nodeCount', 'semanticIdsHash'],
      properties: {
        groupCount: { type: 'integer', minimum: 0 },
        nodeCount: { type: 'integer', minimum: 0 },
        semanticIdsHash: { type: 'string', pattern: SHA256_PATTERN.source }
      }
    },
    selection: {
      type: 'object',
      additionalProperties: false,
      required: [
        'initialResultKind',
        'initialRowCorrelationHash',
        'postVpnRowCorrelationHash',
        'relaunchResultKind',
        'relaunchRowCorrelationHash',
        'startSelectionMatched',
        'relaunchReplay'
      ],
      properties: {
        initialResultKind: { type: 'string', minLength: 1 },
        initialRowCorrelationHash: { type: 'string', pattern: SHA256_PATTERN.source },
        postVpnRowCorrelationHash: { type: 'string', pattern: SHA256_PATTERN.source },
        relaunchResultKind: { type: 'string', minLength: 1 },
        relaunchRowCorrelationHash: { type: 'string', pattern: SHA256_PATTERN.source },
        startSelectionMatched: { type: 'boolean' },
        relaunchReplay: { type: 'boolean' }
      }
    },
    network: {
      type: 'object',
      additionalProperties: false,
      required: ['statusClass', 'responseSha256', 'httpsTraceMatched', 'selectedProxyMatched', 'tunIngress', 'counterDelta', 'replayBeforeRunning'],
      properties: {
        statusClass: { type: 'string', pattern: '^(?:[1-5]xx|unknown)$' },
        responseSha256: { type: 'string', pattern: SHA256_PATTERN.source },
        httpsTraceMatched: { type: 'boolean' },
        selectedProxyMatched: { type: 'boolean' },
        tunIngress: { type: 'boolean' },
        counterDelta: { type: 'integer', minimum: 0 },
        replayBeforeRunning: { type: 'boolean' }
      }
    },
    cleanup: {
      type: 'object',
      additionalProperties: false,
      required: ['phase4CleanupSucceeded', 'relaunchCleanupSucceeded', 'layoutTempRemoved'],
      properties: {
        phase4CleanupSucceeded: { type: 'boolean' },
        relaunchCleanupSucceeded: { type: 'boolean' },
        layoutTempRemoved: { type: 'boolean' }
      }
    },
    failures: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['code', 'stage'],
        properties: {
          code: { type: 'string', minLength: 1 },
          stage: { type: 'string', minLength: 1 }
        }
      }
    }
  },
  $defs: {
    packageProof: {
      type: 'object',
      additionalProperties: false,
      required: ['sha256', 'sizeBytes'],
      properties: {
        sha256: { type: 'string', pattern: SHA256_PATTERN.source },
        sizeBytes: { type: 'integer', minimum: 0 }
      }
    }
  }
});

function iso(now = new Date()) {
  return now.toISOString();
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function scrubStatusCode(value) {
  const numeric = Number.parseInt(`${value ?? ''}`, 10);
  if (!Number.isInteger(numeric) || numeric < 100 || numeric > 599) {
    return 'unknown';
  }
  return `${Math.floor(numeric / 100)}xx`;
}

function createFailure(code, stage) {
  return { code, stage };
}

function createBaseProof({ runId = crypto.randomUUID(), now = new Date() } = {}) {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    runId,
    timestamps: {
      startedAt: iso(now),
      completedAt: iso(now)
    },
    packages: {
      production: { sha256: ZERO_SHA256, sizeBytes: 0 },
      probe: { sha256: ZERO_SHA256, sizeBytes: 0 }
    },
    layout: {
      groupCount: 0,
      nodeCount: 0,
      semanticIdsHash: ZERO_SHA256
    },
    selection: {
      initialResultKind: 'not-run',
      initialRowCorrelationHash: ZERO_SHA256,
      postVpnRowCorrelationHash: ZERO_SHA256,
      relaunchResultKind: 'not-run',
      relaunchRowCorrelationHash: ZERO_SHA256,
      startSelectionMatched: false,
      relaunchReplay: false
    },
    network: {
      statusClass: 'unknown',
      responseSha256: ZERO_SHA256,
      httpsTraceMatched: false,
      selectedProxyMatched: false,
      tunIngress: false,
      counterDelta: 0,
      replayBeforeRunning: false
    },
    cleanup: {
      phase4CleanupSucceeded: false,
      relaunchCleanupSucceeded: false,
      layoutTempRemoved: false
    },
    failures: []
  };
}

function isWithinRepo(repoRoot, targetPath) {
  const relativePath = path.relative(repoRoot, targetPath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function ensureRepoScopedInputPath(repoRoot, inputPath, option) {
  const resolved = path.resolve(inputPath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error(`${option} must stay inside the repository.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return resolved;
}

async function ensureRepoScopedOutputPath(fsApi, repoRoot, outputPath, option) {
  return await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, option);
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

function createLayoutNodeSelection(node) {
  const rawBounds = node?.bounds ?? node?.attributes?.bounds ?? {};
  const stringMatch = typeof rawBounds === 'string'
    ? rawBounds.match(/^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$/u)
    : null;
  const bounds = stringMatch
    ? {
      left: Number.parseInt(stringMatch[1], 10),
      top: Number.parseInt(stringMatch[2], 10),
      right: Number.parseInt(stringMatch[3], 10),
      bottom: Number.parseInt(stringMatch[4], 10)
    }
    : rawBounds;
  return {
    node,
    bounds,
    centerX: Math.floor(((bounds.left ?? 0) + (bounds.right ?? 0)) / 2),
    centerY: Math.floor(((bounds.top ?? 0) + (bounds.bottom ?? 0)) / 2)
  };
}

function selectUniqueActiveProfileRow(layout) {
  const matches = collectLayoutNodes(layout?.root ?? layout).filter((node) => {
    const id = `${node?.attributes?.id ?? ''}`;
    if (!id.startsWith('profiles.row.')) {
      return false;
    }
    const text = collectLayoutTextFragments(node).join(' ');
    return text.includes('当前') || /\bactive\b/iu.test(text);
  });
  if (matches.length !== 1) {
    throw Object.assign(new Error('PLAN_D_ACTIVE_PROFILE_ROW_UNAVAILABLE'), {
      code: 'PLAN_D_ACTIVE_PROFILE_ROW_UNAVAILABLE',
      selectionMatchCount: matches.length
    });
  }
  return createLayoutNodeSelection(matches[0]);
}

function collectLayoutTextFragments(node, output = []) {
  if (!isObject(node)) {
    return output;
  }
  for (const value of [node.attributes?.text, node.attributes?.accessibilityText]) {
    if (typeof value === 'string' && value.trim().length > 0) {
      output.push(value.trim());
    }
  }
  for (const child of node.children ?? []) {
    collectLayoutTextFragments(child, output);
  }
  return output;
}

function nodeIsScrollable(node) {
  const value = `${node?.attributes?.scrollable ?? ''}`.trim().toLowerCase();
  return value === 'true' || value === '1' || value === 'on' || value === 'enabled';
}

function findNearestScrollableAncestorSelection(layout, targetNode) {
  let nearest = null;
  let found = false;
  const visit = (node, ancestors) => {
    if (found || !isObject(node)) {
      return;
    }
    if (node === targetNode) {
      nearest = ancestors.length === 0 ? null : ancestors[ancestors.length - 1];
      found = true;
      return;
    }
    const nextAncestors = nodeIsScrollable(node) ? [...ancestors, node] : ancestors;
    for (const child of node.children ?? []) {
      visit(child, nextAncestors);
      if (found) {
        return;
      }
    }
  };
  const root = layout?.root ?? layout;
  if (Array.isArray(root)) {
    for (const entry of root) {
      visit(entry, []);
      if (found) {
        break;
      }
    }
  } else {
    visit(root, []);
  }
  if (!found) {
    throw Object.assign(new Error('PLAN_D_LAYOUT_NODE_DETACHED'), { code: 'PLAN_D_LAYOUT_NODE_DETACHED' });
  }
  return nearest === null ? null : createLayoutNodeSelection(nearest);
}

function hashSemanticIdList(semanticIds) {
  return sha256Hex(Buffer.from(semanticIds.join('\0'), 'utf8'));
}

export function hashSelectedTerminalLabel(label) {
  return sha256Hex(Buffer.from(`${label ?? ''}`, 'utf8'));
}

export function hashRowCorrelation(runId, rowSemanticId) {
  return sha256Hex(Buffer.from(`${runId}\0${rowSemanticId}`, 'utf8'));
}

export function hashDestinationTuple(protocol, host, port) {
  return sha256Hex(Buffer.from(`${protocol}|${host}|${Number.parseInt(`${port}`, 10)}`, 'utf8'));
}

function readNodeVisibleLabel(node, baseId) {
  const queue = [node];
  while (queue.length > 0) {
    const current = queue.shift();
    const attrs = current?.attributes ?? {};
    if (attrs.id === `${baseId}.label` && typeof attrs.text === 'string' && attrs.text.trim().length > 0) {
      return attrs.text.trim();
    }
    for (const child of current?.children ?? []) {
      queue.push(child);
    }
  }
  throw Object.assign(new Error('PLAN_D_LABEL_MISSING'), { code: 'PLAN_D_LABEL_MISSING' });
}

function gatherProxyLayoutState(layout) {
  const nodes = collectLayoutNodes(layout?.root ?? layout);
  const order = [];
  const baseRows = new Map();
  const groups = new Set();
  const nestedGroups = new Set();
  const runtimeSelected = [];
  const savedIntent = [];

  for (const node of nodes) {
    const id = `${node?.attributes?.id ?? ''}`;
    if (/^proxies\.group\.\d+$/u.test(id)) {
      groups.add(id);
      order.push(id);
    } else if (/^proxies\.node\.\d+$/u.test(id)) {
      baseRows.set(id, node);
      order.push(id);
    } else {
      const suffixMatch = id.match(/^(proxies\.node\.\d+)\.(runtime-selected|saved-intent|nested-group)$/u);
      if (!suffixMatch) {
        continue;
      }
      const [, baseId, suffix] = suffixMatch;
      if (suffix === 'runtime-selected') {
        runtimeSelected.push(baseId);
      } else if (suffix === 'saved-intent') {
        savedIntent.push(baseId);
      } else if (suffix === 'nested-group') {
        nestedGroups.add(baseId);
      }
    }
  }

  return {
    groupIds: [...groups],
    nodeIds: [...baseRows.keys()],
    orderedSemanticIds: order,
    baseRows,
    nestedGroups,
    runtimeSelected,
    savedIntent
  };
}

export function analyzeProxySelectionLayout({ layout, runId, candidateVisibleImpl = () => true }) {
  const state = gatherProxyLayoutState(layout);
  if (state.runtimeSelected.length !== 1) {
    throw Object.assign(new Error('PLAN_D_RUNTIME_SELECTION_AMBIGUOUS'), { code: 'PLAN_D_RUNTIME_SELECTION_AMBIGUOUS' });
  }
  const currentBaseId = state.runtimeSelected[0];
  const candidateBaseId = state.nodeIds.find((baseId) => {
    if (baseId === currentBaseId || state.nestedGroups.has(baseId)) {
      return false;
    }
    const candidateNode = state.baseRows.get(baseId);
    return candidateNode !== undefined && candidateVisibleImpl(createLayoutNodeSelection(candidateNode));
  });
  if (!candidateBaseId) {
    throw Object.assign(new Error('PLAN_D_TERMINAL_SELECTION_MISSING'), { code: 'PLAN_D_TERMINAL_SELECTION_MISSING' });
  }
  const candidateNode = state.baseRows.get(candidateBaseId);
  const candidateLabel = readNodeVisibleLabel(candidateNode, candidateBaseId);
  return {
    groupCount: state.groupIds.length,
    nodeCount: state.nodeIds.length,
    semanticIdsHash: hashSemanticIdList(state.orderedSemanticIds),
    selection: {
      resultKind: 'changed-terminal',
      rowCorrelationHash: hashRowCorrelation(runId, candidateBaseId),
      selectedTerminalHash: hashSelectedTerminalLabel(candidateLabel)
    },
    transient: {
      candidateBaseId,
      currentBaseId,
      candidateSelection: createLayoutNodeSelection(candidateNode)
    }
  };
}

export async function waitForVisibleProxySelection({
  readLayoutImpl,
  scrollForwardImpl,
  runId,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds)),
  attempts = UI_STATE_POLL_ATTEMPTS,
  intervalMs = UI_STATE_POLL_INTERVAL_MS
}) {
  let lastError = Object.assign(new Error('PLAN_D_TERMINAL_SELECTION_MISSING'), {
    code: 'PLAN_D_TERMINAL_SELECTION_MISSING'
  });
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      const analysis = analyzeProxySelectionLayout({
        layout,
        runId
      });
      const viewport = findNearestScrollableAncestorSelection(
        layout,
        analysis.transient.candidateSelection.node
      );
      if (viewport === null ||
          isLayoutSelectionWithinViewport(analysis.transient.candidateSelection, viewport)) {
        return { layout, analysis };
      }
      lastError = Object.assign(new Error('PLAN_D_TERMINAL_SELECTION_MISSING'), {
        code: 'PLAN_D_TERMINAL_SELECTION_MISSING'
      });
      await scrollForwardImpl(viewport);
    } catch (error) {
      if (!TRANSIENT_PROXY_LAYOUT_CODES.has(`${error?.code ?? ''}`)) {
        throw error;
      }
      lastError = error;
    }
    if (attempt + 1 < attempts) {
      await delayImpl(intervalMs);
    }
  }
  throw lastError;
}

export async function waitForProxyLayoutAnalysis({
  readLayoutImpl,
  analyzeLayoutImpl,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds)),
  attempts = UI_STATE_POLL_ATTEMPTS,
  intervalMs = UI_STATE_POLL_INTERVAL_MS
}) {
  if (!Number.isInteger(attempts) || attempts <= 0) {
    throw Object.assign(new Error('PLAN_D_UI_POLL_INVALID'), { code: 'PLAN_D_UI_POLL_INVALID' });
  }
  let lastError = Object.assign(new Error('PLAN_D_UI_STATE_NOT_READY'), { code: 'PLAN_D_UI_STATE_NOT_READY' });
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      return {
        layout,
        analysis: analyzeLayoutImpl(layout)
      };
    } catch (error) {
      if (!TRANSIENT_PROXY_LAYOUT_CODES.has(`${error?.code ?? ''}`)) {
        throw error;
      }
      lastError = error;
    }
    if (attempt + 1 < attempts) {
      await delayImpl(intervalMs);
    }
  }
  throw lastError;
}

function analyzeRuntimeSelectedRow({ layout, runId, expectedRowCorrelationHash = null, requireNoSavedIntent = false, resultKind = 'relaunch-terminal' }) {
  const state = gatherProxyLayoutState(layout);
  if (state.runtimeSelected.length !== 1) {
    throw Object.assign(new Error('PLAN_D_RUNTIME_SELECTION_AMBIGUOUS'), { code: 'PLAN_D_RUNTIME_SELECTION_AMBIGUOUS' });
  }
  if (requireNoSavedIntent && state.savedIntent.length > 0) {
    throw Object.assign(new Error('PLAN_D_SAVED_INTENT_STILL_VISIBLE'), { code: 'PLAN_D_SAVED_INTENT_STILL_VISIBLE' });
  }
  const baseId = state.runtimeSelected[0];
  const rowCorrelationHash = hashRowCorrelation(runId, baseId);
  if (expectedRowCorrelationHash !== null && rowCorrelationHash !== expectedRowCorrelationHash) {
    throw Object.assign(new Error('PLAN_D_REPLAY_SELECTION_MISMATCH'), { code: 'PLAN_D_REPLAY_SELECTION_MISMATCH' });
  }
  return {
    resultKind,
    rowCorrelationHash
  };
}

function requireSavedIntentMarker(layout, baseId) {
  const state = gatherProxyLayoutState(layout);
  const matches = state.savedIntent.filter((value) => value === baseId);
  if (matches.length !== 1) {
    throw Object.assign(new Error('PLAN_D_SAVED_INTENT_MISSING'), { code: 'PLAN_D_SAVED_INTENT_MISSING' });
  }
}

function findHttpsProbeRecord(probeEvidence) {
  const normalized = Array.isArray(probeEvidence?.records)
    ? probeEvidence
    : normalizePhase4ProbeEvidence(probeEvidence);
  const matches = normalized.records.filter((record) => record.stepId === 'https' && record.transport === 'https');
  if (matches.length !== 1) {
    throw Object.assign(new Error('PLAN_D_HTTPS_TRACE_AMBIGUOUS'), { code: 'PLAN_D_HTTPS_TRACE_AMBIGUOUS' });
  }
  return matches[0];
}

function findHttpsObservation(originObservations, responseSha256) {
  const matches = (originObservations ?? []).filter((entry) =>
    entry?.protocol === 'https' && entry?.responseBodySha256 === responseSha256
  );
  if (matches.length !== 1) {
    throw Object.assign(new Error('PLAN_D_HTTPS_TRACE_MISMATCH'), { code: 'PLAN_D_HTTPS_TRACE_MISMATCH' });
  }
  return matches[0];
}

export function verifyPhase4PostVpnEvidence({
  probeEvidence,
  originObservations,
  runtimeJournal,
  expectedDestinationHash,
  selectedTerminalHash
}) {
  const httpsRecord = findHttpsProbeRecord(probeEvidence);
  if (httpsRecord.outcome !== 'pass') {
    throw Object.assign(new Error('PLAN_D_HTTPS_TRACE_FAILED'), { code: 'PLAN_D_HTTPS_TRACE_FAILED' });
  }
  const responseSha256 = `${httpsRecord.responseBodySha256 ?? ''}`;
  if (!SHA256_PATTERN.test(responseSha256)) {
    throw Object.assign(new Error('PLAN_D_HTTPS_TRACE_INVALID'), { code: 'PLAN_D_HTTPS_TRACE_INVALID' });
  }
  findHttpsObservation(originObservations, responseSha256);

  const normalizedRuntime = Array.isArray(runtimeJournal?.records)
    ? runtimeJournal
    : normalizePhase4RuntimeJournal(runtimeJournal);
  const candidates = normalizedRuntime.records.filter((record) =>
    record?.kind === 'traffic'
      && record?.protocol === 'tcp'
      && record?.ingress === 'tun'
      && record?.destinationHash === expectedDestinationHash
      && SHA256_PATTERN.test(`${record?.outboundTerminalHash ?? ''}`)
      && Number.isInteger(record?.counterDelta)
      && record.counterDelta > 0
  );
  if (candidates.length !== 1) {
    throw Object.assign(new Error('PLAN_D_DESTINATION_MATCH_AMBIGUOUS'), { code: 'PLAN_D_DESTINATION_MATCH_AMBIGUOUS' });
  }
  const candidate = candidates[0];
  if (candidate.outboundTerminalHash !== selectedTerminalHash) {
    throw Object.assign(new Error('PLAN_D_SELECTED_PROXY_MISMATCH'), { code: 'PLAN_D_SELECTED_PROXY_MISMATCH' });
  }
  return {
    statusClass: scrubStatusCode(httpsRecord.statusCode),
    responseSha256,
    httpsTraceMatched: true,
    selectedProxyMatched: true,
    tunIngress: candidate.ingress === 'tun',
    counterDelta: candidate.counterDelta
  };
}

export function verifyReplayJournalOrdering(records) {
  const proxyActivate = records.find((record) =>
    record?.kind === 'lifecycle' && record?.detail === 'proxy-activate-ok'
  );
  const runningPublication = records.find((record) =>
    record?.kind === 'lifecycle' && record?.detail === 'STATE_CHANGED:RUNNING'
  );
  if (!proxyActivate || !runningPublication || !(proxyActivate.sequence < runningPublication.sequence)) {
    throw Object.assign(new Error('PLAN_D_REPLAY_ORDER_INVALID'), { code: 'PLAN_D_REPLAY_ORDER_INVALID' });
  }
  return true;
}

export function verifyReplaySessionBoundary(previousSessionAlias, currentSessionAlias) {
  if (typeof previousSessionAlias !== 'string' || previousSessionAlias.length === 0 ||
    typeof currentSessionAlias !== 'string' || currentSessionAlias.length === 0 ||
    previousSessionAlias === currentSessionAlias) {
    throw Object.assign(new Error('PLAN_D_REPLAY_SESSION_STALE'), { code: 'PLAN_D_REPLAY_SESSION_STALE' });
  }
  return true;
}

export function verifyRelaunchSelectionMatch({
  rowCorrelationHash,
  expectedRowCorrelationHash,
  hasSavedIntentMarker
}) {
  if (rowCorrelationHash !== expectedRowCorrelationHash) {
    throw Object.assign(new Error('PLAN_D_RELAUNCH_SELECTION_MISMATCH'), { code: 'PLAN_D_RELAUNCH_SELECTION_MISMATCH' });
  }
  if (hasSavedIntentMarker) {
    throw Object.assign(new Error('PLAN_D_SAVED_INTENT_STILL_VISIBLE'), { code: 'PLAN_D_SAVED_INTENT_STILL_VISIBLE' });
  }
  return true;
}

async function readSchemaDocument(fsApi = fs) {
  return JSON.parse(await fsApi.readFile(SCHEMA_PATH, 'utf8'));
}

export function validatePlanDProofDocument(proof, schema = DEFAULT_PROOF_SCHEMA) {
  return validateValueAgainstSchema(proof, schema, schema);
}

function proofPassesContract(proof) {
  return proof.result === 'pass'
    && proof.failures.length === 0
    && proof.packages.production.sizeBytes > 0
    && proof.packages.probe.sizeBytes > 0
    && SHA256_PATTERN.test(proof.packages.production.sha256)
    && SHA256_PATTERN.test(proof.packages.probe.sha256)
    && proof.layout.groupCount > 0
    && proof.layout.nodeCount > 1
    && SHA256_PATTERN.test(proof.layout.semanticIdsHash)
    && PASS_RESULT_KINDS.has(proof.selection.initialResultKind)
    && PASS_RESULT_KINDS.has(proof.selection.relaunchResultKind)
    && SHA256_PATTERN.test(proof.selection.initialRowCorrelationHash)
    && SHA256_PATTERN.test(proof.selection.postVpnRowCorrelationHash)
    && SHA256_PATTERN.test(proof.selection.relaunchRowCorrelationHash)
    && proof.selection.startSelectionMatched === true
    && proof.selection.relaunchReplay === true
    && proof.network.statusClass === '2xx'
    && SHA256_PATTERN.test(proof.network.responseSha256)
    && proof.network.httpsTraceMatched === true
    && proof.network.selectedProxyMatched === true
    && proof.network.tunIngress === true
    && proof.network.counterDelta > 0
    && proof.network.replayBeforeRunning === true
    && proof.cleanup.phase4CleanupSucceeded === true
    && proof.cleanup.relaunchCleanupSucceeded === true
    && proof.cleanup.layoutTempRemoved === true;
}

export async function writeValidatedPlanDProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const schema = await readSchemaDocument(fsApi).catch(() => DEFAULT_PROOF_SCHEMA);
  const candidate = structuredClone(proof);
  candidate.timestamps.completedAt = isObject(candidate.timestamps) && ISO_TIMESTAMP_PATTERN.test(candidate.timestamps.completedAt ?? '')
    ? candidate.timestamps.completedAt
    : iso(new Date());
  if (!proofPassesContract(candidate)) {
    candidate.result = 'incomplete';
  }
  const validation = validatePlanDProofDocument(candidate, schema);
  const persisted = validation.valid ? candidate : createBaseProof({
    runId: UUID_PATTERN.test(`${candidate.runId ?? ''}`) ? candidate.runId : crypto.randomUUID(),
    now: new Date(candidate.timestamps?.startedAt ?? Date.now())
  });
  persisted.timestamps.completedAt = candidate.timestamps?.completedAt ?? iso(new Date());
  if (!validation.valid) {
    persisted.failures = [createFailure('PLAN_D_PROOF_INVALID', 'validation')];
  }
  const safeOutputPath = await ensureRepoScopedOutputPath(fsApi, repoRoot, outputPath, '--out');
  const tempPath = `${safeOutputPath}.${process.pid}.${Date.now()}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(persisted, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, safeOutputPath);
  return persisted;
}

export async function writeArgumentErrorProof({
  outputPath = DEFAULT_OUTPUT_PATH,
  code = 'ARGUMENT_INVALID',
  stage = 'arguments',
  fsApi = fs,
  repoRoot = REPO_ROOT
} = {}) {
  const proof = createBaseProof();
  proof.failures.push(createFailure(code, stage));
  proof.timestamps.completedAt = iso(new Date());
  return await writeValidatedPlanDProof(proof, outputPath, fsApi, repoRoot);
}

function parseOptionValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`Missing value for ${option}`);
  }
  return value;
}

export function parseCliArguments(argv = process.argv.slice(2)) {
  const parsed = {
    productionHapPath: DEFAULT_PRODUCTION_HAP_PATH,
    productionManifestPath: DEFAULT_PRODUCTION_MANIFEST_PATH,
    probeHapPath: DEFAULT_PROBE_HAP_PATH,
    phase4OutputPath: DEFAULT_PHASE4_OUTPUT_PATH,
    outputPath: DEFAULT_OUTPUT_PATH
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!option.startsWith('--')) {
      throw new Error(`Unknown argument: ${option}`);
    }
    const value = parseOptionValue(argv, index, option);
    if (option === '--production-hap') parsed.productionHapPath = path.resolve(value);
    else if (option === '--production-manifest') parsed.productionManifestPath = path.resolve(value);
    else if (option === '--probe-hap') parsed.probeHapPath = path.resolve(value);
    else if (option === '--phase4-out') parsed.phase4OutputPath = path.resolve(value);
    else if (option === '--out') parsed.outputPath = path.resolve(value);
    else throw new Error(`Unknown argument: ${option}`);
    index += 1;
  }
  return parsed;
}

function extractOutputPathFromArgv(argv = process.argv.slice(2)) {
  const index = argv.indexOf('--out');
  if (index !== -1 && argv[index + 1]) {
    return path.resolve(argv[index + 1]);
  }
  return DEFAULT_OUTPUT_PATH;
}

async function defaultPullEvidence({
  target,
  hdcCommand,
  execImpl,
  fsApi = fs,
  bundleName,
  remotePath,
  localPath,
  cwd = REPO_ROOT,
  expectedRunId = '',
  expectedSessionAlias = '',
  requireReplayOrdering = false,
  previousSessionAlias = ''
}) {
  const args = buildBundleEvidencePullArgs({ target, bundleName, remotePath, localPath });
  for (let attempt = 0; attempt < EVIDENCE_POLL_ATTEMPTS; attempt += 1) {
    const result = await execImpl(hdcCommand, args, { cwd });
    if (!result?.error && result?.exitCode === 0 && !result?.timedOut) {
      try {
        const document = JSON.parse(await fsApi.readFile(localPath, 'utf8'));
        const runMatches = expectedRunId.length === 0 || document?.runId === expectedRunId;
        const sessionMatches = expectedSessionAlias.length === 0 || document?.sessionAlias === expectedSessionAlias;
        const sessionAdvanced = previousSessionAlias.length === 0 ||
          (typeof document?.sessionAlias === 'string' &&
            document.sessionAlias.length > 0 &&
            document.sessionAlias !== previousSessionAlias);
        if (runMatches && sessionMatches && sessionAdvanced) {
          if (!requireReplayOrdering) {
            return document;
          }
          try {
            verifyReplayJournalOrdering(document?.records ?? []);
            return document;
          } catch {
          }
        }
      } catch {
      }
    }
    if (attempt + 1 < EVIDENCE_POLL_ATTEMPTS) {
      await new Promise((resolve) => setTimeout(resolve, EVIDENCE_POLL_INTERVAL_MS));
    }
  }
  throw Object.assign(new Error('PLAN_D_EVIDENCE_PULL_FAILED'), { code: 'PLAN_D_EVIDENCE_PULL_FAILED' });
}

async function defaultDetectTarget({ hdcCommand, execImpl, cwd = REPO_ROOT }) {
  const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd });
  const analysis = analyzeTargetDiscovery(targetsResult);
  if (analysis.kind !== 'selected') {
    throw Object.assign(new Error('PLAN_D_TARGET_UNAVAILABLE'), { code: 'PLAN_D_TARGET_UNAVAILABLE' });
  }
  return analysis.targets[0];
}

async function defaultLaunchProduction({ target, hdcCommand, execImpl, cwd = REPO_ROOT, runId = '' }) {
  const result = await execImpl(hdcCommand, buildProductionLaunchArgs(target, runId), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(new Error('PLAN_D_UI_LAUNCH_FAILED'), { code: 'PLAN_D_UI_LAUNCH_FAILED' });
  }
}

async function defaultDumpLayout({ target, hdcCommand, execImpl, cwd = REPO_ROOT, stage = 'layout', layoutDir }) {
  const localPath = path.join(layoutDir, `${stage}.json`);
  return await phase4DumpLayoutToHost({ target, hdcCommand, execImpl, cwd, localPath });
}

async function defaultOpenProxyManage({ target, hdcCommand, execImpl, cwd = REPO_ROOT, layoutDir }) {
  const homeLayout = await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'open-proxy-manage',
    layoutDir,
    select: (layout) => selectUniqueLayoutNode(layout, HOME_PROFILE_SELECTOR)
  });
  await phase4ClickLayoutNode(selectUniqueLayoutNode(homeLayout, HOME_PROFILE_SELECTOR), { target, hdcCommand, execImpl, cwd });

  const profilesLayout = await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'open-active-profile',
    layoutDir,
    select: selectUniqueActiveProfileRow
  });
  await phase4ClickLayoutNode(selectUniqueActiveProfileRow(profilesLayout), { target, hdcCommand, execImpl, cwd });

  const detailLayout = await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'open-detail-proxy-manager',
    layoutDir,
    select: (layout) => selectUniqueLayoutNode(layout, DETAIL_PROXY_SELECTOR)
  });
  await phase4ClickLayoutNode(selectUniqueLayoutNode(detailLayout, DETAIL_PROXY_SELECTOR), { target, hdcCommand, execImpl, cwd });
}

async function defaultWaitForLayoutSelection({
  target,
  hdcCommand,
  execImpl,
  cwd,
  stage,
  layoutDir,
  select
}) {
  let lastError = Object.assign(new Error('PLAN_D_LAYOUT_SELECTION_UNAVAILABLE'), { code: 'PLAN_D_LAYOUT_SELECTION_UNAVAILABLE' });
  for (let attempt = 0; attempt < UI_STATE_POLL_ATTEMPTS; attempt += 1) {
    const layout = await defaultDumpLayout({ target, hdcCommand, execImpl, cwd, stage, layoutDir });
    try {
      select(layout);
      return layout;
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < UI_STATE_POLL_ATTEMPTS) {
      await new Promise((resolve) => setTimeout(resolve, UI_STATE_POLL_INTERVAL_MS));
    }
  }
  throw lastError;
}

async function defaultNavigateBackHome({ target, hdcCommand, execImpl, cwd = REPO_ROOT, layoutDir }) {
  const detailLayout = await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'leave-detail',
    layoutDir,
    select: (layout) => selectUniqueLayoutNode(layout, DETAIL_BACK_SELECTOR)
  });
  await phase4ClickLayoutNode(selectUniqueLayoutNode(detailLayout, DETAIL_BACK_SELECTOR), { target, hdcCommand, execImpl, cwd });

  const profilesLayout = await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'leave-profiles',
    layoutDir,
    select: (layout) => selectUniqueLayoutNode(layout, PROFILES_BACK_SELECTOR)
  });
  await phase4ClickLayoutNode(selectUniqueLayoutNode(profilesLayout, PROFILES_BACK_SELECTOR), { target, hdcCommand, execImpl, cwd });

  await defaultWaitForLayoutSelection({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'home-after-proxy',
    layoutDir,
    select: (layout) => selectUniqueLayoutNode(layout, HOME_VPN_SELECTOR)
  });
}

async function defaultForceStopProduction({ target, hdcCommand, execImpl, cwd = REPO_ROOT }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', APP_BUNDLE]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(new Error('PLAN_D_FORCE_STOP_FAILED'), { code: 'PLAN_D_FORCE_STOP_FAILED' });
  }
}

async function tryHandleVpnConsent({ target, hdcCommand, execImpl, cwd = REPO_ROOT, layoutDir }) {
  const consentLayout = await defaultDumpLayout({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'vpn-consent',
    layoutDir
  }).catch(() => null);
  if (!consentLayout) {
    return false;
  }
  for (const selector of VPN_CONSENT_SELECTORS) {
    try {
      const selection = selectUniqueLayoutNode(consentLayout, selector);
      await phase4ClickLayoutNode(selection, { target, hdcCommand, execImpl, cwd });
      return true;
    } catch {
      continue;
    }
  }
  return false;
}

async function defaultStartVpn({ target, hdcCommand, execImpl, cwd = REPO_ROOT, layoutDir, runId = '' }) {
  await defaultLaunchProduction({ target, hdcCommand, execImpl, cwd, runId });
  const homeLayout = await defaultDumpLayout({
    target,
    hdcCommand,
    execImpl,
    cwd,
    stage: 'start-vpn',
    layoutDir
  });
  const selection = selectUniqueLayoutNode(homeLayout, HOME_VPN_SELECTOR);
  await phase4ClickLayoutNode(selection, { target, hdcCommand, execImpl, cwd });
  await tryHandleVpnConsent({ target, hdcCommand, execImpl, cwd, layoutDir });
}

function verifyCleanupStopConvergence(runtimeJournal) {
  const normalizedRuntime = Array.isArray(runtimeJournal?.records)
    ? runtimeJournal
    : normalizePhase4RuntimeJournal(runtimeJournal);
  const stoppingSignal = normalizedRuntime.records.find((record) =>
    record?.kind === 'lifecycle' && record?.detail === 'STATE_CHANGED:STOPPING'
  );
  const stoppedSignal = normalizedRuntime.records.find((record) =>
    record?.kind === 'lifecycle' && record?.detail === 'STATE_CHANGED:STOPPED'
  );
  return Number.isInteger(stoppingSignal?.sequence)
    && Number.isInteger(stoppedSignal?.sequence)
    && stoppingSignal.sequence < stoppedSignal.sequence;
}

async function defaultCleanup({
  target,
  hdcCommand,
  execImpl,
  fsApi = fs,
  cwd = REPO_ROOT,
  runId = '',
  tempRoot = os.tmpdir(),
  uiDriver = null,
  pullEvidenceImpl = null,
  expectedSessionAlias = ''
}) {
  let stopVpn = false;
  let forceStop = false;
  let cleanupRootRemoved = false;
  const cleanupRoot = await fsApi.mkdtemp(path.join(tempRoot, 'plan-d-cleanup-'));
  try {
    if (UUID_PATTERN.test(runId)
      && expectedSessionAlias.length > 0
      && uiDriver?.launchProductionImpl
      && uiDriver?.dumpLayoutImpl
      && uiDriver?.clickNodeImpl
      && typeof pullEvidenceImpl === 'function') {
      await uiDriver.launchProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir: cleanupRoot });
      const cleanupLayout = await uiDriver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        runId,
        layoutDir: cleanupRoot,
        stage: 'cleanup-stop'
      });
      const stopSelection = selectUniqueLayoutNode(cleanupLayout, HOME_VPN_SELECTOR);
      await uiDriver.clickNodeImpl(stopSelection, { target, hdcCommand, execImpl, cwd, layoutDir: cleanupRoot });
      const cleanupRuntime = await pullEvidenceImpl({
        kind: 'runtime-journal-cleanup',
        target,
        hdcCommand,
        execImpl,
        fsApi,
        bundleName: APP_BUNDLE,
        remotePath: RUNTIME_REMOTE_PATH,
        localPath: path.join(cleanupRoot, 'runtime-journal-cleanup.json'),
        cwd,
        expectedRunId: runId,
        expectedSessionAlias
      });
      stopVpn = verifyCleanupStopConvergence(cleanupRuntime);
    }
  } catch {
    stopVpn = false;
  }

  try {
    const stopResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', APP_BUNDLE]), { cwd });
    const probeStopResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', PROBE_BUNDLE]), { cwd });
    forceStop = !stopResult?.error
      && stopResult?.exitCode === 0
      && !stopResult?.timedOut
      && !probeStopResult?.error
      && probeStopResult?.exitCode === 0
      && !probeStopResult?.timedOut;
  } catch {
    forceStop = false;
  } finally {
    try {
      await fsApi.rm(cleanupRoot, { recursive: true, force: true });
      cleanupRootRemoved = true;
    } catch {
      cleanupRootRemoved = false;
    }
  }

  return cleanupRootRemoved
    ? { stopVpn, forceStop }
    : { stopVpn: false, forceStop: false };
}

function createUiDriver(overrides = {}) {
  return {
    launchProductionImpl: overrides.launchProductionImpl ?? defaultLaunchProduction,
    openProxyManageImpl: overrides.openProxyManageImpl ?? defaultOpenProxyManage,
    dumpLayoutImpl: overrides.dumpLayoutImpl ?? defaultDumpLayout,
    clickNodeImpl: overrides.clickNodeImpl ?? phase4ClickLayoutNode,
    navigateBackHomeImpl: overrides.navigateBackHomeImpl ?? defaultNavigateBackHome,
    forceStopProductionImpl: overrides.forceStopProductionImpl ?? defaultForceStopProduction,
    startVpnImpl: overrides.startVpnImpl ?? defaultStartVpn,
    performPhase4AutomationImpl: overrides.performPhase4AutomationImpl ?? defaultPerformUiAutomation
  };
}

async function runWrappedPhase4UiAutomation({
  target,
  hdcCommand,
  execImpl,
  fsApi,
  tempRoot,
  cwd,
  runId,
  uiDriver,
  onLayoutCleanup = () => {}
}) {
  const layoutDir = await fsApi.mkdtemp(path.join(tempRoot, 'plan-d-ui-raw-layouts-'));
  let layoutTempRemoved = false;
  let automationResult = null;
  try {
    await uiDriver.launchProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir });
    await uiDriver.openProxyManageImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir });
    const initialResult = await waitForVisibleProxySelection({
      readLayoutImpl: async () => await uiDriver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        runId,
        layoutDir,
        stage: 'initial-selection'
      }),
      scrollForwardImpl: async (viewport) => await scrollLayoutNodeForward(viewport, {
        target,
        hdcCommand,
        execImpl,
        cwd
      }),
      runId
    });
    const initial = initialResult.analysis;
    await uiDriver.clickNodeImpl(initial.transient.candidateSelection, { target, hdcCommand, execImpl, cwd, layoutDir });
    await waitForProxyLayoutAnalysis({
      readLayoutImpl: async () => await uiDriver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        runId,
        layoutDir,
        stage: 'after-selection'
      }),
      analyzeLayoutImpl: (layout) => {
        requireSavedIntentMarker(layout, initial.transient.candidateBaseId);
        return true;
      }
    });
    await uiDriver.navigateBackHomeImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir });

    const phase4Ui = await uiDriver.performPhase4AutomationImpl({
      target,
      hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      runId
    });
    if (!phase4Ui?.ok) {
      automationResult = phase4Ui;
      return automationResult;
    }

    await uiDriver.launchProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir });
    await uiDriver.openProxyManageImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd, runId, layoutDir });
    const postVpnResult = await waitForProxyLayoutAnalysis({
      readLayoutImpl: async () => await uiDriver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        runId,
        layoutDir,
        stage: 'post-vpn'
      }),
      analyzeLayoutImpl: (layout) => analyzeRuntimeSelectedRow({
        layout,
        runId,
        expectedRowCorrelationHash: initial.selection.rowCorrelationHash,
        requireNoSavedIntent: true,
        resultKind: 'changed-terminal'
      })
    });
    const postVpn = postVpnResult.analysis;
    automationResult = {
      ...phase4Ui,
      ok: true,
      groupCount: initial.groupCount,
      nodeCount: initial.nodeCount,
      semanticIdsHash: initial.semanticIdsHash,
      selectedRowCorrelationHash: initial.selection.rowCorrelationHash,
      selectedTerminalHash: initial.selection.selectedTerminalHash,
      selectionResultKind: initial.selection.resultKind,
      postVpnRowCorrelationHash: postVpn.rowCorrelationHash,
      layoutTempRemoved: false
    };
    return automationResult;
  } finally {
    try {
      await fsApi.rm(layoutDir, { recursive: true, force: true });
      layoutTempRemoved = true;
    } catch {
      layoutTempRemoved = false;
    }
    if (automationResult !== null) {
      automationResult.layoutTempRemoved = layoutTempRemoved;
    }
    onLayoutCleanup(layoutTempRemoved);
  }
}

async function resolveToolchainAndTarget({
  repoRoot,
  toolchainInspectorImpl,
  detectTargetImpl,
  execImpl
}) {
  const toolchain = await toolchainInspectorImpl({ cwd: repoRoot });
  if (toolchain?.report?.result !== 'pass' || !toolchain?.resolved?.paths?.hdc) {
    throw Object.assign(new Error('PLAN_D_TOOLCHAIN_UNAVAILABLE'), { code: 'PLAN_D_TOOLCHAIN_UNAVAILABLE' });
  }
  const hdcCommand = toolchain.resolved.paths.hdc;
  const target = await detectTargetImpl({ hdcCommand, execImpl, cwd: repoRoot });
  return { hdcCommand, target };
}

function buildPackageProof(hashResult) {
  return {
    sha256: `${hashResult?.sha256 ?? ZERO_SHA256}`,
    sizeBytes: Number.isInteger(hashResult?.sizeBytes) ? hashResult.sizeBytes : 0
  };
}

function ensurePhase4HashesMatch(phase4Proof, packageProof, stageFailures) {
  const [productionHash, probeHash] = phase4Proof?.bundles?.hapSha256 ?? [];
  if (productionHash !== packageProof.production.sha256 || probeHash !== packageProof.probe.sha256) {
    stageFailures.push(createFailure('PLAN_D_PHASE4_PACKAGE_HASH_MISMATCH', 'phase4'));
  }
}

export async function runPlanDDeviceProof({
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  productionManifestPath = DEFAULT_PRODUCTION_MANIFEST_PATH,
  probeHapPath = DEFAULT_PROBE_HAP_PATH,
  phase4OutputPath = DEFAULT_PHASE4_OUTPUT_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  execImpl = execCommand,
  toolchainInspectorImpl = inspectToolchain,
  detectTargetImpl = defaultDetectTarget,
  hashFileImpl = async (filePath) => {
    const buffer = await fsApi.readFile(filePath);
    return { sha256: sha256Hex(buffer), sizeBytes: buffer.byteLength };
  },
  runPhase4Impl = async (options) => await runPhase4DeviceProof(options),
  startOriginImpl = async (options) => await defaultStartOrigin(options),
  pullEvidenceImpl = async (options) => await defaultPullEvidence(options),
  collectOriginObservationsImpl = async ({ originHandle }) => [...(originHandle?.observations ?? [])],
  cleanupImpl = async (options) => await defaultCleanup(options),
  uiDriver = {},
  nowImpl = () => new Date(),
  runIdImpl = () => crypto.randomUUID(),
  writeValidatedProofImpl = async (proof, resolvedOutputPath) =>
    await writeValidatedPlanDProof(proof, resolvedOutputPath, fsApi, repoRoot),
  tempRoot = os.tmpdir()
} = {}) {
  const startedAt = nowImpl();
  const proof = createBaseProof({ runId: runIdImpl(), now: startedAt });
  const failures = proof.failures;
  const resolvedProductionHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionHapPath, '--production-hap');
  const resolvedProductionManifestPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, productionManifestPath, '--production-manifest');
  const resolvedProbeHapPath = await ensureRepoScopedExistingFile(fsApi, repoRoot, probeHapPath, '--probe-hap');
  const resolvedPhase4OutputPath = await ensureRepoScopedOutputPath(fsApi, repoRoot, phase4OutputPath, '--phase4-out');
  const resolvedOutputPath = await ensureRepoScopedOutputPath(fsApi, repoRoot, outputPath, '--out');

  const packageHashes = {
    production: buildPackageProof(await hashFileImpl(resolvedProductionHapPath)),
    probe: buildPackageProof(await hashFileImpl(resolvedProbeHapPath))
  };
  proof.packages = packageHashes;

  const driver = createUiDriver(uiDriver);
  let originHandle = null;
  let originObservationsCollected = false;
  let originHandleClosed = false;
  let expectedDestinationHash = ZERO_SHA256;
  let capturedOriginObservations = [];
  let wrappedUiResult = null;
  let selectedTerminalHash = ZERO_SHA256;
  let phase4CleanupSucceeded = false;
  let relaunchCleanupSucceeded = false;
  let relaunchSessionAlias = '';
  let layoutTempRemoved = false;
  let phase4Proof = null;
  let target = null;
  let hdcCommand = null;
  const evidenceTempRoot = await fsApi.mkdtemp(path.join(tempRoot, 'plan-d-proof-'));

  const collectOriginObservationsOnce = async () => {
    if (originObservationsCollected) {
      return capturedOriginObservations;
    }
    capturedOriginObservations = await collectOriginObservationsImpl({ originHandle, runId: proof.runId });
    originObservationsCollected = true;
    return capturedOriginObservations;
  };

  const closeOriginHandleOnce = async () => {
    if (originHandleClosed || typeof originHandle?.close !== 'function') {
      return;
    }
    originHandleClosed = true;
    let closeError = null;
    try {
      await collectOriginObservationsOnce();
    } catch (error) {
      closeError = error;
    }
    try {
      await originHandle.close();
    } catch (error) {
      closeError ??= error;
    }
    if (closeError) {
      throw closeError;
    }
  };

  try {
    ({ hdcCommand, target } = await resolveToolchainAndTarget({
      repoRoot,
      toolchainInspectorImpl,
      detectTargetImpl,
      execImpl
    }));

    const wrappedStartOriginImpl = async (options) => {
      originHandle = await startOriginImpl(options);
      expectedDestinationHash = hashDestinationTuple('tcp', originHandle?.https?.host ?? '', originHandle?.https?.port ?? 0);
      return {
        ...originHandle,
        close: async () => await closeOriginHandleOnce()
      };
    };

    const wrappedPerformUiAutomationImpl = async (options) => {
      wrappedUiResult = await runWrappedPhase4UiAutomation({
        ...options,
        fsApi,
        tempRoot,
        uiDriver: driver,
        onLayoutCleanup: (removed) => {
          layoutTempRemoved = removed === true;
        }
      });
      layoutTempRemoved = wrappedUiResult?.layoutTempRemoved === true;
      return wrappedUiResult;
    };

    phase4Proof = await runPhase4Impl({
      runId: proof.runId,
      productionHapPath: resolvedProductionHapPath,
      productionManifestPath: resolvedProductionManifestPath,
      probeHapPath: resolvedProbeHapPath,
      outputPath: resolvedPhase4OutputPath,
      repoRoot,
      fsApi,
      execImpl,
      startOriginImpl: wrappedStartOriginImpl,
      performUiAutomationImpl: wrappedPerformUiAutomationImpl
    });

    if (typeof originHandle?.close === 'function' && capturedOriginObservations.length === 0) {
      capturedOriginObservations = await collectOriginObservationsOnce();
    }

    phase4CleanupSucceeded = phase4Proof?.lifecycle?.stop?.result === 'pass';
    proof.cleanup.phase4CleanupSucceeded = phase4CleanupSucceeded;
    if (phase4Proof?.result !== 'pass') {
      throw Object.assign(new Error('PLAN_D_PHASE4_FAILED'), { code: 'PLAN_D_PHASE4_FAILED' });
    }
    ensurePhase4HashesMatch(phase4Proof, packageHashes, failures);
    if (!wrappedUiResult?.ok) {
      throw Object.assign(
        new Error(wrappedUiResult?.code ?? 'PLAN_D_UI_WRAPPER_FAILED'),
        { code: wrappedUiResult?.code ?? 'PLAN_D_UI_WRAPPER_FAILED' }
      );
    }

    proof.layout.groupCount = wrappedUiResult.groupCount;
    proof.layout.nodeCount = wrappedUiResult.nodeCount;
    proof.layout.semanticIdsHash = wrappedUiResult.semanticIdsHash;
    proof.selection.initialResultKind = wrappedUiResult.selectionResultKind;
    proof.selection.initialRowCorrelationHash = wrappedUiResult.selectedRowCorrelationHash;
    selectedTerminalHash = wrappedUiResult.selectedTerminalHash;
    proof.selection.postVpnRowCorrelationHash = wrappedUiResult.postVpnRowCorrelationHash;
    proof.selection.startSelectionMatched = wrappedUiResult.postVpnRowCorrelationHash === wrappedUiResult.selectedRowCorrelationHash;
    proof.cleanup.layoutTempRemoved = layoutTempRemoved;
    proof.cleanup.phase4CleanupSucceeded = phase4CleanupSucceeded;

    const postPhase4ProbePath = path.join(evidenceTempRoot, 'post-phase4-probe.json');
    const postPhase4RuntimePath = path.join(evidenceTempRoot, 'post-phase4-runtime.json');
    const probeEvidence = await pullEvidenceImpl({
      kind: 'probe',
      target,
      hdcCommand,
      execImpl,
      fsApi,
      bundleName: PROBE_BUNDLE,
      remotePath: PROBE_REMOTE_PATH,
      localPath: postPhase4ProbePath,
      cwd: repoRoot,
      expectedRunId: proof.runId
    });
    const runtimePostPhase4 = await pullEvidenceImpl({
      kind: 'runtime-journal-post-phase4',
      target,
      hdcCommand,
      execImpl,
      fsApi,
      bundleName: APP_BUNDLE,
      remotePath: RUNTIME_REMOTE_PATH,
      localPath: postPhase4RuntimePath,
      cwd: repoRoot,
      expectedRunId: proof.runId
    });
    const networkProof = verifyPhase4PostVpnEvidence({
      probeEvidence,
      originObservations: capturedOriginObservations,
      runtimeJournal: runtimePostPhase4,
      expectedDestinationHash,
      selectedTerminalHash
    });
    Object.assign(proof.network, networkProof);

    await driver.launchProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    await driver.openProxyManageImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    const relaunchSelectionResult = await waitForVisibleProxySelection({
      readLayoutImpl: async () => await driver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd: repoRoot,
        runId: proof.runId,
        stage: 'relaunch-pre-save',
        layoutDir: evidenceTempRoot
      }),
      scrollForwardImpl: async (viewport) => await scrollLayoutNodeForward(viewport, {
        target,
        hdcCommand,
        execImpl,
        cwd: repoRoot
      }),
      runId: proof.runId
    });
    const relaunchSelection = relaunchSelectionResult.analysis;
    await driver.clickNodeImpl(relaunchSelection.transient.candidateSelection, { target, hdcCommand, execImpl, cwd: repoRoot });
    await waitForProxyLayoutAnalysis({
      readLayoutImpl: async () => await driver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd: repoRoot,
        runId: proof.runId,
        stage: 'relaunch-post-save',
        layoutDir: evidenceTempRoot
      }),
      analyzeLayoutImpl: (layout) => {
        requireSavedIntentMarker(layout, relaunchSelection.transient.candidateBaseId);
        return true;
      }
    });
    await driver.navigateBackHomeImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    await driver.forceStopProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    await driver.startVpnImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId, layoutDir: evidenceTempRoot });

    const relaunchRuntimePath = path.join(evidenceTempRoot, 'relaunch-runtime.json');
    const relaunchRuntime = await pullEvidenceImpl({
      kind: 'runtime-journal-relaunch',
      target,
      hdcCommand,
      execImpl,
      fsApi,
      bundleName: APP_BUNDLE,
      remotePath: RUNTIME_REMOTE_PATH,
      localPath: relaunchRuntimePath,
      cwd: repoRoot,
      expectedRunId: proof.runId,
      requireReplayOrdering: true,
      previousSessionAlias: runtimePostPhase4.sessionAlias ?? ''
    });
    verifyReplaySessionBoundary(runtimePostPhase4.sessionAlias, relaunchRuntime.sessionAlias);
    relaunchSessionAlias = typeof relaunchRuntime.sessionAlias === 'string' ? relaunchRuntime.sessionAlias : '';
    proof.network.replayBeforeRunning = verifyReplayJournalOrdering(relaunchRuntime.records ?? relaunchRuntime);

    await driver.launchProductionImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    await driver.openProxyManageImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd: repoRoot, runId: proof.runId });
    const relaunchVerifyResult = await waitForProxyLayoutAnalysis({
      readLayoutImpl: async () => await driver.dumpLayoutImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd: repoRoot,
        runId: proof.runId,
        stage: 'relaunch-verify',
        layoutDir: evidenceTempRoot
      }),
      analyzeLayoutImpl: (layout) => analyzeRuntimeSelectedRow({
        layout,
        runId: proof.runId,
        expectedRowCorrelationHash: relaunchSelection.selection.rowCorrelationHash,
        requireNoSavedIntent: true
      })
    });
    const relaunchVerify = relaunchVerifyResult.analysis;
    proof.selection.relaunchResultKind = relaunchVerify.resultKind;
    proof.selection.relaunchRowCorrelationHash = relaunchVerify.rowCorrelationHash;
    proof.selection.relaunchReplay = verifyRelaunchSelectionMatch({
      rowCorrelationHash: relaunchVerify.rowCorrelationHash,
      expectedRowCorrelationHash: relaunchSelection.selection.rowCorrelationHash,
      hasSavedIntentMarker: gatherProxyLayoutState(relaunchVerifyResult.layout).savedIntent.length > 0
    });

  } catch (error) {
    failures.push(createFailure(error?.code ?? 'PLAN_D_RUNNER_FAILED', 'runner'));
  } finally {
    if (target !== null && hdcCommand !== null) {
      try {
        const cleanupResult = await cleanupImpl({
          target,
          hdcCommand,
          execImpl,
          fsApi,
          cwd: repoRoot,
          runId: proof.runId,
          tempRoot,
          uiDriver: driver,
          pullEvidenceImpl,
          expectedSessionAlias: relaunchSessionAlias
        });
        relaunchCleanupSucceeded = cleanupResult?.stopVpn === true && cleanupResult?.forceStop === true;
      } catch {
        relaunchCleanupSucceeded = false;
      }
    }
    try {
      await closeOriginHandleOnce();
    } catch (error) {
      failures.push(createFailure(error?.code ?? 'PLAN_D_ORIGIN_CLOSE_FAILED', 'runner'));
    }
    await fsApi.rm(evidenceTempRoot, { recursive: true, force: true }).catch(() => {});
  }
  proof.cleanup.phase4CleanupSucceeded = phase4CleanupSucceeded;
  proof.cleanup.relaunchCleanupSucceeded = relaunchCleanupSucceeded;
  proof.cleanup.layoutTempRemoved = layoutTempRemoved;
  proof.timestamps.completedAt = iso(nowImpl());
  proof.result = failures.length === 0 ? 'pass' : 'incomplete';
  return await writeValidatedProofImpl(proof, resolvedOutputPath);
}

async function main() {
  const parsed = parseCliArguments();
  await runPlanDDeviceProof(parsed);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch(async () => {
    await writeArgumentErrorProof({ outputPath: extractOutputPathFromArgv(process.argv.slice(2)) });
    process.exitCode = 1;
  });
}
