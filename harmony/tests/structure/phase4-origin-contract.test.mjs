import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dgram from 'node:dgram';
import fs from 'node:fs/promises';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const modulePath = new URL('../bin/phase4-origin.mjs', import.meta.url);
const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const PROBE_MODELS_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'src', 'main', 'ets', 'probe', 'ProbeModels.ets');
const DIRECT_PROBE_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'src', 'main', 'ets', 'probe', 'DirectTrafficProbe.ets');

function uuid() {
  return crypto.randomUUID();
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function buildToken(protocol, runId, sessionId, flowId) {
  return `${protocol}|${runId}|${sessionId}|${flowId}`;
}

async function makeDnsShapedQuery() {
  return Buffer.from([
    0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x07, 0x65, 0x78, 0x61,
    0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d,
    0x00, 0x00, 0x01, 0x00, 0x01
  ]);
}

async function loadTask10WireContract() {
  const [probeModelsSource, directProbeSource] = await Promise.all([
    fs.readFile(PROBE_MODELS_PATH, 'utf8'),
    fs.readFile(DIRECT_PROBE_PATH, 'utf8')
  ]);
  const runHeader = probeModelsSource.match(/PROBE_HTTP_HEADER_RUN_ID:\s*string\s*=\s*'([^']+)'/u)?.[1];
  const sessionHeader = probeModelsSource.match(/PROBE_HTTP_HEADER_SESSION_ID:\s*string\s*=\s*'([^']+)'/u)?.[1];
  const flowHeader = probeModelsSource.match(/PROBE_HTTP_HEADER_FLOW_ID:\s*string\s*=\s*'([^']+)'/u)?.[1];
  assert.equal(runHeader, 'XCMFAProbeRunId');
  assert.equal(sessionHeader, 'XCMFAProbeSessionId');
  assert.equal(flowHeader, 'XCMFAProbeFlowId');
  assert.match(directProbeSource, /buildHttpsExpectedBody[\s\S]*buildCorrelationToken\('HTTPS'/u);
  assert.match(directProbeSource, /buildTcpExpectedPayload[\s\S]*buildCorrelationToken\('TCP'/u);
  assert.match(directProbeSource, /buildUdpExpectedPayload[\s\S]*buildCorrelationToken\('UDP'/u);
  return {
    runHeader,
    sessionHeader,
    flowHeader,
    buildHttpsBody: (runId, sessionId, flowId) => buildToken('HTTPS', runId, sessionId, flowId),
    buildTcpPayload: (runId, sessionId, flowId) => Buffer.from(`${buildToken('TCP', runId, sessionId, flowId)}|cmfa-${flowId}`, 'utf8'),
    buildUdpPayload: (runId, sessionId, flowId) => Buffer.from(`${buildToken('UDP', runId, sessionId, flowId)}|cmfa-${flowId}`, 'utf8')
  };
}

async function sendRawHttps({ url, caPem, headerNames, runId, sessionId, flowId }) {
  return await new Promise((resolve, reject) => {
    const request = https.request(url, {
      method: 'GET',
      ca: caPem,
      rejectUnauthorized: true,
      headers: {
        [headerNames.runHeader]: runId,
        [headerNames.sessionHeader]: sessionId,
        [headerNames.flowHeader]: flowId
      }
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        resolve({
          statusCode: response.statusCode ?? 0,
          headers: response.headers,
          body
        });
      });
    });
    request.once('error', reject);
    request.end();
  });
}

async function sendRawTcp({ host, port, payload }) {
  return await new Promise((resolve, reject) => {
    const client = net.createConnection({ host, port }, () => {
      client.end(payload);
    });
    const chunks = [];
    client.on('data', (chunk) => {
      chunks.push(chunk);
    });
    client.once('error', reject);
    client.on('end', () => {
      resolve(Buffer.concat(chunks));
    });
  });
}

