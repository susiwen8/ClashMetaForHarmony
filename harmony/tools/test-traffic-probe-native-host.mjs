import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const SOURCE_PATH = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'src', 'main', 'cpp', 'probe_native_core.cpp');
const TEST_PATH = path.join(HARMONY_ROOT, 'tests', 'native', 'traffic_probe_native_core_test.cpp');
const NAPI_TEST_PATH = path.join(HARMONY_ROOT, 'tests', 'native', 'traffic_probe_napi_contract_test.cpp');
const CPP_INCLUDE_DIR = path.join(HARMONY_ROOT, 'traffic-probe', 'entry', 'src', 'main', 'cpp');
const NAPI_SHIM_INCLUDE_DIR = path.join(HARMONY_ROOT, 'tests', 'native', 'shim');
const TIMEOUT_MS = 30_000;
const ARGUMENT_INVALID_EXIT_CODE = 2;
const CASES = new Map([
  ['core', {
    prefix: 'traffic-probe-native-core-',
    outputName: 'traffic_probe_native_core_test',
    sources: [SOURCE_PATH, TEST_PATH],
    includeDirs: [CPP_INCLUDE_DIR],
  }],
  ['napi', {
    prefix: 'traffic-probe-native-napi-',
    outputName: 'traffic_probe_napi_contract_test',
    sources: [NAPI_TEST_PATH],
    includeDirs: [CPP_INCLUDE_DIR, NAPI_SHIM_INCLUDE_DIR],
  }],
]);

class ArgumentError extends Error {
  constructor() {
    super('Usage:\n  node harmony/tools/test-traffic-probe-native-host.mjs\n  node harmony/tools/test-traffic-probe-native-host.mjs --case core\n  node harmony/tools/test-traffic-probe-native-host.mjs --case napi\n  node harmony/tools/test-traffic-probe-native-host.mjs --self-test-scrub');
    this.code = 'ARGUMENT_INVALID';
  }
}

function scrub(text, tempDir) {
  return text
    .split(tempDir).join('<temp>')
    .split(HARMONY_ROOT).join('<repo>');
}

function summarize(result, tempDir) {
  const commandLine = scrub([result.command, ...result.args].join(' '), tempDir);
  const stdout = scrub(result.stdout.trim(), tempDir);
  const stderr = scrub(result.stderr.trim(), tempDir);
  return [
    `command: ${commandLine}`,
    `exitCode: ${result.exitCode}`,
    stdout ? `stdout:\n${stdout}` : null,
    stderr ? `stderr:\n${stderr}` : null,
  ].filter(Boolean).join('\n');
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

function parseCliArguments(args) {
  if (args.length === 0) {
    return { caseName: 'core' };
  }
  if (args.length === 2 && args[0] === '--case' && CASES.has(args[1])) {
    return { caseName: args[1] };
  }
  if (args.length === 1 && args[0] === '--self-test-scrub') {
    return { selfTest: 'scrub' };
  }
  throw new ArgumentError();
}

function runScrubSelfTest() {
  const tempDir = path.join(os.tmpdir(), 'traffic-probe-native-core-redaction');
  const summary = summarize({
    command: path.join(HARMONY_ROOT, 'fake-bin', 'clang++'),
    args: [path.join(HARMONY_ROOT, 'tests', 'native', 'traffic_probe_native_core_test.cpp')],
    exitCode: 1,
    stdout: `${tempDir}\n${HARMONY_ROOT}`,
    stderr: `${HARMONY_ROOT}\n${tempDir}`,
  }, tempDir);

  if (summary.includes(HARMONY_ROOT)) {
    throw new Error('scrub summary leaked repo path');
  }
  if (summary.includes(tempDir)) {
    throw new Error('scrub summary leaked temp path');
  }
  if (!summary.includes('<repo>')) {
    throw new Error('scrub summary did not redact repo path');
  }
  if (!summary.includes('<temp>')) {
    throw new Error('scrub summary did not redact temp path');
  }
}

async function compileAndRunCase(caseConfig) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), caseConfig.prefix));
  const outputBinary = path.join(tempDir, caseConfig.outputName);
  try {
    const compiler = await detectCompiler();
    const compileArgs = [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-pthread',
      '-DCMFA_PROBE_TESTING=1',
      ...caseConfig.includeDirs.flatMap((includeDir) => ['-I', includeDir]),
      ...caseConfig.sources,
      '-o',
      outputBinary,
    ];

    const compileResult = await runCommand(compiler, compileArgs, HARMONY_ROOT);
    if (compileResult.error != null) {
      throw compileResult.error;
    }
    if (compileResult.timedOut) {
      console.error(`Compile timed out after ${TIMEOUT_MS}ms`);
      console.error(summarize(compileResult, tempDir));
      return 1;
    }
    if (compileResult.exitCode !== 0) {
      console.error('Compile failed');
      console.error(summarize(compileResult, tempDir));
      return compileResult.exitCode ?? 1;
    }

    const runResult = await runCommand(outputBinary, [], HARMONY_ROOT);
    if (runResult.error != null) {
      throw runResult.error;
    }
    if (runResult.timedOut) {
      console.error(`Test run timed out after ${TIMEOUT_MS}ms`);
      console.error(summarize(runResult, tempDir));
      return 1;
    }
    process.stdout.write(runResult.stdout);
    process.stderr.write(runResult.stderr);
    if (runResult.exitCode !== 0) {
      console.error(summarize(runResult, tempDir));
      return runResult.exitCode ?? 1;
    }
    return 0;
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

async function runCli(argv = process.argv.slice(2)) {
  try {
    const parsed = parseCliArguments(argv);
    if (parsed.selfTest === 'scrub') {
      runScrubSelfTest();
      return 0;
    }
    const { caseName } = parsed;
    return await compileAndRunCase(CASES.get(caseName));
  } catch (error) {
    if (error?.code === 'ARGUMENT_INVALID') {
      console.error(`${error.code}\n${error.message}`);
      return ARGUMENT_INVALID_EXIT_CODE;
    }
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await runCli();
}
