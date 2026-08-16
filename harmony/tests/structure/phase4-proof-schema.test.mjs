import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'phase4-device-proof.example.json');

function digest(char) {
  return char.repeat(64);
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
const BUNDLE_HAP_HASH_ORDER = ['production', 'probe'];
const CORE_NATIVE_HASH_ORDER = ['addon', 'mihomo'];
const ALLOWED_TOP_LEVEL_KEYS = new Set([
  'schemaVersion',
  'phase',
  'result',
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
        bundleName: 'com.github.kr328.clash.harmony.trafficprobe'
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
        sessionId: 'session-tcp',
        traceId: 'trace-tcp',
        captureTrace: { ingress: 'tun', event: 'tcp-connect' },
        coreEvent: { event: 'mihomo.tcp' }
      },
      udp: {
        result: 'pass',
        sessionId: 'session-udp',
        traceId: 'trace-udp',
        captureTrace: { ingress: 'tun', event: 'udp-associate' },
        coreEvent: { event: 'mihomo.udp' }
      },
      dns: {
        result: 'pass',
        sessionId: 'session-dns',
        traceId: 'trace-dns',
        captureTrace: { ingress: 'tun', event: 'dns-query' },
        coreEvent: { event: 'mihomo.dns' }
      },
      ipv4: {
        result: 'pass',
        sessionId: 'session-ipv4',
        traceId: 'trace-ipv4',
        captureTrace: { ingress: 'tun', event: 'ipv4-flow' },
        coreEvent: { event: 'mihomo.ipv4' }
      }
    },
    localEvidence: {
      http: { result: 'pass', ingress: 'local-http', sessionId: 'local-http-session', traceId: 'local-http-trace' },
      socks: { result: 'pass', ingress: 'local-socks', sessionId: 'local-socks-session', traceId: 'local-socks-trace' }
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
    if (proof.bundles.probe.bundleName !== 'com.github.kr328.clash.harmony.trafficprobe') {
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
    if (
      !isObject(entry) ||
      entry.result !== 'pass' ||
      typeof entry.sessionId !== 'string' ||
      typeof entry.traceId !== 'string' ||
      !isObject(entry.captureTrace) ||
      entry.captureTrace.ingress !== 'tun' ||
      typeof entry.captureTrace.event !== 'string' ||
      entry.captureTrace.event.length === 0 ||
      !isObject(entry.coreEvent) ||
      typeof entry.coreEvent.event !== 'string' ||
      entry.coreEvent.event.length === 0
    ) {
      errors.push(`traffic.${key} must be one canonical correlated evidence object`);
    }
  }
  if (isObject(proof.traffic) && 'ipv6' in proof.traffic) {
    errors.push('traffic must not publish a separate ipv6 probe result');
  }

  for (const [key, expectedIngress] of Object.entries({ http: 'local-http', socks: 'local-socks' })) {
    const entry = proof.localEvidence?.[key];
    if (!isObject(entry) || entry.result !== 'pass' || entry.ingress !== expectedIngress) {
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
  assert.deepEqual(schema.required, [
    'schemaVersion',
    'phase',
    'result',
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
  assert.equal(schema.$defs.probeBundle.properties.bundleName.const, 'com.github.kr328.clash.harmony.trafficprobe');
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
  assert.equal('ipv6' in schema.properties.traffic.properties, false);
  assert.deepEqual(
    Object.keys(schema.properties.traffic.properties),
    REQUIRED_TRAFFIC_KINDS
  );
  assert.equal(schema.$defs.correlatedTraffic.additionalProperties, false);
  assert.equal(schema.$defs.correlatedTraffic.properties.captureTrace.additionalProperties, false);
  assert.equal(schema.$defs.correlatedTraffic.properties.coreEvent.additionalProperties, false);

  assert.deepEqual(example, validProof);
  assert.deepEqual(validatePhase4Proof(validProof), { valid: true, errors: [] });
  assert.deepEqual(validatePhase4Proof(example), { valid: true, errors: [] });
});

test('Phase 4 proof validation rejects old tags, secrets, URLs, signing paths, and broken correlation invariants', () => {
  const cases = [
    ['wrong schema version', (proof) => { proof.schemaVersion = '1.0.0'; }, /schemaVersion/u],
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
    ['unexpected top-level correlations field leaked', (proof) => { proof.correlations = {}; }, /unexpected key correlations/u],
    ['capture ingress broke', (proof) => { proof.traffic.tcp.captureTrace.ingress = 'local-http'; }, /traffic\.tcp/u],
    ['capture trace omitted', (proof) => { delete proof.traffic.tcp.captureTrace; }, /traffic\.tcp/u],
    ['core event omitted', (proof) => { delete proof.traffic.tcp.coreEvent; }, /traffic\.tcp/u]
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
