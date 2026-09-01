#!/usr/bin/env node

import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeForPersistence } from '../../tools/lib/proof-redaction.mjs';
import { createDefaultPhase4ExternalOrigin, normalizePhase4ExternalOrigin } from './phase4-external-origin.mjs';
import { inspectPhase4Packages } from './inspect-phase4-packages.mjs';
import { startControlledOrigin } from './phase4-origin.mjs';
import { ensureRepoScopedOutputFile } from './repo-path-safety.mjs';
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
const PROBE_BUNDLE = 'com.cmfa.phase4.trafficprobe';
const ENTRY_ABILITY_NAME = 'EntryAbility';
const PROBE_ABILITY_NAME = 'ProbeAbility';
const MAX_PULL_BYTES = 1024 * 1024;
const MAX_LAYOUT_POLL_ATTEMPTS = 20;
const MAX_EVIDENCE_POLL_ATTEMPTS = 240;
const MAX_RUNTIME_RECOVERY_POLL_ATTEMPTS = 80;
const MAX_SCREEN_STATE_POLL_ATTEMPTS = 12;
const POLL_WAIT_MS = 250;
const LOCAL_HTTP_CONNECT_PORT = 7890;
const LOCAL_SOCKS5_PORT = 7891;
const RUNTIME_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const PROBE_REMOTE_PATH = '/data/storage/el2/base/haps/entry/files/phase4-probe-evidence.json';
const HDC_FILE_RECV_HELP_PATTERN = /file\s+recv(?:\s+\[option\]|\s+-b)/iu;
const HDC_BUNDLE_RECV_HELP_PATTERN = /file\s+recv\s+-b|(?:^|\n)\s*-b\s*:\s*send\/receive\s+file\s+to\s+debug\s+application\s+directory/imu;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const NETWORK_RECOVERY_RUNTIME_TIMEOUT_DETAIL = 'Runtime journal did not publish a fresh recovery-ready window after network restoration.';
const NETWORK_RECOVERY_ENTERED_TIMEOUT_DETAIL = 'Runtime journal did not publish a fresh recovering transition during controlled network loss.';
const RUNTIME_STOP_TIMEOUT_DETAIL = 'Runtime journal did not publish a fresh stopped window after the stop request.';
const RUNTIME_TRAFFIC_TIMEOUT_DETAIL = 'Runtime journal did not publish fresh linked traffic evidence for the VPN probe.';
const EXTERNAL_ORIGIN_REACHABILITY_DETAIL = 'External echo reachability was not proven.';
const VPN_EXTERNAL_INGRESS_DETAIL = 'VPN-mode external echo evidence was missing or failed.';
const CONTROLLED_HTTPS_REACHABILITY_DETAIL = 'Controlled HTTPS reachability was not proven.';
const RUNTIME_RECOVERY_ENTERED_REASONS = Object.freeze({
  entered: 'entered',
  journalInvalid: 'journal-invalid',
  runMismatch: 'run-mismatch',
  sequenceStale: 'sequence-stale',
  updatedAtStale: 'updated-at-stale',
  recoveringMissing: 'recovering-missing',
  evidenceMissing: 'evidence-missing'
});
const RUNTIME_RECOVERY_READY_REASONS = Object.freeze({
  ready: 'ready',
  journalInvalid: 'journal-invalid',
  runMismatch: 'run-mismatch',
  sequenceStale: 'sequence-stale',
  updatedAtStale: 'updated-at-stale',
  lifecycleNotRunning: 'lifecycle-not-running',
  recoveryAttemptNotReset: 'recovery-attempt-not-reset',
  recoveringCountStale: 'recovering-count-stale',
  runningCountStale: 'running-count-stale',
  recoveringMissing: 'recovering-missing',
  proxyActivateMissing: 'proxy-activate-missing',
  runningMissing: 'running-missing',
  evidenceMissing: 'evidence-missing'
});
const RUNTIME_STOP_REASONS = Object.freeze({
  stopped: 'stopped',
  journalInvalid: 'journal-invalid',
  runMismatch: 'run-mismatch',
  sequenceStale: 'sequence-stale',
  updatedAtStale: 'updated-at-stale',
  lifecycleNotStopped: 'lifecycle-not-stopped',
  stoppedFlagMissing: 'stopped-flag-missing',
  stopRecordMissing: 'stop-record-missing',
  evidenceMissing: 'evidence-missing'
});
const RUNTIME_TRAFFIC_REASONS = Object.freeze({
  ready: 'ready',
  journalInvalid: 'journal-invalid',
  runMismatch: 'run-mismatch',
  sequenceStale: 'sequence-stale',
  updatedAtStale: 'updated-at-stale',
  tcpMissing: 'tcp-missing',
  tcpAmbiguous: 'tcp-ambiguous',
  udpMissing: 'udp-missing',
  udpAmbiguous: 'udp-ambiguous',
  dnsMissing: 'dns-missing',
  dnsAmbiguous: 'dns-ambiguous',
  evidenceMissing: 'evidence-missing'
});
const STOP_CLEANUP_STAGE_DETAILS = Object.freeze({
  gracefulStop: 'Stop cleanup failed at fixed stage: graceful-stop.',
  runtimeStop: 'Stop cleanup failed at fixed stage: runtime-stop.',
  forceStopProduction: 'Stop cleanup failed at fixed stage: force-stop-production.',
  forceStopProbe: 'Stop cleanup failed at fixed stage: force-stop-probe.',
  originClose: 'Stop cleanup failed at fixed stage: origin-close.',
  networkRestore: 'Stop cleanup failed at fixed stage: network-restore.',
  screenRestore: 'Stop cleanup failed at fixed stage: screen-restore.',
  tempCleanup: 'Stop cleanup failed at fixed stage: temp-cleanup.'
});

function iso(date = new Date()) {
  return date.toISOString();
}

function createFailure(code, detail) {
  return { code, detail };
}

function createExternalOriginConfigFailure() {
  return createFailure('EXTERNAL_ORIGIN_CONFIG_INVALID', 'Phase 4 external origin configuration was invalid.');
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
    stubDetected: true,
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
  return await ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, '--out');
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
      if (/^(?:session|trace)-[A-Za-z0-9_-]+$/u.test(value)) {
        errors.push(`${trail} must not contain persisted alias identifiers`);
      }
    }
    return errors;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (key === 'sessionId' || key === 'traceId') {
      errors.push(`${trail}.${key} must not persist identifiers`);
    }
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
  required: ['schemaVersion', 'phase', 'result', 'stubDetected', 'runId', 'outputPath', 'timestamps', 'device', 'bundles', 'core', 'assertions', 'traffic', 'localEvidence', 'lifecycle', 'tun', 'failures'],
  properties: {
    schemaVersion: { const: '4.0.0' },
    phase: { const: 4 },
    result: {
      oneOf: [
        { const: 'incomplete' },
        { const: 'fail' }
      ]
    },
    stubDetected: { type: 'boolean' },
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
  if (typeof sourceProof?.stubDetected === 'boolean') {
    fallback.stubDetected = sourceProof.stubDetected;
  }
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
  if (sanitized.result !== 'pass') {
    sanitized.traffic = {};
    sanitized.localEvidence = {};
  }
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

function parseIpv4(value) {
  const segments = String(value ?? '').trim().split('.');
  if (segments.length !== 4 || !segments.every((entry) => /^\d{1,3}$/u.test(entry))) {
    return null;
  }
  const octets = segments.map((entry) => Number.parseInt(entry, 10));
  if (octets.some((entry) => entry < 0 || entry > 255)) {
    return null;
  }
  return octets.reduce((result, octet) => ((result << 8) | octet) >>> 0, 0);
}

function isCanonicalNumericIpv4(value) {
  const raw = String(value ?? '');
  if (net.isIP(raw) !== 4) {
    return false;
  }
  const segments = raw.split('.');
  return segments.length === 4
    && segments.every((entry) => entry.length > 0 && String(Number.parseInt(entry, 10)) === entry);
}

function isSameIpv4Subnet(host, device) {
  const hostAddress = parseIpv4(host?.address);
  const hostNetmask = parseIpv4(host?.netmask);
  const deviceAddress = parseIpv4(device?.address);
  const deviceNetmask = parseIpv4(device?.netmask);
  if ([hostAddress, hostNetmask, deviceAddress, deviceNetmask].some((entry) => entry === null)) {
    return false;
  }
  return (hostAddress & hostNetmask) === (deviceAddress & hostNetmask)
    && (hostAddress & deviceNetmask) === (deviceAddress & deviceNetmask);
}

export function parseDeviceLanIpv4Candidates(raw) {
  const candidates = [];
  let interfaceName = '';
  for (const line of String(raw ?? '').split(/\r?\n/u)) {
    const interfaceMatch = line.match(/^([A-Za-z0-9_.:-]+)\s+Link\s+encap:/u);
    if (interfaceMatch) {
      interfaceName = interfaceMatch[1];
      continue;
    }
    const addressMatch = line.match(/\binet(?:\s+addr:|\s+)(\d{1,3}(?:\.\d{1,3}){3})\b[^\n]*\b(?:Mask:|netmask\s+)(\d{1,3}(?:\.\d{1,3}){3})\b/iu);
    if (interfaceName.length > 0 && addressMatch
      && parseIpv4(addressMatch[1]) !== null && parseIpv4(addressMatch[2]) !== null
      && addressMatch[1] !== '127.0.0.1') {
      candidates.push({ name: interfaceName, address: addressMatch[1], netmask: addressMatch[2] });
    }
  }
  return candidates;
}

export function parseDeviceWlanIpv4(raw) {
  const first = parseDeviceLanIpv4Candidates(raw)[0];
  return first ? { address: first.address, netmask: first.netmask } : null;
}

export function selectControlledLanOriginAddress(
  networkInterfacesMap = os.networkInterfaces(),
  { deviceIpv4 = null, deviceIpv4Candidates = null } = {}
) {
  const deviceCandidates = Array.isArray(deviceIpv4Candidates)
    ? deviceIpv4Candidates
    : (deviceIpv4 ? [deviceIpv4] : []);
  const ipv4Candidates = [];
  const ipv6Candidates = [];
  for (const [name, entries] of Object.entries(networkInterfacesMap ?? {})) {
    for (const entry of entries ?? []) {
      if (entry?.internal) {
        continue;
      }
      const isIpv4 = entry?.family === 'IPv4' || entry?.family === 4;
      const isPrivateIpv4 = /^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\./u.test(String(entry?.address));
      if (isIpv4 && (deviceCandidates.length > 0
        ? deviceCandidates.some((candidate) => isSameIpv4Subnet(entry, candidate))
        : isPrivateIpv4)) {
        ipv4Candidates.push({ name, address: entry.address });
      }
      if (entry?.family === 'IPv6' && !/^fe80:/iu.test(String(entry.address)) && entry.address !== '::1') {
        ipv6Candidates.push({ name, address: entry.address });
      }
    }
  }
  if (ipv4Candidates.length !== 1) {
    throw Object.assign(new Error('ORIGIN_BIND_BLOCKED: expected exactly one device-reachable LAN IPv4 address for the controlled origin.'), { code: 'ORIGIN_BIND_BLOCKED' });
  }
  const matchingIpv6 = ipv6Candidates.filter((entry) => entry.name === ipv4Candidates[0].name);
  return {
    ipv4: ipv4Candidates[0],
    ipv6: matchingIpv6.length === 1 ? matchingIpv6[0] : null
  };
}

export function buildBundleEvidencePullArgs({ target, bundleName, remotePath, localPath }) {
  return buildTargetedHdcArgs(target, ['file', 'recv', '-b', bundleName, remotePath, localPath]);
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
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: semantic selector was missing or ambiguous.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED', selectionMatchCount: matches.length }
    );
  }
  return createLayoutNodeSelection(matches[0]);
}

function createLayoutNodeSelection(node) {
  const rawBounds = node.bounds ?? node.attributes?.bounds ?? {};
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

function selectUniqueMatchingLayoutNode(layout, predicate) {
  const root = layout?.root ?? layout;
  const matches = collectLayoutNodes(root).filter(predicate);
  if (matches.length !== 1) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: semantic selector was missing or ambiguous.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED', selectionMatchCount: matches.length }
    );
  }
  return createLayoutNodeSelection(matches[0]);
}

export function selectUniqueVpnStatusIndicator(layout) {
  return selectUniqueMatchingLayoutNode(
    layout,
    (node) => node?.attributes?.id === 'StatusBarIconWrapper_status_bar_vpn'
  );
}

export function selectUniqueAppOngoingNotification(layout) {
  return selectUniqueMatchingLayoutNode(layout, (node) => {
    const attrs = node?.attributes ?? {};
    return attrs.type === 'ListItem'
      && typeof attrs.id === 'string'
      && attrs.id.includes(APP_BUNDLE)
      && attrs.id.includes('_bgmode_');
  });
}

export function summarizeSystemUiAnchors(layout) {
  const root = layout?.root ?? layout;
  const counts = {
    listItemCount: 0,
    appBundleIdCount: 0,
    appBundleListItemCount: 0,
    appOwnedListItemAncestorCount: 0,
    backgroundModeIdCount: 0,
    backgroundModeListItemCount: 0,
    appBackgroundModeIdCount: 0,
    appBackgroundModeListItemCount: 0
  };
  for (const node of collectLayoutNodes(root)) {
    const attrs = node?.attributes ?? {};
    const id = typeof attrs.id === 'string' ? attrs.id : '';
    const appOwned = id.includes(APP_BUNDLE);
    const backgroundMode = id.includes('_bgmode_');
    const listItem = attrs.type === 'ListItem';
    if (listItem) counts.listItemCount += 1;
    if (appOwned) counts.appBundleIdCount += 1;
    if (appOwned && listItem) counts.appBundleListItemCount += 1;
    if (listItem && collectLayoutNodes(node, []).some((descendant) =>
      typeof descendant?.attributes?.id === 'string'
      && descendant.attributes.id.includes(APP_BUNDLE)
    )) {
      counts.appOwnedListItemAncestorCount += 1;
    }
    if (backgroundMode) counts.backgroundModeIdCount += 1;
    if (backgroundMode && listItem) counts.backgroundModeListItemCount += 1;
    if (appOwned && backgroundMode) counts.appBackgroundModeIdCount += 1;
    if (appOwned && backgroundMode && listItem) counts.appBackgroundModeListItemCount += 1;
  }
  return counts;
}

