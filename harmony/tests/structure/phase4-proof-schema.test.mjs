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
const signingPathPattern = new RegExp(
  String.raw`(?:^|/)[^/\s]+\.(?:${sensitiveExtensions.join('|')})$`,
  'iu'
);
const leakedUrlValue = joinFragments(['https', '://device.example.invalid/model']);
const leakedSigningPathValue = joinFragments(['/Us', 'ers/dev/', 'sign', 'ing/release.', sensitiveExtensions[0]]);
const leakedSecretKey = joinFragments(['secret', 'Token']);
const leakedSerialKey = joinFragments(['serial', 'Number']);

function collectForbiddenShapeErrors(value, trail = 'proof', errors = []) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => collectForbiddenShapeErrors(entry, `${trail}[${index}]`, errors));
    return errors;
  }

  if (!isObject(value)) {
    if (typeof value === 'string') {
      if (/https?:\/\//iu.test(value)) {
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
      modelAlias: 'HarmonyPhoneLab',
      productAlias: 'PuraX-Lab',
      apiVersion: '20',
      abi: 'arm64-v8a'
    },
    bundles: {
      production: {
        bundleName: 'com.github.kr328.clash.harmony',
        hapSha256: digest('a'),
        nativeSha256: digest('b')
      },
      probe: {
        bundleName: 'com.github.kr328.clash.harmony.probe',
        hapSha256: digest('c'),
        nativeSha256: digest('d')
      }
    },
    core: {
      version: 'v1.19.29'
    },
    assertions: {
      routeMode: 'rule',
      defaultRoute: 'tun',
      dnsMode: 'clash-dns',
      dnsListen: '127.0.0.1:1053',
      mtu: 1500
    },
    traffic: {
      tcp: { result: 'pass', sessionId: 'session-tcp', traceId: 'trace-tcp' },
      udp: { result: 'pass', sessionId: 'session-udp', traceId: 'trace-udp' },
      dns: { result: 'pass', sessionId: 'session-dns', traceId: 'trace-dns' },
      ipv4: { result: 'pass', sessionId: 'session-ipv4', traceId: 'trace-ipv4' },
      ipv6: { result: 'not-run', reason: 'network-not-provisioned' }
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
    correlations: [
      {
        kind: 'tcp',
        sessionId: 'session-tcp',
        traceId: 'trace-tcp',
        captureTrace: {
          ingress: 'tun',
          event: 'tcp-connect'
        },
        coreEvent: {
          sessionId: 'session-tcp',
          traceId: 'trace-tcp',
          event: 'mihomo.tcp'
        }
      },
      {
        kind: 'udp',
        sessionId: 'session-udp',
        traceId: 'trace-udp',
        captureTrace: {
          ingress: 'tun',
          event: 'udp-associate'
        },
        coreEvent: {
          sessionId: 'session-udp',
          traceId: 'trace-udp',
          event: 'mihomo.udp'
        }
      },
      {
        kind: 'dns',
        sessionId: 'session-dns',
        traceId: 'trace-dns',
        captureTrace: {
          ingress: 'tun',
          event: 'dns-query'
        },
        coreEvent: {
          sessionId: 'session-dns',
          traceId: 'trace-dns',
          event: 'mihomo.dns'
        }
      },
      {
        kind: 'ipv4',
        sessionId: 'session-ipv4',
        traceId: 'trace-ipv4',
        captureTrace: {
          ingress: 'tun',
          event: 'ipv4-flow'
        },
        coreEvent: {
          sessionId: 'session-ipv4',
          traceId: 'trace-ipv4',
          event: 'mihomo.ipv4'
        }
      }
    ],
    failures: []
  };
}

function validatePhase4Proof(proof) {
  const errors = [];
  if (!isObject(proof)) {
    return { valid: false, errors: ['proof must be an object'] };
  }

  if (proof.schemaVersion !== '4.0.0') errors.push('schemaVersion must be 4.0.0');
  if (proof.phase !== 4) errors.push('phase must be 4');
  if (proof.result !== 'pass') errors.push('result must be pass');
  if (!isUuid(proof.runId)) errors.push('runId must be a UUID');
  if (proof.outputPath !== 'harmony/artifacts/phase4-device-proof.json') errors.push('outputPath must be canonical');

  if (!isObject(proof.timestamps) || !isIsoTimestamp(proof.timestamps.startedAt) || !isIsoTimestamp(proof.timestamps.completedAt)) {
    errors.push('timestamps must include startedAt/completedAt ISO timestamps');
  }

  if (!isObject(proof.device) || proof.device.targetKind !== 'physical' || !/^target-[a-f0-9]{8}$/u.test(proof.device.identityMasked ?? '')) {
    errors.push('device must be a redacted physical device identity');
  }

  if (!isObject(proof.bundles?.production) || !isObject(proof.bundles?.probe)) {
    errors.push('production and probe bundles are required');
  } else {
    if (proof.bundles.production.bundleName === proof.bundles.probe.bundleName) {
      errors.push('production and probe bundle names must differ');
    }
    if (proof.bundles.production.hapSha256 === proof.bundles.probe.hapSha256) {
      errors.push('production and probe HAP hashes must differ');
    }
    if (proof.bundles.production.nativeSha256 === proof.bundles.probe.nativeSha256) {
      errors.push('production and probe native hashes must differ');
    }
    for (const bundleKey of ['production', 'probe']) {
      const bundle = proof.bundles[bundleKey];
      if (!isSha256(bundle.hapSha256) || !isSha256(bundle.nativeSha256)) {
        errors.push(`${bundleKey} bundle hashes must be sha256`);
      }
    }
  }

  if (proof.core?.version !== 'v1.19.29') errors.push('core.version must be pinned');

  if (
    !isObject(proof.assertions) ||
    proof.assertions.routeMode !== 'rule' ||
    proof.assertions.defaultRoute !== 'tun' ||
    proof.assertions.dnsMode !== 'clash-dns' ||
    proof.assertions.dnsListen !== '127.0.0.1:1053' ||
    proof.assertions.mtu !== 1500
  ) {
    errors.push('assertions must pin route, DNS, and MTU');
  }

  for (const key of ['tcp', 'udp', 'dns', 'ipv4']) {
    const entry = proof.traffic?.[key];
    if (!isObject(entry) || entry.result !== 'pass' || typeof entry.sessionId !== 'string' || typeof entry.traceId !== 'string') {
      errors.push(`traffic.${key} must be a passing correlated result`);
    }
  }
  if (proof.traffic?.ipv6 !== undefined) {
    const ipv6 = proof.traffic.ipv6;
    if (!isObject(ipv6) || !['pass', 'not-run'].includes(ipv6.result)) {
      errors.push('traffic.ipv6 must be optional pass/not-run evidence');
    }
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

  if (!Array.isArray(proof.correlations) || proof.correlations.length < 4) {
    errors.push('correlations must include TCP/UDP/DNS/IPv4 tun traces');
  } else {
    for (const entry of proof.correlations) {
      if (entry.captureTrace?.ingress !== 'tun') {
        errors.push(`correlations.${entry.kind}.captureTrace.ingress must be tun`);
      }
      if (entry.sessionId !== entry.coreEvent?.sessionId || entry.traceId !== entry.coreEvent?.traceId) {
        errors.push(`correlations.${entry.kind} must share sessionId and traceId with coreEvent`);
      }
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
    'correlations',
    'failures'
  ]);
  assert.equal(schema.properties.device.additionalProperties, false);
  assert.equal(schema.properties.bundles.additionalProperties, false);
  assert.equal(schema.properties.traffic.additionalProperties, false);
  assert.equal(schema.properties.localEvidence.additionalProperties, false);
  assert.equal(schema.properties.lifecycle.additionalProperties, false);
  assert.equal(schema.properties.tun.additionalProperties, false);
  assert.equal(schema.properties.correlations.items.additionalProperties, false);
  assert.equal(schema.properties.correlations.items.properties.captureTrace.additionalProperties, false);
  assert.equal(schema.properties.correlations.items.properties.coreEvent.additionalProperties, false);

  assert.deepEqual(example, validProof);
  assert.deepEqual(validatePhase4Proof(validProof), { valid: true, errors: [] });
  assert.deepEqual(validatePhase4Proof(example), { valid: true, errors: [] });
});

test('Phase 4 proof validation rejects old tags, secrets, URLs, signing paths, and broken correlation invariants', () => {
  const cases = [
    ['wrong schema version', (proof) => { proof.schemaVersion = '1.0.0'; }, /schemaVersion/u],
    ['full URL leaked', (proof) => { proof.device.modelAlias = leakedUrlValue; }, /full URLs/u],
    ['signing path leaked', (proof) => { proof.lifecycle.stop.detail = leakedSigningPathValue; }, /signing material/u],
    ['secret field leaked', (proof) => { proof.device[leakedSecretKey] = 'abc'; }, /secret-bearing keys/u],
    ['serial-like field leaked', (proof) => { proof.device[leakedSerialKey] = 'ABC123'; }, /serial-like keys/u],
    ['probe bundle drifted to production', (proof) => { proof.bundles.probe.bundleName = proof.bundles.production.bundleName; }, /bundle names must differ/u],
    ['probe hap hash drifted to production', (proof) => { proof.bundles.probe.hapSha256 = proof.bundles.production.hapSha256; }, /HAP hashes must differ/u],
    ['local ingress broke', (proof) => { proof.localEvidence.http.ingress = 'tun'; }, /localEvidence\.http/u],
    ['capture ingress broke', (proof) => { proof.correlations[0].captureTrace.ingress = 'local-http'; }, /captureTrace\.ingress/u],
    ['trace correlation broke', (proof) => { proof.correlations[0].coreEvent.traceId = 'wrong'; }, /share sessionId and traceId/u]
  ];

  for (const [label, mutate, expected] of cases) {
    const proof = createValidPhase4Proof();
    mutate(proof);
    const validation = validatePhase4Proof(proof);
    assert.equal(validation.valid, false, label);
    assert.match(validation.errors.join('\n'), expected, label);
  }
});
