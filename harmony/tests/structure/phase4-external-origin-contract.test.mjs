import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const MODULE_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'phase4-external-origin.mjs');
const MODULE_URL = pathToFileURL(MODULE_PATH).href;

const FIXED_ERROR_CODE = 'EXTERNAL_ORIGIN_CONFIG_INVALID';
const FIXED_ERROR_MESSAGE = 'Phase 4 external origin configuration was invalid.';
const FIXED_ERROR_DETAIL = 'Phase 4 external origin must use canonical public IPv4 endpoints and exact integer ports.';
const FIXED_PROVIDER_ALIAS = 'public-echo-v1';

const VALID_INPUT = Object.freeze({
  hostIpv4: '52.43.121.77',
  tcpHostIpv4: '223.5.5.5',
  tcpPort: 80,
  udpPort: 10001,
  dnsPort: 10001
});

async function importHelper() {
  return await import(MODULE_URL);
}

function assertFixedError(error) {
  assert.equal(error?.code, FIXED_ERROR_CODE);
  assert.equal(error?.message, FIXED_ERROR_MESSAGE);
  assert.equal(error?.detail, FIXED_ERROR_DETAIL);
  assert.equal(JSON.stringify(error).includes('52.43.121.77'), false);
  assert.equal(JSON.stringify(error).includes('223.5.5.5'), false);
  assert.equal(JSON.stringify(error).includes('80'), false);
  assert.equal(JSON.stringify(error).includes('10001'), false);
  return true;
}

test('phase4 external origin helper exports the minimal public API', async () => {
  const helper = await importHelper();
  assert.equal(typeof helper.normalizePhase4ExternalOrigin, 'function');
  assert.equal(typeof helper.createDefaultPhase4ExternalOrigin, 'function');
  assert.equal(typeof helper.describePhase4ExternalOrigin, 'function');
  assert.deepEqual(
    Object.keys(helper).sort(),
    ['createDefaultPhase4ExternalOrigin', 'describePhase4ExternalOrigin', 'normalizePhase4ExternalOrigin'].sort()
  );
});

test('phase4 external origin normalizer accepts only the exact input shape and returns a frozen copy', async () => {
  const helper = await importHelper();
  const normalized = helper.normalizePhase4ExternalOrigin(VALID_INPUT);

  assert.deepEqual(normalized, VALID_INPUT);
  assert.notEqual(normalized, VALID_INPUT);
  assert.equal(Object.isFrozen(normalized), true);
  assert.deepEqual(Object.keys(normalized), ['hostIpv4', 'tcpHostIpv4', 'tcpPort', 'udpPort', 'dnsPort']);

  const mutableInput = {
    hostIpv4: '52.43.121.77',
    tcpHostIpv4: '223.5.5.5',
    tcpPort: 80,
    udpPort: 10001,
    dnsPort: 10001
  };
  const isolated = helper.normalizePhase4ExternalOrigin(mutableInput);
  mutableInput.hostIpv4 = '8.8.8.8';
  mutableInput.tcpHostIpv4 = '1.1.1.1';
  mutableInput.tcpPort = 1;
  assert.deepEqual(isolated, VALID_INPUT);
  assert.throws(() => {
    isolated.tcpPort = 7;
  });
});

test('phase4 external origin default factory returns the reviewed provider without exposing coordinates in diagnostics', async () => {
  const helper = await importHelper();
  const normalized = helper.createDefaultPhase4ExternalOrigin();
  const description = helper.describePhase4ExternalOrigin(normalized);

  assert.deepEqual(normalized, VALID_INPUT);
  assert.equal(Object.isFrozen(normalized), true);
  assert.deepEqual(description, {
    provider: FIXED_PROVIDER_ALIAS,
    kind: 'external-echo-origin'
  });
  const serialized = JSON.stringify(description);
  assert.equal(serialized.includes('52.43.121.77'), false);
  assert.equal(serialized.includes('223.5.5.5'), false);
  assert.equal(serialized.includes('80'), false);
  assert.equal(serialized.includes('10001'), false);
});

test('phase4 external origin normalizer rejects missing and extra fields with fixed redacted errors', async () => {
  const helper = await importHelper();

  for (const input of [
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 80, udpPort: 10001 },
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 80, udpPort: 10001, dnsPort: 10001, provider: 'leak' }
  ]) {
    assert.throws(() => {
      helper.normalizePhase4ExternalOrigin(input);
    }, assertFixedError);
  }
});

test('phase4 external origin normalizer rejects hostname ipv6 noncanonical and non-unicast ipv4 values for both host fields', async () => {
  const helper = await importHelper();

  for (const invalidHost of [
    'echo.example.com',
    '2001:db8::1',
    '052.43.121.77',
    '10.0.0.1',
    '10.255.255.254',
    '172.16.0.1',
    '172.31.255.254',
    '192.168.0.1',
    '192.168.255.254',
    '100.64.0.1',
    '100.127.255.254',
    '169.254.0.1',
    '169.254.255.254',
    '192.0.2.1',
    '198.51.100.1',
    '203.0.113.1',
    '198.18.0.1',
    '198.19.255.254',
    '127.0.0.1',
    '224.0.0.1',
    '0.0.0.0'
  ]) {
    assert.throws(() => {
      helper.normalizePhase4ExternalOrigin({
        hostIpv4: invalidHost,
        tcpHostIpv4: '223.5.5.5',
        tcpPort: 80,
        udpPort: 10001,
        dnsPort: 10001
      });
    }, assertFixedError);
    assert.throws(() => {
      helper.normalizePhase4ExternalOrigin({
        hostIpv4: '52.43.121.77',
        tcpHostIpv4: invalidHost,
        tcpPort: 80,
        udpPort: 10001,
        dnsPort: 10001
      });
    }, assertFixedError);
  }
});

test('phase4 external origin normalizer rejects non-integer and out-of-range ports with fixed redacted errors', async () => {
  const helper = await importHelper();

  for (const input of [
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 0, udpPort: 10001, dnsPort: 10001 },
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 65536, udpPort: 10001, dnsPort: 10001 },
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 80.5, udpPort: 10001, dnsPort: 10001 },
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: '80', udpPort: 10001, dnsPort: 10001 },
    { hostIpv4: '52.43.121.77', tcpHostIpv4: '223.5.5.5', tcpPort: 80, udpPort: 10001, dnsPort: -1 }
  ]) {
    assert.throws(() => {
      helper.normalizePhase4ExternalOrigin(input);
    }, assertFixedError);
  }
});

test('phase4 external origin normalizer accepts canonical global-unicast boundary samples including .0 and .255', async () => {
  const helper = await importHelper();

  for (const input of [
    { hostIpv4: '11.22.33.0', tcpHostIpv4: '22.33.44.0', tcpPort: 7, udpPort: 53, dnsPort: 65535 },
    { hostIpv4: '11.22.33.255', tcpHostIpv4: '22.33.44.255', tcpPort: 1, udpPort: 123, dnsPort: 4096 },
    { hostIpv4: '1.0.0.0', tcpHostIpv4: '8.8.8.8', tcpPort: 80, udpPort: 443, dnsPort: 53 },
    { hostIpv4: '223.255.255.255', tcpHostIpv4: '223.255.255.254', tcpPort: 8080, udpPort: 10001, dnsPort: 10001 }
  ]) {
    const normalized = helper.normalizePhase4ExternalOrigin(input);
    assert.deepEqual(normalized, input);
    assert.equal(Object.isFrozen(normalized), true);
  }
});