async function sendRawTcpWithoutHalfClose({ host, port, payload }) {
  return await new Promise((resolve, reject) => {
    const client = net.createConnection({ host, port }, () => {
      client.write(payload);
    });
    const chunks = [];
    const timeoutId = setTimeout(() => {
      client.destroy();
      reject(new Error('tcp echo timed out before client half-close'));
    }, 1000);
    client.on('data', (chunk) => {
      chunks.push(chunk);
      if (Buffer.concat(chunks).length >= payload.length) {
        clearTimeout(timeoutId);
        client.end();
        resolve(Buffer.concat(chunks));
      }
    });
    client.once('error', (error) => {
      clearTimeout(timeoutId);
      reject(error);
    });
  });
}

async function sendRawUdp({ host, port, payload }) {
  const socket = dgram.createSocket(net.isIP(host) === 6 ? 'udp6' : 'udp4');
  return await new Promise((resolve, reject) => {
    const timeoutId = setTimeout(() => {
      socket.close();
      reject(new Error('udp timeout'));
    }, 5000);
    socket.once('message', (message) => {
      clearTimeout(timeoutId);
      socket.close();
      resolve(message);
    });
    socket.once('error', (error) => {
      clearTimeout(timeoutId);
      socket.close();
      reject(error);
    });
    socket.send(payload, port, host);
  });
}

test('phase4 origin exports a live controlled origin with exact HTTPS/TCP/UDP correlation and sanitized observations', async () => {
  const origin = await import(modulePath);
  const observations = [];
  const runId = uuid();
  const sessionId = uuid();
  const flowIds = {
    https: uuid(),
    tcp: uuid(),
    udp: uuid()
  };

  const controlled = await origin.startControlledOrigin({
    bindAddress: '127.0.0.1',
    runId,
    emit(record) {
      observations.push(record);
    }
  });

  try {
    assert.equal(observations.length, 1);
    const started = observations[0];
    assert.equal(started.type, 'started');
    assert.equal(started.runId, runId);
    assert.equal(started.host, '127.0.0.1');
    assert.match(started.sessionId, origin.OPAQUE_ID_PATTERN);
    assert.match(started.certificateSha256, /^[a-f0-9]{64}$/u);
    assert.match(started.publicKeyPinSha256, /^sha256\/[0-9A-Za-z+/=]+$/u);
    assert.match(started.responseBodySha256, /^[a-f0-9]{64}$/u);
    assert.equal(typeof started.privateKeyPem, 'undefined');
    assert.equal(typeof started.privateKey, 'undefined');

    const httpsResult = await origin.sendHttpsProbe({
      url: controlled.https.url,
      caPem: controlled.https.caPem,
      runId,
      sessionId,
      flowId: flowIds.https
    });
    assert.equal(httpsResult.statusCode, 200);
    assert.equal(httpsResult.headers['x-cmfa-probe-run-id'], runId);
    assert.equal(httpsResult.headers['x-cmfa-probe-session-id'], sessionId);
    assert.equal(httpsResult.headers['x-cmfa-probe-flow-id'], flowIds.https);
    assert.equal(httpsResult.body, buildToken('HTTPS', runId, sessionId, flowIds.https));

    const tcpPayload = Buffer.from(`${buildToken('TCP', runId, sessionId, flowIds.tcp)}|cmfa-${flowIds.tcp}`, 'utf8');
    const tcpEcho = await origin.sendTcpProbe({
      port: controlled.tcp.port,
      host: controlled.tcp.host,
      payload: tcpPayload
    });
    assert.deepEqual(tcpEcho, tcpPayload);

    const udpPayload = Buffer.from(`${buildToken('UDP', runId, sessionId, flowIds.udp)}|cmfa-${flowIds.udp}`, 'utf8');
    const udpEcho = await origin.sendUdpProbe({
      port: controlled.udp.port,
      host: controlled.udp.host,
      payload: udpPayload,
      runId,
      sessionId,
      flowId: flowIds.udp
    });
    assert.deepEqual(udpEcho, udpPayload);

    assert.equal(observations.length, 4);
    const [_, httpsRecord, tcpRecord, udpRecord] = observations;
    assert.equal(httpsRecord.protocol, 'https');
    assert.equal(httpsRecord.runId, runId);
    assert.equal(httpsRecord.sessionId, sessionId);
    assert.equal(httpsRecord.flowId, flowIds.https);
    assert.equal(httpsRecord.statusCode, 200);
    assert.equal(httpsRecord.responseBodySha256, sha256(httpsResult.body));
    assert.equal(tcpRecord.protocol, 'tcp');
    assert.equal(tcpRecord.payloadSha256, sha256(tcpPayload));
    assert.equal(udpRecord.protocol, 'udp');
    assert.equal(udpRecord.payloadSha256, sha256(udpPayload));
    assert.equal(udpRecord.dnsShaped, true);

    const dnsPayload = await makeDnsShapedQuery();
    const dnsEcho = await origin.sendUdpProbe({
      port: controlled.udp.port,
      host: controlled.udp.host,
      payload: dnsPayload,
      runId,
      sessionId,
      flowId: uuid()
    });
    assert.deepEqual(dnsEcho, dnsPayload);
  } finally {
    await controlled.close();
  }
});

