#!/usr/bin/env node

import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeForPersistence } from '../../tools/lib/proof-redaction.mjs';
import { inspectPhase4Packages } from './inspect-phase4-packages.mjs';
import { startControlledOrigin } from './phase4-origin.mjs';
import {
  analyzeTargetDiscovery,
  buildTargetedHdcArgs,
  createMaskedDeviceIdentity,
  execCommand
} from './run-phase0-device-proof.mjs';

const REPO_ROOT = path.resolve(new URL('../../..', import.meta.url).pathname);
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.schema.json');
const DEFAULT_OUTPUT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase4-device-proof.json');
const DEFAULT_PRODUCTION_HAP_PATH = path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const DEFAULT_PRODUCTION_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');
const DEFAULT_PROBE_HAP_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
const APP_BUNDLE = 'com.github.kr328.clash.harmony';
const PROBE_BUNDLE = 'com.github.kr328.clash.harmony.trafficprobe';
const ENTRY_ABILITY_NAME = 'EntryAbility';
const PROBE_ABILITY_NAME = 'ProbeAbility';
const MAX_PULL_BYTES = 1024 * 1024;
const MAX_LAYOUT_POLL_ATTEMPTS = 20;
const MAX_EVIDENCE_POLL_ATTEMPTS = 20;
const POLL_WAIT_MS = 250;
const LOCAL_HTTP_CONNECT_PORT = 7890;
const LOCAL_SOCKS5_PORT = 7891;
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const PROBE_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json';
const HDC_HELP_PATTERN = /file\s+recv\s+-b/iu;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

function iso(date = new Date()) {
  return date.toISOString();
}

function createFailure(code, detail) {
  return { code, detail };
}

export function hashOpaqueCorrelationId(value) {
  return shortHash(String(value ?? ''));
}

function aliasOpaqueId(prefix, value) {
  return `${prefix}-${hashOpaqueCorrelationId(value)}`;
}

function scrubSensitiveDetail(raw) {
  return `${raw ?? ''}`
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/giu, '<redacted-url>')
    .replace(/(?:^|[\\/])[^\\/\s]+\.(?:p12|pem|pfx|cer|p7b)/giu, '<path>');
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value);
}

function isDigest(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
}

function digest(seed) {
  return crypto.createHash('sha256').update(seed).digest('hex');
}

function buildFlowMarker(flowId) {
  return `cmfa-${flowId}`;
}

function flowMarkerHash(flowId) {
  return digest(buildFlowMarker(flowId));
}

function shortHash(value) {
  let hashValue = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hashValue ^= value.charCodeAt(index);
    hashValue = Math.imul(hashValue, 16777619);
  }
  return (hashValue >>> 0).toString(16).padStart(8, '0');
}

function buildHashedInvalidLabel(left, right) {
  return `${shortHash(left)}-${shortHash(right)}.invalid`;
}

function buildDnsQueryPacket(label) {
  const header = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  const bytes = [];
  const segments = label.split('.');
  for (const next of segments) {
    bytes.push(next.length);
    for (let charIndex = 0; charIndex < next.length; charIndex += 1) {
      bytes.push(next.charCodeAt(charIndex) & 0xff);
    }
  }
  bytes.push(0x00, 0x00, 0x01, 0x00, 0x01);
  return Buffer.from(header.concat(bytes));
}

function normalizeIngressExpectation(raw) {
  const value = `${raw ?? ''}`.toLowerCase();
  if (value.includes('local-http')) {
    return 'local-http';
  }
  if (value.includes('local-socks')) {
    return 'local-socks';
  }
  return value.includes('tun') ? 'tun' : value;
}

function createDnsPacketCorrelationHash(runId, flowId) {
  return digest(buildDnsQueryPacket(buildHashedInvalidLabel(runId, flowId)));
}

function createBaseProof({ outputPath = DEFAULT_OUTPUT_PATH, runId = crypto.randomUUID(), now = new Date() } = {}) {
  return {
    schemaVersion: '4.0.0',
    phase: 4,
    result: 'incomplete',
    runId,
    outputPath: 'harmony/artifacts/phase4-device-proof.json',
    timestamps: {
      startedAt: iso(now),
      completedAt: iso(now)
    },
    device: {
      targetKind: 'physical',
      identityMasked: 'target-00000000',
      osVersion: 'HarmonyOS 6.0.0',
      apiVersion: 20,
      abi: 'arm64-v8a',
      deviceClass: 'phone'
    },
    bundles: {
      production: { bundleName: APP_BUNDLE },
      probe: { bundleName: PROBE_BUNDLE },
      hapSha256: [digest('production'), digest('probe')]
    },
    core: {
      version: 'v1.19.29',
      nativeSha256: [digest('addon'), digest('mihomo')]
    },
    assertions: {
      addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
      routes: ['0.0.0.0/0', '::/0'],
      dns: ['10.111.222.2', 'fd00:111:222::2'],
      mtu: 1500,
      ipv4Accepted: true,
      ipv6Accepted: true,
      blocking: false,
      blockedApplications: [APP_BUNDLE]
    },
    traffic: {},
    localEvidence: {},
    lifecycle: {
      notification: { result: 'pass' },
      background: { result: 'pass' },
      recovery: { result: 'pass' },
      stop: { result: 'pass' }
    },
    tun: {
      counters: { rxPackets: 0, txPackets: 0, rxBytes: 0, txBytes: 0 }
    },
    failures: []
  };
}

export function createBaseProofForTesting(options = {}) {
  return createBaseProof(options);
}

function isWithinRepo(repoRoot, filePath) {
  const relativePath = path.relative(repoRoot, filePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

async function resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath) {
  const resolved = path.resolve(outputPath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error('--out must stay inside the repository root.'), { code: 'PATH_OUTSIDE_REPO' });
  }
  await fsApi.mkdir(path.dirname(resolved), { recursive: true });
  return resolved;
}

function collectSensitiveProofErrors(value, trail = 'proof', errors = []) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectSensitiveProofErrors(entry, `${trail}[${index}]`, errors));
    return errors;
  }
  if (!isObject(value)) {
    if (typeof value === 'string') {
      if (/\b[a-z][a-z0-9+.-]*:\/\/\S+/iu.test(value)) {
        errors.push(`${trail} must not contain full URLs`);
      }
      if (/(?:^|[\\/])[^\\/\s]+\.(?:p12|pem|pfx|cer|p7b)$/iu.test(value)) {
        errors.push(`${trail} must not contain signing material paths`);
      }
    }
    return errors;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (/(?:serial|udid|imei|deviceid|sn)/iu.test(key)) {
      errors.push(`${trail}.${key} must not use serial-like keys`);
    }
    if (/(?:secret|token|password|cert|key)(?:$|[A-Z_])/u.test(key)) {
      errors.push(`${trail}.${key} must not use secret-bearing keys`);
    }
    collectSensitiveProofErrors(entry, `${trail}.${key}`, errors);
  }
  return errors;
}

async function readSchemaDocument(fsApi = fs) {
  return JSON.parse(await fsApi.readFile(SCHEMA_PATH, 'utf8'));
}

const CANONICAL_INCOMPLETE_PROOF_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['schemaVersion', 'phase', 'result', 'runId', 'outputPath', 'timestamps', 'device', 'bundles', 'core', 'assertions', 'traffic', 'localEvidence', 'lifecycle', 'tun', 'failures'],
  properties: {
    schemaVersion: { const: '4.0.0' },
    phase: { const: 4 },
    result: {
      oneOf: [
        { const: 'incomplete' },
        { const: 'fail' }
      ]
    },
    runId: { type: 'string', pattern: UUID_PATTERN.source },
    outputPath: { const: 'harmony/artifacts/phase4-device-proof.json' },
    timestamps: {
      type: 'object',
      additionalProperties: false,
      required: ['startedAt', 'completedAt'],
      properties: {
        startedAt: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$' },
        completedAt: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$' }
      }
    },
    device: {
      type: 'object',
      additionalProperties: false,
      required: ['targetKind', 'identityMasked', 'osVersion', 'apiVersion', 'abi', 'deviceClass'],
      properties: {
        targetKind: { const: 'physical' },
        identityMasked: { type: 'string', pattern: '^target-[a-f0-9]{8}$' },
        osVersion: { type: 'string', pattern: '^HarmonyOS 6\\.' },
        apiVersion: { type: 'integer', minimum: 20 },
        abi: { const: 'arm64-v8a' },
        deviceClass: { const: 'phone' }
      }
    },
    bundles: {
      type: 'object',
      additionalProperties: false,
      required: ['production', 'probe', 'hapSha256'],
      properties: {
        production: {
          type: 'object',
          additionalProperties: false,
          required: ['bundleName'],
          properties: {
            bundleName: { const: APP_BUNDLE }
          }
        },
        probe: {
          type: 'object',
          additionalProperties: false,
          required: ['bundleName'],
          properties: {
            bundleName: { const: PROBE_BUNDLE }
          }
        },
        hapSha256: {
          type: 'array',
          minItems: 2,
          maxItems: 2,
          uniqueItems: true,
          prefixItems: [
            { type: 'string', pattern: '^[a-f0-9]{64}$' },
            { type: 'string', pattern: '^[a-f0-9]{64}$' }
          ],
          items: false
        }
      }
    },
    core: {
      type: 'object',
      additionalProperties: false,
      required: ['version', 'nativeSha256'],
      properties: {
        version: { const: 'v1.19.29' },
        nativeSha256: {
          type: 'array',
          minItems: 2,
          maxItems: 2,
          uniqueItems: true,
          prefixItems: [
            { type: 'string', pattern: '^[a-f0-9]{64}$' },
            { type: 'string', pattern: '^[a-f0-9]{64}$' }
          ],
          items: false
        }
      }
    },
    assertions: {
      type: 'object',
      additionalProperties: false,
      required: ['addresses', 'routes', 'dns', 'mtu', 'ipv4Accepted', 'ipv6Accepted', 'blocking', 'blockedApplications'],
      properties: {
        addresses: { type: 'array', minItems: 2, maxItems: 2, items: false, prefixItems: [{ const: '10.111.222.1/30' }, { const: 'fd00:111:222::1/126' }] },
        routes: { type: 'array', minItems: 2, maxItems: 2, items: false, prefixItems: [{ const: '0.0.0.0/0' }, { const: '::/0' }] },
        dns: { type: 'array', minItems: 2, maxItems: 2, items: false, prefixItems: [{ const: '10.111.222.2' }, { const: 'fd00:111:222::2' }] },
        mtu: { const: 1500 },
        ipv4Accepted: { const: true },
        ipv6Accepted: { const: true },
        blocking: { const: false },
        blockedApplications: { type: 'array', minItems: 1, maxItems: 1, items: false, prefixItems: [{ const: APP_BUNDLE }] }
      }
    },
    traffic: { type: 'object', additionalProperties: false, properties: {} },
    localEvidence: { type: 'object', additionalProperties: false, properties: {} },
    lifecycle: {
      type: 'object',
      additionalProperties: false,
      required: ['notification', 'background', 'recovery', 'stop'],
      properties: {
        notification: { type: 'object', additionalProperties: false, required: ['result'], properties: { result: { type: 'string', minLength: 1 } } },
        background: { type: 'object', additionalProperties: false, required: ['result'], properties: { result: { type: 'string', minLength: 1 } } },
        recovery: { type: 'object', additionalProperties: false, required: ['result'], properties: { result: { type: 'string', minLength: 1 } } },
        stop: { type: 'object', additionalProperties: false, required: ['result'], properties: { result: { type: 'string', minLength: 1 } } }
      }
    },
    tun: {
      type: 'object',
      additionalProperties: false,
      required: ['counters'],
      properties: {
        counters: {
          type: 'object',
          additionalProperties: false,
          required: ['rxPackets', 'txPackets', 'rxBytes', 'txBytes'],
          properties: {
            rxPackets: { type: 'integer', minimum: 0 },
            txPackets: { type: 'integer', minimum: 0 },
            rxBytes: { type: 'integer', minimum: 0 },
            txBytes: { type: 'integer', minimum: 0 }
          }
        }
      }
    },
    failures: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['code', 'detail'],
        properties: {
          code: { type: 'string', minLength: 1 },
          detail: { type: 'string', minLength: 1 }
        }
      }
    }
  }
};