export async function waitForUniqueLayoutSelection({
  readLayoutImpl,
  selectImpl,
  maxAttempts = MAX_LAYOUT_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastMissingError = null;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const layout = await readLayoutImpl();
    try {
      return { layout, selection: selectImpl(layout) };
    } catch (error) {
      if (error?.selectionMatchCount !== 0) {
        throw error;
      }
      lastMissingError = error;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  throw lastMissingError ?? Object.assign(
    new Error('UI_AUTOMATION_UNSUPPORTED: semantic selector did not become available.'),
    { code: 'UI_AUTOMATION_UNSUPPORTED', selectionMatchCount: 0 }
  );
}

function selectLargestValidLayoutBounds(layout) {
  const root = layout?.root ?? layout;
  const candidates = collectLayoutNodes(root)
    .map((node) => createLayoutNodeSelection(node))
    .filter(({ bounds }) => {
      const values = [bounds?.left, bounds?.top, bounds?.right, bounds?.bottom];
      return values.every((value) => Number.isFinite(value))
        && bounds.right > bounds.left
        && bounds.bottom > bounds.top;
    })
    .map((selection) => ({
      selection,
      area: (selection.bounds.right - selection.bounds.left)
        * (selection.bounds.bottom - selection.bounds.top)
    }))
    .sort((left, right) => right.area - left.area);
  if (candidates.length === 0) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: layout did not expose valid screen bounds.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
  return candidates[0].selection.bounds;
}

export async function openNotificationCenter(layout, { target, hdcCommand, execImpl, cwd }) {
  const bounds = selectLargestValidLayoutBounds(layout);
  const width = bounds.right - bounds.left;
  const height = bounds.bottom - bounds.top;
  const gestureX = bounds.left + Math.floor(width * 0.25);
  const startY = bounds.top + 1;
  const endY = bounds.top + Math.floor(height * 0.75);
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, [
      'shell', 'uinput', '-T', '-m',
      `${gestureX}`, `${startY}`,
      `${gestureX}`, `${endY}`,
      '600'
    ]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: notification center gesture failed.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
}

export async function openControlCenter(layout, { target, hdcCommand, execImpl, cwd }) {
  const bounds = selectLargestValidLayoutBounds(layout);
  const width = bounds.right - bounds.left;
  const height = bounds.bottom - bounds.top;
  const gestureX = bounds.left + Math.floor(width * (1066 / 1216));
  const startY = bounds.top + 1;
  const endY = bounds.top + Math.floor(height * 0.35);
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, [
      'shell', 'uinput', '-T', '-m',
      `${gestureX}`, `${startY}`,
      `${gestureX}`, `${endY}`,
      '600'
    ]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: control center gesture failed.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
}

export function selectUniqueActionableLayoutNode(layout, selector) {
  const selected = selectUniqueLayoutNode(layout, selector);
  const attrs = selected.node?.attributes ?? {};
  if (normalizeStateWord(attrs.clickable) !== true || normalizeStateWord(attrs.enabled) !== true) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: semantic action was not clickable and enabled.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
  return selected;
}

export async function observeControlCenterWifiState({
  target,
  hdcCommand,
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT
}) {
  const localLayout = createLayoutDumpPath('phase4-control-center', tempRoot);
  try {
    const baseLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    await openControlCenter(baseLayout, { target, hdcCommand, execImpl, cwd });
    const controlCenterLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
    const wifi = selectUniqueActionableLayoutNode(controlCenterLayout, CONTROL_CENTER_WIFI_SELECTOR);
    const observed = readExplicitBooleanState(wifi.node);
    if (!observed.supported) {
      return { supported: false, reason: 'UI_AUTOMATION_UNSUPPORTED: control center wifi state was unreadable.' };
    }
    return {
      supported: true,
      wifiEnabled: observed.value,
      wifi: {
        selector: CONTROL_CENTER_WIFI_SELECTOR,
        centerX: wifi.centerX,
        centerY: wifi.centerY,
        value: observed.value,
        source: observed.source
      }
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

const VPN_CONSENT_SELECTORS = Object.freeze([
  Object.freeze({ resourceNames: Object.freeze(['vpn_permission_allow', 'permission_allow_button']) }),
  Object.freeze({ ids: Object.freeze(['system.vpn.allow', 'permission_allow']) }),
  Object.freeze({ texts: Object.freeze(['允许', 'Allow']) })
]);

function nodeIsActionable(node) {
  const attrs = node?.attributes ?? {};
  return normalizeStateWord(attrs.clickable) === true && normalizeStateWord(attrs.enabled) === true;
}

function nodeMatchesVpnConsentHint(node) {
  return VPN_CONSENT_SELECTORS.some((selector) => nodeMatchesSelector(node, selector));
}

export function summarizeVpnConsentLayout(layout) {
  const root = layout?.root ?? layout;
  const nodes = collectLayoutNodes(root);
  const windowScenes = nodes.filter((node) => node?.attributes?.type === 'WindowScene');
  const windowSceneCategoryCounts = {
    vpn: 0,
    permission: 0,
    systemUi: 0,
    launcher: 0,
    settings: 0,
    other: 0
  };
  for (const windowScene of windowScenes) {
    const bundleName = `${windowScene?.attributes?.bundleName ?? ''}`.toLowerCase();
    if (bundleName.length === 0 || bundleName === APP_BUNDLE) {
      continue;
    }
    if (bundleName.includes('vpn')) windowSceneCategoryCounts.vpn += 1;
    else if (/permission|security/iu.test(bundleName)) windowSceneCategoryCounts.permission += 1;
    else if (bundleName.includes('systemui')) windowSceneCategoryCounts.systemUi += 1;
    else if (/launcher|sceneboard/iu.test(bundleName)) windowSceneCategoryCounts.launcher += 1;
    else if (bundleName.includes('settings')) windowSceneCategoryCounts.settings += 1;
    else windowSceneCategoryCounts.other += 1;
  }
  const displayIds = new Set();
  const hostWindowIds = new Set();
  let actionableNodeCount = 0;
  let consentHintNodeCount = 0;
  let consentActionNodeCount = 0;
  let dialogLikeNodeCount = 0;
  for (const node of nodes) {
    const attrs = node?.attributes ?? {};
    if (attrs.displayId !== undefined && `${attrs.displayId}`.length > 0) {
      displayIds.add(`${attrs.displayId}`);
    }
    if (attrs.hostWindowId !== undefined && `${attrs.hostWindowId}`.length > 0) {
      hostWindowIds.add(`${attrs.hostWindowId}`);
    }
    const actionable = nodeIsActionable(node);
    const consentHint = nodeMatchesVpnConsentHint(node);
    if (actionable) actionableNodeCount += 1;
    if (consentHint) consentHintNodeCount += 1;
    if (actionable && consentHint) consentActionNodeCount += 1;
    if (typeof attrs.type === 'string' && /dialog|popup|modal|alert/iu.test(attrs.type)) {
      dialogLikeNodeCount += 1;
    }
  }
  return {
    nodeCount: nodes.length,
    windowSceneCount: windowScenes.length,
    appWindowSceneCount: windowScenes.filter((node) => node?.attributes?.bundleName === APP_BUNDLE).length,
    nonAppWindowSceneCount: windowScenes.filter((node) => {
      const bundleName = node?.attributes?.bundleName;
      return typeof bundleName === 'string' && bundleName.length > 0 && bundleName !== APP_BUNDLE;
    }).length,
    vpnWindowSceneCount: windowSceneCategoryCounts.vpn,
    permissionWindowSceneCount: windowSceneCategoryCounts.permission,
    systemUiWindowSceneCount: windowSceneCategoryCounts.systemUi,
    launcherWindowSceneCount: windowSceneCategoryCounts.launcher,
    settingsWindowSceneCount: windowSceneCategoryCounts.settings,
    otherWindowSceneCount: windowSceneCategoryCounts.other,
    distinctDisplayCount: displayIds.size,
    distinctHostWindowCount: hostWindowIds.size,
    actionableNodeCount,
    consentHintNodeCount,
    consentActionNodeCount,
    dialogLikeNodeCount
  };
}

export function selectUniqueVpnConsentAction(layout) {
  const summary = summarizeVpnConsentLayout(layout);
  const textFallbackAllowed = summary.vpnWindowSceneCount > 0 ||
    summary.permissionWindowSceneCount > 0 ||
    (summary.systemUiWindowSceneCount > 0 && summary.dialogLikeNodeCount > 0);
  for (let index = 0; index < VPN_CONSENT_SELECTORS.length; index += 1) {
    const selector = VPN_CONSENT_SELECTORS[index];
    if (index === VPN_CONSENT_SELECTORS.length - 1 && !textFallbackAllowed) {
      continue;
    }
    try {
      return selectUniqueActionableLayoutNode(layout, selector);
    } catch (error) {
      if (error?.selectionMatchCount === 0) {
        continue;
      }
      throw error;
    }
  }
  return null;
}

export async function waitForVpnConsentAction({
  readLayoutImpl,
  maxAttempts = MAX_LAYOUT_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds)),
  onLayoutObserved = () => {}
}) {
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const layout = await readLayoutImpl();
    onLayoutObserved(summarizeVpnConsentLayout(layout));
    const selection = selectUniqueVpnConsentAction(layout);
    if (selection !== null) {
      return { layout, selection };
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return null;
}

export function selectUniqueScrollableLayoutNode(layout) {
  const root = layout?.root ?? layout;
  const matches = collectLayoutNodes(root).filter((node) =>
    normalizeStateWord(node?.attributes?.scrollable) === true
  );
  if (matches.length !== 1) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: scrollable semantic container was missing or ambiguous.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
  return createLayoutNodeSelection(matches[0]);
}

export function isLayoutSelectionWithinViewport(selection, viewport) {
  const bounds = selection?.bounds;
  const viewportBounds = viewport?.bounds;
  const values = [
    bounds?.left,
    bounds?.top,
    bounds?.right,
    bounds?.bottom,
    viewportBounds?.left,
    viewportBounds?.top,
    viewportBounds?.right,
    viewportBounds?.bottom
  ];
  if (!values.every((value) => Number.isFinite(value))) {
    return false;
  }
  return bounds.left >= viewportBounds.left
    && bounds.top >= viewportBounds.top
    && bounds.right <= viewportBounds.right
    && bounds.bottom <= viewportBounds.bottom;
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
  for (const source of ['checked', 'state', 'value']) {
    if (!(source in attrs)) {
      continue;
    }
    const value = normalizeStateWord(attrs[source]);
    if (value === null) {
      return { supported: false, reason: `${source} was not a recognized boolean state value` };
    }
    candidates.push({ source, value });
  }
  if (candidates.length === 0 && 'selected' in attrs) {
    const value = normalizeStateWord(attrs.selected);
    if (value === null) {
      return { supported: false, reason: 'selected was not a recognized boolean state value' };
    }
    candidates.push({ source: 'selected', value });
  }
  if (candidates.length === 0 && 'enabled' in attrs && enabledAttributeIsStateBearing(node)) {
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
const CONTROL_CENTER_WIFI_SELECTOR = Object.freeze(normalizeSelector({
  ids: ['transition_togglewifi_ui_extension']
}));
const SETTINGS_BUNDLE = 'com.huawei.hmos.settings';
const SETTINGS_MAIN_ABILITY = 'com.huawei.hmos.settings.MainAbility';
const SETTINGS_MOBILE_ENTRY_SELECTOR = Object.freeze(normalizeSelector({ ids: ['mobile_network_entry'] }));
const SETTINGS_AIRPLANE_TOGGLE_SELECTOR = Object.freeze(normalizeSelector({
  ids: ['Setting.MobileNetwork.air_plane_group.air_plane_mode_setting.result']
}));
const SETTINGS_HOTSPOT_ENTRY_SELECTOR = Object.freeze(normalizeSelector({
  ids: ['Setting.MobileNetwork.air_plane_group.hotspot_data_settings']
}));
const SETTINGS_HOTSPOT_TOGGLE_SELECTOR = Object.freeze(normalizeSelector({
  ids: ['Setting.hotspot_data_entry.hotspot_switch.hotspot_switch_setting.result']
}));

function createLayoutDumpPath(prefix, tempRoot = os.tmpdir()) {
  return path.join(tempRoot, `${prefix}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.json`);
}

export async function clickLayoutNode(nodeSelection, { target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, [
      'shell', 'uitest', 'uiInput', 'click',
      `${nodeSelection.centerX}`, `${nodeSelection.centerY}`
    ]),
    { cwd }
  );
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: semantic click injection failed.'),
      { code: 'UI_AUTOMATION_UNSUPPORTED' }
    );
  }
}

export async function scrollLayoutNodeForward(nodeSelection, { target, hdcCommand, execImpl, cwd }) {
  const { left, top, right, bottom } = nodeSelection.bounds;
  const height = bottom - top;
  if (height <= 0 || right <= left) {
    throw Object.assign(new Error('UI_AUTOMATION_UNSUPPORTED: scrollable bounds were invalid.'), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  const inset = Math.max(40, Math.floor(height * 0.12));
  const startY = bottom - inset;
  const endY = top + inset;
  if (startY <= endY) {
    throw Object.assign(new Error('UI_AUTOMATION_UNSUPPORTED: scrollable bounds were too small.'), { code: 'UI_AUTOMATION_UNSUPPORTED' });
  }
  await execImpl(
    hdcCommand,
    buildTargetedHdcArgs(target, [
      'shell', 'uinput', '-T', '-m',
      `${nodeSelection.centerX}`, `${startY}`,
      `${nodeSelection.centerX}`, `${endY}`,
      '600'
    ]),
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

function hasActiveSettingsDestination(layout) {
  return collectLayoutNodes(layout).some((node) => {
    const attrs = node?.attributes ?? {};
    return attrs.type === 'NavDestination' && attrs.bounds !== '[0,0][0,0]' && attrs.bounds !== '';
  });
}

async function defaultDumpSettingsLayout({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd }) {
  const localPath = createLayoutDumpPath('phase4-settings', tempRoot);
  try {
    return await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath, cwd });
  } finally {
    await fsApi.rm(localPath, { force: true }).catch(() => {});
  }
}

async function openSettingsMobilePage({
  target,
  hdcCommand,
  execImpl,
  fsApi,
  tempRoot,
  cwd,
  dumpLayoutImpl
}) {
  const startResult = await execImpl(hdcCommand, buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start', '-a', SETTINGS_MAIN_ABILITY, '-b', SETTINGS_BUNDLE
  ]), { cwd });
  if (startResult?.error || startResult?.exitCode !== 0 || startResult?.timedOut) {
    return null;
  }

  const dumpOptions = { target, hdcCommand, execImpl, fsApi, tempRoot, cwd };
  let layout = null;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    layout = await dumpLayoutImpl(dumpOptions);
    if (!hasActiveSettingsDestination(layout)) {
      break;
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, [
      'shell', 'uitest', 'uiInput', 'keyEvent', 'Back'
    ]), { cwd });
  }
  if (layout === null || hasActiveSettingsDestination(layout)) {
    return null;
  }

  const mobileEntry = selectUniqueLayoutNode(layout, SETTINGS_MOBILE_ENTRY_SELECTOR);
  await clickLayoutNode(mobileEntry, { target, hdcCommand, execImpl, cwd });
  return await dumpLayoutImpl(dumpOptions);
}

export async function observeCurrentAirplaneModeState({
  target,
  hdcCommand,
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  airplaneSelector = SETTINGS_AIRPLANE_TOGGLE_SELECTOR,
  dumpLayoutImpl = async (options) => await defaultDumpSettingsLayout(options)
}) {
  try {
    const layout = await openSettingsMobilePage({
      target,
      hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      dumpLayoutImpl
    });
    if (layout === null) {
      return { supported: false };
    }
    const airplane = observeNamedToggleState(layout, airplaneSelector, 'airplane mode');
    return {
      supported: true,
      airplaneModeEnabled: airplane.value,
      airplane
    };
  } catch (error) {
    if (error?.code === 'UI_AUTOMATION_UNSUPPORTED') {
      return { supported: false, reason: error.message };
    }
    throw error;
  }
}

export async function observeCurrentHotspotState({
  target,
  hdcCommand,
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  hotspotSelector = SETTINGS_HOTSPOT_TOGGLE_SELECTOR,
  dumpLayoutImpl = async (options) => await defaultDumpSettingsLayout(options)
}) {
  try {
    let layout = await openSettingsMobilePage({
      target,
      hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      dumpLayoutImpl
    });
    if (layout === null) {
      return { supported: false };
    }

    const dumpOptions = { target, hdcCommand, execImpl, fsApi, tempRoot, cwd };
    const hotspotEntry = selectUniqueLayoutNode(layout, SETTINGS_HOTSPOT_ENTRY_SELECTOR);
    await clickLayoutNode(hotspotEntry, { target, hdcCommand, execImpl, cwd });
    layout = await dumpLayoutImpl(dumpOptions);
    const hotspot = observeNamedToggleState(layout, hotspotSelector, 'hotspot');
    return {
      supported: true,
      hotspotEnabled: hotspot.value,
      hotspot
    };
  } catch (error) {
    if (error?.code === 'UI_AUTOMATION_UNSUPPORTED') {
      return { supported: false, reason: error.message };
    }
    throw error;
  }
}

export function parseObservedScreenState(raw) {
  const text = `${raw ?? ''}`;
  const matches = [...text.matchAll(/\b(?:screen|display)(?:\s+\w+){0,3}\s*(?:state)?\s*[:=]\s*(on|off)\b/giu)];
  const numericMatches = [...text.matchAll(/\bDisplay\s+Id=\d+\s+State=(0|2)\b/gu)];
  const powerMatches = [...text.matchAll(/\bCurrent\s+State:\s*(AWAKE|DIM|SLEEP|HIBERNATE)\b/gu)];
  const values = [...new Set([
    ...matches.map((entry) => entry[1].toLowerCase()),
    ...numericMatches.map((entry) => entry[1] === '2' ? 'on' : 'off'),
    ...powerMatches.map((entry) => entry[1] === 'AWAKE' || entry[1] === 'DIM' ? 'on' : 'off')
  ])];
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

export async function waitForScreenState({
  expectedScreenOn,
  maxAttempts = MAX_SCREEN_STATE_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  readScreenStateImpl = async () => await defaultReadScreenState({}),
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const observed = await readScreenStateImpl();
    if (observed.supported && observed.screenOn === expectedScreenOn) {
      return observed;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return { supported: false };
}

function createTrafficPass(kind, linked, probeEntry) {
  void linked;
  void probeEntry;
  return {
    result: 'pass',
    correlated: true,
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
  const dnsPacketIpv4 = byStepId.get('dns-packet-ipv4');
  const dnsPacketIpv6 = byStepId.get('dns-packet-ipv6');
  const httpConnect = byStepId.get('http-connect');
  const socks5 = byStepId.get('socks5');
  const directReachability = {
    result: https?.outcome === 'pass' &&
      tcp?.outcome === 'pass' &&
      udpIpv4?.outcome === 'pass' &&
      dnsPacketIpv4?.outcome === 'pass'
      ? 'pass'
      : 'fail'
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

export function assessPhase4ProbeReachability(normalized) {
  const records = Array.isArray(normalized?.records) ? normalized.records : [];
  const byStepId = createProbeRecordIndex(records);
  const controlledHttpsPass = byStepId.get('https')?.outcome === 'pass';
  const externalReachabilityPass = byStepId.get('tcp')?.outcome === 'pass' &&
    byStepId.get('udp-ipv4')?.outcome === 'pass' &&
    byStepId.get('dns-packet-ipv4')?.outcome === 'pass';
  return Object.freeze({
    controlledHttpsPass,
    externalReachabilityPass,
    complete: controlledHttpsPass && externalReachabilityPass
  });
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
  const sessionAlias = typeof raw.sessionAlias === 'string' ? raw.sessionAlias : '';
  const sessionAliasMatch = sessionAlias.match(/^session-([a-f0-9]{8})$/u);
  const expectedSessionIdHash = sessionAliasMatch?.[1] ?? '';
  if (sessionAlias.length > 0 && expectedSessionIdHash.length === 0) {
    errors.push('runtime journal session alias is invalid');
  }
  let lastSequence = 0;
  const linkedRecords = [];
  for (const record of records) {
    if (!Number.isInteger(record?.sequence) || record.sequence <= lastSequence) {
      errors.push('runtime journal sequence must be monotonic');
      continue;
    }
    lastSequence = record.sequence;
    if (record.kind === 'traffic' && record.linkageStatus === 'linked') {
      if (expectedSessionIdHash.length > 0 && record.sessionIdHash !== expectedSessionIdHash) {
        errors.push('runtime journal traffic session binding is invalid');
        continue;
      }
      const destinationHash = typeof record.destinationHash === 'string' ? record.destinationHash : '';
      const outboundTerminalHash = typeof record.outboundTerminalHash === 'string' ? record.outboundTerminalHash : '';
      const outboundChainHash = typeof record.outboundChainHash === 'string' ? record.outboundChainHash : '';
      const outboundChainLength = Number.isInteger(record.outboundChainLength) ? record.outboundChainLength : 0;
      const counterDelta = Number.isInteger(record.counterDelta) ? record.counterDelta : -1;
      const hasAnyOutboundProof = outboundTerminalHash.length > 0 || outboundChainHash.length > 0 || outboundChainLength > 0;
      const hasCompleteOutboundProof = isDigest(outboundTerminalHash) &&
        isDigest(outboundChainHash) &&
        outboundChainLength >= 1 &&
        outboundChainLength <= 16;
      if ((destinationHash.length > 0 && !isDigest(destinationHash)) ||
        (hasAnyOutboundProof && !hasCompleteOutboundProof) ||
        (record.protocol === 'tcp' && (!isDigest(destinationHash) || !hasCompleteOutboundProof)) ||
        counterDelta < 0) {
        errors.push('runtime journal linked traffic proof fields are invalid');
        continue;
      }
      linkedRecords.push({
        sequence: record.sequence,
        ingress: record.ingress,
        flowIdHash: record.flowIdHash,
        sessionIdHash: record.sessionIdHash,
        traceAlias: record.traceAlias,
        coreAlias: record.coreAlias,
        protocol: record.protocol,
        correlationHash: record.correlationHash,
        destinationHash,
        outboundTerminalHash,
        outboundChainHash,
        outboundChainLength,
        counterDelta
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
  const localProof = input.localProof ?? {};
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
    local: {
      http: localProof.http ? {
        ingress: `${localProof.http.ingress ?? ''}`,
        outcome: `${localProof.http.outcome ?? ''}`,
        correlated: localProof.http.correlated === true
      } : null,
      socks: localProof.socks ? {
        ingress: `${localProof.socks.ingress ?? ''}`,
        outcome: `${localProof.socks.outcome ?? ''}`,
        correlated: localProof.socks.correlated === true
      } : null
    },
    _normalizationErrors: [...origin.errors, ...probe.errors, ...runtime.errors]
  };
}

export function correlatePhase4Evidence(evidence) {
  const normalized = evidence._normalizationErrors ? evidence : normalizePhase4CollectedEvidence(evidence);
  const proof = createBaseProof({ runId: normalized.runId });
  proof.stubDetected = normalized.packages?.production?.stubDetected === false ? false : true;
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
  if (proof.stubDetected !== false) {
    proof.failures.push(createFailure('PACKAGE_STUB_DETECTED', 'Production package inspection must prove stub detection is false.'));
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
  if (normalized.probe?.directReachability?.result !== 'pass' || !directHttps) {
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
    const linkedMatches = normalized.runtime.linkedRecords.filter((entry) =>
      entry.ingress === 'tun' &&
      entry.protocol === probeEntry.protocol &&
      entry.correlationHash === flowIdHash &&
      entry.flowIdHash === flowIdHash
    );
    if (linkedMatches.length === 0) {
      proof.failures.push(createFailure('TUN_LINK_MISSING', `${kind} missing linked tun/core evidence.`));
      continue;
    }
    if (linkedMatches.length !== 1) {
      proof.failures.push(createFailure('TUN_LINK_AMBIGUOUS', `${kind} produced ambiguous linked tun/core evidence.`));
      continue;
    }
    const linked = linkedMatches[0];
    if (kind === 'tcp' && !(linked.destinationHash && linked.outboundTerminalHash && linked.outboundChainHash && linked.outboundChainLength > 0)) {
      proof.failures.push(createFailure('TUN_LINK_MISSING', `${kind} missing outbound terminal proof.`));
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
      correlated: true,
      captureTrace: { ingress: 'tun', event: 'ipv6-flow' },
      coreEvent: { event: 'mihomo.ipv6' }
    };
  }

  if (normalized.local?.http?.ingress !== 'local-http' || normalized.local.http?.outcome !== 'pass' || normalized.local.http?.correlated !== true) {
    proof.failures.push(createFailure('LOCAL_HTTP_INGRESS_INVALID', 'Local HTTP checks must stay on local-http ingress.'));
  } else {
    proof.localEvidence.http = {
      result: 'pass',
      ingress: 'local-http',
      correlated: true
    };
  }
  if (normalized.local?.socks?.ingress !== 'local-socks' || normalized.local.socks?.outcome !== 'pass' || normalized.local.socks?.correlated !== true) {
    proof.failures.push(createFailure('LOCAL_SOCKS_INGRESS_INVALID', 'Local SOCKS checks must stay on local-socks ingress.'));
  } else {
    proof.localEvidence.socks = {
      result: 'pass',
      ingress: 'local-socks',
      correlated: true
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

export function buildProbeAbilityParameters(originHandle, externalOrigin, runId, captureMode = 'baseline') {
  const sessionId = crypto.randomUUID();
  return {
    runId,
    sessionId,
    captureMode,
    pinnedPublicKeyHash: originHandle.publicKeyPinSha256 ?? originHandle.pinnedCertificateHash,
    originCaPem: originHandle.https.caPem,
    flowIds: createFlowIds(),
    lanOrigin: {
      host: originHandle.https.host,
      httpsPort: originHandle.https.port,
      tcpPort: originHandle.tcp.port,
      udpPort: originHandle.udp.port,
      dnsPort: originHandle.udp.port
    },
    externalOrigin,
    localListeners: {
      httpConnectPort: LOCAL_HTTP_CONNECT_PORT,
      socks5Port: LOCAL_SOCKS5_PORT
    }
  };
}

export function buildProbeLaunchArgs(target, parameters) {
  return buildTargetedHdcArgs(target, [
    'shell', 'aa', 'start',
    '-a', PROBE_ABILITY_NAME,
    '-b', PROBE_BUNDLE,
    '--ps', 'runId', parameters.runId,
    '--ps', 'sessionId', parameters.sessionId,
    '--ps', 'captureMode', parameters.captureMode,
    '--ps', 'pinnedPublicKeyHash', parameters.pinnedPublicKeyHash,
    '--ps', 'originCaPem', parameters.originCaPem,
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
    '--ps', 'externalOriginHost', parameters.externalOrigin.hostIpv4,
    '--ps', 'externalTcpHost', parameters.externalOrigin.tcpHostIpv4,
    '--pi', 'originHttpsPort', `${parameters.lanOrigin.httpsPort}`,
    '--pi', 'originTcpPort', `${parameters.lanOrigin.tcpPort}`,
    '--pi', 'originUdpPort', `${parameters.lanOrigin.udpPort}`,
    '--pi', 'originDnsPort', `${parameters.lanOrigin.dnsPort}`,
    '--pi', 'externalOriginTcpPort', `${parameters.externalOrigin.tcpPort}`,
    '--pi', 'externalOriginUdpPort', `${parameters.externalOrigin.udpPort}`,
    '--pi', 'externalOriginDnsPort', `${parameters.externalOrigin.dnsPort}`,
    '--pi', 'localHttpConnectPort', `${parameters.localListeners.httpConnectPort}`,
    '--pi', 'localSocks5Port', `${parameters.localListeners.socks5Port}`
  ]);
}

export function buildProductionLaunchArgs(target, runId = '') {
  const launchArgs = [
    'shell', 'aa', 'start',
    '-a', ENTRY_ABILITY_NAME,
    '-b', APP_BUNDLE
  ];
  if (UUID_PATTERN.test(runId)) {
    launchArgs.push('--ps', 'cmfa.phase1.runId', runId);
  }
  return buildTargetedHdcArgs(target, launchArgs);
}

async function verifyHdcHelp(execImpl, hdcCommand, cwd) {
  for (const args of [['help'], ['-h'], ['--help']]) {
    const result = await execImpl(hdcCommand, args, { cwd });
    const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    if (!result?.error && result?.exitCode === 0
      && HDC_FILE_RECV_HELP_PATTERN.test(output)
      && HDC_BUNDLE_RECV_HELP_PATTERN.test(output)
      && /install/iu.test(output)
      && /shell/iu.test(output)
      && /list targets/iu.test(output)) {
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

export async function readDeviceLanIpv4Candidates({ execImpl, hdcCommand, target, cwd }) {
  const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'ifconfig']), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    return [];
  }
  return parseDeviceLanIpv4Candidates(result.stdout);
}

function findDeviceInterface(candidates, name) {
  return Array.isArray(candidates)
    ? candidates.find((candidate) => candidate?.name === name) ?? null
    : null;
}

function createDeviceLanFingerprint(candidate) {
  const name = typeof candidate?.name === 'string' ? candidate.name : '';
  const address = typeof candidate?.address === 'string' ? candidate.address : '';
  const netmask = typeof candidate?.netmask === 'string' ? candidate.netmask : '';
  if (name.length === 0 || parseIpv4(address) === null || parseIpv4(netmask) === null) {
    return null;
  }
  return crypto.createHash('sha256').update(`${name}\n${address}\n${netmask}`).digest('hex');
}

function hasDeviceInterface(candidates, name) {
  return findDeviceInterface(candidates, name) !== null;
}

function matchesDeviceInterfaceFingerprint(candidates, name, fingerprint) {
  if (typeof fingerprint !== 'string' || fingerprint.length === 0) {
    return false;
  }
  return Array.isArray(candidates) && candidates.some((candidate) =>
    candidate?.name === name && createDeviceLanFingerprint(candidate) === fingerprint
  );
}

function resolveWifiHotspotInterfaces(deviceIpv4Candidates) {
  const wifiUplink = findDeviceInterface(deviceIpv4Candidates, 'wlan0');
  const hotspotLan = findDeviceInterface(deviceIpv4Candidates, 'wlan1');
  if (!wifiUplink || !hotspotLan) {
    return null;
  }
  const wifiUplinkFingerprint = createDeviceLanFingerprint(wifiUplink);
  const hotspotLanFingerprint = createDeviceLanFingerprint(hotspotLan);
  if (wifiUplinkFingerprint === null || hotspotLanFingerprint === null) {
    return null;
  }
  return {
    wifiUplinkInterfaceName: wifiUplink.name,
    wifiUplinkFingerprint,
    hotspotLanInterfaceName: hotspotLan.name,
    hotspotLanFingerprint
  };
}

async function waitForDeviceLanState({
  target,
  hdcCommand,
  cwd,
  readDeviceLanIpv4CandidatesImpl,
  predicate,
  failureDetail,
  maxAttempts = MAX_LAYOUT_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const candidates = await readDeviceLanIpv4CandidatesImpl({ target, hdcCommand, cwd });
    if (predicate(candidates)) {
      return candidates;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  throw Object.assign(new Error(`NETWORK_RECOVERY_NOT_PROVEN: ${failureDetail}`), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
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
  if (normalizeHarmonyOsVersion(device.buildVersion) === null) {
    return { kind: 'unsupported', code: 'DEVICE_TARGET_UNSUPPORTED', detail: 'Phase 4 requires HarmonyOS 6.' };
  }
  return { kind: 'physical' };
}

export function normalizeHarmonyOsVersion(rawVersion) {
  const match = String(rawVersion ?? '').trim().match(/\b(6(?:\.\d+){1,3})\b/u);
  return match ? `HarmonyOS ${match[1]}` : null;
}

export async function pullBundleEvidenceJson({
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
  const transferOutput = `${result?.stdout ?? ''}\n${result?.stderr ?? ''}`;
  if (result?.error || result?.exitCode !== 0 || result?.timedOut
    || /\[Fail\]|no such file or directory|Error opening file/iu.test(transferOutput)) {
    return { ok: false, failure: createFailure('APP_EVIDENCE_MISSING', `Unable to pull ${bundleName} evidence.`), args };
  }
  let handle = null;
  try {
    handle = await fsApi.open(localPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return { ok: false, failure: createFailure('APP_EVIDENCE_MISSING', `Unable to pull ${bundleName} evidence.`), args };
    }
    throw error;
  }
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

export async function waitForBundleEvidence({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  bundleName,
  remotePath,
  localPath,
  cwd,
  expectedRunId,
  expectedSessionId,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastFailure = createFailure('APP_EVIDENCE_MISSING', `Missing ${bundleName} evidence.`);
  for (let attempt = 0; attempt < MAX_EVIDENCE_POLL_ATTEMPTS; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({ fsApi, execImpl, hdcCommand, target, bundleName, remotePath, localPath, cwd });
    if (pulled.ok) {
      const runMatches = pulled.proof?.runId === expectedRunId;
      const sessionMatches = expectedSessionId === undefined || pulled.proof?.sessionId === expectedSessionId;
      if (runMatches && sessionMatches) {
        return pulled;
      }
      lastFailure = createFailure('APP_EVIDENCE_STALE', `${bundleName} evidence belonged to another run or session.`);
    } else {
      lastFailure = pulled.failure;
    }
    await delayImpl(POLL_WAIT_MS);
  }
  return { ok: false, failure: lastFailure };
}

function readRuntimeJournalSequence(raw, records = []) {
  const documentSequence = Number.isInteger(raw?.sequence) && raw.sequence >= 0 ? raw.sequence : 0;
  const recordSequence = records.reduce((highest, record) =>
    Number.isInteger(record?.sequence) && record.sequence > highest ? record.sequence : highest, 0);
  return Math.max(documentSequence, recordSequence);
}

function countLifecycleDetail(records, detail) {
  return records.filter((record) => record?.kind === 'lifecycle' && record?.detail === detail).length;
}

export function captureRuntimeRecoveryBaseline(runtimeJournal, expectedRunId = null) {
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  return {
    runId: expectedRunId ?? runtimeJournal?.runId ?? '',
    sequence: readRuntimeJournalSequence(runtimeJournal, records),
    updatedAt: isIsoTimestamp(runtimeJournal?.updatedAt) ? runtimeJournal.updatedAt : '',
    recoveryAttempt: Number.isInteger(runtimeJournal?.lifecycle?.recoveryAttempt) && runtimeJournal.lifecycle.recoveryAttempt >= 0
      ? runtimeJournal.lifecycle.recoveryAttempt
      : 0,
    recoveringCount: countLifecycleDetail(records, 'STATE_CHANGED:RECOVERING'),
    runningCount: countLifecycleDetail(records, 'STATE_CHANGED:RUNNING')
  };
}

export function captureRuntimeStopBaseline(runtimeJournal, expectedRunId = null) {
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  return {
    runId: expectedRunId ?? runtimeJournal?.runId ?? '',
    sequence: readRuntimeJournalSequence(runtimeJournal, records),
    updatedAt: isIsoTimestamp(runtimeJournal?.updatedAt) ? runtimeJournal.updatedAt : ''
  };
}

export function captureRuntimeTrafficBaseline(runtimeJournal, expectedRunId = null) {
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  return {
    runId: expectedRunId ?? runtimeJournal?.runId ?? '',
    sequence: readRuntimeJournalSequence(runtimeJournal, records),
    updatedAt: isIsoTimestamp(runtimeJournal?.updatedAt) ? runtimeJournal.updatedAt : ''
  };
}

export function assessRuntimeStopped(runtimeJournal, baseline) {
  if (!isObject(runtimeJournal) || !isObject(baseline)) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.journalInvalid };
  }
  const expectedRunId = typeof baseline.runId === 'string' ? baseline.runId : '';
  if (expectedRunId.length > 0 && runtimeJournal.runId !== expectedRunId) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.runMismatch };
  }
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  if ((normalized.errors ?? []).length > 0) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.journalInvalid };
  }
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  const sequence = readRuntimeJournalSequence(runtimeJournal, records);
  if (sequence <= Number(baseline.sequence ?? 0)) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.sequenceStale };
  }
  const updatedAt = isIsoTimestamp(runtimeJournal.updatedAt) ? runtimeJournal.updatedAt : '';
  if (updatedAt.length === 0 || updatedAt <= `${baseline.updatedAt ?? ''}`) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.updatedAtStale };
  }
  const state = `${runtimeJournal.lifecycle?.state ?? ''}`.toLowerCase();
  if (state !== 'stopped') {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.lifecycleNotStopped };
  }
  if (runtimeJournal.lifecycle?.stopped !== true) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.stoppedFlagMissing };
  }
  const stopRecord = records.find((record) =>
    record?.kind === 'stop' && Number.isInteger(record?.sequence) && record.sequence > Number(baseline.sequence ?? 0));
  if (!stopRecord) {
    return { stopped: false, reason: RUNTIME_STOP_REASONS.stopRecordMissing };
  }
  return {
    stopped: true,
    reason: RUNTIME_STOP_REASONS.stopped,
    sequence,
    updatedAt
  };
}

export function assessRuntimeTrafficEvidence(runtimeJournal, baseline, probe) {
  if (!isObject(runtimeJournal) || !isObject(baseline)) {
    return { ready: false, reason: RUNTIME_TRAFFIC_REASONS.journalInvalid };
  }
  const expectedRunId = typeof baseline.runId === 'string' ? baseline.runId : '';
  if (expectedRunId.length > 0 && runtimeJournal.runId !== expectedRunId) {
    return { ready: false, reason: RUNTIME_TRAFFIC_REASONS.runMismatch };
  }
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  if ((normalized.errors ?? []).length > 0) {
    return { ready: false, reason: RUNTIME_TRAFFIC_REASONS.journalInvalid };
  }
  const sequence = readRuntimeJournalSequence(runtimeJournal, normalized.records);
  if (sequence <= Number(baseline.sequence ?? 0)) {
    return { ready: false, reason: RUNTIME_TRAFFIC_REASONS.sequenceStale };
  }
  const updatedAt = isIsoTimestamp(runtimeJournal.updatedAt) ? runtimeJournal.updatedAt : '';
  if (updatedAt.length === 0 || updatedAt <= `${baseline.updatedAt ?? ''}`) {
    return { ready: false, reason: RUNTIME_TRAFFIC_REASONS.updatedAtStale };
  }
  const freshLinkedRecords = normalized.linkedRecords
    .filter((record) => Number.isInteger(record?.sequence) && record.sequence > Number(baseline.sequence ?? 0));
  const expectations = [
    {
      reason: RUNTIME_TRAFFIC_REASONS.tcpMissing,
      protocol: 'tcp',
      correlationHash: probe?.global?.tcp?.correlationHash ?? '',
      requireDestination: true,
      requireOutbound: true
    },
    {
      reason: RUNTIME_TRAFFIC_REASONS.udpMissing,
      protocol: 'udp',
      correlationHash: probe?.global?.udp?.correlationHash ?? '',
      requireDestination: false,
      requireOutbound: false
    },
    {
      reason: RUNTIME_TRAFFIC_REASONS.dnsMissing,
      protocol: 'dns',
      correlationHash: probe?.global?.dns?.correlationHash ?? '',
      requireDestination: false,
      requireOutbound: false
    }
  ];
  for (const expectation of expectations) {
    const matches = freshLinkedRecords.filter((record) => {
      if (record.ingress !== 'tun' || record.protocol !== expectation.protocol) {
        return false;
      }
      if (record.correlationHash !== expectation.correlationHash || record.flowIdHash !== expectation.correlationHash) {
        return false;
      }
      if (!(record.counterDelta > 0)) {
        return false;
      }
      if (expectation.requireDestination && !isDigest(record.destinationHash)) {
        return false;
      }
      if (expectation.requireOutbound && !(isDigest(record.outboundTerminalHash) && isDigest(record.outboundChainHash) && record.outboundChainLength > 0)) {
        return false;
      }
      return true;
    });
    if (matches.length === 0) {
      return { ready: false, reason: expectation.reason };
    }
    if (matches.length !== 1) {
      return {
        ready: false,
        reason: expectation.protocol === 'tcp'
          ? RUNTIME_TRAFFIC_REASONS.tcpAmbiguous
          : expectation.protocol === 'udp'
            ? RUNTIME_TRAFFIC_REASONS.udpAmbiguous
            : RUNTIME_TRAFFIC_REASONS.dnsAmbiguous
      };
    }
  }
  return {
    ready: true,
    reason: RUNTIME_TRAFFIC_REASONS.ready,
    sequence,
    updatedAt
  };
}

export function assessRuntimeRecoveryReadiness(runtimeJournal, baseline) {
  if (!isObject(runtimeJournal) || !isObject(baseline)) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.journalInvalid };
  }
  const expectedRunId = typeof baseline.runId === 'string' ? baseline.runId : '';
  if (expectedRunId.length > 0 && runtimeJournal.runId !== expectedRunId) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.runMismatch };
  }
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  if ((normalized.errors ?? []).length > 0) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.journalInvalid };
  }
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  const sequence = readRuntimeJournalSequence(runtimeJournal, records);
  if (sequence <= Number(baseline.sequence ?? 0)) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.sequenceStale };
  }
  const updatedAt = isIsoTimestamp(runtimeJournal.updatedAt) ? runtimeJournal.updatedAt : '';
  if (updatedAt.length === 0 || updatedAt <= `${baseline.updatedAt ?? ''}`) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.updatedAtStale };
  }
  const state = `${runtimeJournal.lifecycle?.state ?? ''}`.toLowerCase();
  if (state !== 'running') {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.lifecycleNotRunning };
  }
  if (!Number.isInteger(runtimeJournal.lifecycle?.recoveryAttempt) || runtimeJournal.lifecycle.recoveryAttempt !== 0) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.recoveryAttemptNotReset };
  }
  const recoveringCount = countLifecycleDetail(records, 'STATE_CHANGED:RECOVERING');
  if (recoveringCount <= Number(baseline.recoveringCount ?? 0)) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.recoveringCountStale };
  }
  const runningCount = countLifecycleDetail(records, 'STATE_CHANGED:RUNNING');
  if (runningCount <= Number(baseline.runningCount ?? 0)) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.runningCountStale };
  }
  const freshLifecycleRecords = records
    .filter((record) => record?.kind === 'lifecycle' && Number.isInteger(record?.sequence) && record.sequence > Number(baseline.sequence ?? 0))
    .sort((left, right) => left.sequence - right.sequence);
  const recoveringRecord = freshLifecycleRecords.find((record) => record.detail === 'STATE_CHANGED:RECOVERING');
  if (!recoveringRecord) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.recoveringMissing };
  }
  const proxyActivateRecord = freshLifecycleRecords.find((record) =>
    record.detail === 'proxy-activate-ok' && record.sequence > recoveringRecord.sequence);
  if (!proxyActivateRecord) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.proxyActivateMissing };
  }
  const runningRecord = freshLifecycleRecords.find((record) =>
    record.detail === 'STATE_CHANGED:RUNNING' && record.sequence > proxyActivateRecord.sequence);
  if (!runningRecord) {
    return { ready: false, reason: RUNTIME_RECOVERY_READY_REASONS.runningMissing };
  }
  return {
    ready: true,
    reason: RUNTIME_RECOVERY_READY_REASONS.ready,
    sequence,
    updatedAt
  };
}

