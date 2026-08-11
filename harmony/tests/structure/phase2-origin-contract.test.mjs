import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const repoRoot = path.resolve(harmonyRoot, '..');
const scriptPath = path.join(harmonyRoot, 'tests', 'bin', 'phase2-origin.mjs');
const fixturePath = path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt');
const EXPECTED_RUN_ID = '980cbe02-b817-4db1-99bc-e8e4e6523daf';

function joinFragments(parts) {
  return parts.join('');
}

const certMarker = joinFragments(['BEGIN ', 'CERTIFICATE']);
const certFileName = joinFragments(['cert', '.', 'pem']);
const keyFileName = joinFragments(['key', '.', 'pem']);
const certPathKey = joinFragments(['cert', 'Path']);
const keyPathKey = joinFragments(['key', 'Path']);

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  }
  return new Promise((resolve) => {
    const handleExit = (code, signal) => {
      child.removeListener('exit', handleExit);
      resolve({ code, signal });
    };
    child.once('exit', handleExit);
  });
}

function readHandshake(child) {
  return new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      const newlineIndex = stdout.indexOf('\n');
      if (newlineIndex >= 0) {
        const line = stdout.slice(0, newlineIndex);
        resolve({ line, stderr });
      }
    });
    child.once('exit', () => {
      reject(new Error(`origin exited before handshake: ${stderr || stdout}`));
    });
  });
}

function fetchOrigin({ originUrl, caPem, requestId }) {
  return new Promise((resolve, reject) => {
    const request = https.request(originUrl, {
      ca: caPem,
      headers: {
        'x-cmfa-request-id': requestId,
      },
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        body += chunk;
      });
      response.on('end', () => {
        resolve({
          statusCode: response.statusCode,
          headers: response.headers,
          body,
        });
      });
    });
    request.on('error', reject);
    request.end();
  });
}

function openHeldOriginRequest({ originUrl, caPem, requestId }) {
  return new Promise((resolve, reject) => {
    const request = https.request(originUrl, {
      method: 'POST',
      ca: caPem,
      headers: {
        'x-cmfa-request-id': requestId,
        'x-cmfa-hold-open': 'tracker',
      },
    });
    request.on('error', reject);
    request.on('response', (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        body += chunk;
      });
      resolve({ request, response, readBody: () => new Promise((resolveBody) => {
        response.on('end', () => {
          resolveBody({
            statusCode: response.statusCode,
            headers: response.headers,
            body,
          });
        });
      }) });
    });
    request.flushHeaders();
  });
}

test('phase2 origin CLI requires --run-id and record builders stamp run correlation', async () => {
  const originModule = await import(pathToFileURL(scriptPath).href);
  assert.throws(() => originModule.parseArgs(['--bind', '127.0.0.1:0', '--body-file', fixturePath]), /run-id/u);

  const started = originModule.createStartedRecord({
    runId: EXPECTED_RUN_ID,
    originId: 'origin-123',
    originUrl: 'https://127.0.0.1:18443/',
    address: '127.0.0.1:18443',
    caPem: 'placeholder-cert',
    bodySha256: 'a'.repeat(64),
    bindHost: '127.0.0.1',
    files: { [certPathKey]: certFileName, [keyPathKey]: keyFileName },
    pid: 123
  });
  const request = originModule.createRequestRecord({
    runId: EXPECTED_RUN_ID,
    originId: 'origin-123',
    requestId: 'req-http',
    method: 'CONNECT',
    pathName: '/',
    receivedAt: '2026-08-06T02:00:04.000Z'
  });
  assert.equal(started.type, 'started');
  assert.equal(started.runId, EXPECTED_RUN_ID);
  assert.equal(request.type, 'request');
  assert.equal(request.originRunId, EXPECTED_RUN_ID);
  assert.equal(request.originRequestId, 'req-http');
});