test('phase4 origin rejects LAN-only proof on wildcard, loopback-only, malformed IDs, and oversized UDP payloads', async () => {
  const origin = await import(modulePath);

  await assert.rejects(
    origin.startControlledOrigin({ bindAddress: '0.0.0.0', runId: uuid(), lanProofRequired: true }),
    /private lan ipv4/u
  );
  await assert.rejects(
    origin.startControlledOrigin({ bindAddress: '127.0.0.1', runId: uuid(), lanProofRequired: true }),
    /private lan ipv4/u
  );
  await assert.rejects(
    origin.startControlledOrigin({ bindAddress: '127.0.0.1', runId: 'not-a-uuid' }),
    /runId/u
  );

  const controlled = await origin.startControlledOrigin({ bindAddress: '127.0.0.1', runId: uuid() });
  try {
    await assert.rejects(
      origin.sendHttpsProbe({
        url: controlled.https.url,
        caPem: controlled.https.caPem,
        runId: uuid(),
        sessionId: 'bad',
        flowId: uuid()
      }),
      /sessionId/u
    );

    const oversize = Buffer.alloc(origin.MAX_UDP_BYTES + 1, 0xaa);
    await assert.rejects(
      origin.sendUdpProbe({
        port: controlled.udp.port,
        host: controlled.udp.host,
        payload: oversize,
        runId: uuid(),
        sessionId: uuid(),
        flowId: uuid()
      }),
      /MAX_UDP_BYTES/u
    );
  } finally {
    await controlled.close();
  }
});

test('phase4 origin echoes a complete TCP correlation token before the client half-closes', async () => {
  const origin = await import(modulePath);
  const runId = uuid();
  const controlled = await origin.startControlledOrigin({ bindAddress: '127.0.0.1', runId });
  try {
    const sessionId = uuid();
    const flowId = uuid();
    const payload = Buffer.from(`${buildToken('TCP', runId, sessionId, flowId)}|cmfa-${flowId}`, 'utf8');
    assert.deepEqual(await sendRawTcpWithoutHalfClose({
      host: controlled.tcp.host,
      port: controlled.tcp.port,
      payload
    }), payload);
  } finally {
    await controlled.close();
  }
});

test('phase4 origin helpers expose predictable CLI parsing and LAN address rules', async () => {
  const origin = await import(modulePath);

  assert.deepEqual(origin.parseCliArgs([
    '--bind-address', '192.168.1.12',
    '--run-id', uuid(),
    '--lan-proof'
  ]).lanProofRequired, true);
  assert.equal(origin.isPrivateLanAddress('192.168.1.12'), true);
  assert.equal(origin.isPrivateLanAddress('10.0.0.4'), true);
  assert.equal(origin.isPrivateLanAddress('172.20.0.4'), true);
  assert.equal(origin.isPrivateLanAddress('8.8.8.8'), false);
  assert.equal(origin.isPrivateLanAddress('127.0.0.1'), false);
  assert.equal(origin.isPrivateLanAddress('::1'), false);
  assert.equal(origin.isPrivateLanAddress('fd00::1'), false);
  assert.doesNotThrow(() => origin.validateBindAddress('30.231.220.115', true, 'ipv4', true));
  assert.throws(() => origin.validateBindAddress('30.231.220.115', true, 'ipv4', false), /private lan ipv4/u);
  assert.throws(() => origin.validateBindAddress('0.0.0.0', true, 'ipv4', true), /wildcard|explicit/u);
});

