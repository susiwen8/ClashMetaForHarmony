import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.example.json');
const RUNNER_MODULE_PATH = new URL('../bin/run-phase4-device-proof.mjs', import.meta.url);

function digest(char) {
  return char.repeat(64);
}

function hashHex(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function shortHash(value) {
  let hashValue = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hashValue ^= value.charCodeAt(index);
    hashValue = Math.imul(hashValue, 16777619);
  }
  return (hashValue >>> 0).toString(16).padStart(8, '0');
}

function createDnsPacketHash(runId, flowId) {
  const label = `${shortHash(runId)}-${shortHash(flowId)}.invalid`;
  const header = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
  const bytes = [];
  for (const segment of label.split('.')) {
    bytes.push(segment.length);
    for (let index = 0; index < segment.length; index += 1) {
      bytes.push(segment.charCodeAt(index) & 0xff);
    }
  }
  bytes.push(0x00, 0x00, 0x01, 0x00, 0x01);
  return hashHex(Buffer.from(header.concat(bytes)));
}

function joinFragments(parts) {
  return parts.join('');
}

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isUuid(value) {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(value);
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value);
}

function isSha256(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
}

const sensitiveExtensions = ['p12', joinFragments(['p', 'fx']), 'pem', 'cer', 'p7b'];
const uriSchemePattern = /\b[a-z][a-z0-9+.-]*:\/\//iu;
const signingPathPattern = new RegExp(
  String.raw`(?:^|[\\/])[^\\/\s]+\.(?:${sensitiveExtensions.join('|')})$`,
  'iu'
);
const leakedUrlValue = joinFragments(['https', '://device.example.invalid/model']);
const leakedFileUrlValue = joinFragments(['file', ':///tmp/device-proof/local-evidence']);
const leakedSshUrlValue = joinFragments(['ssh', '://builder@example.invalid/device-proof']);
const leakedSigningPathValue = joinFragments(['/Us', 'ers/dev/', 'sign', 'ing/release.', sensitiveExtensions[0]]);
const leakedWindowsSigningPathValue = joinFragments(['C', ':', '\\', 'Us', 'ers', '\\', 'dev', '\\', 'certificate.', sensitiveExtensions[0]]);
const leakedWindowsForwardSlashSigningPathValue = joinFragments(['C', ':/', 'Us', 'ers/dev/', 'sign', 'ing/client.', sensitiveExtensions[0]]);
const leakedSecretKey = joinFragments(['secret', 'Token']);
const leakedSerialKey = joinFragments(['serial', 'Number']);
const REQUIRED_TRAFFIC_KINDS = ['tcp', 'udp', 'dns', 'ipv4'];
const TRAFFIC_EVENT_CONTRACT = {
  tcp: { capture: 'tcp-connect', core: 'mihomo.tcp' },
  udp: { capture: 'udp-associate', core: 'mihomo.udp' },
  dns: { capture: 'dns-query', core: 'mihomo.dns' },
  ipv4: { capture: 'ipv4-flow', core: 'mihomo.ipv4' },
  ipv6: { capture: 'ipv6-flow', core: 'mihomo.ipv6' }
};
const BUNDLE_HAP_HASH_ORDER = ['production', 'probe'];
const CORE_NATIVE_HASH_ORDER = ['addon', 'mihomo'];
const ALLOWED_TOP_LEVEL_KEYS = new Set([
  'schemaVersion',
  'phase',
  'result',
  'stubDetected',
  'runId',
  'outputPath',
  'timestamps',
  'device',
  'bundles',
  'core',
  'assertions',
  'traffic',
  'localEvidence',
  'lifecycle',
  'tun',
  'failures'
]);
const FORBIDDEN_IDENTIFIER_KEYS = new Set(['sessionId', 'traceId']);

function collectForbiddenShapeErrors(value, trail = 'proof', errors = []) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectForbiddenShapeErrors(entry, `${trail}[${index}]`, errors));
    return errors;
  }

  if (!isObject(value)) {
    if (typeof value === 'string') {
      if (uriSchemePattern.test(value)) {
        errors.push(`${trail} must not contain full URLs`);
      }
      if (signingPathPattern.test(value)) {
        errors.push(`${trail} must not contain signing material paths`);
      }
    }
    return errors;
  }

  for (const [key, entry] of Object.entries(value)) {
    if (FORBIDDEN_IDENTIFIER_KEYS.has(key)) {
      errors.push(`${trail}.${key} must not persist identifiers`);
    }
    if (/(?:serial|udid|imei|deviceid|sn)/iu.test(key)) {
      errors.push(`${trail}.${key} must not use serial-like keys`);
    }
    if (/(?:secret|token|password|cert|key)(?:$|[A-Z_])/u.test(key)) {
      errors.push(`${trail}.${key} must not use secret-bearing keys`);
    }
    collectForbiddenShapeErrors(entry, `${trail}.${key}`, errors);
  }

  return errors;
}

