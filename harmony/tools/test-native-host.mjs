import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const INCLUDE_DIR = path.join(HARMONY_ROOT, 'core', 'abi', 'include');
const CONTRACT_SOURCE = path.join(HARMONY_ROOT, 'core', 'abi', 'src', 'cmfa_contract.cpp');
const TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'cmfa_contract_test.cpp');
const CORE_HEADER = path.join(INCLUDE_DIR, 'cmfa_core.h');
const HOST_HEADER = path.join(INCLUDE_DIR, 'cmfa_host.h');
const TYPES_HEADER = path.join(INCLUDE_DIR, 'cmfa_types.h');
const TIMEOUT_MS = 30_000;

function summarize(result) {
  const stdout = result.stdout.trim();
  const stderr = result.stderr.trim();
  return [
    `command: ${[result.command, ...result.args].join(' ')}`,
    `exitCode: ${result.exitCode}`,
    stdout ? `stdout:\n${stdout}` : null,
    stderr ? `stderr:\n${stderr}` : null,
  ]
      .filter(Boolean)
      .join('\n');
}

async function runCommand(command, args, cwd) {
  return await new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let settled = false;
    let timedOut = false;

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, TIMEOUT_MS);

    const finalize = (exitCode, signal, error = null) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve({ command, args, cwd, exitCode, signal, stdout, stderr, error, timedOut });
    };

    child.on('error', (error) => finalize(null, null, error));
    child.on('close', (exitCode, signal) => finalize(exitCode, signal));
  });
}

async function detectCompiler() {
  for (const candidate of ['clang++', 'c++', 'g++']) {
    const result = await runCommand(candidate, ['--version'], HARMONY_ROOT);
    if (result.error == null && result.exitCode === 0) {
      return candidate;
    }
  }
  throw new Error('No suitable C++ compiler found (tried clang++, c++, g++).');
}

async function detectCCompiler() {
  for (const candidate of ['clang', 'cc', 'gcc']) {
    const result = await runCommand(candidate, ['--version'], HARMONY_ROOT);
    if (result.error == null && result.exitCode === 0) {
      return candidate;
    }
  }
  throw new Error('No suitable C compiler found (tried clang, cc, gcc).');
}

async function detectNm() {
  for (const candidate of ['nm', 'llvm-nm']) {
    const result = await runCommand(candidate, ['--version'], HARMONY_ROOT);
    if (result.error == null && result.exitCode === 0) {
      return candidate;
    }
  }
  for (const candidate of ['nm', 'llvm-nm']) {
    const result = await runCommand(candidate, [], HARMONY_ROOT);
    if (result.error == null && (result.exitCode === 0 || result.exitCode === 1)) {
      return candidate;
    }
  }
  throw new Error('No suitable nm tool found (tried nm, llvm-nm).');
}