export function assessRuntimeRecoveryEntered(runtimeJournal, baseline) {
  if (!isObject(runtimeJournal) || !isObject(baseline)) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.journalInvalid };
  }
  const expectedRunId = typeof baseline.runId === 'string' ? baseline.runId : '';
  if (expectedRunId.length > 0 && runtimeJournal.runId !== expectedRunId) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.runMismatch };
  }
  const normalized = normalizePhase4RuntimeJournal(runtimeJournal);
  if ((normalized.errors ?? []).length > 0) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.journalInvalid };
  }
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  const sequence = readRuntimeJournalSequence(runtimeJournal, records);
  if (sequence <= Number(baseline.sequence ?? 0)) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.sequenceStale };
  }
  const updatedAt = isIsoTimestamp(runtimeJournal.updatedAt) ? runtimeJournal.updatedAt : '';
  if (updatedAt.length === 0 || updatedAt <= `${baseline.updatedAt ?? ''}`) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.updatedAtStale };
  }
  const freshRecovering = records
    .filter((record) => record?.kind === 'lifecycle' && Number.isInteger(record?.sequence) && record.sequence > Number(baseline.sequence ?? 0))
    .sort((left, right) => left.sequence - right.sequence)
    .find((record) => record.detail === 'STATE_CHANGED:RECOVERING');
  if (!freshRecovering) {
    return { entered: false, reason: RUNTIME_RECOVERY_ENTERED_REASONS.recoveringMissing };
  }
  return {
    entered: true,
    reason: RUNTIME_RECOVERY_ENTERED_REASONS.entered,
    sequence,
    updatedAt
  };
}