function createValidPhase4Proof() {
  return {
    schemaVersion: '4.0.0',
    phase: 4,
    result: 'pass',
    stubDetected: false,
    runId: '4b6ec0a3-47cd-4776-96f1-b03df8a09472',
    outputPath: 'harmony/artifacts/phase4-device-proof.json',
    timestamps: {
      startedAt: '2026-08-15T03:00:00.000Z',
      completedAt: '2026-08-15T03:00:09.000Z'
    },
    device: {
      targetKind: 'physical',
      identityMasked: 'target-91ac4f20',
      osVersion: 'HarmonyOS 6.0.1.123',
      apiVersion: 24,
      abi: 'arm64-v8a',
      deviceClass: 'phone'
    },
    bundles: {
      production: {
        bundleName: 'com.github.kr328.clash.harmony'
      },
      probe: {
        bundleName: 'com.cmfa.phase4.trafficprobe'
      },
      hapSha256: [digest('a'), digest('b')]
    },
    core: {
      version: 'v1.19.29',
      nativeSha256: [digest('c'), digest('d')]
    },
    assertions: {
      addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
      routes: ['0.0.0.0/0', '::/0'],
      dns: ['10.111.222.2', 'fd00:111:222::2'],
      mtu: 1500,
      ipv4Accepted: true,
      ipv6Accepted: true,
      blocking: false,
      blockedApplications: ['com.github.kr328.clash.harmony']
    },
    traffic: {
      tcp: {
        result: 'pass',
        correlated: true,
        captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.tcp.capture },
        coreEvent: { event: TRAFFIC_EVENT_CONTRACT.tcp.core }
      },
      udp: {
        result: 'pass',
        correlated: true,
        captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.udp.capture },
        coreEvent: { event: TRAFFIC_EVENT_CONTRACT.udp.core }
      },
      dns: {
        result: 'pass',
        correlated: true,
        captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.dns.capture },
        coreEvent: { event: TRAFFIC_EVENT_CONTRACT.dns.core }
      },
      ipv4: {
        result: 'pass',
        correlated: true,
        captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.ipv4.capture },
        coreEvent: { event: TRAFFIC_EVENT_CONTRACT.ipv4.core }
      },
      ipv6: { result: 'not-run', reason: 'network-not-provisioned' }
    },
    localEvidence: {
      http: { result: 'pass', ingress: 'local-http', correlated: true },
      socks: { result: 'pass', ingress: 'local-socks', correlated: true }
    },
    lifecycle: {
      notification: { result: 'pass' },
      background: { result: 'pass' },
      recovery: { result: 'pass' },
      stop: { result: 'pass' }
    },
    tun: {
      counters: {
        rxPackets: 41,
        txPackets: 38,
        rxBytes: 4096,
        txBytes: 6144
      }
    },
    failures: []
  };
}