function resolveLocalSchemaRef(ref, rootSchema) {
  if (!ref.startsWith('#/')) {
    throw new Error(`Unsupported $ref ${ref}`);
  }
  const segments = ref.slice(2).split('/');
  let current = rootSchema;
  for (const segment of segments) {
    if (!isObject(current) || !(segment in current)) {
      throw new Error(`Missing local $ref target ${ref}`);
    }
    current = current[segment];
  }
  return current;
}

function matchesSchemaType(value, expectedType) {
  if (expectedType === 'object') return isObject(value);
  if (expectedType === 'array') return Array.isArray(value);
  if (expectedType === 'integer') return Number.isInteger(value);
  if (expectedType === 'number') return typeof value === 'number' && Number.isFinite(value);
  if (expectedType === 'string') return typeof value === 'string';
  if (expectedType === 'boolean') return typeof value === 'boolean';
  if (expectedType === 'null') return value === null;
  return false;
}

function deepEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

export function validateValueAgainstSchema(value, schema, rootSchema = schema, trail = 'proof') {
  const errors = [];
  function visit(currentValue, currentSchema, currentTrail) {
    if (!isObject(currentSchema)) {
      return;
    }
    if ('$ref' in currentSchema) {
      try {
        const resolved = resolveLocalSchemaRef(currentSchema.$ref, rootSchema);
        visit(currentValue, resolved, currentTrail);
      } catch (error) {
        errors.push(`${currentTrail} ${error.message}`);
      }
      return;
    }
    if (Array.isArray(currentSchema.oneOf)) {
      let matches = 0;
      for (const branch of currentSchema.oneOf) {
        const branchResult = validateValueAgainstSchema(currentValue, branch, rootSchema, currentTrail);
        if (branchResult.valid) {
          matches += 1;
        }
      }
      if (matches !== 1) {
        errors.push(`${currentTrail} must satisfy exactly one oneOf branch`);
      }
      return;
    }
    if ('const' in currentSchema && !deepEqual(currentValue, currentSchema.const)) {
      errors.push(`${currentTrail} must equal const ${JSON.stringify(currentSchema.const)}`);
      return;
    }
    if ('type' in currentSchema) {
      const expectedTypes = Array.isArray(currentSchema.type) ? currentSchema.type : [currentSchema.type];
      if (!expectedTypes.some((type) => matchesSchemaType(currentValue, type))) {
        errors.push(`${currentTrail} must match type ${expectedTypes.join('|')}`);
        return;
      }
    }
    if (typeof currentValue === 'string') {
      if (typeof currentSchema.pattern === 'string' && !(new RegExp(currentSchema.pattern, 'u')).test(currentValue)) {
        errors.push(`${currentTrail} must match pattern ${currentSchema.pattern}`);
      }
      if (Number.isInteger(currentSchema.minLength) && currentValue.length < currentSchema.minLength) {
        errors.push(`${currentTrail} must have minLength ${currentSchema.minLength}`);
      }
    }
    if (typeof currentValue === 'number' && Number.isFinite(currentValue)) {
      if (Number.isFinite(currentSchema.minimum) && currentValue < currentSchema.minimum) {
        errors.push(`${currentTrail} must be >= ${currentSchema.minimum}`);
      }
    }
    if (Array.isArray(currentValue)) {
      if (Number.isInteger(currentSchema.minItems) && currentValue.length < currentSchema.minItems) {
        errors.push(`${currentTrail} must have at least ${currentSchema.minItems} items`);
      }
      if (Number.isInteger(currentSchema.maxItems) && currentValue.length > currentSchema.maxItems) {
        errors.push(`${currentTrail} must have at most ${currentSchema.maxItems} items`);
      }
      if (currentSchema.uniqueItems === true) {
        const seen = new Set(currentValue.map((entry) => JSON.stringify(entry)));
        if (seen.size !== currentValue.length) {
          errors.push(`${currentTrail} must not contain duplicate items`);
        }
      }
      const prefixItems = Array.isArray(currentSchema.prefixItems) ? currentSchema.prefixItems : [];
      for (let index = 0; index < prefixItems.length && index < currentValue.length; index += 1) {
        visit(currentValue[index], prefixItems[index], `${currentTrail}[${index}]`);
      }
      if (currentValue.length > prefixItems.length) {
        if (currentSchema.items === false) {
          errors.push(`${currentTrail} must not contain additional tuple items`);
        } else if (isObject(currentSchema.items)) {
          for (let index = prefixItems.length; index < currentValue.length; index += 1) {
            visit(currentValue[index], currentSchema.items, `${currentTrail}[${index}]`);
          }
        }
      }
    }
    if (isObject(currentValue)) {
      const required = Array.isArray(currentSchema.required) ? currentSchema.required : [];
      for (const key of required) {
        if (!(key in currentValue)) {
          errors.push(`${currentTrail}.${key} is required`);
        }
      }
      const properties = isObject(currentSchema.properties) ? currentSchema.properties : {};
      for (const [key, entry] of Object.entries(currentValue)) {
        if (currentSchema.additionalProperties === false && !(key in properties)) {
          errors.push(`${currentTrail} must not include unexpected key ${key}`);
          continue;
        }
        if (key in properties) {
          visit(entry, properties[key], `${currentTrail}.${key}`);
        }
      }
    }
  }
  visit(value, schema, trail);
  return { valid: errors.length === 0, errors };
}

function validateIncompleteProofDocument(proof) {
  return validateValueAgainstSchema(proof, CANONICAL_INCOMPLETE_PROOF_SCHEMA, CANONICAL_INCOMPLETE_PROOF_SCHEMA);
}

export async function validatePhase4ProofDocument(proof, fsApi = fs) {
  const schema = await readSchemaDocument(fsApi);
  const sensitiveErrors = collectSensitiveProofErrors(proof, 'proof', []);
  const baseValidation = proof?.result === 'pass'
    ? validateValueAgainstSchema(proof, schema, schema)
    : validateIncompleteProofDocument(proof);
  return {
    valid: baseValidation.valid && sensitiveErrors.length === 0,
    errors: [...baseValidation.errors, ...sensitiveErrors]
  };
}

function buildProofValidationFallback(sourceProof, validationErrors) {
  const fallback = createBaseProof({ runId: UUID_PATTERN.test(String(sourceProof?.runId ?? '')) ? sourceProof.runId : crypto.randomUUID() });
  fallback.timestamps.startedAt = sourceProof?.timestamps?.startedAt && isIsoTimestamp(sourceProof.timestamps.startedAt)
    ? sourceProof.timestamps.startedAt
    : fallback.timestamps.startedAt;
  fallback.timestamps.completedAt = iso(new Date());
  fallback.device.identityMasked = sourceProof?.device?.identityMasked && /^target-[a-f0-9]{8}$/u.test(String(sourceProof.device.identityMasked))
    ? sourceProof.device.identityMasked
    : fallback.device.identityMasked;
  fallback.failures.push(createFailure('PHASE4_PROOF_INVALID', scrubSensitiveDetail(validationErrors.join('; '))));
  return fallback;
}

export async function writeValidatedProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const replacements = createRedactionReplacements({ repoRoot, env: process.env });
  const sanitized = sanitizeForPersistence(proof, replacements);
  const validation = await validatePhase4ProofDocument(sanitized, fsApi);
  const persisted = validation.valid ? sanitized : buildProofValidationFallback(sanitized, validation.errors);
  return await writeProof(persisted, outputPath, fsApi, repoRoot);
}