test('phase4 origin optionally serves an explicit ipv6 branch or reports a clean not-run capability', async () => {
  const origin = await import(modulePath);
  const runId = uuid();
  const controlled = await origin.startControlledOrigin({
    bindAddress: '127.0.0.1',
    ipv6BindAddress: '::1',
    runId
  });

  try {
    assert.ok(controlled.ipv6);
    if (controlled.ipv6.result === 'pass') {
      const httpsResult = await origin.sendHttpsProbe({
        url: controlled.ipv6.https.url,
        caPem: controlled.ipv6.https.caPem,
        runId,
        sessionId: uuid(),
        flowId: uuid()
      });
      assert.equal(httpsResult.statusCode, 200);

      const tcpPayload = Buffer.from(buildToken('TCP', runId, uuid(), uuid()), 'utf8');
      const tcpEcho = await origin.sendTcpProbe({
        port: controlled.ipv6.tcp.port,
        host: controlled.ipv6.tcp.host,
        payload: tcpPayload
      });
      assert.deepEqual(tcpEcho, tcpPayload);
    } else {
      assert.equal(controlled.ipv6.result, 'not-run');
      assert.match(controlled.ipv6.reason, /ipv6/i);
    }
  } finally {
    await controlled.close();
  }
});

test('phase4 origin ipv6 helpers reject wildcard and malformed bracket semantics', async () => {
  const origin = await import(modulePath);
  await assert.rejects(
    origin.startControlledOrigin({
      bindAddress: '127.0.0.1',
      ipv6BindAddress: '::',
      runId: uuid()
    }),
    /wildcard|ipv6/u
  );
  await assert.rejects(
    Promise.resolve().then(() => origin.parseCliArgs(['--bind-address', '127.0.0.1', '--ipv6-bind-address', '[::1]', '--run-id', uuid()])),
    /ipv6/u
  );
});

test('phase4 origin live traffic matches the actual Task10 probe header and token contract, and cleans temp material on close', async () => {
  const origin = await import(modulePath);
  const contract = await loadTask10WireContract();
  const runId = uuid();
  const sessionId = uuid();
  const flowId = uuid();
  const controlled = await origin.startControlledOrigin({
    bindAddress: '127.0.0.1',
    runId
  });

  const materialPath = path.join(HARMONY_ROOT, 'artifacts', 'phase4-origin', controlled.sessionId);
  try {
    const httpsResult = await sendRawHttps({
      url: controlled.https.url,
      caPem: controlled.https.caPem,
      headerNames: contract,
      runId,
      sessionId,
      flowId
    });
    assert.equal(httpsResult.statusCode, 200);
    assert.equal(httpsResult.body, contract.buildHttpsBody(runId, sessionId, flowId));
    assert.equal(httpsResult.headers['x-cmfa-probe-run-id'], runId);

    const tcpPayload = contract.buildTcpPayload(runId, sessionId, flowId);
    assert.deepEqual(await sendRawTcp({
      host: controlled.tcp.host,
      port: controlled.tcp.port,
      payload: tcpPayload
    }), tcpPayload);

    const udpPayload = contract.buildUdpPayload(runId, sessionId, flowId);
    assert.deepEqual(await sendRawUdp({
      host: controlled.udp.host,
      port: controlled.udp.port,
      payload: udpPayload
    }), udpPayload);

    const dnsPayload = await makeDnsShapedQuery();
    assert.deepEqual(await sendRawUdp({
      host: controlled.udp.host,
      port: controlled.udp.port,
      payload: dnsPayload
    }), dnsPayload);

    assert.match(controlled.publicKeyPinSha256, /^sha256\/[0-9A-Za-z+/=]+$/u);
    await fs.access(materialPath);
  } finally {
    await controlled.close();
  }

  await assert.rejects(fs.access(materialPath));
});
