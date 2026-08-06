#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const repoRoot = path.resolve(new URL('../../..', import.meta.url).pathname);
const artifactsRoot = path.join(repoRoot, 'harmony', 'artifacts', 'phase2-origin');

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
  const keyPath = path.join(originRoot, 'origin-key.pem');
  const certPath = path.join(originRoot, 'origin-cert.pem');
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
DNS.1 = localhost
IP.1 = 127.0.0.1
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
    '-out', certPath,
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
    fsp.readFile(certPath, 'utf8'),
  ]);
  return { keyPem, certPem, keyPath, certPath };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const [host, rawPort] = args.bind.split(':');
  const bodyPath = await resolveRepoScopedBodyFile(args.bodyFile);
  const body = await fsp.readFile(bodyPath, 'utf8');
  const originId = crypto.randomUUID();
  const bodySha256 = crypto.createHash('sha256').update(body).digest('hex');
  const originRoot = path.join(artifactsRoot, originId);
  const certificate = await generateCertificate(originRoot, host);

  const server = https.createServer({
    key: certificate.keyPem,
    cert: certificate.certPem,
  }, (request, response) => {
    const requestId = String(request.headers['x-cmfa-request-id'] ?? '');
    response.writeHead(200, {
      'content-type': 'text/plain; charset=utf-8',
      'content-length': Buffer.byteLength(body),
      'x-cmfa-request-id': requestId,
      'x-cmfa-origin-id': originId,
    });
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
  if (!address || typeof address === 'string') {
    throw new Error('server did not expose a TCP address');
  }

  const payload = {
    originId,
    originUrl: `https://${address.address}:${address.port}/`,
    address: `${address.address}:${address.port}`,
    caPem: certificate.certPem,
    bodySha256,
    pid: process.pid,
    files: {
      certPath: path.relative(repoRoot, certificate.certPath),
      keyPath: path.relative(repoRoot, certificate.keyPath),
    },
  };
  process.stdout.write(`${JSON.stringify(payload)}\n`);

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
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  process.exit(1);
});