function assertPublicHeaderContract(coreHeader, hostHeader, typesHeader) {
  if (coreHeader.includes('cmfa_backend_api') || coreHeader.includes('cmfa_backend_host') ||
      coreHeader.includes('cmfa_internal_register_backend')) {
    throw new Error('Public cmfa_core.h exposes backend seam symbols by default.');
  }
  if (hostHeader.includes('lifetime_token')) {
    throw new Error('Public host ABI still exposes lifetime_token.');
  }
  if (!/char\s+active_config_path\s*\[\s*CMFA_MAX_PATH_BYTES\s*\]\s*;/u.test(typesHeader)) {
    throw new Error('cmfa_runtime_snapshot.active_config_path is not an inline fixed-size array.');
  }

  const publicFunctions = [...coreHeader.matchAll(/^cmfa_status\s+(cmfa_[a-z0-9_]+)\s*\(/gmu)].map((entry) => entry[1]);
  if (publicFunctions.length !== 8) {
    throw new Error(`Expected exactly 8 app-facing cmfa_* declarations, found ${publicFunctions.length}.`);
  }
  const expectedFunctions = [
    'cmfa_initialize',
    'cmfa_core_version',
    'cmfa_validate_config',
    'cmfa_load_config',
    'cmfa_start_local',
    'cmfa_stop',
    'cmfa_runtime_state',
    'cmfa_shutdown',
  ];
  if (publicFunctions.join('\n') !== expectedFunctions.join('\n')) {
    throw new Error(`Public function list mismatch.\nActual:\n${publicFunctions.join('\n')}`);
  }
}

async function verifyPublicHeaders(tempDir) {
  const [coreHeader, hostHeader, typesHeader, cCompiler] = await Promise.all([
    fs.readFile(CORE_HEADER, 'utf8'),
    fs.readFile(HOST_HEADER, 'utf8'),
    fs.readFile(TYPES_HEADER, 'utf8'),
    detectCCompiler(),
  ]);
  assertPublicHeaderContract(coreHeader, hostHeader, typesHeader);

  const smokeSource = path.join(tempDir, 'public-headers-smoke.c');
  await fs.writeFile(smokeSource, [
    '#include "cmfa_types.h"',
    '#include "cmfa_host.h"',
    '#include "cmfa_core.h"',
    '',
    '_Static_assert(sizeof(((cmfa_runtime_snapshot *)0)->active_config_path) == CMFA_MAX_PATH_BYTES,',
    '               "snapshot path must be an inline fixed-size buffer");',
    '',
    'int main(void) {',
    '  cmfa_host_callbacks callbacks = {0};',
    '  cmfa_runtime_snapshot snapshot = {0};',
    '  cmfa_error error = {0};',
    '  (void)callbacks;',
    '  (void)snapshot;',
    '  (void)error;',
    '  return 0;',
    '}',
    '',
  ].join('\n'), 'utf8');

  const syntaxResult = await runCommand(cCompiler, [
    '-x',
    'c',
    '-std=c11',
    '-fsyntax-only',
    '-I',
    INCLUDE_DIR,
    smokeSource,
  ], HARMONY_ROOT);

  if (syntaxResult.error != null) {
    throw syntaxResult.error;
  }
  if (syntaxResult.exitCode !== 0) {
    throw new Error(`Public header smoke compile failed.\n${summarize(syntaxResult)}`);
  }
}

async function verifyProductionBuildHidesTestHook(tempDir) {
  const compiler = await detectCompiler();
  const nmTool = await detectNm();
  const objectPath = path.join(tempDir, 'cmfa_contract_prod.o');

  const compileResult = await runCommand(compiler, [
    '-std=c++17',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-fvisibility=hidden',
    '-I',
    INCLUDE_DIR,
    '-c',
    CONTRACT_SOURCE,
    '-o',
    objectPath,
  ], HARMONY_ROOT);

  if (compileResult.error != null) {
    throw compileResult.error;
  }
  if (compileResult.exitCode !== 0) {
    throw new Error(`Production object compile failed.\n${summarize(compileResult)}`);
  }

  const nmResult = await runCommand(nmTool, ['-g', objectPath], HARMONY_ROOT);
  if (nmResult.error != null) {
    throw nmResult.error;
  }
  if (nmResult.exitCode !== 0) {
    throw new Error(`nm symbol check failed.\n${summarize(nmResult)}`);
  }
  if (nmResult.stdout.includes('cmfa_internal_set_test_hook') || nmResult.stderr.includes('cmfa_internal_set_test_hook')) {
    throw new Error('Production build still exports cmfa_internal_set_test_hook.');
  }
}

async function main() {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'cmfa-host-test-'));
  const outputBinary = path.join(tempDir, 'cmfa_contract_test');

  try {
    await verifyPublicHeaders(tempDir);
    await verifyProductionBuildHidesTestHook(tempDir);
    const compiler = await detectCompiler();
    const compileArgs = [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-pthread',
      '-DCMFA_INTERNAL_BACKEND_API=1',
      '-DCMFA_CONTRACT_TESTING=1',
      '-I',
      INCLUDE_DIR,
      CONTRACT_SOURCE,
      TEST_SOURCE,
      '-o',
      outputBinary,
    ];

    const compileResult = await runCommand(compiler, compileArgs, HARMONY_ROOT);
    if (compileResult.error != null) {
      throw compileResult.error;
    }
    if (compileResult.timedOut) {
      console.error(`Compile timed out after ${TIMEOUT_MS}ms`);
      console.error(summarize(compileResult));
      process.exitCode = 1;
      return;
    }
    if (compileResult.exitCode !== 0) {
      console.error('Compile failed');
      console.error(summarize(compileResult));
      process.exitCode = compileResult.exitCode ?? 1;
      return;
    }

    const runResult = await runCommand(outputBinary, [], HARMONY_ROOT);
    if (runResult.error != null) {
      throw runResult.error;
    }
    if (runResult.timedOut) {
      console.error(`Test run timed out after ${TIMEOUT_MS}ms`);
      console.error(summarize(runResult));
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${runResult.stdout}`);
    process.stderr.write(`${runResult.stderr}`);
    if (runResult.exitCode !== 0) {
      console.error(summarize(runResult));
      process.exitCode = runResult.exitCode ?? 1;
    }
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

await main();