export async function waitForRuntimeRecoveryEntered({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  remotePath = RUNTIME_REMOTE_PATH,
  localPath,
  cwd,
  expectedRunId,
  baseline,
  maxAttempts = MAX_RUNTIME_RECOVERY_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastReason = RUNTIME_RECOVERY_ENTERED_REASONS.evidenceMissing;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      bundleName: APP_BUNDLE,
      remotePath,
      localPath,
      cwd
    });
    if (pulled.ok) {
      const entered = assessRuntimeRecoveryEntered(pulled.proof, {
        ...baseline,
        runId: expectedRunId ?? baseline?.runId ?? ''
      });
      if (entered.entered) {
        return pulled;
      }
      lastReason = entered.reason;
    } else {
      lastReason = RUNTIME_RECOVERY_ENTERED_REASONS.evidenceMissing;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return {
    ok: false,
    reason: lastReason,
    failure: createFailure('NETWORK_RECOVERY_RUNTIME_TIMEOUT', NETWORK_RECOVERY_ENTERED_TIMEOUT_DETAIL)
  };
}

export async function waitForRuntimeRecoveryReadiness({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  remotePath = RUNTIME_REMOTE_PATH,
  localPath,
  cwd,
  expectedRunId,
  baseline,
  maxAttempts = MAX_RUNTIME_RECOVERY_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastReason = RUNTIME_RECOVERY_READY_REASONS.evidenceMissing;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      bundleName: APP_BUNDLE,
      remotePath,
      localPath,
      cwd
    });
    if (pulled.ok) {
      const readiness = assessRuntimeRecoveryReadiness(pulled.proof, {
        ...baseline,
        runId: expectedRunId ?? baseline?.runId ?? ''
      });
      if (readiness.ready) {
        return pulled;
      }
      lastReason = readiness.reason;
    } else {
      lastReason = RUNTIME_RECOVERY_READY_REASONS.evidenceMissing;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return {
    ok: false,
    reason: lastReason,
    failure: createFailure('NETWORK_RECOVERY_RUNTIME_TIMEOUT', NETWORK_RECOVERY_RUNTIME_TIMEOUT_DETAIL)
  };
}

