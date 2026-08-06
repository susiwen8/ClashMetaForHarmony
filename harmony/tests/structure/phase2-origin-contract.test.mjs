import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const repoRoot = path.resolve(harmonyRoot, '..');
const scriptPath = path.join(harmonyRoot, 'tests', 'bin', 'phase2-origin.mjs');
const fixturePath = path.join(harmonyRoot, 'tests', 'fixtures', 'origin-body.txt');

function waitForExit(child) {
  return new Promise((resolve) => {
    child.once('exit', (code, signal) => resolve({ code, signal }));
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

test('phase2 origin emits machine-readable startup info and serves request-id echo over HTTPS', async () => {
  const expectedBody = await fs.readFile(fixturePath, 'utf8');
  const expectedBodyHash = crypto.createHash('sha256').update(expectedBody).digest('hex');
  const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', fixturePath], {
    cwd: repoRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  try {
    const { line } = await readHandshake(child);
    const payload = JSON.parse(line);

    assert.match(payload.originId, /^[0-9a-f-]{36}$/u);
    assert.match(payload.originUrl, /^https:\/\/127\.0\.0\.1:\d+\/$/u);
    assert.match(payload.address, /^127\.0\.0\.1:\d+$/u);
    assert.equal(payload.bodySha256, expectedBodyHash);
    assert.match(payload.files.certPath, /^harmony\/artifacts\/phase2-origin\//u);
    assert.match(payload.files.keyPath, /^harmony\/artifacts\/phase2-origin\//u);
    assert.match(payload.caPem, /BEGIN CERTIFICATE/u);

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

test('phase2 origin exits promptly on SIGTERM after startup', async () => {
  const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', fixturePath], {
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
    const child = spawn('node', [scriptPath, '--bind', '127.0.0.1:0', '--body-file', outsideFile], {
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