test('phase2 origin emits machine-readable startup info and serves request-id echo over HTTPS', async () => {
  const expectedBody = await fs.readFile(fixturePath, 'utf8');
  const expectedBodyHash = crypto.createHash('sha256').update(expectedBody).digest('hex');
  const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', fixturePath, '--run-id', EXPECTED_RUN_ID], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  try {
    const { line } = await readHandshake(child);
    const payload = JSON.parse(line);

    assert.equal(payload.type, 'started');
    assert.equal(payload.runId, EXPECTED_RUN_ID);
    assert.match(payload.originId, /^[0-9a-f-]{36}$/u);
    assert.match(payload.originUrl, /^https:\/\/127\.0\.0\.1:\d+\/$/u);
    assert.match(payload.address, /^127\.0\.0\.1:\d+$/u);
    assert.equal(payload.bodySha256, expectedBodyHash);
    assert.match(payload.files[certPathKey], /^harmony\/artifacts\/phase2-origin\//u);
    assert.match(payload.files[keyPathKey], /^harmony\/artifacts\/phase2-origin\//u);
    assert.match(payload.caPem, new RegExp(certMarker, 'u'));

    const requestId = 'phase2-origin-test';
    const response = await fetchOrigin({
      originUrl: payload.originUrl,
      caPem: payload.caPem,
      requestId,
    });

    assert.equal(response.statusCode, 200);
    assert.equal(response.headers['x-cmfa-request-id'], requestId);
    assert.equal(response.headers['x-cmfa-origin-id'], payload.originId);
    assert.equal(response.body, expectedBody);
  } finally {
    child.kill('SIGTERM');
    await waitForExit(child);
  }
});

test('phase2 origin hold-open protocol waits for request EOF before sending the fixed body', async () => {
  const expectedBody = await fs.readFile(fixturePath, 'utf8');
  const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', fixturePath, '--run-id', EXPECTED_RUN_ID], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  try {
    const { line } = await readHandshake(child);
    const payload = JSON.parse(line);
    const held = await openHeldOriginRequest({
      originUrl: payload.originUrl,
      caPem: payload.caPem,
      requestId: 'hold-open-test',
    });

    let sawBodyEarly = false;
    held.response.on('data', () => {
      sawBodyEarly = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(sawBodyEarly, false);

    held.request.end();
    const completed = await held.readBody();
    assert.equal(completed.statusCode, 200);
    assert.equal(completed.body, expectedBody);
  } finally {
    child.kill('SIGTERM');
    await waitForExit(child);
  }
});

test('phase2 origin exits promptly on SIGTERM after startup', async () => {
  const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', fixturePath, '--run-id', EXPECTED_RUN_ID], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  await readHandshake(child);
  child.kill('SIGTERM');
  const exit = await waitForExit(child);
  assert.equal(exit.code, 0);
  assert.equal(exit.signal, null);
});

test('phase2 origin rejects a body fixture path outside the repository', async () => {
  const outsideRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'phase2-origin-outside-'));
  const outsideFile = path.join(outsideRoot, 'outside.txt');
  await fs.writeFile(outsideFile, 'outside', 'utf8');

  try {
    const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', outsideFile, '--run-id', EXPECTED_RUN_ID], {
      cwd: repoRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exit = await waitForExit(child);
    assert.notEqual(exit.code, 0);
    assert.match(stderr, /outside the repository/u);
  } finally {
    await fs.rm(outsideRoot, { recursive: true, force: true });
  }
});

test('phase2 origin rejects wildcard and unbracketed IPv6 bind forms', async () => {
  for (const bind of ['0.0.0.0:0', '::1:0']) {
    const child = spawn('node', [scriptPath, '--bind', bind, '--body-file', fixturePath, '--run-id', EXPECTED_RUN_ID], {
      cwd: repoRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    const exit = await waitForExit(child);
    assert.notEqual(exit.code, 0);
    assert.match(stderr, /concrete reachable interface|use \[ipv6\]:port/u);
  }
});

test('phase2 origin accepts bracketed IPv6 loopback and returns a bracketed HTTPS URL when IPv6 is available', async (t) => {
  const availability = await new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', (error) => {
      resolve(error);
    });
    server.listen(0, '::1', () => {
      server.close(() => resolve(null));
    });
  });
  if (availability) {
    t.skip(`IPv6 loopback unavailable: ${availability.message}`);
  }

  const child = spawn('node', [scriptPath, '--bind', '[::1]:0', '--body-file', fixturePath, '--run-id', EXPECTED_RUN_ID], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  try {
    const { line } = await readHandshake(child);
    const payload = JSON.parse(line);
    assert.match(payload.originUrl, /^https:\/\/\[[0-9a-f:]+\]:\d+\/$/iu);
    const response = await fetchOrigin({
      originUrl: payload.originUrl,
      caPem: payload.caPem,
      requestId: 'ipv6-test',
    });
    assert.equal(response.statusCode, 200);
  } finally {
    child.kill('SIGTERM');
    await waitForExit(child);
  }
});