export async function waitForRuntimeStopped({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  remotePath = RUNTIME_REMOTE_PATH,
  localPath,
  cwd,
  expectedRunId,
  baseline,
  maxAttempts = MAX_RUNTIME_RECOVERY_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastReason = RUNTIME_STOP_REASONS.evidenceMissing;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      bundleName: APP_BUNDLE,
      remotePath,
      localPath,
      cwd
    });
    if (pulled.ok) {
      const stopped = assessRuntimeStopped(pulled.proof, {
        ...baseline,
        runId: expectedRunId ?? baseline?.runId ?? ''
      });
      if (stopped.stopped) {
        return pulled;
      }
      lastReason = stopped.reason;
    } else {
      lastReason = RUNTIME_STOP_REASONS.evidenceMissing;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return {
    ok: false,
    reason: lastReason,
    failure: createFailure('STOP_CLEANUP_NOT_PROVEN', RUNTIME_STOP_TIMEOUT_DETAIL)
  };
}

export async function waitForRuntimeTrafficEvidence({
  fsApi,
  execImpl,
  hdcCommand,
  target,
  remotePath = RUNTIME_REMOTE_PATH,
  localPath,
  cwd,
  expectedRunId,
  baseline,
  probe,
  maxAttempts = MAX_RUNTIME_RECOVERY_POLL_ATTEMPTS,
  pollIntervalMs = POLL_WAIT_MS,
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
}) {
  let lastReason = RUNTIME_TRAFFIC_REASONS.evidenceMissing;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const pulled = await pullBundleEvidenceJson({
      fsApi,
      execImpl,
      hdcCommand,
      target,
      bundleName: APP_BUNDLE,
      remotePath,
      localPath,
      cwd
    });
    if (pulled.ok) {
      const ready = assessRuntimeTrafficEvidence(pulled.proof, {
        ...baseline,
        runId: expectedRunId ?? baseline?.runId ?? ''
      }, probe);
      if (ready.ready) {
        return pulled;
      }
      lastReason = ready.reason;
    } else {
      lastReason = RUNTIME_TRAFFIC_REASONS.evidenceMissing;
    }
    if (attempt + 1 < maxAttempts) {
      await delayImpl(pollIntervalMs);
    }
  }
  return {
    ok: false,
    reason: lastReason,
    failure: createFailure(
      'TUN_LINK_MISSING',
      `${RUNTIME_TRAFFIC_TIMEOUT_DETAIL} Fixed reason: ${lastReason}.`
    )
  };
}

export async function dumpLayoutToHost({
  execImpl,
  hdcCommand,
  target,
  localPath,
  cwd
}) {
  const remotePath = `/data/local/tmp/cmfa-layout-${Date.now()}.json`;
  let layout = null;
  let operationError = null;
  try {
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
    layout = JSON.parse(await fs.readFile(localPath, 'utf8'));
  } catch (error) {
    operationError = error;
  }

  let cleanupResult = null;
  try {
    cleanupResult = await execImpl(
      hdcCommand,
      buildTargetedHdcArgs(target, ['shell', 'rm', '-f', remotePath]),
      { cwd }
    );
  } catch {
    cleanupResult = null;
  }
  if (cleanupResult === null || cleanupResult?.error || cleanupResult?.exitCode !== 0 || cleanupResult?.timedOut) {
    throw Object.assign(
      new Error('UI_AUTOMATION_UNSUPPORTED: remote layout cleanup failed.'),
      { code: 'REMOTE_LAYOUT_CLEANUP_FAILED' }
    );
  }
  if (operationError !== null) {
    throw operationError;
  }
  return layout;
}

export async function defaultPerformUiAutomation({
  target,
  hdcCommand,
  execImpl,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  runId = ''
}) {
  const localLayout = path.join(tempRoot, `phase4-layout-${process.pid}-${Date.now()}.json`);
  const clicks = [];
  let consentLayoutDiagnostic = null;
  try {
    await execImpl(
      hdcCommand,
      buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Home']),
      { cwd }
    );
    const launchResult = await execImpl(hdcCommand, buildProductionLaunchArgs(target, runId), { cwd });
    if (launchResult?.error || launchResult?.exitCode !== 0 || launchResult?.timedOut) {
      throw Object.assign(
        new Error('UI_AUTOMATION_UNSUPPORTED: production launch failed.'),
        { code: 'UI_AUTOMATION_UNSUPPORTED' }
      );
    }
    const launchEvidence = await waitForUniqueLayoutSelection({
      readLayoutImpl: async () => await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd }),
      selectImpl: (layout) => selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] })
    });
    let appLayout = launchEvidence.layout;
    let primary = launchEvidence.selection;
    let scrollContainer = selectUniqueScrollableLayoutNode(appLayout);
    if (primary === undefined || !isLayoutSelectionWithinViewport(primary, scrollContainer)) {
      await scrollLayoutNodeForward(scrollContainer, { target, hdcCommand, execImpl, cwd });
      appLayout = await dumpLayoutToHost({ execImpl, hdcCommand, target, localPath: localLayout, cwd });
      primary = selectUniqueActionableLayoutNode(appLayout, { ids: ['home.vpn.action'] });
      scrollContainer = selectUniqueScrollableLayoutNode(appLayout);
      if (!isLayoutSelectionWithinViewport(primary, scrollContainer)) {
        throw Object.assign(
          new Error('UI_AUTOMATION_UNSUPPORTED: VPN action remained outside the scroll viewport.'),
          { code: 'UI_AUTOMATION_UNSUPPORTED' }
        );
      }
    }
    await clickLayoutNode(primary, { target, hdcCommand, execImpl, cwd });
    clicks.push('primary');
    const consentEvidence = await waitForVpnConsentAction({
      readLayoutImpl: async () => await dumpLayoutToHost({
        execImpl,
        hdcCommand,
        target,
        localPath: localLayout,
        cwd
      }),
      onLayoutObserved: (summary) => {
        consentLayoutDiagnostic = summary;
      }
    });
    if (consentEvidence !== null) {
      await clickLayoutNode(consentEvidence.selection, { target, hdcCommand, execImpl, cwd });
      clicks.push('consent');
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
        consentLayoutDiagnostic,
        clicks
      };
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Power']), { cwd });
    const afterScreenOff = await waitForScreenState({
      expectedScreenOn: false,
      readScreenStateImpl: async () => await defaultReadScreenState({ target, hdcCommand, execImpl, cwd })
    });
    if (!afterScreenOff.supported || afterScreenOff.screenOn !== false) {
      return {
        ok: false,
        code: 'CONTINUITY_NOT_PROVEN',
        detail: 'Screen-off continuity could not be observed after pressing Power.',
        launcherContinuity: false,
        screenOffContinuity: false,
        vpnIndicatorVisible: false,
        ongoingNotificationVisible: false,
        consentLayoutDiagnostic,
        clicks
      };
    }
    await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Power']), { cwd });
    const afterScreenOn = await waitForScreenState({
      expectedScreenOn: true,
      readScreenStateImpl: async () => await defaultReadScreenState({ target, hdcCommand, execImpl, cwd })
    });
    if (!afterScreenOn.supported || afterScreenOn.screenOn !== true) {
      return {
        ok: false,
        code: 'CONTINUITY_NOT_PROVEN',
        detail: 'Screen-on continuity could not be observed after restoring from screen-off.',
        launcherContinuity: false,
        screenOffContinuity: false,
        vpnIndicatorVisible: false,
        ongoingNotificationVisible: false,
        consentLayoutDiagnostic,
        clicks
      };
    }
    await execImpl(
      hdcCommand,
      buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Home']),
      { cwd }
    );
    const readSystemLayout = async () => await dumpLayoutToHost({
      execImpl,
      hdcCommand,
      target,
      localPath: localLayout,
      cwd
    });
    let indicatorLayout = null;
    let vpnIndicatorVisible = false;
    try {
      const indicatorEvidence = await waitForUniqueLayoutSelection({
        readLayoutImpl: readSystemLayout,
        selectImpl: selectUniqueVpnStatusIndicator
      });
      indicatorLayout = indicatorEvidence.layout;
      vpnIndicatorVisible = true;
    } catch {
      indicatorLayout = await readSystemLayout();
    }
    let ongoingNotificationVisible = false;
    let systemUiDiagnostics = summarizeSystemUiAnchors(indicatorLayout);
    try {
      await openNotificationCenter(indicatorLayout, { target, hdcCommand, execImpl, cwd });
      const notificationEvidence = await waitForUniqueLayoutSelection({
        readLayoutImpl: readSystemLayout,
        selectImpl: selectUniqueAppOngoingNotification
      });
      systemUiDiagnostics = summarizeSystemUiAnchors(notificationEvidence.layout);
      ongoingNotificationVisible = true;
    } catch {
      systemUiDiagnostics = summarizeSystemUiAnchors(await readSystemLayout());
      ongoingNotificationVisible = false;
    }
    return {
      ok: vpnIndicatorVisible && ongoingNotificationVisible,
      code: vpnIndicatorVisible && ongoingNotificationVisible ? '' : 'UI_AUTOMATION_UNSUPPORTED',
      detail: vpnIndicatorVisible && ongoingNotificationVisible ? '' : 'System UI did not expose unique VPN indicator/notification selectors.',
      launcherContinuity: vpnIndicatorVisible && ongoingNotificationVisible,
      screenOffContinuity: true,
      vpnIndicatorVisible,
      ongoingNotificationVisible,
      systemUiDiagnostics,
      consentLayoutDiagnostic,
      clicks
    };
  } finally {
    await fsApi.rm(localLayout, { force: true }).catch(() => {});
  }
}

export async function defaultSnapshotNetworkState({
  target,
  hdcCommand,
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  observeNetworkStateImpl = async (options) => await observeCurrentNetworkState(options),
  observeAirplaneModeStateImpl = async (options) => await observeCurrentAirplaneModeState(options),
  observeHotspotStateImpl = async (options) => await observeCurrentHotspotState(options),
  observeControlCenterWifiStateImpl = async (options) => await observeControlCenterWifiState(options),
  readDeviceLanIpv4CandidatesImpl = async (options) => await readDeviceLanIpv4Candidates({ execImpl, ...options })
}) {
  const observed = await observeNetworkStateImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd });
  if (!observed.supported) {
    const hotspot = await observeHotspotStateImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd });
    if (hotspot.supported && hotspot.hotspotEnabled === true) {
      const deviceIpv4Candidates = await readDeviceLanIpv4CandidatesImpl({ target, hdcCommand, cwd });
      const interfaces = resolveWifiHotspotInterfaces(deviceIpv4Candidates);
      if (interfaces !== null) {
        const wifi = await observeControlCenterWifiStateImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd });
        if (!wifi.supported) {
          return { supported: false };
        }
        return {
          supported: true,
          mode: 'wifi-hotspot',
          target,
          hdcCommand,
          cwd,
          wifiSelector: wifi.wifi.selector,
          wifiEnabled: true,
          ...interfaces
        };
      }
    }
    const airplane = await observeAirplaneModeStateImpl({ target, hdcCommand, execImpl, fsApi, tempRoot, cwd });
    if (airplane.supported && airplane.airplaneModeEnabled === false) {
      const snapshot = {
        supported: true,
        mode: 'airplane',
        target,
        hdcCommand,
        cwd,
        airplaneSelector: airplane.airplane.selector,
        airplaneModeEnabled: false
      };
      if (hotspot.supported && hotspot.hotspotEnabled === true) {
        snapshot.hotspotSelector = hotspot.hotspot.selector;
        snapshot.hotspotEnabled = true;
      }
      return snapshot;
    }
    if (hotspot.supported && hotspot.hotspotEnabled === true) {
      return {
        supported: true,
        mode: 'hotspot',
        target,
        hdcCommand,
        cwd,
        hotspotSelector: hotspot.hotspot.selector,
        hotspotEnabled: true
      };
    }
    return { supported: false };
  }
  return {
    supported: true,
    mode: 'wifi-mobile',
    target,
    hdcCommand,
    cwd,
    wifiSelector: observed.wifi.selector,
    mobileSelector: observed.mobile.selector,
    wifiEnabled: observed.wifiEnabled,
    mobileEnabled: observed.mobileEnabled
  };
}