function validatePhase4Proof(proof) {
  const errors = [];
  if (!isObject(proof)) {
    return { valid: false, errors: ['proof must be an object'] };
  }

  for (const key of Object.keys(proof)) {
    if (!ALLOWED_TOP_LEVEL_KEYS.has(key)) {
      errors.push(`proof must not include unexpected key ${key}`);
    }
  }

  if (proof.schemaVersion !== '4.0.0') errors.push('schemaVersion must be 4.0.0');
  if (proof.phase !== 4) errors.push('phase must be 4');
  if (proof.result !== 'pass') errors.push('result must be pass');
  if (proof.stubDetected !== false) errors.push('stubDetected must be false');
  if (!isUuid(proof.runId)) errors.push('runId must be a UUID');
  if (proof.outputPath !== 'harmony/artifacts/phase4-device-proof.json') errors.push('outputPath must be canonical');

  if (!isObject(proof.timestamps) || !isIsoTimestamp(proof.timestamps.startedAt) || !isIsoTimestamp(proof.timestamps.completedAt)) {
    errors.push('timestamps must include startedAt/completedAt ISO timestamps');
  }

  if (
    !isObject(proof.device) ||
    proof.device.targetKind !== 'physical' ||
    !/^target-[a-f0-9]{8}$/u.test(proof.device.identityMasked ?? '') ||
    !/^HarmonyOS 6\./u.test(proof.device.osVersion ?? '') ||
    !Number.isInteger(proof.device.apiVersion) ||
    proof.device.apiVersion < 20 ||
    proof.device.abi !== 'arm64-v8a' ||
    proof.device.deviceClass !== 'phone'
  ) {
    errors.push('device must match the physical HarmonyOS 6 phone contract');
  }

  if (!isObject(proof.bundles?.production) || !isObject(proof.bundles?.probe)) {
    errors.push('production and probe bundles are required');
  } else {
    if (proof.bundles.production.bundleName === proof.bundles.probe.bundleName) {
      errors.push('production and probe bundle names must differ');
    }
    if (proof.bundles.production.bundleName !== 'com.github.kr328.clash.harmony') {
      errors.push('production bundleName must be the canonical app bundle');
    }
    if (proof.bundles.probe.bundleName !== 'com.cmfa.phase4.trafficprobe') {
      errors.push('probe bundleName must be the approved traffic probe bundle');
    }
    if ('hapSha256' in proof.bundles.production || 'hapSha256' in proof.bundles.probe) {
      errors.push('bundles.production/probe must not publish per-bundle hapSha256 fields');
    }
    if (
      !Array.isArray(proof.bundles.hapSha256) ||
      proof.bundles.hapSha256.length !== 2 ||
      !proof.bundles.hapSha256.every((entry) => isSha256(entry))
    ) {
      errors.push('bundles.hapSha256 must be an ordered [production, probe] sha256 pair');
    } else if (proof.bundles.hapSha256[0] === proof.bundles.hapSha256[1]) {
      errors.push('bundles.hapSha256 must keep production and probe HAP hashes distinct');
    }
  }

  if (proof.core?.version !== 'v1.19.29') errors.push('core.version must be pinned');
  if (
    !Array.isArray(proof.core?.nativeSha256) ||
    proof.core.nativeSha256.length !== 2 ||
    !proof.core.nativeSha256.every((entry) => isSha256(entry))
  ) {
    errors.push('core.nativeSha256 must be an ordered [addon, mihomo] sha256 pair');
  } else if (proof.core.nativeSha256[0] === proof.core.nativeSha256[1]) {
    errors.push('core.nativeSha256 must keep addon and mihomo hashes distinct');
  }

  const expectedAssertions = {
    addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
    routes: ['0.0.0.0/0', '::/0'],
    dns: ['10.111.222.2', 'fd00:111:222::2'],
    mtu: 1500,
    ipv4Accepted: true,
    ipv6Accepted: true,
    blocking: false,
    blockedApplications: ['com.github.kr328.clash.harmony']
  };
  if (
    !isObject(proof.assertions) ||
    !Array.isArray(proof.assertions.addresses) ||
    !Array.isArray(proof.assertions.routes) ||
    !Array.isArray(proof.assertions.dns) ||
    proof.assertions.mtu !== expectedAssertions.mtu ||
    proof.assertions.ipv4Accepted !== true ||
    proof.assertions.ipv6Accepted !== true ||
    proof.assertions.blocking !== false ||
    JSON.stringify(proof.assertions.addresses) !== JSON.stringify(expectedAssertions.addresses) ||
    JSON.stringify(proof.assertions.routes) !== JSON.stringify(expectedAssertions.routes) ||
    JSON.stringify(proof.assertions.dns) !== JSON.stringify(expectedAssertions.dns) ||
    JSON.stringify(proof.assertions.blockedApplications) !== JSON.stringify(expectedAssertions.blockedApplications)
  ) {
    errors.push('assertions must match the canonical VPN contract');
  }

  for (const key of REQUIRED_TRAFFIC_KINDS) {
    const entry = proof.traffic?.[key];
    const expected = TRAFFIC_EVENT_CONTRACT[key];
    if (
      !isObject(entry) ||
      entry.result !== 'pass' ||
      entry.correlated !== true ||
      !isObject(entry.captureTrace) ||
      entry.captureTrace.ingress !== 'tun' ||
      entry.captureTrace.event !== expected.capture ||
      !isObject(entry.coreEvent) ||
      entry.coreEvent.event !== expected.core
    ) {
      errors.push(`traffic.${key} must be one canonical correlated evidence object`);
    }
  }
  if (isObject(proof.traffic) && 'ipv6' in proof.traffic) {
    const ipv6 = proof.traffic.ipv6;
    if (
      isObject(ipv6) &&
      ipv6.result === 'pass' &&
      ipv6.correlated === true &&
      isObject(ipv6.captureTrace) &&
      ipv6.captureTrace.ingress === 'tun' &&
      ipv6.captureTrace.event === TRAFFIC_EVENT_CONTRACT.ipv6.capture &&
      isObject(ipv6.coreEvent) &&
      ipv6.coreEvent.event === TRAFFIC_EVENT_CONTRACT.ipv6.core
    ) {
      // valid pass branch
    } else if (
      isObject(ipv6) &&
      ipv6.result === 'not-run' &&
      typeof ipv6.reason === 'string' &&
      ipv6.reason.length > 0 &&
      !Object.hasOwn(ipv6, 'sessionId') &&
      !Object.hasOwn(ipv6, 'traceId') &&
      !Object.hasOwn(ipv6, 'captureTrace') &&
      !Object.hasOwn(ipv6, 'coreEvent')
    ) {
      // valid not-run branch
    } else {
      errors.push('traffic.ipv6 must be either a full canonical ipv6 correlated evidence object or a not-run reason object');
    }
  }

  for (const [key, expectedIngress] of Object.entries({ http: 'local-http', socks: 'local-socks' })) {
    const entry = proof.localEvidence?.[key];
    if (!isObject(entry) || entry.result !== 'pass' || entry.ingress !== expectedIngress || entry.correlated !== true) {
      errors.push(`localEvidence.${key} must use ${expectedIngress}`);
    }
  }

  for (const key of ['notification', 'background', 'recovery', 'stop']) {
    if (proof.lifecycle?.[key]?.result !== 'pass') {
      errors.push(`lifecycle.${key} must pass`);
    }
  }

  for (const key of ['rxPackets', 'txPackets', 'rxBytes', 'txBytes']) {
    if (!Number.isInteger(proof.tun?.counters?.[key]) || proof.tun.counters[key] < 0) {
      errors.push(`tun.counters.${key} must be a non-negative integer`);
    }
  }

  errors.push(...collectForbiddenShapeErrors(proof));
  return { valid: errors.length === 0, errors };
}

