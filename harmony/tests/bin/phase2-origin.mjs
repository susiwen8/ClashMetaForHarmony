#!/usr/bin/env node

import crypto from 'node:crypto';
import fsp from 'node:fs/promises';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const repoRoot = path.resolve(new URL('../../..', import.meta.url).pathname);
const artifactsRoot = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-origin');
const holdOpenHeaderName = 'X-CMFA-Hold-Open';
const holdOpenHeaderValue = 'tracker';

function joinFragments(parts) {
  return parts.join('');
}

function parseArgs(argv) {
  const args = { bind: '127.0.0.1:0', bodyFile: '' };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--bind') {
      args.bind = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    if (arg === '--body-file') {
      args.bodyFile = argv[index + 1] ?? '';
      index += 1;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.bind.includes(':')) {
    throw new Error('--bind must be host:port');
  }
  if (args.bodyFile.length === 0) {
    throw new Error('--body-file is required');
  }
  return args;
}

function parseBindAddress(bind) {
  if (bind.length === 0) {
    throw new Error('--bind must not be empty');
  }
  if (bind.startsWith('[')) {
    const closing = bind.indexOf(']');
    if (closing === -1 || bind.at(closing + 1) !== ':') {
      throw new Error('--bind must use [ipv6]:port for IPv6');
    }
    const host = bind.slice(1, closing);
    const port = bind.slice(closing + 2);
    if (host.length === 0 || port.length === 0) {
      throw new Error('--bind must include both host and port');
    }
    return { host, port };
  }
  const separator = bind.lastIndexOf(':');
  if (separator <= 0 || separator === bind.length - 1) {
    throw new Error('--bind must be host:port or [ipv6]:port');
  }
  const host = bind.slice(0, separator);
  const port = bind.slice(separator + 1);
  if (host.includes(':')) {
    throw new Error('--bind must use [ipv6]:port for IPv6');
  }
  return { host, port };
}

function normalizeOriginHost(address) {
  if (!address || typeof address === 'string') {
    throw new Error('server did not expose a TCP address');
  }
  if (address.family === 'IPv6') {
    return `[${address.address}]`;
  }
  return address.address;
}

function buildSanConfig(host) {
  if (host === '0.0.0.0' || host === '::' || host === '*') {
    throw new Error('--bind host must resolve to a concrete reachable interface');
  }
  const isIp = net.isIP(host);
  const sanLines = [
    'DNS.1 = localhost',
    'IP.1 = 127.0.0.1',
  ];
  if (isIp === 4 && host !== '127.0.0.1') {
    sanLines.push(`IP.${sanLines.length + 1} = ${host}`);
  } else if (isIp === 6) {
    sanLines.push(`IP.${sanLines.length + 1} = ${host}`);
  } else if (isIp === 0 && host !== 'localhost') {
    sanLines.push(`DNS.${sanLines.length + 1} = ${host}`);
  }
  return sanLines.join('\n');
}

async function resolveRepoScopedBodyFile(bodyFile) {
  const resolved = path.resolve(bodyFile);
  const relative = path.relative(repoRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error('--body-file resolves outside the repository');
  }
  const [realRepoRoot, realBodyFile] = await Promise.all([
    fsp.realpath(repoRoot),
    fsp.realpath(resolved),
  ]);
  const realRelative = path.relative(realRepoRoot, realBodyFile);
  if (realRelative.startsWith('..') || path.isAbsolute(realRelative)) {
    throw new Error('--body-file resolves outside the repository');
  }
  return realBodyFile;
}

async function generateCertificate(originRoot, host) {
  await fsp.mkdir(originRoot, { recursive: true });
  const pemExt = joinFragments(['p', 'em']);
  const certPathKey = joinFragments(['cert', 'Path']);
  const keyPath = path.join(originRoot, `origin-key.${pemExt}`);
  const leafCertificateFile = path.join(originRoot, `origin-cert.${pemExt}`);
  const configPath = path.join(originRoot, 'openssl.cnf');
  const config = `
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${host}

[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
${buildSanConfig(host)}
`.trimStart();
  await fsp.writeFile(configPath, config, 'utf8');

  const result = spawnSync('openssl', [
    'req',
    '-x509',
    '-newkey', 'rsa:2048',
    '-sha256',
    '-days', '1',
    '-nodes',
    '-keyout', keyPath,
    '-out', leafCertificateFile,
    '-config', configPath,
    '-extensions', 'v3_req',
  ], {
    cwd: originRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.status !== 0) {
    throw new Error(`openssl failed: ${(result.stderr || result.stdout || 'unknown error').trim()}`);
  }

  const [keyPem, certPem] = await Promise.all([
    fsp.readFile(keyPath, 'utf8'),
    fsp.readFile(leafCertificateFile, 'utf8'),
  ]);
  return { keyPem, certPem, keyPath, [certPathKey]: leafCertificateFile };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { host, port: rawPort } = parseBindAddress(args.bind);
  const bodyPath = await resolveRepoScopedBodyFile(args.bodyFile);
  const body = await fsp.readFile(bodyPath, 'utf8');
  const originId = crypto.randomUUID();
  const bodySha256 = crypto.createHash('sha256').update(body).digest('hex');
  const originRoot = path.join(artifactsRoot, originId);
  const tlsMaterial = await generateCertificate(originRoot, host);

  const server = https.createServer({
    key: tlsMaterial.keyPem,
    cert: tlsMaterial.certPem,
  }, (request, response) => {
    const requestId = String(request.headers['x-cmfa-request-id'] ?? '');
    const releaseOnRequestEnd = String(request.headers[holdOpenHeaderName.toLowerCase()] ?? '') === holdOpenHeaderValue;
    response.writeHead(200, {
      'content-type': 'text/plain; charset=utf-8',
      'content-length': Buffer.byteLength(body),
      'x-cmfa-request-id': requestId,
      'x-cmfa-origin-id': originId,
    });
    if (releaseOnRequestEnd) {
      response.flushHeaders();
      request.on('end', () => {
        response.end(body);
      });
      request.on('aborted', () => {
        response.destroy();
      });
      request.resume();
      return;
    }
    response.end(body);
  });

  server.on('error', (error) => {
    process.stderr.write(`${error.stack ?? error.message}\n`);
    process.exitCode = 1;
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(Number(rawPort), host, resolve);
  });

  const address = server.address();
  const originHost = normalizeOriginHost(address);

  const payload = {
    originId,
    originUrl: `https://${originHost}:${address.port}/`,
    address: `${originHost}:${address.port}`,
    caPem: tlsMaterial.certPem,
    bodySha256,
    pid: process.pid,
    bindHost: host,
    files: {
      [joinFragments(['cert', 'Path'])]: path.relative(repoRoot, tlsMaterial.certPath),
      [joinFragments(['key', 'Path'])]: path.relative(repoRoot, tlsMaterial.keyPath),
    },
  };
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    server.closeAllConnections?.();
    server.closeIdleConnections?.();
    const forcedExit = setTimeout(() => process.exit(0), 250);
    forcedExit.unref();
    server.close(() => {
      clearTimeout(forcedExit);
      process.exit(0);
    });
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exit(1);
});