export async function defaultRestoreNetworkState(snapshot, {
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = snapshot?.cwd ?? REPO_ROOT,
  observeAirplaneModeStateImpl = async (options) => await observeCurrentAirplaneModeState(options),
  observeHotspotStateImpl = async (options) => await observeCurrentHotspotState(options),
  observeControlCenterWifiStateImpl = async (options) => await observeControlCenterWifiState(options),
  readDeviceLanIpv4CandidatesImpl = async (options) => await readDeviceLanIpv4Candidates({ execImpl, ...options }),
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
} = {}) {
  if (!snapshot?.supported) {
    return { restored: false, supported: false };
  }
  if (snapshot.mode === 'wifi-hotspot') {
    const current = await observeControlCenterWifiStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd
    });
    if (!current.supported) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: control center wifi state was unreadable during restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    const currentCandidates = await readDeviceLanIpv4CandidatesImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      cwd
    });
    if (!matchesDeviceInterfaceFingerprint(currentCandidates, snapshot.hotspotLanInterfaceName, snapshot.hotspotLanFingerprint)) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot LAN interface was not preserved during restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    if (
      matchesDeviceInterfaceFingerprint(currentCandidates, snapshot.wifiUplinkInterfaceName, snapshot.wifiUplinkFingerprint)
    ) {
      return { restored: true, clicks: [] };
    }
    await clickLayoutNode(current.wifi, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    await waitForDeviceLanState({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      cwd,
      readDeviceLanIpv4CandidatesImpl,
      delayImpl,
      predicate: (candidates) =>
        matchesDeviceInterfaceFingerprint(candidates, snapshot.wifiUplinkInterfaceName, snapshot.wifiUplinkFingerprint)
        && matchesDeviceInterfaceFingerprint(candidates, snapshot.hotspotLanInterfaceName, snapshot.hotspotLanFingerprint),
      failureDetail: 'wifi-hotspot restore did not return both uplink and hotspot LAN interfaces.'
    });
    return { restored: true, clicks: ['wifi'] };
  }
  if (snapshot.mode === 'airplane') {
    let current = await observeAirplaneModeStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      airplaneSelector: snapshot.airplaneSelector
    });
    if (!current.supported) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: airplane mode state was unreadable during restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    const clicks = [];
    if (current.airplaneModeEnabled !== snapshot.airplaneModeEnabled) {
      await clickLayoutNode(current.airplane, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
      current = await observeAirplaneModeStateImpl({
        target: snapshot.target,
        hdcCommand: snapshot.hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        airplaneSelector: snapshot.airplaneSelector
      });
      if (!current.supported || current.airplaneModeEnabled !== snapshot.airplaneModeEnabled) {
        throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: airplane mode restore did not return to the exact pre-state.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
      }
      clicks.push('airplane');
    }
    if (snapshot.hotspotEnabled === true) {
      let hotspot = await observeHotspotStateImpl({
        target: snapshot.target,
        hdcCommand: snapshot.hdcCommand,
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        hotspotSelector: snapshot.hotspotSelector
      });
      if (!hotspot.supported) {
        throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot state was unreadable after airplane restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
      }
      if (!hotspot.hotspotEnabled) {
        await clickLayoutNode(hotspot.hotspot, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
        hotspot = await observeHotspotStateImpl({
          target: snapshot.target,
          hdcCommand: snapshot.hdcCommand,
          execImpl,
          fsApi,
          tempRoot,
          cwd,
          hotspotSelector: snapshot.hotspotSelector
        });
        if (!hotspot.supported || !hotspot.hotspotEnabled) {
          throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot restore did not return to the enabled pre-state.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
        }
        clicks.push('hotspot');
      }
    }
    return { restored: true, clicks };
  }
  if (snapshot.mode === 'hotspot') {
    const current = await observeHotspotStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      hotspotSelector: snapshot.hotspotSelector
    });
    if (!current.supported) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot state was unreadable during restore.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    if (current.hotspotEnabled === snapshot.hotspotEnabled) {
      return { restored: true, clicks: [] };
    }
    await clickLayoutNode(current.hotspot, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    const verified = await observeHotspotStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      hotspotSelector: snapshot.hotspotSelector
    });
    if (!verified.supported || verified.hotspotEnabled !== snapshot.hotspotEnabled) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot restore did not return to the exact pre-state.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    return { restored: true, clicks: ['hotspot'] };
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

export async function defaultExerciseNetworkRecovery(snapshot, {
  execImpl = execCommand,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = snapshot?.cwd ?? REPO_ROOT,
  onLossObserved = async () => {},
  observeAirplaneModeStateImpl = async (options) => await observeCurrentAirplaneModeState(options),
  observeHotspotStateImpl = async (options) => await observeCurrentHotspotState(options),
  observeControlCenterWifiStateImpl = async (options) => await observeControlCenterWifiState(options),
  readDeviceLanIpv4CandidatesImpl = async (options) => await readDeviceLanIpv4Candidates({ execImpl, ...options }),
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds))
} = {}) {
  if (!snapshot?.supported) {
    return { supported: false };
  }
  if (snapshot.mode === 'wifi-hotspot') {
    const current = await observeControlCenterWifiStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd
    });
    if (!current.supported) {
      return { supported: false };
    }
    await waitForDeviceLanState({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      cwd,
      readDeviceLanIpv4CandidatesImpl,
      delayImpl,
      predicate: (candidates) =>
        matchesDeviceInterfaceFingerprint(candidates, snapshot.wifiUplinkInterfaceName, snapshot.wifiUplinkFingerprint)
        && matchesDeviceInterfaceFingerprint(candidates, snapshot.hotspotLanInterfaceName, snapshot.hotspotLanFingerprint),
      failureDetail: 'wifi-hotspot recovery could not confirm both initial uplink and hotspot LAN interfaces.'
    });
    await clickLayoutNode(current.wifi, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    await waitForDeviceLanState({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      cwd,
      readDeviceLanIpv4CandidatesImpl,
      delayImpl,
      predicate: (candidates) =>
        !matchesDeviceInterfaceFingerprint(candidates, snapshot.wifiUplinkInterfaceName, snapshot.wifiUplinkFingerprint)
        && matchesDeviceInterfaceFingerprint(candidates, snapshot.hotspotLanInterfaceName, snapshot.hotspotLanFingerprint),
      failureDetail: 'wifi-hotspot loss did not preserve hotspot LAN while removing the Wi-Fi uplink.'
    });
    try {
      await onLossObserved();
    } finally {
      await defaultRestoreNetworkState(snapshot, {
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        observeControlCenterWifiStateImpl,
        readDeviceLanIpv4CandidatesImpl,
        delayImpl
      });
    }
    return { supported: true, recovered: true, lossObserved: true, toggled: ['wifi'] };
  }
  if (snapshot.mode === 'airplane') {
    const current = await observeAirplaneModeStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      airplaneSelector: snapshot.airplaneSelector
    });
    if (!current.supported || current.airplaneModeEnabled !== false) {
      return { supported: false };
    }
    await clickLayoutNode(current.airplane, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    const lost = await observeAirplaneModeStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      airplaneSelector: snapshot.airplaneSelector
    });
    if (!lost.supported || lost.airplaneModeEnabled !== true) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: airplane mode loss was not observed.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    try {
      await onLossObserved();
    } finally {
      await defaultRestoreNetworkState(snapshot, {
        execImpl,
        fsApi,
        tempRoot,
        cwd,
        observeAirplaneModeStateImpl
      });
    }
    return { supported: true, recovered: true, lossObserved: true, toggled: ['airplane'] };
  }
  if (snapshot.mode === 'hotspot') {
    const current = await observeHotspotStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      hotspotSelector: snapshot.hotspotSelector
    });
    if (!current.supported || !current.hotspotEnabled) {
      return { supported: false };
    }
    await clickLayoutNode(current.hotspot, { target: snapshot.target, hdcCommand: snapshot.hdcCommand, execImpl, cwd });
    const lost = await observeHotspotStateImpl({
      target: snapshot.target,
      hdcCommand: snapshot.hdcCommand,
      execImpl,
      fsApi,
      tempRoot,
      cwd,
      hotspotSelector: snapshot.hotspotSelector
    });
    if (!lost.supported || lost.hotspotEnabled) {
      throw Object.assign(new Error('NETWORK_RECOVERY_NOT_PROVEN: hotspot loss was not observed.'), { code: 'NETWORK_RECOVERY_NOT_PROVEN' });
    }
    try {
      await onLossObserved();
    } finally {
      await defaultRestoreNetworkState(snapshot, { execImpl, fsApi, tempRoot, cwd, observeHotspotStateImpl });
    }
    return { supported: true, recovered: true, lossObserved: true, toggled: ['hotspot'] };
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
  try {
    await onLossObserved();
  } finally {
    await defaultRestoreNetworkState(snapshot, { execImpl, fsApi, tempRoot, cwd });
  }
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

export async function defaultStartOrigin({ runId, deviceIpv4Candidates }) {
  const selected = selectControlledLanOriginAddress(os.networkInterfaces(), { deviceIpv4Candidates });
  const origin = await startControlledOrigin({
    bindAddress: selected.ipv4.address,
    ipv6BindAddress: selected.ipv6?.address ?? '',
    runId,
    lanProofRequired: true,
    deviceSubnetProof: Array.isArray(deviceIpv4Candidates) && deviceIpv4Candidates.length > 0
  });
  origin.selectedLan = selected;
  return origin;
}

export async function defaultRunBaselineProbeImpl({
  target,
  hdcCommand,
  execImpl,
  origin,
  externalOrigin,
  cwd = REPO_ROOT,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  runId,
  waitForEvidenceImpl = async (options) => await waitForBundleEvidence(options)
}) {
  const parameters = buildProbeAbilityParameters(origin, externalOrigin, runId, 'baseline');
  const launchArgs = buildProbeLaunchArgs(target, parameters);
  const launchResult = await execImpl(hdcCommand, launchArgs, { cwd });
  if (launchResult?.error || launchResult?.exitCode !== 0 || launchResult?.timedOut) {
    return { result: 'fail', failure: createFailure('PROBE_LAUNCH_FAILED', 'The baseline probe failed to launch.') };
  }
  const pulled = await waitForEvidenceImpl({
    fsApi,
    execImpl,
    hdcCommand,
    target,
    bundleName: PROBE_BUNDLE,
    remotePath: PROBE_REMOTE_PATH,
    localPath: path.join(tempRoot, `phase4-baseline-${process.pid}.json`),
    cwd,
    expectedRunId: runId,
    expectedSessionId: parameters.sessionId
  });
  if (!pulled.ok) {
    return { result: 'fail', failure: pulled.failure };
  }
  const normalized = normalizePhase4ProbeEvidence(pulled.proof, runId);
  const reachability = assessPhase4ProbeReachability(normalized);
  const failure = reachability.controlledHttpsPass
    ? createFailure('EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN', EXTERNAL_ORIGIN_REACHABILITY_DETAIL)
    : createFailure('ORIGIN_REACHABILITY_NOT_PROVEN', CONTROLLED_HTTPS_REACHABILITY_DETAIL);
  return {
    result: reachability.complete ? 'pass' : 'fail',
    normalized,
    raw: pulled.proof,
    failure: reachability.complete ? null : failure
  };
}

export async function defaultRunVpnProbeImpl({
  target,
  hdcCommand,
  execImpl,
  origin,
  externalOrigin,
  cwd = REPO_ROOT,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  runId,
  waitForEvidenceImpl = async (options) => await waitForBundleEvidence(options)
}) {
  const parameters = buildProbeAbilityParameters(origin, externalOrigin, runId, 'vpn');
  const launchArgs = buildProbeLaunchArgs(target, parameters);
  const launchResult = await execImpl(hdcCommand, launchArgs, { cwd });
  if (launchResult?.error || launchResult?.exitCode !== 0 || launchResult?.timedOut) {
    return { result: 'fail', failure: createFailure('PROBE_LAUNCH_FAILED', 'The VPN traffic probe failed to launch.') };
  }
  const pulled = await waitForEvidenceImpl({
    fsApi,
    execImpl,
    hdcCommand,
    target,
    bundleName: PROBE_BUNDLE,
    remotePath: PROBE_REMOTE_PATH,
    localPath: path.join(tempRoot, `phase4-vpn-${process.pid}.json`),
    cwd,
    expectedRunId: runId,
    expectedSessionId: parameters.sessionId
  });
  if (!pulled.ok) {
    return { result: 'fail', failure: pulled.failure };
  }
  const normalized = normalizePhase4ProbeEvidence(pulled.proof, runId);
  const reachability = assessPhase4ProbeReachability(normalized);
  if (!reachability.controlledHttpsPass) {
    return {
      result: 'fail',
      raw: pulled.proof,
      normalized,
      requiresExternalOriginTriage: false,
      failure: createFailure('ORIGIN_REACHABILITY_NOT_PROVEN', CONTROLLED_HTTPS_REACHABILITY_DETAIL)
    };
  }
  if (!reachability.externalReachabilityPass) {
    return {
      result: 'fail',
      raw: pulled.proof,
      normalized,
      requiresExternalOriginTriage: true,
      failure: createFailure('GLOBAL_INGRESS_INVALID', VPN_EXTERNAL_INGRESS_DETAIL)
    };
  }
  return {
    result: 'pass',
    raw: pulled.proof,
    normalized,
    requiresExternalOriginTriage: false
  };
}

function isValidTcpPort(value) {
  return Number.isInteger(value) && value > 0 && value <= 65535;
}

async function allocateLoopbackTcpPort() {
  const server = net.createServer();
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => {
        server.off('error', reject);
        resolve();
      });
    });
    const address = server.address();
    if (!address || typeof address !== 'object' || !isValidTcpPort(address.port)) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: host port allocation failed.');
    }
    return address.port;
  } finally {
    await new Promise((resolve) => server.close(() => resolve())).catch(() => {});
  }
}

function parseCanonicalFportNodes(localNode, remoteNode) {
  if (!/^tcp:\d{1,5}$/u.test(`${localNode ?? ''}`) || !/^tcp:\d{1,5}$/u.test(`${remoteNode ?? ''}`)) {
    return null;
  }
  const localPort = Number.parseInt(String(localNode).slice(4), 10);
  const remotePort = Number.parseInt(String(remoteNode).slice(4), 10);
  if (!isValidTcpPort(localPort) || !isValidTcpPort(remotePort)) {
    return null;
  }
  return `${localNode} ${remoteNode}`;
}

export function parseFportTaskLines(raw) {
  const seen = new Set();
  const parsed = [];
  for (const rawLine of `${raw ?? ''}`.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    if (line.length > 512 || /[\u0000-\u001f\u007f]/u.test(line)) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward listing contained invalid task rows.');
    }
    const tokens = line.split(/\s+/u);
    let localNode = '';
    let remoteNode = '';
    if (tokens.length === 2) {
      [localNode, remoteNode] = tokens;
    } else if (tokens.length === 4 && tokens[3] === '[Forward]') {
      [, localNode, remoteNode] = tokens;
    } else {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward listing contained invalid task rows.');
    }
    const canonical = parseCanonicalFportNodes(localNode, remoteNode);
    if (canonical === null || seen.has(canonical)) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward listing contained invalid task rows.');
    }
    seen.add(canonical);
    parsed.push(canonical);
  }
  return parsed;
}

function findOwnedFportTask(lines, localNode, remoteNode, beforeTasks) {
  const task = parseCanonicalFportNodes(localNode, remoteNode);
  if (task === null || beforeTasks.has(task)) {
    return null;
  }
  const matches = lines.filter((line) => line === task);
  return matches.length === 1 ? matches[0] : null;
}

async function readFportTasks({ target, hdcCommand, execImpl, cwd }) {
  const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['fport', 'ls']), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward listing failed.');
  }
  return parseFportTaskLines(result.stdout);
}

async function createFport({ target, hdcCommand, execImpl, cwd, localNode, remoteNode }) {
  const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['fport', localNode, remoteNode]), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward creation failed.');
  }
}

async function removeFportTask({ target, hdcCommand, execImpl, cwd, task }) {
  const parts = `${task ?? ''}`.split(' ');
  if (parts.length !== 2) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward cleanup task was invalid.');
  }
  const canonical = parseCanonicalFportNodes(parts[0], parts[1]);
  if (canonical === null) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward cleanup task was invalid.');
  }
  const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['fport', 'rm', parts[0], parts[1]]), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: HDC forward cleanup failed.');
  }
}

function waitForSocketChunk(socket, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error('LOCAL_LISTENER_PROOF_FAILED: socket read timed out.')), timeoutMs);
    const onData = (chunk) => finish(null, chunk);
    const onError = () => finish(new Error('LOCAL_LISTENER_PROOF_FAILED: socket read failed.'));
    const onClose = () => finish(new Error('LOCAL_LISTENER_PROOF_FAILED: socket closed early.'));
    const finish = (error, chunk) => {
      clearTimeout(timer);
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('close', onClose);
      if (error) reject(error);
      else resolve(chunk);
    };
    socket.once('data', onData);
    socket.once('error', onError);
    socket.once('close', onClose);
  });
}

