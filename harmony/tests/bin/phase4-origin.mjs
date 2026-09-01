#!/usr/bin/env node

import crypto from 'node:crypto';
import dgram from 'node:dgram';
import fs from 'node:fs/promises';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { spawnSync } from 'node:child_process';

const HARMONY_ROOT = path.resolve(new URL('../..', import.meta.url).pathname);
const ARTIFACTS_ROOT = path.join(HARMONY_ROOT, 'artifacts', 'phase4-origin');
const PROBE_RUN_HEADER = 'xcmfaproberunid';
const PROBE_SESSION_HEADER = 'xcmfaprobesessionid';
const PROBE_FLOW_HEADER = 'xcmfaprobeflowid';

export const OPAQUE_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
export const MAX_HEADER_BYTES = 8 * 1024;
export const MAX_UDP_BYTES = 1024;
const MAX_TCP_BYTES = 8 * 1024;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sha256Base64(value) {
  return crypto.createHash('sha256').update(value).digest('base64');
}

function assertOpaqueId(value, label) {
  if (!OPAQUE_ID_PATTERN.test(value ?? '')) {
    throw new Error(`${label} must be an opaque UUID`);
  }
}

function writeRecord(record) {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}

function buildCorrelationToken(protocol, runId, sessionId, flowId) {
  return `${protocol}|${runId}|${sessionId}|${flowId}`;
}

function parseCorrelationToken(raw, protocol) {
  const parts = `${raw ?? ''}`.split('|');
  if ((parts.length !== 4 && parts.length !== 5) || parts[0] !== protocol) {
    throw new Error(`expected ${protocol} correlation token`);
  }
  assertOpaqueId(parts[1], 'runId');
  assertOpaqueId(parts[2], 'sessionId');
  assertOpaqueId(parts[3], 'flowId');
  return {
    runId: parts[1],
    sessionId: parts[2],
    flowId: parts[3],
    marker: parts.length === 5 ? parts[4] : ''
  };
}

export function isPrivateLanAddress(value) {
  if (typeof value !== 'string') {
    return false;
  }
  const segments = value.trim().split('.');
  if (segments.length !== 4 || !segments.every((entry) => /^\d+$/u.test(entry))) {
    return false;
  }
  const octets = segments.map((entry) => Number.parseInt(entry, 10));
  if (octets.some((entry) => !Number.isInteger(entry) || entry < 0 || entry > 255)) {
    return false;
  }
  if (octets[0] === 10) {
    return true;
  }
  if (octets[0] === 192 && octets[1] === 168) {
    return true;
  }
  return octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31;
}

