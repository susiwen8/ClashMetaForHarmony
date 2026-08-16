import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const INCLUDE_DIR = path.join(HARMONY_ROOT, 'core', 'abi', 'include');
const ENTRY_INCLUDE_DIR = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'include');
const ENTRY_SOURCE_DIR = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src');
const RUNNER_PATH = path.join(HARMONY_ROOT, 'tools', 'test-native-host.mjs');
const CONTRACT_SOURCE_PATH = path.join(HARMONY_ROOT, 'core', 'abi', 'src', 'cmfa_contract.cpp');

function extractFunctionBody(body, functionName) {
  const signature = `${functionName}(`;
  const start = body.indexOf(signature);
  assert.notEqual(start, -1, `Expected to find ${functionName}`);
  const braceStart = body.indexOf('{', start);
  assert.notEqual(braceStart, -1, `Expected ${functionName} to have a body`);
  let depth = 0;
  for (let index = braceStart; index < body.length; index += 1) {
    const char = body[index];
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return body.slice(start, index + 1);
      }
    }
  }
  throw new Error(`Unbalanced braces in ${functionName}`);
}

test('Task 3 public ABI appends tun and protection symbols without leaking Harmony types', async () => {
  const [typesHeader, hostHeader, coreHeader] = await Promise.all([
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_types.h'), 'utf8'),
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_host.h'), 'utf8'),
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_core.h'), 'utf8'),
  ]);

  assert.match(typesHeader, /CMFA_SOCKET_PROTECT_FAILED/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_options\b/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_snapshot\b/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_trace_collection\b/u);
  assert.match(hostHeader, /\bcmfa_socket_protect_fn\s+protect_socket\s*;/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_start\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_stop\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_runtime_state\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_copy_traces\(/u);

  for (const header of [typesHeader, hostHeader, coreHeader]) {
    assert.doesNotMatch(header, /\bVpnConnection\b/u);
    assert.doesNotMatch(header, /\bArkTS\b/u);
    assert.doesNotMatch(header, /\bnapi_value\b/u);
    assert.doesNotMatch(header, /\bJNIEnv\b/u);
  }
});

test('Task 3 native host runner keeps documented cli stable while defaulting to tun coverage', async () => {
  const runnerSource = await fs.readFile(RUNNER_PATH, 'utf8');

  assert.match(runnerSource, /const TUN_CONTRACT_TEST_SOURCE = .*cmfa_tun_contract_test\.cpp/u);
  assert.match(runnerSource, /\['tun-contract',\s*\{/u);
  assert.match(runnerSource, /const defaultCaseNames = \['contract', 'tun-contract'\];/u);
  assert.doesNotMatch(runnerSource, /node harmony\/tools\/test-native-host\.mjs --case tun-contract/u);
});

test('Task 3 backend seam adds tun hooks and host protection trampoline', async () => {
  const [backendHeader, backendSource] = await Promise.all([
    fs.readFile(path.join(ENTRY_INCLUDE_DIR, 'cmfa_mihomo_backend.h'), 'utf8'),
    fs.readFile(path.join(ENTRY_SOURCE_DIR, 'cmfa_mihomo_backend.cpp'), 'utf8'),
  ]);

  assert.match(backendHeader, /register_mihomo_backend/u);
  assert.match(backendSource, /\bcmfa_mihomo_start_tun_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_stop_tun_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_tun_runtime_state_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_tun_copy_traces_v1\b/u);
  assert.match(backendSource, /\bhost_protect_socket\b/u);
});

test('Task 3 protect_socket_to_host stays a synchronous trampoline with no detached worker state', async () => {
  const contractSource = await fs.readFile(CONTRACT_SOURCE_PATH, 'utf8');
  const functionBody = extractFunctionBody(contractSource, 'protect_socket_to_host');

  assert.doesNotMatch(functionBody, /\bstd::thread\b/u);
  assert.doesNotMatch(functionBody, /\.detach\s*\(/u);
  assert.doesNotMatch(contractSource, /\bProtectSocketCallState\b/u);
});