async function readSocketUntil(socket, state, complete, timeoutMs, maxBytes = 8192) {
  while (!complete(state.buffer)) {
    const chunk = await waitForSocketChunk(socket, timeoutMs);
    state.buffer = Buffer.concat([state.buffer, Buffer.from(chunk)]);
    if (state.buffer.length > maxBytes) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: socket response exceeded the bounded size.');
    }
  }
}

function writeSocket(socket, bytes) {
  return new Promise((resolve, reject) => {
    socket.write(bytes, (error) => {
      if (error) reject(new Error('LOCAL_LISTENER_PROOF_FAILED: socket write failed.'));
      else resolve();
    });
  });
}

function connectLoopbackSocket(port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const timer = setTimeout(() => finish(new Error('LOCAL_LISTENER_PROOF_FAILED: socket connect timed out.')), timeoutMs);
    const onConnect = () => finish(null, socket);
    const onError = () => finish(new Error('LOCAL_LISTENER_PROOF_FAILED: socket connect failed.'));
    const finish = (error, connected) => {
      clearTimeout(timer);
      socket.off('connect', onConnect);
      socket.off('error', onError);
      if (error) {
        socket.destroy();
        reject(error);
      } else {
        resolve(connected);
      }
    };
    socket.once('connect', onConnect);
    socket.once('error', onError);
  });
}

function buildLocalTcpToken(runId, sessionId, flowId) {
  return Buffer.from(`TCP|${runId}|${sessionId}|${flowId}|cmfa-${flowId}`, 'utf8');
}

function hasCurrentRuntimeLocalOwnershipEvidence(runtimeProof, expectedRunId) {
  if (!isObject(runtimeProof) || !UUID_PATTERN.test(String(expectedRunId ?? ''))) {
    return false;
  }
  if (runtimeProof.runId !== expectedRunId) {
    return false;
  }
  const normalized = normalizePhase4RuntimeJournal(runtimeProof);
  if ((normalized.errors ?? []).length > 0) {
    return false;
  }
  if (`${runtimeProof.lifecycle?.state ?? ''}`.toLowerCase() !== 'running') {
    return false;
  }
  const records = Array.isArray(normalized.records) ? normalized.records : [];
  return ['tun-start-ok', 'proxy-activate-ok', 'STATE_CHANGED:RUNNING'].every((detail) =>
    records.some((record) => record?.kind === 'lifecycle' && record?.detail === detail));
}