test('Phase 4 proof schema and example lock the closed production contract', async () => {
  const [schema, example] = await Promise.all([
    fs.readFile(SCHEMA_PATH, 'utf8').then(JSON.parse),
    fs.readFile(EXAMPLE_PATH, 'utf8').then(JSON.parse)
  ]);

  const validProof = createValidPhase4Proof();

  assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.schemaVersion.const, '4.0.0');
  assert.equal(schema.properties.phase.const, 4);
  assert.equal(schema.properties.stubDetected.const, false);
  assert.deepEqual(schema.required, [
    'schemaVersion',
    'phase',
    'result',
    'stubDetected',
    'runId',
    'outputPath',
    'timestamps',
    'device',
    'bundles',
    'core',
    'assertions',
    'traffic',
    'localEvidence',
    'lifecycle',
    'tun',
    'failures'
  ]);
  assert.equal(schema.properties.device.additionalProperties, false);
  assert.equal(schema.properties.bundles.additionalProperties, false);
  assert.equal(schema.properties.traffic.additionalProperties, false);
  assert.equal(schema.properties.localEvidence.additionalProperties, false);
  assert.equal(schema.properties.lifecycle.additionalProperties, false);
  assert.equal(schema.properties.tun.additionalProperties, false);
  assert.equal(schema.$defs.productionBundle.properties.bundleName.const, 'com.github.kr328.clash.harmony');
  assert.equal(schema.$defs.probeBundle.properties.bundleName.const, 'com.cmfa.phase4.trafficprobe');
  assert.equal('hapSha256' in schema.$defs.productionBundle.properties, false);
  assert.equal('hapSha256' in schema.$defs.probeBundle.properties, false);
  assert.equal(schema.properties.bundles.properties.hapSha256.uniqueItems, true);
  assert.deepEqual(schema.properties.bundles.properties.hapSha256.description, 'Ordered [production, probe] HAP sha256 digests.');
  assert.equal(schema.properties.core.properties.version.const, 'v1.19.29');
  assert.equal(schema.properties.core.properties.nativeSha256.uniqueItems, true);
  assert.deepEqual(schema.properties.core.properties.nativeSha256.description, 'Ordered [addon, mihomo] native sha256 digests.');
  assert.equal(schema.properties.device.properties.targetKind.const, 'physical');
  assert.equal(schema.properties.device.properties.deviceClass.const, 'phone');
  assert.equal(schema.properties.device.properties.apiVersion.minimum, 20);
  assert.equal(schema.properties.device.properties.abi.const, 'arm64-v8a');
  assert.match(schema.properties.device.properties.osVersion.pattern, /HarmonyOS 6/u);
  assert.equal('modelAlias' in schema.properties.device.properties, false);
  assert.equal('productAlias' in schema.properties.device.properties, false);
  assert.equal(schema.properties.assertions.properties.addresses.items, false);
  assert.equal(schema.properties.assertions.properties.routes.items, false);
  assert.equal(schema.properties.assertions.properties.dns.items, false);
  assert.equal(schema.properties.assertions.properties.blocking.const, false);
  assert.equal(schema.properties.assertions.properties.blockedApplications.items, false);
  assert.equal(schema.$defs.localHttpEvidence.properties.ingress.const, 'local-http');
  assert.equal(schema.$defs.localSocksEvidence.properties.ingress.const, 'local-socks');
  assert.equal('sessionId' in schema.$defs.trafficTcp.properties, false);
  assert.equal('traceId' in schema.$defs.trafficTcp.properties, false);
  assert.equal(schema.$defs.trafficTcp.properties.correlated.const, true);
  assert.equal(schema.$defs.localHttpEvidence.properties.correlated.const, true);
  assert.equal('ipv6' in schema.properties.traffic.properties, true);
  assert.deepEqual(
    Object.keys(schema.properties.traffic.properties),
    [...REQUIRED_TRAFFIC_KINDS, 'ipv6']
  );
  assert.equal(schema.$defs.trafficTcp.properties.captureTrace.properties.event.const, TRAFFIC_EVENT_CONTRACT.tcp.capture);
  assert.equal(schema.$defs.trafficTcp.properties.coreEvent.properties.event.const, TRAFFIC_EVENT_CONTRACT.tcp.core);
  assert.equal(schema.$defs.trafficUdp.properties.captureTrace.properties.event.const, TRAFFIC_EVENT_CONTRACT.udp.capture);
  assert.equal(schema.$defs.trafficUdp.properties.coreEvent.properties.event.const, TRAFFIC_EVENT_CONTRACT.udp.core);
  assert.equal(schema.$defs.trafficDns.properties.captureTrace.properties.event.const, TRAFFIC_EVENT_CONTRACT.dns.capture);
  assert.equal(schema.$defs.trafficDns.properties.coreEvent.properties.event.const, TRAFFIC_EVENT_CONTRACT.dns.core);
  assert.equal(schema.$defs.trafficIpv4.properties.captureTrace.properties.event.const, TRAFFIC_EVENT_CONTRACT.ipv4.capture);
  assert.equal(schema.$defs.trafficIpv4.properties.coreEvent.properties.event.const, TRAFFIC_EVENT_CONTRACT.ipv4.core);
  assert.equal(schema.$defs.trafficIpv6.oneOf.length, 2);
  assert.equal(schema.$defs.trafficIpv6.oneOf[0].properties.captureTrace.properties.event.const, TRAFFIC_EVENT_CONTRACT.ipv6.capture);
  assert.equal(schema.$defs.trafficIpv6.oneOf[0].properties.coreEvent.properties.event.const, TRAFFIC_EVENT_CONTRACT.ipv6.core);

  assert.deepEqual(example, validProof);
  assert.deepEqual(validatePhase4Proof(validProof), { valid: true, errors: [] });
  assert.deepEqual(validatePhase4Proof(example), { valid: true, errors: [] });
});