export async function writeProof(proof, outputPath = DEFAULT_OUTPUT_PATH, fsApi = fs, repoRoot = REPO_ROOT) {
  const safeOutputPath = await resolveRepoScopedOutputPath(fsApi, repoRoot, outputPath);
  const tempPath = `${safeOutputPath}.${process.pid}.${Date.now()}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(proof, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, safeOutputPath);
  return proof;
}

export async function writeArgumentErrorProof({
  outputPath = DEFAULT_OUTPUT_PATH,
  detail = 'Invalid CLI arguments.',
  fsApi = fs
} = {}) {
  const proof = createBaseProof({ outputPath });
  proof.failures.push(createFailure('ARGUMENT_INVALID', scrubSensitiveDetail(detail)));
  proof.timestamps.completedAt = iso(new Date());
  return await writeValidatedProof(proof, outputPath, fsApi);
}

export function selectControlledLanOriginAddress(networkInterfacesMap = os.networkInterfaces()) {
  const ipv4Candidates = [];
  const ipv6Candidates = [];
  for (const [name, entries] of Object.entries(networkInterfacesMap ?? {})) {
    for (const entry of entries ?? []) {
      if (entry?.internal) {
        continue;
      }
      if (entry?.family === 'IPv4' && /^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\./u.test(String(entry.address))) {
        ipv4Candidates.push({ name, address: entry.address });
      }
      if (entry?.family === 'IPv6' && !/^fe80:/iu.test(String(entry.address)) && entry.address !== '::1') {
        ipv6Candidates.push({ name, address: entry.address });
      }
    }
  }
  if (ipv4Candidates.length !== 1) {
    throw Object.assign(new Error('ORIGIN_BIND_BLOCKED: expected exactly one private LAN IPv4 address for the controlled origin.'), { code: 'ORIGIN_BIND_BLOCKED' });
  }
  return {
    ipv4: ipv4Candidates[0],
    ipv6: ipv6Candidates.length === 1 ? ipv6Candidates[0] : null
  };
}

export function buildBundleEvidencePullArgs({ target, bundleName, remotePath, localPath }) {
  return buildTargetedHdcArgs(target, ['file', 'recv', '-b', bundleName, remotePath, localPath]);
}

function collectLayoutNodes(root, nodes = []) {
  if (!isObject(root)) {
    return nodes;
  }
  nodes.push(root);
  const children = Array.isArray(root.children) ? root.children : [];
  for (const child of children) {
    collectLayoutNodes(child, nodes);
  }
  return nodes;
}

function nodeMatchesSelector(node, selector) {
  const attrs = node.attributes ?? {};
  const ids = selector.ids ?? [];
  const texts = selector.texts ?? [];
  const resourceNames = selector.resourceNames ?? [];
  const arkuiIds = selector.arkuiIds ?? [];
  return ids.includes(attrs.id) ||
    ids.includes(attrs.resourceId) ||
    texts.includes(attrs.text) ||
    resourceNames.includes(attrs.resourceName) ||
    arkuiIds.includes(attrs.arkuiId);
}

export function selectUniqueLayoutNode(layout, selector) {
  const root = layout?.root ?? layout;
  const matches = collectLayoutNodes(root).filter((node) => nodeMatchesSelector(node, selector));
  if (matches.length !== 1) {
    throw Object.assign(new Error('UI_AUTOMATION_UNSUPPORTED: semantic selector was missing or ambiguous.'), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  const bounds = matches[0].bounds ?? {};
  return {
    node: matches[0],
    centerX: Math.floor(((bounds.left ?? 0) + (bounds.right ?? 0)) / 2),
    centerY: Math.floor(((bounds.top ?? 0) + (bounds.bottom ?? 0)) / 2)
  };
}

function normalizeSelector(selector = {}) {
  return {
    ids: Array.isArray(selector.ids) ? [...selector.ids] : [],
    texts: Array.isArray(selector.texts) ? [...selector.texts] : [],
    resourceNames: Array.isArray(selector.resourceNames) ? [...selector.resourceNames] : [],
    arkuiIds: Array.isArray(selector.arkuiIds) ? [...selector.arkuiIds] : []
  };
}

function normalizeStateWord(raw) {
  if (typeof raw === 'boolean') {
    return raw;
  }
  const value = `${raw ?? ''}`.trim().toLowerCase();
  if (['true', '1', 'on', 'checked', 'selected', 'enabled'].includes(value)) {
    return true;
  }
  if (['false', '0', 'off', 'unchecked', 'unselected', 'disabled'].includes(value)) {
    return false;
  }
  return null;
}

function enabledAttributeIsStateBearing(node) {
  const attrs = node?.attributes ?? {};
  const semanticHints = [
    attrs.id,
    attrs.resourceId,
    attrs.resourceName,
    attrs.arkuiId,
    attrs.text,
    attrs.accessibilityText,
    attrs.className,
    attrs.type
  ].filter(Boolean).join(' ');
  return /switch|toggle|wifi|mobile|cellular|data|network|screen|display|power/iu.test(semanticHints);
}

export function readExplicitBooleanState(node) {
  const attrs = node?.attributes ?? {};
  const candidates = [];
  for (const source of ['checked', 'selected', 'state', 'value']) {
    if (!(source in attrs)) {
      continue;
    }
    const value = normalizeStateWord(attrs[source]);
    if (value === null) {
      return { supported: false, reason: `${source} was not a recognized boolean state value` };
    }
    candidates.push({ source, value });
  }
  if ('enabled' in attrs && enabledAttributeIsStateBearing(node)) {
    const value = normalizeStateWord(attrs.enabled);
    if (value === null) {
      return { supported: false, reason: 'enabled was not a recognized boolean state value' };
    }
    candidates.push({ source: 'enabled', value });
  }
  if (candidates.length === 0) {
    return { supported: false, reason: 'no explicit boolean state attributes were available' };
  }
  const firstValue = candidates[0].value;
  if (candidates.some((entry) => entry.value !== firstValue)) {
    return { supported: false, reason: 'explicit state attributes disagreed' };
  }
  return {
    supported: true,
    value: firstValue,
    source: candidates.map((entry) => entry.source).join('+')
  };
}

const NETWORK_TOGGLE_SELECTORS = Object.freeze({
  wifi: normalizeSelector({
    ids: ['wifi_switch', 'wifi_toggle'],
    resourceNames: ['wifi_switch', 'wifi_toggle']
  }),
  mobile: normalizeSelector({
    ids: ['mobile_data_switch', 'mobile_data_toggle'],
    resourceNames: ['mobile_data_switch', 'mobile_data_toggle']
  })
});

function createLayoutDumpPath(prefix, tempRoot = os.tmpdir()) {
  return path.join(tempRoot, `${prefix}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.json`);
}

async function clickLayoutNode(nodeSelection, { target, hdcCommand, execImpl, cwd }) {
  await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'click', `${nodeSelection.centerX}`, `${nodeSelection.centerY}`]),
    { cwd }
  );
}

function observeNamedToggleState(layout, selector, label) {
  const selected = selectUniqueLayoutNode(layout, selector);
  const observed = readExplicitBooleanState(selected.node);
  if (!observed.supported) {
    throw Object.assign(new Error(`UI_AUTOMATION_UNSUPPORTED: ${label} state was unreadable.`), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  return {
    selector: normalizeSelector(selector),
    centerX: selected.centerX,
    centerY: selected.centerY,
    value: observed.value,
    source: observed.source
  };
}

async function observeCurrentNetworkState({
  target,
  hdcCommand,
  execImpl,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  wifiSelector = NETWORK_TOGGLE_SELECTORS.wifi,
  mobileSelector = NETWORK_TOGGLE_SELECTORS.mobile
}) {
  const localLayout = createLayoutDumpPath('phase4-network', tempRoot);
  try {
    const layout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    const wifi = observeNamedToggleState(layout, wifiSelector, 'wifi');
    const mobile = observeNamedToggleState(layout, mobileSelector, 'mobile');
    return {
      supported: true,
      wifiEnabled: wifi.value,
      mobileEnabled: mobile.value,
      wifi,
      mobile
    };
  } catch (error) {
    if (error?.code === 'UI_AUTOMATION_UNSUPPORTED') {
      return { supported: false, reason: error.message };
    }
    throw error;
  } finally {
    await fsApi.rm(localLayout, { force: true }).catch(() => {});
  }
}

export function parseObservedScreenState(raw) {
  const matches = [...`${raw ?? ''}`.matchAll(/\b(?:screen|display)(?:\s+\w+){0,3}\s*(?:state)?\s*[:=]\s*(on|off)\b/giu)];
  const values = [...new Set(matches.map((entry) => entry[1].toLowerCase()))];
  if (values.length !== 1) {
    return { supported: false };
  }
  return {
    supported: true,
    state: values[0],
    screenOn: values[0] === 'on'
  };
}

const DEFAULT_SCREEN_STATE_COMMANDS = Object.freeze([
  ['shell', 'hidumper', '-s', 'PowerManagerService', '-a', '-a'],
  ['shell', 'hidumper', '-s', 'DisplayManagerService', '-a', '-a']
]);

export async function defaultReadScreenState({
  target,
  hdcCommand,
  execImpl = execCommand,
  cwd = REPO_ROOT,
  commands = DEFAULT_SCREEN_STATE_COMMANDS
}) {
  for (const args of commands) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, args), { cwd });
    if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
      continue;
    }
    const observed = parseObservedScreenState(`${result.stdout ?? ''}\n${result.stderr ?? ''}`);
    if (observed.supported) {
      return observed;
    }
  }
  return { supported: false };
}

function createTrafficPass(kind, linked, probeEntry) {
  return {
    result: 'pass',
    sessionId: linked.sessionAlias ?? aliasOpaqueId('session', probeEntry.sessionId),
    traceId: linked.traceAlias ?? aliasOpaqueId('trace', probeEntry.flowId),
    captureTrace: {
      ingress: linked.ingress,
      event: kind === 'tcp' ? 'tcp-connect' : kind === 'udp' ? 'udp-associate' : kind === 'dns' ? 'dns-query' : kind === 'ipv4' ? 'ipv4-flow' : 'ipv6-flow'
    },
    coreEvent: {
      event: kind === 'tcp' ? 'mihomo.tcp' : kind === 'udp' ? 'mihomo.udp' : kind === 'dns' ? 'mihomo.dns' : kind === 'ipv4' ? 'mihomo.ipv4' : 'mihomo.ipv6'
    }
  };
}

export function normalizePhase4OriginEvidence(raw, expectedRunId = null) {
  if (!isObject(raw)) {
    return { observations: [], errors: ['origin evidence must be an object'] };
  }
  const observations = Array.isArray(raw.observations) ? raw.observations.filter((entry) => expectedRunId === null || entry?.runId === expectedRunId) : [];
  const errors = [];
  const byProtocol = new Map();
  for (const entry of observations) {
    if (!UUID_PATTERN.test(String(entry?.runId ?? '')) || !UUID_PATTERN.test(String(entry?.sessionId ?? '')) || !UUID_PATTERN.test(String(entry?.flowId ?? ''))) {
      errors.push('origin observation ids must be opaque UUIDs');
      continue;
    }
    byProtocol.set(entry.protocol, entry);
  }
  return {
    started: raw.started ?? null,
    observations,
    byProtocol,
    errors
  };
}

function createProbeRecordIndex(records) {
  const byStepId = new Map();
  for (const record of records) {
    byStepId.set(record.stepId, record);
  }
  return byStepId;
}

function normalizeSyntheticProbe(raw) {
  const withDefaultOutcome = (entry) => entry ? { outcome: 'pass', ...entry } : entry;
  return {
    directReachability: raw.directReachability,
    global: {
      tcp: withDefaultOutcome(raw.global?.tcp),
      udp: withDefaultOutcome(raw.global?.udp),
      dns: withDefaultOutcome(raw.global?.dns),
      ipv4: withDefaultOutcome(raw.global?.ipv4),
      ipv6: raw.global?.ipv6 ?? { result: 'not-run', reason: 'network-not-provisioned' }
    },
    local: {
      http: withDefaultOutcome(raw.local?.http),
      socks: withDefaultOutcome(raw.local?.socks)
    },
    lifecycle: raw.lifecycle,
    sessionId: raw.sessionId ?? null,
    records: [],
    errors: ['synthetic probe.global shortcut unsupported']
  };
}

export function normalizePhase4ProbeEvidence(raw, expectedRunId = null) {
  if (isObject(raw?.global) && isObject(raw?.local)) {
    return normalizeSyntheticProbe(raw);
  }
  const errors = [];
  if (!isObject(raw)) {
    return { directReachability: { result: 'fail' }, global: {}, local: {}, lifecycle: {}, sessionId: null, records: [], errors: ['probe evidence must be an object'] };
  }
  if (expectedRunId !== null && raw.runId !== expectedRunId) {
    errors.push('probe runId mismatch');
  }
  const records = Array.isArray(raw.records) ? raw.records : [];
  const byStepId = createProbeRecordIndex(records);
  const https = byStepId.get('https');
  const tcp = byStepId.get('tcp');
  const udpIpv4 = byStepId.get('udp-ipv4');
  const udpIpv6 = byStepId.get('udp-ipv6');
  const dnsPacketIpv4 = byStepId.get('dns-packet-ipv4') ?? byStepId.get('dns-lookup');
  const dnsPacketIpv6 = byStepId.get('dns-packet-ipv6');
  const httpConnect = byStepId.get('http-connect');
  const socks5 = byStepId.get('socks5');
  const directReachability = {
    result: https?.outcome === 'pass' && tcp?.outcome === 'pass' && udpIpv4?.outcome === 'pass' ? 'pass' : 'fail'
  };
  const lifecycle = raw.lifecycle ?? {};
  return {
    directReachability,
    global: {
      tcp: tcp ? { ingress: normalizeIngressExpectation(tcp.ingressExpectation), sessionId: tcp.sessionId ?? raw.sessionId ?? '', flowId: tcp.flowId, outcome: tcp.outcome, protocol: 'tcp', correlationHash: flowMarkerHash(tcp.flowId) } : null,
      udp: udpIpv4 ? { ingress: normalizeIngressExpectation(udpIpv4.ingressExpectation), sessionId: udpIpv4.sessionId ?? raw.sessionId ?? '', flowId: udpIpv4.flowId, outcome: udpIpv4.outcome, protocol: 'udp', correlationHash: flowMarkerHash(udpIpv4.flowId) } : null,
      dns: dnsPacketIpv4 ? { ingress: normalizeIngressExpectation(dnsPacketIpv4.ingressExpectation), sessionId: dnsPacketIpv4.sessionId ?? raw.sessionId ?? '', flowId: dnsPacketIpv4.flowId, outcome: dnsPacketIpv4.outcome, protocol: 'dns', correlationHash: createDnsPacketCorrelationHash(raw.runId, dnsPacketIpv4.flowId) } : null,
      ipv4: dnsPacketIpv4 ? { ingress: normalizeIngressExpectation(dnsPacketIpv4.ingressExpectation), sessionId: dnsPacketIpv4.sessionId ?? raw.sessionId ?? '', flowId: dnsPacketIpv4.flowId, outcome: dnsPacketIpv4.outcome, protocol: 'dns', correlationHash: createDnsPacketCorrelationHash(raw.runId, dnsPacketIpv4.flowId) } : null,
      ipv6: udpIpv6
        ? (udpIpv6.outcome === 'pass'
          ? { ingress: normalizeIngressExpectation(udpIpv6.ingressExpectation), sessionId: udpIpv6.sessionId ?? raw.sessionId ?? '', flowId: udpIpv6.flowId, outcome: udpIpv6.outcome, protocol: 'udp', correlationHash: flowMarkerHash(udpIpv6.flowId) }
          : { result: 'not-run', reason: udpIpv6.outcome })
        : (dnsPacketIpv6?.outcome === 'pass'
          ? { ingress: normalizeIngressExpectation(dnsPacketIpv6.ingressExpectation), sessionId: dnsPacketIpv6.sessionId ?? raw.sessionId ?? '', flowId: dnsPacketIpv6.flowId, outcome: dnsPacketIpv6.outcome, protocol: 'dns', correlationHash: createDnsPacketCorrelationHash(raw.runId, dnsPacketIpv6.flowId) }
          : { result: 'not-run', reason: 'network-not-provisioned' })
    },
    local: {
      http: httpConnect ? { ingress: 'local-http', sessionId: httpConnect.sessionId ?? raw.sessionId ?? '', flowId: httpConnect.flowId, outcome: httpConnect.outcome } : null,
      socks: socks5 ? { ingress: 'local-socks', sessionId: socks5.sessionId ?? raw.sessionId ?? '', flowId: socks5.flowId, outcome: socks5.outcome } : null
    },
    lifecycle,
    sessionId: raw.sessionId ?? null,
    records,
    errors
  };
}

function normalizeSyntheticRuntime(raw) {
  return {
    counters: raw.counters ?? { rxPackets: 0, txPackets: 0, rxBytes: 0, txBytes: 0 },
    linkedRecords: [],
    records: raw.records ?? [],
    errors: Array.isArray(raw.linkedRecords) ? ['synthetic runtime linkedRecords shortcut unsupported'] : []
  };
}

export function normalizePhase4RuntimeJournal(raw) {
  if (Array.isArray(raw?.linkedRecords)) {
    return normalizeSyntheticRuntime(raw);
  }
  const errors = [];
  if (!isObject(raw)) {
    return { counters: { rxPackets: 0, txPackets: 0, rxBytes: 0, txBytes: 0 }, linkedRecords: [], records: [], errors: ['runtime journal must be an object'] };
  }
  const records = Array.isArray(raw.records) ? raw.records : [];
  let lastSequence = 0;
  const linkedRecords = [];
  for (const record of records) {
    if (!Number.isInteger(record?.sequence) || record.sequence <= lastSequence) {
      errors.push('runtime journal sequence must be monotonic');
      continue;
    }
    lastSequence = record.sequence;
    if (record.kind === 'traffic' && record.linkageStatus === 'linked') {
      linkedRecords.push({
        ingress: record.ingress,
        flowIdHash: record.flowIdHash,
        sessionIdHash: record.sessionIdHash,
        traceAlias: record.traceAlias,
        coreAlias: record.coreAlias,
        protocol: record.protocol,
        correlationHash: record.correlationHash,
        counterDelta: (record.counterSnapshot?.rxPackets ?? 0) + (record.counterSnapshot?.txPackets ?? 0) > 0 ? 1 : 0
      });
    }
  }
  return {
    counters: raw.counters ?? { rxPackets: 0, txPackets: 0, rxBytes: 0, txBytes: 0 },
    linkedRecords,
    records,
    errors
  };
}

export function normalizePhase4CollectedEvidence(input) {
  const origin = normalizePhase4OriginEvidence(input.origin ?? {}, input.runId ?? null);
  const probe = normalizePhase4ProbeEvidence(input.probe ?? {}, input.runId ?? null);
  const runtime = normalizePhase4RuntimeJournal(input.runtime ?? {});
  return {
    runId: input.runId,
    device: input.device ?? {},
    packages: input.packages ?? {},
    origin,
    probe: {
      directReachability: probe.directReachability,
      global: probe.global,
      local: probe.local,
      lifecycle: input.lifecycle ?? probe.lifecycle ?? {},
      sessionId: probe.sessionId,
      records: probe.records
    },
    runtime,
    _normalizationErrors: [...origin.errors, ...probe.errors, ...runtime.errors]
  };
}

export function correlatePhase4Evidence(evidence) {
  const normalized = evidence._normalizationErrors ? evidence : normalizePhase4CollectedEvidence(evidence);
  const proof = createBaseProof({ runId: normalized.runId });
  proof.device.identityMasked = normalized.device?.identityMasked ?? 'target-91ac4f20';
  proof.device.osVersion = normalized.device?.osVersion ?? 'HarmonyOS 6.0.1.123';
  proof.device.apiVersion = normalized.device?.apiVersion ?? 20;
  proof.device.abi = normalized.device?.abi ?? 'arm64-v8a';
  proof.bundles.hapSha256 = [
    normalized.packages?.production?.hapSha256 ?? digest('production'),
    normalized.packages?.probe?.hapSha256 ?? digest('probe')
  ];
  proof.tun.counters = normalized.runtime?.counters ?? proof.tun.counters;

  for (const error of normalized._normalizationErrors ?? []) {
    proof.failures.push(createFailure('EVIDENCE_NORMALIZATION_FAILED', scrubSensitiveDetail(error)));
  }
  if (normalized.packages?.result !== 'pass') {
    proof.failures.push(createFailure('PACKAGE_INSPECTION_FAILED', 'Package inspection did not pass.'));
  }
  if (normalized.packages?.production?.bundleName !== APP_BUNDLE || normalized.packages?.probe?.bundleName !== PROBE_BUNDLE) {
    proof.failures.push(createFailure('BUNDLE_IDENTITY_INVALID', 'Production/probe bundle names drifted.'));
  }
  if (normalized.packages?.production?.hapSha256 === normalized.packages?.probe?.hapSha256 ||
    normalized.packages?.production?.signatureSha256 === normalized.packages?.probe?.signatureSha256) {
    proof.failures.push(createFailure('SHARED_BUNDLE_IDENTITY', 'Production and probe identities must be distinct.'));
  }

  const originByProtocol = normalized.origin?.byProtocol ?? new Map();
  const directHttps = originByProtocol.get('https');
  const directTcp = originByProtocol.get('tcp');
  const directUdp = originByProtocol.get('udp');
  if (normalized.probe?.directReachability?.result !== 'pass' || !directHttps || !directTcp || !directUdp) {
    proof.failures.push(createFailure('ORIGIN_REACHABILITY_NOT_PROVEN', 'Direct reachability before VPN start was not proven.'));
  }

  const stepMapping = Object.freeze({
    tcp: normalized.probe?.global?.tcp,
    udp: normalized.probe?.global?.udp,
    dns: normalized.probe?.global?.dns,
    ipv4: normalized.probe?.global?.ipv4
  });
  for (const [kind, probeEntry] of Object.entries(stepMapping)) {
    if (!probeEntry || probeEntry.outcome === 'fail') {
      proof.failures.push(createFailure('GLOBAL_INGRESS_INVALID', `${kind} probe evidence was missing or failed.`));
      continue;
    }
    if (probeEntry.ingress !== 'tun') {
      proof.failures.push(createFailure('GLOBAL_INGRESS_INVALID', `${kind} must stay on tun ingress.`));
      continue;
    }
    const flowIdHash = probeEntry.correlationHash;
    const sessionIdHash = hashOpaqueCorrelationId(probeEntry.sessionId);
    const linked = normalized.runtime.linkedRecords.find((entry) =>
      entry.ingress === 'tun' &&
      entry.protocol === probeEntry.protocol &&
      entry.correlationHash === flowIdHash &&
      entry.flowIdHash === flowIdHash &&
      entry.sessionIdHash === sessionIdHash
    );
    if (!linked) {
      proof.failures.push(createFailure('TUN_LINK_MISSING', `${kind} missing linked tun/core evidence.`));
      continue;
    }
    if ((kind === 'tcp' || kind === 'udp') && !directUdp && !directTcp) {
      proof.failures.push(createFailure('ORIGIN_RECORD_INVALID', `${kind} origin observation was missing.`));
      continue;
    }
    if (!(linked.counterDelta > 0)) {
      proof.failures.push(createFailure('COUNTER_DELTA_MISSING', `${kind} must show positive counter deltas.`));
      continue;
    }
    proof.traffic[kind] = createTrafficPass(kind, linked, probeEntry);
  }

  const ipv6Probe = normalized.probe?.global?.ipv6;
  if (ipv6Probe?.result === 'not-run' || !ipv6Probe) {
    proof.traffic.ipv6 = { result: 'not-run', reason: ipv6Probe?.reason ?? 'network-not-provisioned' };
  } else if (ipv6Probe.ingress === 'tun') {
    proof.traffic.ipv6 = {
      result: 'pass',
      sessionId: aliasOpaqueId('session', ipv6Probe.sessionId),
      traceId: aliasOpaqueId('trace', ipv6Probe.flowId),
      captureTrace: { ingress: 'tun', event: 'ipv6-flow' },
      coreEvent: { event: 'mihomo.ipv6' }
    };
  }

  if (normalized.probe?.local?.http?.ingress !== 'local-http' || normalized.probe.local.http?.outcome !== 'pass') {
    proof.failures.push(createFailure('LOCAL_HTTP_INGRESS_INVALID', 'Local HTTP checks must stay on local-http ingress.'));
  } else {
    proof.localEvidence.http = {
      result: 'pass',
      ingress: 'local-http',
      sessionId: aliasOpaqueId('session', normalized.probe.local.http.sessionId),
      traceId: aliasOpaqueId('trace', normalized.probe.local.http.flowId)
    };
  }
  if (normalized.probe?.local?.socks?.ingress !== 'local-socks' || normalized.probe.local.socks?.outcome !== 'pass') {
    proof.failures.push(createFailure('LOCAL_SOCKS_INGRESS_INVALID', 'Local SOCKS checks must stay on local-socks ingress.'));
  } else {
    proof.localEvidence.socks = {
      result: 'pass',
      ingress: 'local-socks',
      sessionId: aliasOpaqueId('session', normalized.probe.local.socks.sessionId),
      traceId: aliasOpaqueId('trace', normalized.probe.local.socks.flowId)
    };
  }

  const lifecycle = normalized.probe?.lifecycle ?? {};
  if (!lifecycle.launcherContinuity || !lifecycle.screenOffContinuity) {
    proof.failures.push(createFailure('CONTINUITY_NOT_PROVEN', 'Launcher/screen-off continuity was not proven.'));
  }
  if (!lifecycle.vpnIndicatorVisible || !lifecycle.ongoingNotificationVisible) {
    proof.failures.push(createFailure('SYSTEM_UI_NOT_PROVEN', 'VPN indicator and ongoing notification must both be visible.'));
  }
  if (!lifecycle.networkLossRecovery) {
    proof.failures.push(createFailure('NETWORK_RECOVERY_NOT_PROVEN', 'Controlled network loss/recovery was not proven.'));
  }
  if (!lifecycle.stopCleanup || !lifecycle.networkingRestored) {
    proof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', 'Stop cleanup and ordinary networking restore were not proven.'));
  }

  proof.result = proof.failures.length === 0 ? 'pass' : 'incomplete';
  proof.timestamps.completedAt = iso(new Date());
  return proof;
}

async function defaultHashFile(filePath, fsApi = fs) {
  const buffer = await fsApi.readFile(filePath);
  return {
    path: filePath,
    absolutePath: filePath,
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

function createFlowIds() {
  return {
    https: crypto.randomUUID(),
    tcp: crypto.randomUUID(),
    udpIpv4: crypto.randomUUID(),
    udpIpv6: crypto.randomUUID(),
    dnsLookup: crypto.randomUUID(),
    dnsPacketIpv4: crypto.randomUUID(),
    dnsPacketIpv6: crypto.randomUUID(),
    httpConnect: crypto.randomUUID(),
    socks5: crypto.randomUUID()
  };
}

function buildProbeAbilityParameters(originHandle, runId) {
  const sessionId = crypto.randomUUID();
  return {
    runId,
    sessionId,
    pinnedPublicKeyHash: originHandle.publicKeyPinSha256 ?? originHandle.pinnedCertificateHash,
    flowIds: createFlowIds(),
    lanOrigin: {
      host: originHandle.https.host,
      httpsPort: originHandle.https.port,
      tcpPort: originHandle.tcp.port,
      udpPort: originHandle.udp.port,
      dnsPort: originHandle.udp.port
    },
    localListeners: {
      httpConnectPort: LOCAL_HTTP_CONNECT_PORT,
      socks5Port: LOCAL_SOCKS5_PORT
    }
  };
}

function buildProbeLaunchArgs(target, parameters) {
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', PROBE_ABILITY_NAME,
    '-b', PROBE_BUNDLE,
    '--ps', 'runId', parameters.runId,
    '--ps', 'sessionId', parameters.sessionId,
    '--ps', 'pinnedPublicKeyHash', parameters.pinnedPublicKeyHash,
    '--ps', 'flowHttps', parameters.flowIds.https,
    '--ps', 'flowTcp', parameters.flowIds.tcp,
    '--ps', 'flowUdpIpv4', parameters.flowIds.udpIpv4,
    '--ps', 'flowUdpIpv6', parameters.flowIds.udpIpv6,
    '--ps', 'flowDnsLookup', parameters.flowIds.dnsLookup,
    '--ps', 'flowDnsPacketIpv4', parameters.flowIds.dnsPacketIpv4,
    '--ps', 'flowDnsPacketIpv6', parameters.flowIds.dnsPacketIpv6,
    '--ps', 'flowHttpConnect', parameters.flowIds.httpConnect,
    '--ps', 'flowSocks5', parameters.flowIds.socks5,
    '--ps', 'originHost', parameters.lanOrigin.host,
    '--pi', 'originHttpsPort', `${parameters.lanOrigin.httpsPort}`,
    '--pi', 'originTcpPort', `${parameters.lanOrigin.tcpPort}`,
    '--pi', 'originUdpPort', `${parameters.lanOrigin.udpPort}`,
    '--pi', 'originDnsPort', `${parameters.lanOrigin.dnsPort}`,
    '--pi', 'localHttpConnectPort', `${parameters.localListeners.httpConnectPort}`,
    '--pi', 'localSocks5Port', `${parameters.localListeners.socks5Port}`
  ]);
}

function buildProductionLaunchArgs(target) {
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', ENTRY_ABILITY_NAME,
    '-b', APP_BUNDLE
  ]);
}

async function verifyHdcHelp(execImpl, hdcCommand, cwd) {
  for (const args of [['help'], ['-h'], ['--help']]) {
    const result = await execImpl(hdcCommand, args, { cwd });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    if (!result?.error && result?.exitCode === 0 && HDC_HELP_PATTERN.test(output) && /install/iu.test(output) && /shell/iu.test(output) && /list targets/iu.test(output)) {
      return { ok: true, result };
    }
  }
  return { ok: false, failure: createFailure('HDC_HELP_UNSUPPORTED', 'hdc help does not confirm file recv -b support.') };
}

async function readDeviceFact({ execImpl, hdcCommand, target, candidates, cwd }) {
  for (const key of candidates) {
    const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'param', 'get', key]), { cwd });
    const value = String(result.stdout ?? '').trim();
    if (!result?.error && result?.exitCode === 0 && value.length > 0) {
      return value;
    }
  }
  return null;
}

export function classifyHarmonyTarget(device) {
  if (!device.model || !device.product || !device.buildVersion || !device.apiVersion || !device.abi) {
    return { kind: 'incomplete', code: 'DEVICE_FACT_MISSING', detail: 'The selected target did not expose all required device facts.' };
  }
  if (/simulator|emulator/iu.test(`${device.model} ${device.product}`)) {
    return { kind: 'unsupported', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Simulator targets cannot satisfy Phase 4.' };
  }
  if (!/arm64|aarch64/iu.test(device.abi)) {
    return { kind: 'unsupported', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Only AArch64 devices can satisfy Phase 4.' };
  }
  if (Number.parseInt(device.apiVersion, 10) < 20) {
    return { kind: 'unsupported', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Phase 4 requires API 20 or later.' };
  }
  if (!/HarmonyOS 6|^\s*6(?:\.\d+)+/iu.test(device.buildVersion)) {
    return { kind: 'unsupported', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Phase 4 requires HarmonyOS 6.' };
  }
  return { kind: 'physical' };
}

async function pullBundleEvidenceJson({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  bundleName,
  remotePath,
  localPath,
  cwd
}) {
  const args = buildBundleEvidencePullArgs({ target, bundleName, remotePath, localPath });
  const result = await execImpl(hdcCommand, args, { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    return { ok: false, failure: createFailure('APP_EVIDENCE_MISSING', `Unable to pull ${bundleName} evidence.`), args };
  }
  const handle = await fsApi.open(localPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const stats = await handle.stat();
    if (!stats.isFile() || stats.size < 1 || stats.size > MAX_PULL_BYTES) {
      return { ok: false, failure: createFailure('APP_EVIDENCE_INVALID', `${bundleName} evidence size was invalid.`), args };
    }
    const buffer = await handle.readFile();
    let parsed = null;
    try {
      parsed = JSON.parse(buffer.toString('utf8'));
    } catch {
      return { ok: false, failure: createFailure('APP_EVIDENCE_INVALID', `${bundleName} evidence was not valid JSON.`), args };
    }
    return { ok: true, proof: parsed, args };
  } finally {
    await handle.close().catch(() => {});
  }
}

async function waitForBundleEvidence({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  bundleName,
  remotePath,
  localPath,
  cwd,
  expectedRunId
}) {
  let lastFailure = createFailure('APP_EVIDENCE_MISSING', `Missing ${bundleName} evidence.`);
  for (let attempt = 0; attempt < MAX_EVIDENCE_POLL_ATTEMPTS; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({ fsApi, execImpl, hdcCommand, target, bundleName, remotePath, localPath, cwd });
    if (pulled.ok) {
      if (pulled.proof?.runId === expectedRunId) {
        return pulled;
      }
      lastFailure = createFailure('APP_EVIDENCE_STALE', `${bundleName} evidence belonged to another run.`);
    } else {
      lastFailure = pulled.failure;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_WAIT_MS));
  }
  return { ok: false, failure: lastFailure };
}

async function dumpLayoutToHost({
  execImpl,
  hdcCommand,
  target,
  localPath,
  cwd
}) {
  const remotePath = `/data/local/tmp/cmfa-layout-${Date.now()}.json`;
  const dumpArgs = buildTargetedHdcArgs(target, ['shell', 'uitest', 'dumpLayout', '-i', '-p', remotePath]);
  const dumpResult = await execImpl(hdcCommand, dumpArgs, { cwd });
  if (dumpResult?.error || dumpResult?.exitCode !== 0 || dumpResult?.timedOut) {
    throw Object.assign(new Error('UI_AUTOMATION_UNSUPPORTED: dumpLayout failed.'), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  const pullArgs = buildTargetedHdcArgs(target, ['file', 'recv', remotePath, localPath]);
  const pullResult = await execImpl(hdcCommand, pullArgs, { cwd });
  if (pullResult?.error || pullResult?.exitCode !== 0 || pullResult?.timedOut) {
    throw Object.assign(new Error('UI_AUTOMATION_UNSUPPORTED: layout pull failed.'), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  return JSON.parse(await fs.readFile(localPath, 'utf8'));
}

async function defaultPerformUiAutomation({ target, hdcCommand, execImpl, fsApi = fs, tempRoot = os.tmpdir(), cwd = REPO_ROOT }) {
  const localLayout = path.join(tempRoot, `phase4-layout-${process.pid}-${Date.now()}.json`);
  const clicks = [];
  try {
    await execImpl(hdcCommand, buildProductionLaunchArgs(target), { cwd });
    const appLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    const primary = selectUniqueLayoutNode(appLayout, { ids: ['home.vpn.primary'] });
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'click', `${primary.centerX}`, `${primary.centerY}`]), { cwd });
    clicks.push('primary');
    const mergedLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    const consentSelectorCandidates = [
      { resourceNames: ['vpn_permission_allow', 'permission_allow_button'] },
      { ids: ['system.vpn.allow', 'permission_allow'] }
    ];
    for (const selector of consentSelectorCandidates) {
      try {
        const consent = selectUniqueLayoutNode(mergedLayout, selector);
        await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'click', `${consent.centerX}`, `${consent.centerY}`]), { cwd });
        clicks.push('consent');
        break;
      } catch {
      }
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Home']), { cwd });
    const beforeScreenToggle = await defaultReadScreenState({ target, hdcCommand, execImpl, cwd });
    if (!beforeScreenToggle.supported || beforeScreenToggle.screenOn !== true) {
      return {
        ok: false,
        code: 'CONTINUITY_NOT_PROVEN',
        detail: 'Screen state could not be observed as ON before the continuity toggle.',
        launcherContinuity: false,
        screenOffContinuity: false,
        vpnIndicatorVisible: false,
        ongoingNotificationVisible: false,
        clicks
      };
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Power']), { cwd });
    const afterScreenOff = await defaultReadScreenState({ target, hdcCommand, execImpl, cwd });
    if (!afterScreenOff.supported || afterScreenOff.screenOn !== false) {
      return {
        ok: false,
        code: 'CONTINUITY_NOT_PROVEN',
        detail: 'Screen-off continuity could not be observed after pressing Power.',
        launcherContinuity: false,
        screenOffContinuity: false,
        vpnIndicatorVisible: false,
        ongoingNotificationVisible: false,
        clicks
      };
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Power']), { cwd });
    const afterScreenOn = await defaultReadScreenState({ target, hdcCommand, execImpl, cwd });
    if (!afterScreenOn.supported || afterScreenOn.screenOn !== true) {
      return {
        ok: false,
        code: 'CONTINUITY_NOT_PROVEN',
        detail: 'Screen-on continuity could not be observed after restoring from screen-off.',
        launcherContinuity: false,
        screenOffContinuity: false,
        vpnIndicatorVisible: false,
        ongoingNotificationVisible: false,
        clicks
      };
    }
    const indicatorLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    const vpnIndicatorVisible = (() => {
      try {
        selectUniqueLayoutNode(indicatorLayout, { resourceNames: ['home_vpn_notification_label', 'vpn_indicator'] });
        return true;
      } catch {
        return false;
      }
    })();
    const ongoingNotificationVisible = (() => {
      try {
        selectUniqueLayoutNode(indicatorLayout, { resourceNames: ['home_vpn_notification_label', 'ongoing_notification'] });
        return true;
      } catch {
        return false;
      }
    })();
    return {
      ok: vpnIndicatorVisible && ongoingNotificationVisible,
      code: vpnIndicatorVisible && ongoingNotificationVisible ? '' : 'UI_AUTOMATION_UNSUPPORTED',
      detail: vpnIndicatorVisible && ongoingNotificationVisible ? '' : 'Merged layout did not expose unique VPN indicator/notification selectors.',
      launcherContinuity: vpnIndicatorVisible && ongoingNotificationVisible,
      screenOffContinuity: true,
      vpnIndicatorVisible,
      ongoingNotificationVisible,
      clicks
    };
  } finally {
    await fsApi.rm(localLayout, { force: true }).catch(() => {});
  }
}

export async function defaultSnapshotNetworkState({ target, hdcCommand, execImpl, fsApi = fs, tempRoot = os.tmpdir(), cwd = REPO_ROOT }) {
  const observed = await observeCurrentNetworkState({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd });
  if (!observed.supported) {
    return { supported: false };
  }
  return {
    supported: true,
    target,
    hdcCommand,
    cwd,
    wifiSelector: observed.wifi.selector,
    mobileSelector: observed.mobile.selector,
    wifiEnabled: observed.wifiEnabled,
    mobileEnabled: observed.mobileEnabled
  };
}

export async function defaultRestoreNetworkState(snapshot, { execImpl = execCommand, fsApi = fs, tempRoot = os.tmpdir(), cwd = snapshot?.cwd ?? REPO_ROOT } = {}) {
  if (!snapshot?.supported) {
    return { restored: false, supported: false };
  }
  const current = await observeCurrentNetworkState({
    target: snapshot.target,
    hdcCommand: snapshot.hdcCommand,
    execImpl,
    fsApi,
    tempRoot,
    cwd,
    wifiSelector: snapshot.wifiSelector,
    mobileSelector: snapshot.mobileSelector
  });
  if (!current.supported) {
    throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: current network state was unreadable during restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
  }
  const clicks = [];
  if (current.wifiEnabled !== snapshot.wifiEnabled) {
    await clickLayoutNode(current.wifi, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    clicks.push('wifi');
  }
  if (current.mobileEnabled !== snapshot.mobileEnabled) {
    await clickLayoutNode(current.mobile, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    clicks.push('mobile');
  }
  if (clicks.length === 0) {
    return { restored: true, clicks };
  }
  const verified = await observeCurrentNetworkState({
    target: snapshot.target,
    hdcCommand: snapshot.hdcCommand,
    execImpl,
    fsApi,
    tempRoot,
    cwd,
    wifiSelector: snapshot.wifiSelector,
    mobileSelector: snapshot.mobileSelector
  });
  if (!verified.supported || verified.wifiEnabled !== snapshot.wifiEnabled || verified.mobileEnabled !== snapshot.mobileEnabled) {
    throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: network restore did not return to the exact pre-state.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
  }
  return { restored: true, clicks };
}

export async function defaultExerciseNetworkRecovery(snapshot, { execImpl = execCommand, fsApi = fs, tempRoot = os.tmpdir(), cwd = snapshot?.cwd ?? REPO_ROOT } = {}) {
  if (!snapshot?.supported) {
    return { supported: false };
  }
  if (!snapshot.wifiEnabled && !snapshot.mobileEnabled) {
    return { supported: false };
  }
  let current = await observeCurrentNetworkState({
    target: snapshot.target,
    hdcCommand: snapshot.hdcCommand,
    execImpl,
    fsApi,
    tempRoot,
    cwd,
    wifiSelector: snapshot.wifiSelector,
    mobileSelector: snapshot.mobileSelector
  });
  if (!current.supported) {
    return { supported: false };
  }
  const toggled = [];
  for (const key of ['wifi', 'mobile']) {
    if (!current[`${key}Enabled`]) {
      continue;
    }
    await clickLayoutNode(current[key], { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    toggled.push(key);
    current = await observeCurrentNetworkState({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      wifiSelector: snapshot.wifiSelector,
      mobileSelector: snapshot.mobileSelector
    });
    if (!current.supported) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: network state became unreadable during recovery.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
  }
  if (toggled.length === 0 || current.wifiEnabled || current.mobileEnabled) {
    throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: controlled loss did not leave both wifi and mobile disabled.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
  }
  await defaultRestoreNetworkState(snapshot, { execImpl, fsApi, tempRoot, cwd });
  return { supported: true, recovered: true, lossObserved: true, toggled };
}

export async function defaultSnapshotScreenState({
  target,
  hdcCommand,
  execImpl = execCommand,
  cwd = REPO_ROOT,
  readScreenStateImpl = async (options) => await defaultReadScreenState(options)
}) {
  const observed = await readScreenStateImpl({ target, hdcCommand, execImpl, cwd });
  if (!observed.supported) {
    return { supported: false };
  }
  return {
    supported: true,
    target,
    hdcCommand,
    cwd,
    screenOn: observed.screenOn
  };
}

export async function defaultRestoreScreenState(
  snapshot,
  {
    execImpl = execCommand,
    cwd = snapshot?.cwd ?? REPO_ROOT,
    readScreenStateImpl = async (options) => await defaultReadScreenState(options)
  } = {}
) {
  if (!snapshot?.supported) {
    return { restored: false, supported: false };
  }
  const current = await readScreenStateImpl({
    target: snapshot.target,
    hdcCommand: snapshot.hdcCommand,
    execImpl,
    cwd
  });
  if (!current.supported) {
    throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: current screen state was unreadable during restore.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
  }
  if (current.screenOn === snapshot.screenOn) {
    return { restored: true, changed: false };
  }
  await execImpl(snapshot.hdcCommand, buildTargetedHdcArgs(snapshot.target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Power']), { cwd });
  const verified = await readScreenStateImpl({
    target: snapshot.target,
    hdcCommand: snapshot.hdcCommand,
    execImpl,
    cwd
  });
  if (!verified.supported || verified.screenOn !== snapshot.screenOn) {
    throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: screen state did not restore to the exact pre-state.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
  }
  return { restored: true, changed: true };
}

async function defaultStartOrigin({ runId }) {
  const selected = selectControlledLanOriginAddress(os.networkInterfaces());
  const origin = await startControlledOrigin({
    bindAddress: selected.ipv4.address,
    ipv6BindAddress: selected.ipv6?.address ?? '',
    runId,
    lanProofRequired: true
  });
  origin.selectedLan = selected;
  return origin;
}

async function defaultRunBaselineProbeImpl({
  target,
  hdcCommand,
  execImpl,
  origin,
  cwd = REPO_ROOT,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  runId
}) {
  const parameters = buildProbeAbilityParameters(origin, runId);
  const launchArgs = buildProbeLaunchArgs(target, parameters);
  const launchResult = await execImpl(hdcCommand, launchArgs, { cwd });
  if (launchResult?.error || launchResult?.exitCode !== 0 || launchResult?.timedOut) {
    return { result: 'fail', failure: createFailure('PROBE_LAUNCH_FAILED', 'The baseline probe failed to launch.') };
  }
  const pulled = await waitForBundleEvidence({
    fsApi,
    execImpl,
    hdcCommand,
    target,
    bundleName: PROBE_BUNDLE,
    remotePath: PROBE_REMOTE_PATH,
    localPath: path.join(tempRoot, `phase4-baseline-${process.pid}.json`),
    cwd,
    expectedRunId: runId
  });
  if (!pulled.ok) {
    return { result: 'fail', failure: pulled.failure };
  }
  const normalized = normalizePhase4ProbeEvidence(pulled.proof, runId);
  return {
    result: normalized.directReachability.result,
    normalized,
    raw: pulled.proof
  };
}

async function defaultStopVpn({ target, hdcCommand, execImpl, cwd = REPO_ROOT }) {
  return await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', APP_BUNDLE]), { cwd });
}

async function defaultForceStopBundle({ target, hdcCommand, execImpl, bundleName, cwd = REPO_ROOT }) {
  return await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', bundleName]), { cwd });
}

function parseCliArguments(argv = process.argv.slice(2)) {
  const parsed = {
    productionHapPath: DEFAULT_PRODUCTION_HAP_PATH,
    productionManifestPath: DEFAULT_PRODUCTION_MANIFEST_PATH,
    probeHapPath: DEFAULT_PROBE_HAP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    const value = argv[index + 1] ?? '';
    if (option === '--production-hap') parsed.productionHapPath = value;
    else if (option === '--production-manifest') parsed.productionManifestPath = value;
    else if (option === '--probe-hap') parsed.probeHapPath = value;
    else if (option === '--out') parsed.outputPath = value;
    else throw new Error(`Unknown argument: ${option}`);
    index += 1;
  }
  return parsed;
}

function applyIncompleteFailure(proof, code, detail) {
  proof.result = 'incomplete';
  proof.failures.push(createFailure(code, scrubSensitiveDetail(detail)));
}

export async function runPhase4DeviceProof({
  productionHapPath = DEFAULT_PRODUCTION_HAP_PATH,
  productionManifestPath = DEFAULT_PRODUCTION_MANIFEST_PATH,
  probeHapPath = DEFAULT_PROBE_HAP_PATH,
  outputPath = DEFAULT_OUTPUT_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  toolchainInspectorImpl = inspectToolchain,
  inspectPackagesImpl = inspectPhase4Packages,
  execImpl = execCommand,
  hashFileImpl = (filePath) => defaultHashFile(filePath, fsApi),
  startOriginImpl = async ({ runId }) => await defaultStartOrigin({ runId }),
  runBaselineProbeImpl = async (options) => await defaultRunBaselineProbeImpl(options),
  snapshotNetworkStateImpl = async (options) => await defaultSnapshotNetworkState(options),
  exerciseNetworkRecoveryImpl = async (snapshot) => await defaultExerciseNetworkRecovery(snapshot, { execImpl }),
  restoreNetworkStateImpl = async (snapshot) => await defaultRestoreNetworkState(snapshot, { execImpl }),
  snapshotScreenStateImpl = async (options) => await defaultSnapshotScreenState(options),
  restoreScreenStateImpl = async (snapshot) => await defaultRestoreScreenState(snapshot, { execImpl, cwd: repoRoot }),
  stopVpnImpl = async (options) => await defaultStopVpn(options),
  forceStopBundleImpl = async (options) => await defaultForceStopBundle(options),
  performUiAutomationImpl = async (options) => await defaultPerformUiAutomation(options),
  writeValidatedProofImpl = async (candidate, outputPathArg, fsArg, repoRootArg) =>
    await writeValidatedProof(candidate, outputPathArg, fsArg, repoRootArg)
} = {}) {
  const startedAt = new Date();
  const proof = createBaseProof({ outputPath, now: startedAt });
  const tempPullRoot = await fsApi.mkdtemp(path.join(os.tmpdir(), 'phase4-pull-'));
  let hdcCommand = null;
  let target = null;
  let networkSnapshot = null;
  let screenSnapshot = null;
  let originHandle = null;
  let candidateProof = proof;
  let persistedProof = null;
  let notificationOk = false;
  let backgroundOk = false;
  let recoveryOk = false;

  try {
    main: {
      const productionHash = await hashFileImpl(productionHapPath);
      const probeHash = await hashFileImpl(probeHapPath);
      const packageInspection = await inspectPackagesImpl({
        productionHapPath,
        productionManifestPath,
        probeHapPath
      });
      proof.bundles.hapSha256 = [
        packageInspection.production?.hapSha256 ?? productionHash.sha256,
        packageInspection.probe?.hapSha256 ?? probeHash.sha256
      ];
      if (packageInspection.result !== 'pass') {
        applyIncompleteFailure(proof, 'PACKAGE_INSPECTION_FAILED', 'Package inspection did not pass.');
        break main;
      }

      const toolchain = await toolchainInspectorImpl({ cwd: repoRoot });
      if (toolchain?.report?.result !== 'pass' || !toolchain?.resolved?.paths?.hdc) {
        applyIncompleteFailure(proof, 'TOOL_MISSING', 'The integrated hdc command is unavailable.');
        break main;
      }
      hdcCommand = toolchain.resolved.paths.hdc;

      const help = await verifyHdcHelp(execImpl, hdcCommand, repoRoot);
      if (!help.ok) {
        proof.failures.push(help.failure);
        break main;
      }

      const targetsResult = await execImpl(hdcCommand, ['list', 'targets'], { cwd: repoRoot });
      const targetAnalysis = analyzeTargetDiscovery(targetsResult);
      if (targetAnalysis.kind === 'missing') {
        applyIncompleteFailure(proof, 'DEVICE_TARGET_MISSING', 'No HarmonyOS target was available.');
        break main;
      }
      if (targetAnalysis.kind !== 'selected') {
        applyIncompleteFailure(proof, 'DEVICE_TARGET_AMBIGUOUS', 'Phase 4 requires exactly one selected physical device target.');
        break main;
      }
      target = targetAnalysis.targets[0];
      proof.device.identityMasked = createMaskedDeviceIdentity(target);
      proof.device.osVersion = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.software.version'], cwd: repoRoot }) ?? proof.device.osVersion;
      proof.device.apiVersion = Number.parseInt(await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.ohos.apiversion', 'const.product.apiversion'], cwd: repoRoot }) ?? '0', 10) || 0;
      proof.device.abi = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.cpu.abilist'], cwd: repoRoot }) ?? '';
      const model = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.model'], cwd: repoRoot });
      const product = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.name', 'const.product.device'], cwd: repoRoot });
      const classification = classifyHarmonyTarget({
        model,
        product,
        buildVersion: proof.device.osVersion,
        apiVersion: `${proof.device.apiVersion}`,
        abi: proof.device.abi
      });
      if (classification.kind !== 'physical') {
        applyIncompleteFailure(proof, classification.code, classification.detail);
        break main;
      }

      const productionInstall = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['install', '-r', productionHapPath]), { cwd: repoRoot });
      if (productionInstall?.error || productionInstall?.exitCode !== 0 || productionInstall?.timedOut) {
        applyIncompleteFailure(proof, 'INSTALL_FAILED', 'Production HAP install failed.');
        break main;
      }
      const probeInstall = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['install', '-r', probeHapPath]), { cwd: repoRoot });
      if (probeInstall?.error || probeInstall?.exitCode !== 0 || probeInstall?.timedOut) {
        applyIncompleteFailure(proof, 'INSTALL_FAILED', 'Probe HAP install failed.');
        break main;
      }

      originHandle = await startOriginImpl({ runId: proof.runId });
      const baseline = await runBaselineProbeImpl({
        target,
        hdcCommand,
        execImpl,
        origin: originHandle,
        cwd: repoRoot,
        fsApi,
        tempRoot: tempPullRoot,
        runId: proof.runId
      });
      if (baseline.result !== 'pass') {
        applyIncompleteFailure(proof, 'ORIGIN_REACHABILITY_NOT_PROVEN', 'Direct reachability before VPN start was not proven.');
        break main;
      }

      screenSnapshot = await snapshotScreenStateImpl({ target, hdcCommand, execImpl, cwd: repoRoot });
      if (screenSnapshot?.supported === false) {
        applyIncompleteFailure(proof, 'CONTINUITY_NOT_PROVEN', 'Screen state controls were unsupported or unavailable.');
        break main;
      }
      networkSnapshot = await snapshotNetworkStateImpl({ target, hdcCommand, execImpl, cwd: repoRoot });
      if (networkSnapshot?.supported === false) {
        applyIncompleteFailure(proof, 'NETWORK_RECOVERY_NOT_PROVEN', 'Network state controls were unsupported or unavailable.');
        break main;
      }

      const uiResult = await performUiAutomationImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot: tempPullRoot,
        cwd: repoRoot
      });
      if (!uiResult.ok) {
        applyIncompleteFailure(proof, uiResult.code ?? 'UI_AUTOMATION_UNSUPPORTED', uiResult.detail ?? 'UI automation was unsupported.');
        break main;
      }
      notificationOk = uiResult.ongoingNotificationVisible === true;
      backgroundOk = uiResult.launcherContinuity === true && uiResult.screenOffContinuity === true;
      const recoveryResult = await exerciseNetworkRecoveryImpl(networkSnapshot);
      recoveryOk = recoveryResult?.supported === true && recoveryResult?.recovered === true;
      if (!recoveryOk) {
        applyIncompleteFailure(proof, 'NETWORK_RECOVERY_NOT_PROVEN', 'Controlled network loss/recovery was not proven.');
        break main;
      }

      const [runtimePull, probePull] = await Promise.all([
        waitForBundleEvidence({
          fsApi,
          execImpl,
          hdcCommand,
          target,
          bundleName: APP_BUNDLE,
          remotePath: RUNTIME_REMOTE_PATH,
          localPath: path.join(tempPullRoot, 'runtime.json'),
          cwd: repoRoot,
          expectedRunId: proof.runId
        }),
        waitForBundleEvidence({
          fsApi,
          execImpl,
          hdcCommand,
          target,
          bundleName: PROBE_BUNDLE,
          remotePath: PROBE_REMOTE_PATH,
          localPath: path.join(tempPullRoot, 'probe.json'),
          cwd: repoRoot,
          expectedRunId: proof.runId
        })
      ]);
      if (!runtimePull.ok) {
        proof.failures.push(runtimePull.failure);
        break main;
      }
      if (!probePull.ok) {
        proof.failures.push(probePull.failure);
        break main;
      }

      candidateProof = correlatePhase4Evidence(normalizePhase4CollectedEvidence({
        runId: proof.runId,
        device: proof.device,
        packages: {
          result: packageInspection.result,
          production: packageInspection.production,
          probe: packageInspection.probe
        },
        origin: {
          started: originHandle?.sessionId ? { sessionId: originHandle.sessionId } : null,
          observations: originHandle?.observations ?? []
        },
        probe: probePull.proof,
        runtime: runtimePull.proof,
        lifecycle: {
          launcherContinuity: uiResult.launcherContinuity === true,
          screenOffContinuity: uiResult.screenOffContinuity === true,
          vpnIndicatorVisible: uiResult.vpnIndicatorVisible === true,
          ongoingNotificationVisible: uiResult.ongoingNotificationVisible === true,
          networkLossRecovery: recoveryOk === true,
          stopCleanup: false,
          networkingRestored: false
        }
      }));
    }
  } catch (error) {
    applyIncompleteFailure(proof, error?.code ?? 'PHASE4_RUNNER_FAILED', error?.message ?? 'Phase 4 runner failed.');
    candidateProof = proof;
  } finally {
    let stopCleanupOk = true;
    let networkingRestoredOk = networkSnapshot === null ? true : false;
    let screenRestoredOk = screenSnapshot === null ? true : false;
    const activeProof = candidateProof ?? proof;
    if (hdcCommand !== null && target !== null) {
      const cleanupResults = await Promise.allSettled([
        stopVpnImpl({ target, hdcCommand, execImpl, cwd: repoRoot }),
        forceStopBundleImpl({ target, hdcCommand, execImpl, bundleName: APP_BUNDLE, cwd: repoRoot }),
        forceStopBundleImpl({ target, hdcCommand, execImpl, bundleName: PROBE_BUNDLE, cwd: repoRoot })
      ]);
      if (cleanupResults.some((entry) => entry.status === 'rejected')) {
        stopCleanupOk = false;
        activeProof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', 'Stop cleanup failed during finally.'));
      }
    }
    if (originHandle?.close) {
      try {
        await originHandle.close();
      } catch {
        stopCleanupOk = false;
        activeProof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', 'Controlled origin cleanup failed during finally.'));
      }
    }
    try {
      await restoreNetworkStateImpl(networkSnapshot);
      networkingRestoredOk = true;
    } catch {
      activeProof.failures.push(createFailure('NETWORK_RECOVERY_NOT_PROVEN', 'Network restoration failed during finally.'));
    }
    try {
      await restoreScreenStateImpl(screenSnapshot);
      screenRestoredOk = true;
    } catch {
      stopCleanupOk = false;
      activeProof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', 'Screen restoration failed during finally.'));
    }
    try {
      await fsApi.rm(tempPullRoot, { recursive: true, force: true });
    } catch {
      stopCleanupOk = false;
      activeProof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', 'Temporary cleanup failed during finally.'));
    }
    activeProof.lifecycle.notification = { result: notificationOk ? 'pass' : 'fail' };
    activeProof.lifecycle.background = { result: backgroundOk && screenRestoredOk ? 'pass' : 'fail' };
    activeProof.lifecycle.recovery = { result: recoveryOk && networkingRestoredOk ? 'pass' : 'fail' };
    activeProof.lifecycle.stop = { result: stopCleanupOk ? 'pass' : 'fail' };
    if (activeProof.result === 'pass' && (!stopCleanupOk || !networkingRestoredOk || !screenRestoredOk)) {
      activeProof.result = 'incomplete';
    }
    activeProof.timestamps.completedAt = iso(new Date());
    persistedProof = await writeValidatedProofImpl(activeProof, outputPath, fsApi, repoRoot);
  }
  return persistedProof;
}

async function main() {
  const parsed = parseCliArguments();
  await runPhase4DeviceProof(parsed);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch(async (error) => {
    await writeArgumentErrorProof({
      outputPath: DEFAULT_OUTPUT_PATH,
      detail: error?.message ?? 'Phase 4 runner failed.'
    });
    process.stderr.write(`${error?.message ?? error}\n`);
    process.exitCode = 1;
  });
}