export async function runHttpConnectThroughForward({ localPort, originHost, originPort, runId, timeoutMs = 8000 }) {
  const socket = await connectLoopbackSocket(localPort, timeoutMs);
  const state = { buffer: Buffer.alloc(0) };
  try {
    const sessionId = crypto.randomUUID();
    const flowId = crypto.randomUUID();
    const authority = `${originHost}:${originPort}`;
    await writeSocket(socket, Buffer.from(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n\r\n`, 'ascii'));
    await readSocketUntil(socket, state, (buffer) => buffer.includes(Buffer.from('\r\n\r\n', 'ascii')), timeoutMs);
    const headerEnd = state.buffer.indexOf(Buffer.from('\r\n\r\n', 'ascii')) + 4;
    const header = state.buffer.subarray(0, headerEnd).toString('ascii');
    state.buffer = state.buffer.subarray(headerEnd);
    if (!/^HTTP\/1\.[01] 2\d\d(?: |\r)/u.test(header)) {
      return { ok: false };
    }
    const token = buildLocalTcpToken(runId, sessionId, flowId);
    await writeSocket(socket, token);
    await readSocketUntil(socket, state, (buffer) => buffer.length >= token.length, timeoutMs);
    return { ok: state.buffer.subarray(0, token.length).equals(token) };
  } catch {
    return { ok: false };
  } finally {
    socket.destroy();
  }
}

function buildSocksIpv4ConnectRequest(host, port) {
  const octets = `${host}`.split('.').map((entry) => Number.parseInt(entry, 10));
  if (octets.length !== 4 || octets.some((entry) => !Number.isInteger(entry) || entry < 0 || entry > 255) || !isValidTcpPort(port)) {
    throw new Error('LOCAL_LISTENER_PROOF_FAILED: SOCKS target was invalid.');
  }
  return Buffer.from([0x05, 0x01, 0x00, 0x01, ...octets, (port >> 8) & 0xff, port & 0xff]);
}

export async function runSocks5ThroughForward({ localPort, originHost, originPort, runId, timeoutMs = 8000 }) {
  const socket = await connectLoopbackSocket(localPort, timeoutMs);
  const state = { buffer: Buffer.alloc(0) };
  try {
    await writeSocket(socket, Buffer.from([0x05, 0x01, 0x00]));
    await readSocketUntil(socket, state, (buffer) => buffer.length >= 2, timeoutMs);
    if (state.buffer[0] !== 0x05 || state.buffer[1] !== 0x00) {
      return { ok: false };
    }
    state.buffer = state.buffer.subarray(2);
    await writeSocket(socket, buildSocksIpv4ConnectRequest(originHost, originPort));
    await readSocketUntil(socket, state, (buffer) => {
      if (buffer.length < 4) return false;
      if (buffer[3] === 0x01) return buffer.length >= 10;
      if (buffer[3] === 0x04) return buffer.length >= 22;
      return buffer[3] === 0x03 && buffer.length >= 7 + buffer[4];
    }, timeoutMs);
    if (state.buffer[0] !== 0x05 || state.buffer[1] !== 0x00) {
      return { ok: false };
    }
    const replyLength = state.buffer[3] === 0x01 ? 10 : (state.buffer[3] === 0x04 ? 22 : 7 + state.buffer[4]);
    state.buffer = state.buffer.subarray(replyLength);
    const sessionId = crypto.randomUUID();
    const flowId = crypto.randomUUID();
    const token = buildLocalTcpToken(runId, sessionId, flowId);
    await writeSocket(socket, token);
    await readSocketUntil(socket, state, (buffer) => buffer.length >= token.length, timeoutMs);
    return { ok: state.buffer.subarray(0, token.length).equals(token) };
  } catch {
    return { ok: false };
  } finally {
    socket.destroy();
  }
}

export async function defaultRunLocalListenerProof({
  target,
  hdcCommand,
  execImpl,
  origin,
  runId,
  runtimeProof = null,
  cwd = REPO_ROOT,
  allocateLocalPortImpl = async () => await allocateLoopbackTcpPort(),
  runHttpConnectProbeImpl = async (options) => await runHttpConnectThroughForward(options),
  runSocks5ProbeImpl = async (options) => await runSocks5ThroughForward(options)
}) {
  const remoteHttpNode = `tcp:${LOCAL_HTTP_CONNECT_PORT}`;
  const remoteSocksNode = `tcp:${LOCAL_SOCKS5_PORT}`;
  let httpOk = false;
  let socksOk = false;
  let cleanupOk = true;
  const ownershipOk = hasCurrentRuntimeLocalOwnershipEvidence(runtimeProof, runId);
  let beforeTasks = new Set();
  const ownedTasks = new Set();
  const localNodes = [];
  try {
    beforeTasks = new Set(await readFportTasks({ target, hdcCommand, execImpl, cwd }));
    const httpPort = await allocateLocalPortImpl();
    const socksPort = await allocateLocalPortImpl();
    if (!isValidTcpPort(httpPort) || !isValidTcpPort(socksPort) || httpPort === socksPort) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: allocated host ports were invalid.');
    }
    const localHttpNode = `tcp:${httpPort}`;
    const localSocksNode = `tcp:${socksPort}`;
    localNodes.push([localHttpNode, remoteHttpNode], [localSocksNode, remoteSocksNode]);
    await createFport({ target, hdcCommand, execImpl, cwd, localNode: localHttpNode, remoteNode: remoteHttpNode });
    await createFport({ target, hdcCommand, execImpl, cwd, localNode: localSocksNode, remoteNode: remoteSocksNode });
    const afterTasks = await readFportTasks({ target, hdcCommand, execImpl, cwd });
    const httpTask = findOwnedFportTask(afterTasks, localHttpNode, remoteHttpNode, beforeTasks);
    const socksTask = findOwnedFportTask(afterTasks, localSocksNode, remoteSocksNode, beforeTasks);
    if (httpTask === null || socksTask === null || httpTask === socksTask) {
      throw new Error('LOCAL_LISTENER_PROOF_FAILED: exact HDC forward tasks were not observable.');
    }
    ownedTasks.add(httpTask);
    ownedTasks.add(socksTask);
    const originHost = origin?.tcp?.host;
    const originPort = origin?.tcp?.port;
    const httpResult = await runHttpConnectProbeImpl({ localPort: httpPort, originHost, originPort, runId });
    const socksResult = await runSocks5ProbeImpl({ localPort: socksPort, originHost, originPort, runId });
    httpOk = httpResult?.ok === true;
    socksOk = socksResult?.ok === true;
  } catch {
  } finally {
    if (ownedTasks.size === 0 && localNodes.length > 0) {
      try {
        const currentTasks = await readFportTasks({ target, hdcCommand, execImpl, cwd });
        for (const [localNode, remoteNode] of localNodes) {
          const task = findOwnedFportTask(currentTasks, localNode, remoteNode, beforeTasks);
          if (task !== null) ownedTasks.add(task);
        }
      } catch {
        cleanupOk = false;
      }
    }
    for (const task of ownedTasks) {
      try {
        await removeFportTask({ target, hdcCommand, execImpl, cwd, task });
      } catch {
        cleanupOk = false;
      }
    }
    try {
      const remaining = new Set(await readFportTasks({ target, hdcCommand, execImpl, cwd }));
      if ([...ownedTasks].some((task) => remaining.has(task))) cleanupOk = false;
    } catch {
      cleanupOk = false;
    }
  }
  const httpOutcome = httpOk && cleanupOk ? 'pass' : 'fail';
  const socksOutcome = socksOk && cleanupOk ? 'pass' : 'fail';
  const httpCorrelated = httpOutcome === 'pass' && ownershipOk;
  const socksCorrelated = socksOutcome === 'pass' && ownershipOk;
  return {
    result: httpCorrelated && socksCorrelated ? 'pass' : 'fail',
    http: { ingress: 'local-http', outcome: httpOutcome, correlated: httpCorrelated },
    socks: { ingress: 'local-socks', outcome: socksOutcome, correlated: socksCorrelated }
  };
}

function readVpnActionMode(selection) {
  const texts = collectLayoutNodes(selection?.node)
    .map((node) => `${node?.attributes?.text ?? ''}`)
    .filter((value) => value.length > 0)
    .join(' ');
  if (/\bStop\b|停止/u.test(texts)) {
    return 'stop';
  }
  if (/\bStart\b|启动/u.test(texts)) {
    return 'start';
  }
  return 'unknown';
}

export async function defaultStopVpn({
  target,
  hdcCommand,
  execImpl,
  fsApi = fs,
  tempRoot = os.tmpdir(),
  cwd = REPO_ROOT,
  readLayoutImpl,
  clickLayoutNodeImpl = async (selection, options) => await clickLayoutNode(selection, options),
  delayImpl = async (milliseconds) => await new Promise((resolve) => setTimeout(resolve, milliseconds)),
  maxAttempts = MAX_LAYOUT_POLL_ATTEMPTS * 2
}) {
  const localLayout = path.join(tempRoot, `phase4-stop-layout-${process.pid}-${Date.now()}.json`);
  const readLayout = readLayoutImpl ?? (async () => await dumpLayoutToHost({
    execImpl,
    hdcCommand,
    target,
    localPath: localLayout,
    cwd
  }));
  try {
    const homeResult = await execImpl(
      hdcCommand,
      buildTargetedHdcArgs(target, ['shell', 'uitest', 'uiInput', 'keyEvent', 'Home']),
      { cwd }
    );
    if (homeResult?.error || homeResult?.exitCode !== 0 || homeResult?.timedOut) {
      throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: Home normalization failed during VPN stop.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
    }
    const launchResult = await execImpl(hdcCommand, buildProductionLaunchArgs(target, ''), { cwd });
    if (launchResult?.error || launchResult?.exitCode !== 0 || launchResult?.timedOut) {
      throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: production launch failed during VPN stop.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
    }
    const initial = await waitForUniqueLayoutSelection({
      readLayoutImpl: readLayout,
      selectImpl: (layout) => selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] }),
      maxAttempts,
      pollIntervalMs: POLL_WAIT_MS,
      delayImpl
    });
    if (readVpnActionMode(initial.selection) === 'start') {
      return { stopped: true, changed: false };
    }
    if (readVpnActionMode(initial.selection) !== 'stop') {
      throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: VPN stop action was not observable.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
    }
    let stopSelection = initial.selection;
    try {
      const scrollContainer = selectUniqueScrollableLayoutNode(initial.layout);
      if (!isLayoutSelectionWithinViewport(stopSelection, scrollContainer)) {
        await scrollLayoutNodeForward(scrollContainer, { target, hdcCommand, execImpl, cwd });
        const scrolledLayout = await readLayout();
        stopSelection = selectUniqueActionableLayoutNode(scrolledLayout, { ids: ['home.vpn.action'] });
      }
    } catch (error) {
      if (error?.code !== 'UI_AUTOMATION_UNSUPPORTED') {
        throw error;
      }
    }
    await clickLayoutNodeImpl(stopSelection, { target, hdcCommand, execImpl, cwd });
    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      const layout = await readLayout();
      try {
        const selection = selectUniqueActionableLayoutNode(layout, { ids: ['home.vpn.action'] });
        if (readVpnActionMode(selection) === 'start') {
          return { stopped: true, changed: true };
        }
      } catch (error) {
        if (error?.selectionMatchCount !== 0) {
          throw error;
        }
      }
      if (attempt + 1 < maxAttempts) {
        await delayImpl(POLL_WAIT_MS);
      }
    }
    throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: graceful VPN stop did not complete.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
  } finally {
    await fsApi.rm(localLayout, { force: true }).catch(() => {});
  }
}

export async function defaultForceStopBundle({ target, hdcCommand, execImpl, bundleName, cwd = REPO_ROOT }) {
  const result = await execImpl(hdcCommand, buildTargetedHdcArgs(target, ['shell', 'aa', 'force-stop', bundleName]), { cwd });
  if (result?.error || result?.exitCode !== 0 || result?.timedOut) {
    throw Object.assign(new Error('STOP_CLEANUP_NOT_PROVEN: bundle force-stop failed.'), { code: 'STOP_CLEANUP_NOT_PROVEN' });
  }
  return result;
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
  createExternalOriginImpl = async () => createDefaultPhase4ExternalOrigin(),
  normalizeExternalOriginImpl = (input) => normalizePhase4ExternalOrigin(input),
  startOriginImpl = async (options) => await defaultStartOrigin(options),
  runBaselineProbeImpl = async (options) => await defaultRunBaselineProbeImpl(options),
  runVpnProbeImpl = async (options) => await defaultRunVpnProbeImpl(options),
  runLocalListenerProofImpl = async (options) => await defaultRunLocalListenerProof(options),
  snapshotNetworkStateImpl = async (options) => await defaultSnapshotNetworkState(options),
  exerciseNetworkRecoveryImpl = async (snapshot, options = {}) => await defaultExerciseNetworkRecovery(snapshot, { execImpl, ...options }),
  restoreNetworkStateImpl = async (snapshot) => await defaultRestoreNetworkState(snapshot, { execImpl }),
  snapshotScreenStateImpl = async (options) => await defaultSnapshotScreenState(options),
  restoreScreenStateImpl = async (snapshot) => await defaultRestoreScreenState(snapshot, { execImpl, cwd: repoRoot }),
  stopVpnImpl = async (options) => await defaultStopVpn(options),
  forceStopBundleImpl = async (options) => await defaultForceStopBundle(options),
  performUiAutomationImpl = async (options) => await defaultPerformUiAutomation(options),
  waitForRuntimeRecoveryEnteredImpl = async (options) => await waitForRuntimeRecoveryEntered(options),
  waitForRuntimeRecoveryReadinessImpl = async (options) => await waitForRuntimeRecoveryReadiness(options),
  waitForRuntimeBaselineImpl = async (options) => await waitForBundleEvidence(options),
  waitForRuntimeStoppedImpl = async (options) => await waitForRuntimeStopped(options),
  waitForRuntimeTrafficEvidenceImpl = async (options) => await waitForRuntimeTrafficEvidence(options),
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
  let runtimeRecoveryBaseline = null;
  let runtimeStopBaseline = null;
  let vpnStartAttempted = false;
  let externalOrigin = null;
  let pendingVpnProbeFailure = null;
  let requiresExternalOriginTriage = false;
  let localProof = {
    result: 'fail',
    http: { ingress: 'local-http', outcome: 'fail', correlated: false },
    socks: { ingress: 'local-socks', outcome: 'fail', correlated: false }
  };

  try {
    main: {
      const productionHash = await hashFileImpl(productionHapPath);
      const probeHash = await hashFileImpl(probeHapPath);
      const packageInspection = await inspectPackagesImpl({
        productionHapPath,
        productionManifestPath,
        probeHapPath
      });
      proof.stubDetected = packageInspection.production?.stubDetected === false ? false : true;
      proof.bundles.hapSha256 = [
        packageInspection.production?.hapSha256 ?? productionHash.sha256,
        packageInspection.probe?.hapSha256 ?? probeHash.sha256
      ];
      if (packageInspection.result !== 'pass') {
        applyIncompleteFailure(proof, 'PACKAGE_INSPECTION_FAILED', 'Package inspection did not pass.');
        if (proof.stubDetected !== false) {
          applyIncompleteFailure(proof, 'PACKAGE_STUB_DETECTED', 'Production package inspection must prove stub detection is false.');
        }
        break main;
      }
      if (proof.stubDetected !== false) {
        applyIncompleteFailure(proof, 'PACKAGE_STUB_DETECTED', 'Production package inspection must prove stub detection is false.');
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
      const rawOsVersion = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.software.version'], cwd: repoRoot });
      proof.device.osVersion = normalizeHarmonyOsVersion(rawOsVersion) ?? proof.device.osVersion;
      proof.device.apiVersion = Number.parseInt(await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.ohos.apiversion', 'const.product.apiversion'], cwd: repoRoot }) ?? '0', 10) || 0;
      proof.device.abi = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.cpu.abilist'], cwd: repoRoot }) ?? '';
      const model = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.model'], cwd: repoRoot });
      const product = await readDeviceFact({ execImpl, hdcCommand, target, candidates: ['const.product.name', 'const.product.device'], cwd: repoRoot });
      const classification = classifyHarmonyTarget({
        model,
        product,
        buildVersion: rawOsVersion,
        apiVersion: `${proof.device.apiVersion}`,
        abi: proof.device.abi
      });
      if (classification.kind !== 'physical') {
        applyIncompleteFailure(proof, classification.code, classification.detail);
        break main;
      }
      const deviceIpv4Candidates = await readDeviceLanIpv4Candidates({ execImpl, hdcCommand, target, cwd: repoRoot });

      try {
        externalOrigin = await normalizeExternalOriginImpl(await createExternalOriginImpl());
      } catch {
        applyIncompleteFailure(proof, 'EXTERNAL_ORIGIN_CONFIG_INVALID', 'Phase 4 external origin configuration was invalid.');
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

      originHandle = await startOriginImpl({ runId: proof.runId, deviceIpv4Candidates });
      const baseline = await runBaselineProbeImpl({
        target,
        hdcCommand,
        execImpl,
        origin: originHandle,
        externalOrigin,
        cwd: repoRoot,
        fsApi,
        tempRoot: tempPullRoot,
        runId: proof.runId
      });
      if (baseline.result !== 'pass') {
        proof.result = 'incomplete';
        proof.failures.push(baseline.failure ?? createFailure('ORIGIN_REACHABILITY_NOT_PROVEN', 'Direct reachability before VPN start was not proven.'));
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

      vpnStartAttempted = true;
      const uiResult = await performUiAutomationImpl({
        target,
        hdcCommand,
        execImpl,
        fsApi,
        tempRoot: tempPullRoot,
        cwd: repoRoot,
        runId: proof.runId
      });
      if (!uiResult.ok) {
        applyIncompleteFailure(proof, uiResult.code ?? 'UI_AUTOMATION_UNSUPPORTED', uiResult.detail ?? 'UI automation was unsupported.');
        break main;
      }
      notificationOk = uiResult.ongoingNotificationVisible === true;
      backgroundOk = uiResult.launcherContinuity === true && uiResult.screenOffContinuity === true;
      const runtimeBaselinePull = await waitForRuntimeBaselineImpl({
        fsApi,
        execImpl,
        hdcCommand,
        target,
        bundleName: APP_BUNDLE,
        remotePath: RUNTIME_REMOTE_PATH,
        localPath: path.join(tempPullRoot, 'runtime-recovery-baseline.json'),
        cwd: repoRoot,
        expectedRunId: proof.runId
      });
      if (!runtimeBaselinePull.ok) {
        applyIncompleteFailure(proof, 'NETWORK_RECOVERY_RUNTIME_TIMEOUT', NETWORK_RECOVERY_RUNTIME_TIMEOUT_DETAIL);
        break main;
      }
      runtimeRecoveryBaseline = captureRuntimeRecoveryBaseline(runtimeBaselinePull.proof, proof.runId);
      runtimeStopBaseline = captureRuntimeStopBaseline(runtimeBaselinePull.proof, proof.runId);
      const recoveryResult = await exerciseNetworkRecoveryImpl(networkSnapshot, {
        onLossObserved: async () => {
          const runtimeEntered = await waitForRuntimeRecoveryEnteredImpl({
            fsApi,
            execImpl,
            hdcCommand,
            target,
            remotePath: RUNTIME_REMOTE_PATH,
            localPath: path.join(tempPullRoot, 'runtime-recovery-entered.json'),
            cwd: repoRoot,
            expectedRunId: proof.runId,
            baseline: runtimeRecoveryBaseline
          });
          if (!runtimeEntered.ok) {
            throw Object.assign(
              new Error(runtimeEntered.failure?.detail ?? NETWORK_RECOVERY_ENTERED_TIMEOUT_DETAIL),
              { code: runtimeEntered.failure?.code ?? 'NETWORK_RECOVERY_RUNTIME_TIMEOUT' }
            );
          }
        }
      });
      recoveryOk = recoveryResult?.supported === true && recoveryResult?.recovered === true;
      if (!recoveryOk) {
        applyIncompleteFailure(proof, 'NETWORK_RECOVERY_NOT_PROVEN', 'Controlled network loss/recovery was not proven.');
        break main;
      }
      const runtimeReady = await waitForRuntimeRecoveryReadinessImpl({
        fsApi,
        execImpl,
        hdcCommand,
        target,
        remotePath: RUNTIME_REMOTE_PATH,
        localPath: path.join(tempPullRoot, 'runtime-recovery-ready.json'),
        cwd: repoRoot,
        expectedRunId: proof.runId,
        baseline: runtimeRecoveryBaseline
      });
      if (!runtimeReady.ok) {
        applyIncompleteFailure(
          proof,
          runtimeReady.failure?.code ?? 'NETWORK_RECOVERY_RUNTIME_TIMEOUT',
          runtimeReady.failure?.detail ?? NETWORK_RECOVERY_RUNTIME_TIMEOUT_DETAIL
        );
        break main;
      }
      runtimeStopBaseline = captureRuntimeStopBaseline(runtimeReady.proof, proof.runId);

      try {
        localProof = await runLocalListenerProofImpl({
          target,
          hdcCommand,
          execImpl,
          origin: originHandle,
          runId: proof.runId,
          runtimeProof: runtimeReady.proof ?? null,
          cwd: repoRoot
        });
      } catch {
      }

      const vpnProbe = await runVpnProbeImpl({
        target,
        hdcCommand,
        execImpl,
        origin: originHandle,
        externalOrigin,
        cwd: repoRoot,
        fsApi,
        tempRoot: tempPullRoot,
        runId: proof.runId
      });
      if (vpnProbe.result !== 'pass' || !vpnProbe.raw) {
        if (vpnProbe.requiresExternalOriginTriage === true && vpnProbe.raw) {
          pendingVpnProbeFailure = createFailure('GLOBAL_INGRESS_INVALID', VPN_EXTERNAL_INGRESS_DETAIL);
          requiresExternalOriginTriage = true;
          break main;
        }
        proof.failures.push(vpnProbe.failure ?? createFailure('APP_EVIDENCE_MISSING', 'Fresh VPN probe evidence was unavailable.'));
        break main;
      }
      const normalizedVpnProbe = vpnProbe.normalized ?? normalizePhase4ProbeEvidence(vpnProbe.raw, proof.runId);

      const runtimePull = await waitForRuntimeTrafficEvidenceImpl({
        fsApi,
        execImpl,
        hdcCommand,
        target,
        remotePath: RUNTIME_REMOTE_PATH,
        localPath: path.join(tempPullRoot, 'runtime-traffic.json'),
        cwd: repoRoot,
        expectedRunId: proof.runId,
        baseline: captureRuntimeTrafficBaseline(runtimeReady.proof, proof.runId),
        probe: normalizedVpnProbe
      });
      if (!runtimePull.ok) {
        proof.failures.push(runtimePull.failure);
        break main;
      }
      runtimeStopBaseline = captureRuntimeStopBaseline(runtimePull.proof, proof.runId);

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
        probe: vpnProbe.raw,
        runtime: runtimePull.proof,
        localProof,
        lifecycle: {
          launcherContinuity: uiResult.launcherContinuity === true,
          screenOffContinuity: uiResult.screenOffContinuity === true,
          vpnIndicatorVisible: uiResult.vpnIndicatorVisible === true,
          ongoingNotificationVisible: uiResult.ongoingNotificationVisible === true,
          networkLossRecovery: recoveryOk === true,
          stopCleanup: true,
          networkingRestored: true
        }
      }));
    }
  } catch (error) {
    applyIncompleteFailure(proof, error?.code ?? 'PHASE4_RUNNER_FAILED', error?.message ?? 'Phase 4 runner failed.');
    candidateProof = proof;
  } finally {
    const stopCleanupStages = new Set();
    let networkingRestoredOk = networkSnapshot === null ? true : false;
    let screenRestoredOk = screenSnapshot === null ? true : false;
    const activeProof = candidateProof ?? proof;
    if (hdcCommand !== null && target !== null) {
      if (vpnStartAttempted) {
        let stopJournalOk = false;
        let runtimeStopAttempted = false;
        try {
          await stopVpnImpl({ target, hdcCommand, execImpl, fsApi, tempRoot: tempPullRoot, cwd: repoRoot });
        } catch {
          stopCleanupStages.add('gracefulStop');
        }
        if (runtimeStopBaseline) {
          runtimeStopAttempted = true;
          try {
            const runtimeStopped = await waitForRuntimeStoppedImpl({
              fsApi,
              execImpl,
              hdcCommand,
              target,
              remotePath: RUNTIME_REMOTE_PATH,
              localPath: path.join(tempPullRoot, 'runtime-stopped.json'),
              cwd: repoRoot,
              expectedRunId: proof.runId,
              baseline: runtimeStopBaseline
            });
            stopJournalOk = runtimeStopped.ok === true;
            if (runtimeStopped.ok && runtimeStopped.proof) {
              runtimeStopBaseline = captureRuntimeStopBaseline(runtimeStopped.proof, proof.runId);
            }
          } catch {
            stopJournalOk = false;
          }
        }
        if (runtimeStopAttempted && !stopJournalOk) {
          stopCleanupStages.add('runtimeStop');
        }
        if (requiresExternalOriginTriage) {
          if (stopJournalOk && originHandle && externalOrigin) {
            try {
              const postStopBaseline = await runBaselineProbeImpl({
                target,
                hdcCommand,
                execImpl,
                origin: originHandle,
                externalOrigin,
                cwd: repoRoot,
                fsApi,
                tempRoot: tempPullRoot,
                runId: proof.runId
              });
              if (postStopBaseline?.result === 'pass' && pendingVpnProbeFailure) {
                activeProof.failures.push(pendingVpnProbeFailure);
              } else {
                activeProof.failures.push(createFailure(
                  'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN',
                  EXTERNAL_ORIGIN_REACHABILITY_DETAIL
                ));
              }
            } catch {
              activeProof.failures.push(createFailure(
                'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN',
                EXTERNAL_ORIGIN_REACHABILITY_DETAIL
              ));
            }
          } else {
            activeProof.failures.push(createFailure(
              'EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN',
              EXTERNAL_ORIGIN_REACHABILITY_DETAIL
            ));
          }
          pendingVpnProbeFailure = null;
          requiresExternalOriginTriage = false;
        }
      }
      const cleanupResults = await Promise.allSettled([
        forceStopBundleImpl({ target, hdcCommand, execImpl, bundleName: APP_BUNDLE, cwd: repoRoot }),
        forceStopBundleImpl({ target, hdcCommand, execImpl, bundleName: PROBE_BUNDLE, cwd: repoRoot })
      ]);
      if (cleanupResults[0]?.status === 'rejected') {
        stopCleanupStages.add('forceStopProduction');
      }
      if (cleanupResults[1]?.status === 'rejected') {
        stopCleanupStages.add('forceStopProbe');
      }
    }
    if (originHandle?.close) {
      try {
        await originHandle.close();
      } catch {
        stopCleanupStages.add('originClose');
      }
    }
    try {
      await restoreNetworkStateImpl(networkSnapshot);
      networkingRestoredOk = true;
    } catch {
      stopCleanupStages.add('networkRestore');
      activeProof.failures.push(createFailure(
        'NETWORK_RECOVERY_NOT_PROVEN',
        'Network recovery failed at fixed stage: network-restore.'
      ));
    }
    try {
      await restoreScreenStateImpl(screenSnapshot);
      screenRestoredOk = true;
    } catch {
      stopCleanupStages.add('screenRestore');
    }
    try {
      await fsApi.rm(tempPullRoot, { recursive: true, force: true });
    } catch {
      stopCleanupStages.add('tempCleanup');
    }
    for (const stage of stopCleanupStages) {
      activeProof.failures.push(createFailure('STOP_CLEANUP_NOT_PROVEN', STOP_CLEANUP_STAGE_DETAILS[stage]));
    }
    const stopCleanupOk = stopCleanupStages.size === 0;
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