test('Phase 4 proof validation rejects old tags, secrets, URLs, signing paths, and broken correlation invariants', () => {
  const cases = [
    ['wrong schema version', (proof) => { proof.schemaVersion = '1.0.0'; }, /schemaVersion/u],
    ['stub flag missing', (proof) => { delete proof.stubDetected; }, /stubDetected/u],
    ['stub flag true', (proof) => { proof.stubDetected = true; }, /stubDetected/u],
    ['full URL leaked', (proof) => { proof.device.modelAlias = leakedUrlValue; }, /full URLs/u],
    ['file URL leaked', (proof) => { proof.device.productAlias = leakedFileUrlValue; }, /full URLs/u],
    ['ssh URL leaked', (proof) => { proof.device.productAlias = leakedSshUrlValue; }, /full URLs/u],
    ['signing path leaked', (proof) => { proof.lifecycle.stop.detail = leakedSigningPathValue; }, /signing material/u],
    ['windows signing path leaked', (proof) => { proof.lifecycle.stop.detail = leakedWindowsSigningPathValue; }, /signing material/u],
    ['windows forward slash signing path leaked', (proof) => { proof.lifecycle.stop.detail = leakedWindowsForwardSlashSigningPathValue; }, /signing material/u],
    ['secret field leaked', (proof) => { proof.device[leakedSecretKey] = 'abc'; }, /secret-bearing keys/u],
    ['serial-like field leaked', (proof) => { proof.device[leakedSerialKey] = 'ABC123'; }, /serial-like keys/u],
    ['device class drifted', (proof) => { proof.device.deviceClass = 'tablet'; }, /device must match/u],
    ['api version too low', (proof) => { proof.device.apiVersion = 19; }, /device must match/u],
    ['probe bundle identity drifted', (proof) => { proof.bundles.probe.bundleName = 'com.github.kr328.clash.harmony.probe'; }, /traffic probe bundle/u],
    ['probe bundle drifted to production', (proof) => { proof.bundles.probe.bundleName = proof.bundles.production.bundleName; }, /bundle names must differ/u],
    ['probe hap hash drifted to production', (proof) => {
      proof.bundles.hapSha256[1] = proof.bundles.hapSha256[0];
    }, /bundles\.hapSha256/u],
    ['hap hash pair missing probe entry', (proof) => { proof.bundles.hapSha256 = [proof.bundles.hapSha256[0]]; }, /ordered \[production, probe\]/u],
    ['hap hash pair carries extra entry', (proof) => { proof.bundles.hapSha256.push(digest('e')); }, /ordered \[production, probe\]/u],
    ['core native hash pair missing mihomo entry', (proof) => { proof.core.nativeSha256 = [proof.core.nativeSha256[0]]; }, /ordered \[addon, mihomo\]/u],
    ['core native hash pair duplicated', (proof) => { proof.core.nativeSha256[1] = proof.core.nativeSha256[0]; }, /core\.nativeSha256/u],
    ['old production hap field leaked', (proof) => { proof.bundles.production.hapSha256 = digest('a'); }, /per-bundle hapSha256/u],
    ['assertions drifted from vpn addresses', (proof) => { proof.assertions.addresses = ['10.111.222.9/30', 'fd00:111:222::1/126']; }, /VPN contract/u],
    ['blocked applications drifted', (proof) => { proof.assertions.blockedApplications = []; }, /VPN contract/u],
    ['local ingress broke', (proof) => { proof.localEvidence.http.ingress = 'tun'; }, /localEvidence\.http/u],
    ['socks ingress broke', (proof) => { proof.localEvidence.socks.ingress = 'tun'; }, /localEvidence\.socks/u],
    ['traffic tcp identifier leaked', (proof) => { proof.traffic.tcp.sessionId = 'session-tcp'; }, /must not persist identifiers/u],
    ['local http identifier leaked', (proof) => { proof.localEvidence.http.traceId = 'trace-http'; }, /must not persist identifiers/u],
    ['unexpected top-level correlations field leaked', (proof) => { proof.correlations = {}; }, /unexpected key correlations/u],
    ['capture ingress broke', (proof) => { proof.traffic.tcp.captureTrace.ingress = 'local-http'; }, /traffic\.tcp/u],
    ['tcp capture event drifted', (proof) => { proof.traffic.tcp.captureTrace.event = TRAFFIC_EVENT_CONTRACT.udp.capture; }, /traffic\.tcp/u],
    ['tcp core event drifted', (proof) => { proof.traffic.tcp.coreEvent.event = TRAFFIC_EVENT_CONTRACT.udp.core; }, /traffic\.tcp/u],
    ['capture trace omitted', (proof) => { delete proof.traffic.tcp.captureTrace; }, /traffic\.tcp/u],
    ['core event omitted', (proof) => { delete proof.traffic.tcp.coreEvent; }, /traffic\.tcp/u],
    ['ipv6 not-run missing reason', (proof) => { proof.traffic.ipv6 = { result: 'not-run' }; }, /ipv6/u],
    ['ipv6 partial pass evidence', (proof) => { proof.traffic.ipv6 = { result: 'pass', correlated: true }; }, /ipv6/u],
    ['ipv6 wrong capture event', (proof) => {
      proof.traffic.ipv6 = {
        result: 'pass',
        correlated: true,
        captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.tcp.capture },
        coreEvent: { event: TRAFFIC_EVENT_CONTRACT.ipv6.core }
      };
    }, /ipv6/u]
  ];

  for (const [label, mutate, expected] of cases) {
    const proof = createValidPhase4Proof();
    mutate(proof);
    const validation = validatePhase4Proof(proof);
    assert.equal(validation.valid, false, label);
    assert.match(validation.errors.join('\n'), expected, label);
  }
});