export function parseCliArgs(argv = process.argv.slice(2)) {
  const parsed = {
    bindAddress: '127.0.0.1',
    ipv6BindAddress: '',
    runId: '',
    lanProofRequired: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--bind-address') {
      parsed.bindAddress = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (option === '--run-id') {
      parsed.runId = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (option === '--ipv6-bind-address') {
      parsed.ipv6BindAddress = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (option === '--lan-proof') {
      parsed.lanProofRequired = true;
      continue;
    }
    throw new Error(`unknown argument: ${option}`);
  }

  if (parsed.bindAddress.length === 0) {
    throw new Error('bindAddress is required');
  }
  if (parsed.ipv6BindAddress.startsWith('[') || parsed.ipv6BindAddress.endsWith(']')) {
    throw new Error('ipv6 bindAddress must use a raw host literal without URL brackets');
  }
  assertOpaqueId(parsed.runId, 'runId');
  return parsed;
}

export function validateBindAddress(bindAddress, lanProofRequired, family = 'ipv4', deviceSubnetProof = false) {
  if (bindAddress === '0.0.0.0' || bindAddress === '::' || bindAddress === '*') {
    throw new Error(family === 'ipv6'
      ? 'Optional ipv6 branch must not bind a wildcard host'
      : 'LAN proof requires an explicit private lan ipv4 bind address');
  }
  if (family === 'ipv6') {
    if (bindAddress.length === 0) {
      return;
    }
    if (net.isIP(bindAddress) !== 6) {
      throw new Error('Optional ipv6 branch requires an explicit ipv6 host literal');
    }
    return;
  }
  const firstOctet = Number.parseInt(String(bindAddress).split('.')[0] ?? '', 10);
  const isExplicitUnicastIpv4 = net.isIP(bindAddress) === 4
    && firstOctet > 0 && firstOctet < 224 && firstOctet !== 127;
  if (lanProofRequired && !isPrivateLanAddress(bindAddress)
    && !(deviceSubnetProof && isExplicitUnicastIpv4)) {
    throw new Error('LAN proof requires an explicit private lan ipv4 bind address');
  }
}

async function generateCertificate(bindAddress, sessionId) {
  const sessionRoot = path.join(ARTIFACTS_ROOT, sessionId);
  await fs.mkdir(sessionRoot, { recursive: true });
  const primaryMaterialPath = path.join(sessionRoot, 'origin-primary-material');
  const secondaryMaterialPath = path.join(sessionRoot, 'origin-secondary-material');
  const configPath = path.join(sessionRoot, 'openssl.cnf');
  const sanLine = net.isIP(bindAddress) >= 4
    ? `IP.1 = ${bindAddress}`
    : 'DNS.1 = localhost';
  const config = `
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${bindAddress}

[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
${sanLine}
`.trimStart();
  await fs.writeFile(configPath, config, 'utf8');
  const result = spawnSync('openssl', [
    'req',
    '-x509',
    '-newkey', 'rsa:2048',
    '-sha256',
    '-days', '1',
    '-nodes',
    '-keyout', primaryMaterialPath,
    '-out', secondaryMaterialPath,
    '-config', configPath,
    '-extensions', 'v3_req'
  ], {
    cwd: sessionRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || 'openssl failed').trim());
  }
  const [keyPem, certPem] = await Promise.all([
    fs.readFile(primaryMaterialPath, 'utf8'),
    fs.readFile(secondaryMaterialPath, 'utf8')
  ]);
  const spkiDer = new crypto.X509Certificate(certPem).publicKey.export({ type: 'spki', format: 'der' });
  return {
    sessionRoot,
    keyPem,
    certPem,
    certificateSha256: sha256(certPem),
    publicKeyPinSha256: `sha256/${sha256Base64(spkiDer)}`
  };
}

function isDnsShaped(payload) {
  return Buffer.isBuffer(payload) && payload.byteLength >= 12;
}

function createHttpsBody({ runId, sessionId, flowId }) {
  return buildCorrelationToken('HTTPS', runId, sessionId, flowId);
}

function extractCorrelation(headers) {
  const runId = `${headers[PROBE_RUN_HEADER] ?? ''}`;
  const sessionId = `${headers[PROBE_SESSION_HEADER] ?? ''}`;
  const flowId = `${headers[PROBE_FLOW_HEADER] ?? ''}`;
  assertOpaqueId(runId, 'runId');
  assertOpaqueId(sessionId, 'sessionId');
  assertOpaqueId(flowId, 'flowId');
  return { runId, sessionId, flowId };
}

function parseTcpEnvelope(buffer) {
  return parseCorrelationToken(buffer.toString('utf8'), 'TCP');
}

function parseUdpPayload(buffer) {
  try {
    return parseCorrelationToken(buffer.toString('utf8'), 'UDP');
  } catch {
    return null;
  }
}

export async function startControlledOrigin({
  bindAddress,
  ipv6BindAddress = '',
  runId,
  lanProofRequired = false,
  deviceSubnetProof = false,
  emit = writeRecord
}) {
  validateBindAddress(bindAddress, lanProofRequired, 'ipv4', deviceSubnetProof);
  if (ipv6BindAddress.length > 0) {
    validateBindAddress(ipv6BindAddress, false, 'ipv6');
  }
  assertOpaqueId(runId, 'runId');
  const sessionId = crypto.randomUUID();
  const tlsMaterial = await generateCertificate(bindAddress, sessionId);
  const observations = [];
  const emitObservation = (record) => {
    if (record?.type === 'observation') {
      observations.push(record);
    }
    emit(record);
  };
  const baseResponseBody = createHttpsBody({
    runId,
    sessionId,
    flowId: crypto.randomUUID()
  });
  const responseBodySha256 = sha256(baseResponseBody);
  const closeActions = [];

  const httpsServer = https.createServer({
    key: tlsMaterial.keyPem,
    cert: tlsMaterial.certPem
  }, (request, response) => {
    try {
      const correlation = extractCorrelation(request.headers);
      const body = createHttpsBody(correlation);
      const record = {
        type: 'observation',
        protocol: 'https',
        runId: correlation.runId,
        sessionId: correlation.sessionId,
        flowId: correlation.flowId,
        statusCode: 200,
        requestHeaderBytes: JSON.stringify(request.headers).length,
        responseBodySha256: sha256(body),
        certificateSha256: tlsMaterial.certificateSha256
      };
      emitObservation(record);
      response.writeHead(200, {
        'content-type': 'application/json; charset=utf-8',
        'x-cmfa-probe-run-id': correlation.runId,
        'x-cmfa-probe-session-id': correlation.sessionId,
        'x-cmfa-probe-flow-id': correlation.flowId
      });
      response.end(body);
    } catch (error) {
      response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' });
      response.end((error?.message ?? 'invalid request').slice(0, 200));
    }
  });
  httpsServer.maxHeadersCount = 24;
  await new Promise((resolve, reject) => {
    httpsServer.once('error', reject);
    httpsServer.listen(0, bindAddress, () => {
      httpsServer.off('error', reject);
      resolve();
    });
  });
  closeActions.push(async () => {
    await new Promise((resolve) => httpsServer.close(() => resolve()));
  });
  closeActions.push(async () => {
    await fs.rm(tlsMaterial.sessionRoot, { recursive: true, force: true });
  });
  const httpsAddress = httpsServer.address();
  const httpsPort = typeof httpsAddress === 'object' && httpsAddress ? httpsAddress.port : 0;

  const tcpServer = net.createServer((socket) => {
    const chunks = [];
    let responded = false;
    const respondIfComplete = () => {
      if (responded) {
        return true;
      }
      const payload = Buffer.concat(chunks);
      try {
        const correlation = parseTcpEnvelope(payload);
        if (correlation.marker !== `cmfa-${correlation.flowId}`) {
          return false;
        }
        responded = true;
        emitObservation({
          type: 'observation',
          protocol: 'tcp',
          runId: correlation.runId,
          sessionId: correlation.sessionId,
          flowId: correlation.flowId,
          payloadSha256: sha256(payload),
          correlationHash: sha256(correlation.marker)
        });
        socket.end(payload);
        return true;
      } catch {
        return false;
      }
    };
    socket.on('data', (chunk) => {
      chunks.push(chunk);
      const size = chunks.reduce((total, entry) => total + entry.length, 0);
      if (size > MAX_TCP_BYTES) {
        socket.destroy(new Error('MAX_TCP_BYTES exceeded'));
        return;
      }
      respondIfComplete();
    });
    socket.on('end', () => {
      if (!respondIfComplete()) {
        socket.destroy();
      }
    });
  });
  await new Promise((resolve, reject) => {
    tcpServer.once('error', reject);
    tcpServer.listen(0, bindAddress, () => {
      tcpServer.off('error', reject);
      resolve();
    });
  });
  closeActions.push(async () => {
    await new Promise((resolve) => tcpServer.close(() => resolve()));
  });
  const tcpAddress = tcpServer.address();
  const tcpPort = typeof tcpAddress === 'object' && tcpAddress ? tcpAddress.port : 0;

  const udpServer = dgram.createSocket('udp4');
  udpServer.on('message', (message, remote) => {
    try {
      if (message.byteLength > MAX_UDP_BYTES) {
        return;
      }
      assertOpaqueId(remote.address ? runId : '', 'runId');
      const metadata = JSON.parse(message.subarray(0, 0).toString('utf8') || '{}');
      void metadata;
    } catch {
    }
    udpServer.send(message, remote.port, remote.address);
  });
  await new Promise((resolve, reject) => {
    udpServer.once('error', reject);
    udpServer.bind(0, bindAddress, () => {
      udpServer.off('error', reject);
      resolve();
    });
  });
  closeActions.push(async () => {
    udpServer.close();
  });
  const udpAddress = udpServer.address();
  const udpPort = typeof udpAddress === 'object' && udpAddress ? udpAddress.port : 0;

  emitObservation({
    type: 'started',
    runId,
    sessionId,
    host: bindAddress,
    httpsPort,
    tcpPort,
    udpPort,
    certificateSha256: tlsMaterial.certificateSha256,
    publicKeyPinSha256: tlsMaterial.publicKeyPinSha256,
    responseBodySha256
  });

  const onUdpMessage = (record) => {
    emitObservation(record);
  };
  udpServer.removeAllListeners('message');
  udpServer.on('message', (message, remote) => {
    try {
      const newline = message.indexOf(0x0a);
      const payload = newline > 0 ? message.subarray(newline + 1) : message;
      const correlation = parseUdpPayload(payload);
      onUdpMessage({
        type: 'observation',
        protocol: 'udp',
        runId: correlation?.runId ?? runId,
        sessionId: correlation?.sessionId ?? sessionId,
        flowId: correlation?.flowId ?? crypto.randomUUID(),
        payloadSha256: sha256(payload),
        dnsShaped: isDnsShaped(payload),
        correlationHash: correlation?.marker?.length > 0 ? sha256(correlation.marker) : ''
      });
      udpServer.send(payload, remote.port, remote.address);
    } catch {
    }
  });

  async function close() {
    if (controlled.ipv6?.result === 'pass') {
      await controlled.ipv6.close();
    }
    while (closeActions.length > 0) {
      const closer = closeActions.pop();
      await closer();
    }
  }

  const controlled = {
    sessionId,
    observations,
    publicKeyPinSha256: tlsMaterial.publicKeyPinSha256,
    pinnedCertificateHash: tlsMaterial.publicKeyPinSha256,
    https: {
      host: bindAddress,
      port: httpsPort,
      url: `https://${bindAddress}:${httpsPort}/phase4`,
      caPem: tlsMaterial.certPem
    },
    tcp: {
      host: bindAddress,
      port: tcpPort
    },
    udp: {
      host: bindAddress,
      port: udpPort
    },
    ipv6: null,
    close
  };

  if (ipv6BindAddress.length > 0) {
    controlled.ipv6 = await startOptionalIpv6Origin({ bindAddress: ipv6BindAddress, runId, emit: emitObservation });
  }

  const shutdown = async () => {
    await close();
    process.exitCode = 0;
  };
  process.once('SIGTERM', () => {
    void shutdown();
  });

  return controlled;
}

export async function sendHttpsProbe({ url, caPem, runId, sessionId, flowId }) {
  assertOpaqueId(runId, 'runId');
  assertOpaqueId(sessionId, 'sessionId');
  assertOpaqueId(flowId, 'flowId');
  return await new Promise((resolve, reject) => {
    const request = https.request(url, {
      method: 'GET',
      ca: caPem,
      rejectUnauthorized: true,
      headers: {
        'XCMFAProbeRunId': runId,
        'XCMFAProbeSessionId': sessionId,
        'XCMFAProbeFlowId': flowId
      }
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        body += chunk;
      });
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

export async function sendTcpProbe({ host, port, payload }) {
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

export async function sendUdpProbe({ host, port, payload, runId, sessionId, flowId }) {
  assertOpaqueId(runId, 'runId');
  assertOpaqueId(sessionId, 'sessionId');
  assertOpaqueId(flowId, 'flowId');
  if (!Buffer.isBuffer(payload)) {
    throw new Error('payload must be a Buffer');
  }
  if (payload.byteLength > MAX_UDP_BYTES) {
    throw new Error(`payload exceeds MAX_UDP_BYTES (${MAX_UDP_BYTES})`);
  }
  const socket = dgram.createSocket(net.isIP(host) === 6 ? 'udp6' : 'udp4');
  return await new Promise((resolve, reject) => {
    const timeoutId = setTimeout(() => {
      socket.close();
      reject(new Error('udp probe timed out'));
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

async function startOptionalIpv6Origin({ bindAddress, runId, emit }) {
  try {
    const sessionId = crypto.randomUUID();
    const tlsMaterial = await generateCertificate(bindAddress, sessionId);
    const closeActions = [];
    const httpsServer = https.createServer({
      key: tlsMaterial.keyPem,
      cert: tlsMaterial.certPem
    }, (request, response) => {
      try {
        const correlation = extractCorrelation(request.headers);
        const body = createHttpsBody(correlation);
        emit({
          type: 'observation',
          protocol: 'https',
          runId: correlation.runId,
          sessionId: correlation.sessionId,
          flowId: correlation.flowId,
          statusCode: 200,
          responseBodySha256: sha256(body),
          certificateSha256: tlsMaterial.certificateSha256,
          ipFamily: 'ipv6'
        });
        response.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'x-cmfa-probe-run-id': correlation.runId,
          'x-cmfa-probe-session-id': correlation.sessionId,
          'x-cmfa-probe-flow-id': correlation.flowId
        });
        response.end(body);
      } catch (error) {
        response.writeHead(400);
        response.end((error?.message ?? 'invalid request').slice(0, 200));
      }
    });
    await new Promise((resolve, reject) => {
      httpsServer.once('error', reject);
      httpsServer.listen(0, bindAddress, () => {
        httpsServer.off('error', reject);
        resolve();
      });
    });
    closeActions.push(async () => {
      await new Promise((resolve) => httpsServer.close(() => resolve()));
    });
    closeActions.push(async () => {
      await fs.rm(tlsMaterial.sessionRoot, { recursive: true, force: true });
    });
    const httpsAddress = httpsServer.address();
    const httpsPort = typeof httpsAddress === 'object' && httpsAddress ? httpsAddress.port : 0;

    const tcpServer = net.createServer((socket) => {
      const chunks = [];
      socket.on('data', (chunk) => {
        chunks.push(chunk);
      });
      socket.on('end', () => {
        const payload = Buffer.concat(chunks);
        try {
          const correlation = parseTcpEnvelope(payload);
          emit({
            type: 'observation',
            protocol: 'tcp',
            runId: correlation.runId,
            sessionId: correlation.sessionId,
            flowId: correlation.flowId,
            payloadSha256: sha256(payload),
            correlationHash: correlation.marker.length > 0 ? sha256(correlation.marker) : '',
            ipFamily: 'ipv6'
          });
          socket.end(payload);
        } catch {
          socket.destroy();
        }
      });
    });
    await new Promise((resolve, reject) => {
      tcpServer.once('error', reject);
      tcpServer.listen(0, bindAddress, () => {
        tcpServer.off('error', reject);
        resolve();
      });
    });
    closeActions.push(async () => {
      await new Promise((resolve) => tcpServer.close(() => resolve()));
    });
    const tcpAddress = tcpServer.address();
    const tcpPort = typeof tcpAddress === 'object' && tcpAddress ? tcpAddress.port : 0;

    const udpServer = dgram.createSocket('udp6');
    udpServer.on('message', (message, remote) => {
      try {
        const payload = message;
        const correlation = parseUdpPayload(payload);
        emit({
          type: 'observation',
          protocol: 'udp',
          runId: correlation?.runId ?? runId,
          sessionId: correlation?.sessionId ?? sessionId,
          flowId: correlation?.flowId ?? crypto.randomUUID(),
          payloadSha256: sha256(payload),
          correlationHash: correlation?.marker?.length > 0 ? sha256(correlation.marker) : '',
          dnsShaped: isDnsShaped(payload),
          ipFamily: 'ipv6'
        });
        udpServer.send(payload, remote.port, remote.address);
      } catch {
      }
    });
    await new Promise((resolve, reject) => {
      udpServer.once('error', reject);
      udpServer.bind(0, bindAddress, () => {
        udpServer.off('error', reject);
        resolve();
      });
    });
    closeActions.push(async () => {
      udpServer.close();
    });
    const udpAddress = udpServer.address();
    const udpPort = typeof udpAddress === 'object' && udpAddress ? udpAddress.port : 0;

    return {
      result: 'pass',
      https: {
        host: bindAddress,
        port: httpsPort,
        url: `https://[${bindAddress}]:${httpsPort}/phase4`,
        caPem: tlsMaterial.certPem
      },
      tcp: {
        host: bindAddress,
        port: tcpPort
      },
      udp: {
        host: bindAddress,
        port: udpPort
      },
      publicKeyPinSha256: tlsMaterial.publicKeyPinSha256,
      async close() {
        while (closeActions.length > 0) {
          const closer = closeActions.pop();
          await closer();
        }
      }
    };
  } catch (error) {
    if (['EAFNOSUPPORT', 'EADDRNOTAVAIL', 'EPERM'].includes(error?.code ?? '')) {
      return {
        result: 'not-run',
        reason: `ipv6-unavailable:${error.code}`
      };
    }
    throw error;
  }
}

async function main() {
  const parsed = parseCliArgs();
  const controlled = await startControlledOrigin(parsed);
  const keepAlive = setInterval(() => {}, 60_000);
  const shutdown = async () => {
    clearInterval(keepAlive);
    await controlled.close();
  };
  process.once('SIGINT', () => {
    void shutdown();
  });
  process.once('SIGTERM', () => {
    void shutdown();
  });
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch((error) => {
    process.stderr.write(`${error?.message ?? error}\n`);
    process.exitCode = 1;
  });
}