test('Phase 4 bundle hash ordering stays canonical and non-redundant', () => {
  const validProof = createValidPhase4Proof();
  assert.deepEqual(validProof.bundles.hapSha256, [digest('a'), digest('b')]);
  assert.deepEqual(BUNDLE_HAP_HASH_ORDER, ['production', 'probe']);
  assert.deepEqual(validProof.core.nativeSha256, [digest('c'), digest('d')]);
  assert.deepEqual(CORE_NATIVE_HASH_ORDER, ['addon', 'mihomo']);
  assert.equal('hapSha256' in validProof.bundles.production, false);
  assert.equal('hapSha256' in validProof.bundles.probe, false);
  assert.equal('nativeSha256' in validProof.bundles.production, false);
  assert.equal('nativeSha256' in validProof.bundles.probe, false);
});

test('Phase 4 proof validation accepts canonical ipv6 pass and not-run branches', () => {
  const notRunProof = createValidPhase4Proof();
  notRunProof.traffic.ipv6 = { result: 'not-run', reason: 'network-not-provisioned' };
  assert.deepEqual(validatePhase4Proof(notRunProof), { valid: true, errors: [] });

  const passProof = createValidPhase4Proof();
  passProof.traffic.ipv6 = {
    result: 'pass',
    correlated: true,
    captureTrace: { ingress: 'tun', event: TRAFFIC_EVENT_CONTRACT.ipv6.capture },
    coreEvent: { event: TRAFFIC_EVENT_CONTRACT.ipv6.core }
  };
  assert.deepEqual(validatePhase4Proof(passProof), { valid: true, errors: [] });
});

test('Phase 4 runner argument proofs stay canonical, incomplete, and recursively redacted', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-proof-schema-'));
  const outputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const proof = await runner.writeArgumentErrorProof({
    outputPath,
    detail: `bad input ${leakedUrlValue} ${leakedSigningPathValue} ${leakedWindowsSigningPathValue}`
  });

  assert.equal(proof.result, 'incomplete');
  assert.equal(proof.outputPath, 'harmony/artifacts/phase4-device-proof.json');
  assert.equal(collectForbiddenShapeErrors(proof).length, 0);
  assert.equal(JSON.stringify(proof).includes(leakedUrlValue), false);
  assert.equal(JSON.stringify(proof).includes(leakedSigningPathValue), false);
  assert.equal(JSON.stringify(proof).includes(leakedWindowsSigningPathValue), false);
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), proof);
});

test('Phase 4 runner correlated pass output matches the closed production schema', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const runId = '4b6ec0a3-47cd-4776-96f1-b03df8a09472';
  const sessionId = '0eaf3b3d-5d04-4cd7-b1f4-e2a7d5ccf7a1';
  const flowId = '5e55ea90-9911-489f-93b3-fffd53605025';
  const markerHash = hashHex(`cmfa-${flowId}`);
  const dnsHash = createDnsPacketHash(runId, flowId);
  const proof = runner.correlatePhase4Evidence({
    runId,
    origin: {
      runId,
      observations: [
        { protocol: 'https', runId, sessionId, flowId, responseBodySha256: digest('6') },
        { protocol: 'tcp', runId, sessionId, flowId, payloadSha256: digest('7'), correlationHash: markerHash },
        { protocol: 'udp', runId, sessionId, flowId, payloadSha256: digest('8'), correlationHash: markerHash, dnsShaped: false }
      ]
    },
    probe: {
      version: '1.0.0',
      result: 'pass',
      runId,
      sessionId,
      records: [
        { flowId: 'https-flow', stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1, statusCode: 200 },
        { flowId, stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId: 'local-http-flow', stepId: 'http-connect', ingressExpectation: 'local-http-connect-listener', outcome: 'fail', transport: 'tcp', targetPort: 7890, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 0 },
        { flowId: 'local-socks-flow', stepId: 'socks5', ingressExpectation: 'local-socks5-listener', outcome: 'fail', transport: 'tcp', targetPort: 7891, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 0 }
      ],
      failures: []
    },
    localProof: {
      http: { ingress: 'local-http', outcome: 'pass', correlated: true },
      socks: { ingress: 'local-socks', outcome: 'pass', correlated: true }
    },
    runtime: {
      counters: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 },
      records: [
        { sequence: 1, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: markerHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-tcp', coreAlias: '', protocol: 'tcp', hashedTuple: 'hash-tcp', correlationHash: markerHash, destinationHash: hashHex('dest-tcp'), outboundTerminalHash: hashHex('term-tcp'), outboundChainHash: hashHex('chain-tcp'), outboundChainLength: 2, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'tcp' },
        { sequence: 2, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: markerHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-udp', coreAlias: '', protocol: 'udp', hashedTuple: 'hash-udp', correlationHash: markerHash, destinationHash: hashHex('dest-udp'), outboundTerminalHash: hashHex('term-udp'), outboundChainHash: hashHex('chain-udp'), outboundChainLength: 2, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'udp' },
        { sequence: 3, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: dnsHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-dns', coreAlias: '', protocol: 'dns', hashedTuple: 'hash-dns', correlationHash: dnsHash, destinationHash: hashHex('dest-dns'), outboundTerminalHash: hashHex('term-dns'), outboundChainHash: hashHex('chain-dns'), outboundChainLength: 1, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'dns' }
      ]
    },
    packages: {
      result: 'pass',
      production: {
        bundleName: 'com.github.kr328.clash.harmony',
        stubDetected: false,
        hapSha256: digest('a'),
        signatureSha256: digest('b')
      },
      probe: {
        bundleName: 'com.cmfa.phase4.trafficprobe',
        hapSha256: digest('c'),
        signatureSha256: digest('d')
      }
    },
    lifecycle: {
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true,
      networkLossRecovery: true,
      stopCleanup: true,
      networkingRestored: true
    }
  });

  assert.equal(proof.result, 'pass', JSON.stringify(proof.failures));
  assert.equal(proof.stubDetected, false);
  assert.deepEqual(validatePhase4Proof(proof), { valid: true, errors: [] });
  assert.equal(collectForbiddenShapeErrors(proof).length, 0);
});

test('Phase 4 runner fail-closes correlated output when production stub detection is missing or true', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const base = createValidPhase4Proof();
  const runId = base.runId;
  const sessionId = '0eaf3b3d-5d04-4cd7-b1f4-e2a7d5ccf7a1';
  const flowId = '5e55ea90-9911-489f-93b3-fffd53605025';
  const markerHash = hashHex(`cmfa-${flowId}`);
  const dnsHash = createDnsPacketHash(runId, flowId);
  const evidence = {
    runId,
    origin: {
      runId,
      observations: [
        { protocol: 'https', runId, sessionId, flowId, responseBodySha256: digest('6') },
        { protocol: 'tcp', runId, sessionId, flowId, payloadSha256: digest('7'), correlationHash: markerHash },
        { protocol: 'udp', runId, sessionId, flowId, payloadSha256: digest('8'), correlationHash: markerHash, dnsShaped: false }
      ]
    },
    probe: {
      version: '1.0.0',
      result: 'pass',
      runId,
      sessionId,
      records: [
        { flowId: 'https-flow', stepId: 'https', ingressExpectation: 'origin-https', outcome: 'pass', transport: 'https', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1, statusCode: 200 },
        { flowId, stepId: 'tcp', ingressExpectation: 'tun', outcome: 'pass', transport: 'tcp', targetPort: 443, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'udp-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 },
        { flowId, stepId: 'dns-packet-ipv4', ingressExpectation: 'tun', outcome: 'pass', transport: 'udp', targetPort: 53, startedAt: '2026-08-17T00:00:00.000Z', completedAt: '2026-08-17T00:00:01.000Z', bytesSent: 1, bytesReceived: 1 }
      ],
      failures: []
    },
    localProof: {
      http: { ingress: 'local-http', outcome: 'pass', correlated: true },
      socks: { ingress: 'local-socks', outcome: 'pass', correlated: true }
    },
    runtime: {
      counters: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 },
      records: [
        { sequence: 1, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: markerHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-tcp', coreAlias: '', protocol: 'tcp', hashedTuple: 'hash-tcp', correlationHash: markerHash, destinationHash: hashHex('dest-tcp'), outboundTerminalHash: hashHex('term-tcp'), outboundChainHash: hashHex('chain-tcp'), outboundChainLength: 2, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'tcp' },
        { sequence: 2, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: markerHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-udp', coreAlias: '', protocol: 'udp', hashedTuple: 'hash-udp', correlationHash: markerHash, destinationHash: hashHex('dest-udp'), outboundTerminalHash: hashHex('term-udp'), outboundChainHash: hashHex('chain-udp'), outboundChainLength: 2, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'udp' },
        { sequence: 3, kind: 'traffic', ingress: 'tun', linkageStatus: 'linked', flowIdHash: dnsHash, sessionIdHash: runner.hashOpaqueCorrelationId(sessionId), traceAlias: 'trace-dns', coreAlias: '', protocol: 'dns', hashedTuple: 'hash-dns', correlationHash: dnsHash, destinationHash: hashHex('dest-dns'), outboundTerminalHash: hashHex('term-dns'), outboundChainHash: hashHex('chain-dns'), outboundChainLength: 1, counterDelta: 1, counterSnapshot: { rxPackets: 41, txPackets: 38, rxBytes: 4096, txBytes: 6144 }, detail: 'dns' }
      ]
    },
    packages: {
      result: 'pass',
      production: {
        bundleName: 'com.github.kr328.clash.harmony',
        hapSha256: digest('a'),
        signatureSha256: digest('b')
      },
      probe: {
        bundleName: 'com.cmfa.phase4.trafficprobe',
        hapSha256: digest('c'),
        signatureSha256: digest('d')
      }
    },
    lifecycle: {
      launcherContinuity: true,
      screenOffContinuity: true,
      vpnIndicatorVisible: true,
      ongoingNotificationVisible: true,
      networkLossRecovery: true,
      stopCleanup: true,
      networkingRestored: true
    }
  };

  const missingStub = runner.correlatePhase4Evidence(evidence);
  assert.equal(missingStub.result, 'incomplete');
  assert.equal(missingStub.stubDetected, true);
  assert.match(missingStub.failures.map((entry) => entry.code).join(','), /PACKAGE_STUB_DETECTED/u);

  const explicitStub = runner.correlatePhase4Evidence({
    ...evidence,
    packages: {
      ...evidence.packages,
      production: {
        ...evidence.packages.production,
        stubDetected: true
      }
    }
  });
  assert.equal(explicitStub.result, 'incomplete');
  assert.equal(explicitStub.stubDetected, true);
  assert.match(explicitStub.failures.map((entry) => entry.code).join(','), /PACKAGE_STUB_DETECTED/u);
});

test('Phase 4 runner incomplete proof defaults stubDetected to fail-closed true until package inspection proves false', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const baseProof = runner.createBaseProofForTesting();
  assert.equal(baseProof.result, 'incomplete');
  assert.equal(baseProof.stubDetected, true);

  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-proof-schema-stub-'));
  const outputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const argumentProof = await runner.writeArgumentErrorProof({ outputPath });
  assert.equal(argumentProof.result, 'incomplete');
  assert.equal(argumentProof.stubDetected, true);
});

test('Phase 4 runner generic schema validator enforces additionalProperties, required, const/type/pattern/minimum, tuples, uniqueItems, oneOf, and bad refs', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const schema = JSON.parse(await fs.readFile(SCHEMA_PATH, 'utf8'));
  const valid = createValidPhase4Proof();
  assert.deepEqual(await runner.validatePhase4ProofDocument(valid), { valid: true, errors: [] });

  const badTop = createValidPhase4Proof();
  badTop.extraTop = true;
  assert.equal((await runner.validatePhase4ProofDocument(badTop)).valid, false);

  const badNested = createValidPhase4Proof();
  badNested.traffic.tcp.extra = true;
  assert.equal((await runner.validatePhase4ProofDocument(badNested)).valid, false);

  const missingRequired = createValidPhase4Proof();
  delete missingRequired.device.abi;
  assert.equal((await runner.validatePhase4ProofDocument(missingRequired)).valid, false);

  const wrongConst = createValidPhase4Proof();
  wrongConst.phase = 3;
  assert.equal((await runner.validatePhase4ProofDocument(wrongConst)).valid, false);

  const wrongType = createValidPhase4Proof();
  wrongType.device.apiVersion = '20';
  assert.equal((await runner.validatePhase4ProofDocument(wrongType)).valid, false);

  const wrongPattern = createValidPhase4Proof();
  wrongPattern.runId = 'nope';
  assert.equal((await runner.validatePhase4ProofDocument(wrongPattern)).valid, false);

  const wrongMinimum = createValidPhase4Proof();
  wrongMinimum.device.apiVersion = 19;
  assert.equal((await runner.validatePhase4ProofDocument(wrongMinimum)).valid, false);

  const tupleDrift = createValidPhase4Proof();
  tupleDrift.bundles.hapSha256 = [digest('a')];
  assert.equal((await runner.validatePhase4ProofDocument(tupleDrift)).valid, false);

  const duplicateUnique = createValidPhase4Proof();
  duplicateUnique.bundles.hapSha256[1] = duplicateUnique.bundles.hapSha256[0];
  assert.equal((await runner.validatePhase4ProofDocument(duplicateUnique)).valid, false);

  const oneOfBoth = createValidPhase4Proof();
  oneOfBoth.traffic.ipv6 = {
    result: 'not-run',
    reason: 'network-not-provisioned',
    correlated: true
  };
  assert.equal((await runner.validatePhase4ProofDocument(oneOfBoth)).valid, false);

  const oneOfNeither = createValidPhase4Proof();
  oneOfNeither.traffic.ipv6 = { result: 'meh' };
  assert.equal((await runner.validatePhase4ProofDocument(oneOfNeither)).valid, false);

  const sensitiveNested = createValidPhase4Proof();
  sensitiveNested.lifecycle.stop.secretToken = 'abc';
  assert.equal((await runner.validatePhase4ProofDocument(sensitiveNested)).valid, false);

  const badRefSchema = {
    type: 'object',
    properties: {
      value: { $ref: '#/$defs/missing' }
    }
  };
  const badRef = await runner.validateValueAgainstSchema({ value: 1 }, badRefSchema, badRefSchema);
  assert.equal(badRef.valid, false);
  assert.match(badRef.errors.join('\n'), /\$ref|missing/u);

  assert.equal(schema.$defs.trafficIpv6.oneOf.length, 2);
});

test('Phase 4 runner falls back to canonical incomplete proof when pass candidate violates shipped schema', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'phase4-schema-fallback-'));
  const outputPath = path.join(tempRoot, 'phase4-device-proof.json');
  const invalidPass = createValidPhase4Proof();
  invalidPass.result = 'pass';
  invalidPass.traffic = {};
  invalidPass.device.secretToken = 'abc';

  const persisted = await runner.writeValidatedProof(invalidPass, outputPath);
  assert.equal(persisted.result, 'incomplete');
  assert.equal(persisted.outputPath, 'harmony/artifacts/phase4-device-proof.json');
  assert.match(persisted.failures.map((entry) => entry.code).join(','), /PHASE4_PROOF_INVALID/u);
  assert.equal(collectForbiddenShapeErrors(persisted).length, 0);
  assert.deepEqual(JSON.parse(await fs.readFile(outputPath, 'utf8')), persisted);
});
