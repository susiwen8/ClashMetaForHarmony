import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const INCLUDE_DIR = path.join(HARMONY_ROOT, 'core', 'abi', 'include');
const CONTRACT_SOURCE = path.join(HARMONY_ROOT, 'core', 'abi', 'src', 'cmfa_contract.cpp');
const CONTRACT_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'cmfa_contract_test.cpp');
const TUN_CONTRACT_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'cmfa_tun_contract_test.cpp');
const MIHOMO_BACKEND_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'cmfa_mihomo_backend.cpp');
const MIHOMO_BACKEND_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'cmfa_mihomo_backend_test.cpp');
const NAPI_ENVIRONMENT_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'napi_environment.cpp');
const NAPI_ENVIRONMENT_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'napi_environment_test.cpp');
const JS_ERRORS_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_errors.cpp');
const JS_CODEC_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_codec.cpp');
const JS_ASYNC_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_async.cpp');
const JS_EVENTS_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_events.cpp');
const JS_CORE_MODULE_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_core_module.cpp');
const JS_RUNTIME_CONTROL_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_runtime_control.cpp');
const JS_PROXY_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_proxy.cpp');
const JS_TUN_SOURCE = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src', 'js_tun.cpp');
const JS_PROXY_NAPI_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'js_proxy_napi_test.cpp');
const JS_TUN_NAPI_TEST_SOURCE = path.join(HARMONY_ROOT, 'tests', 'native', 'js_tun_napi_test.cpp');
const ENTRY_INCLUDE_DIR = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'include');
const NAPI_SHIM_INCLUDE_DIR = path.join(HARMONY_ROOT, 'tests', 'native', 'shim');
const CORE_HEADER = path.join(INCLUDE_DIR, 'cmfa_core.h');
const HOST_HEADER = path.join(INCLUDE_DIR, 'cmfa_host.h');
const TYPES_HEADER = path.join(INCLUDE_DIR, 'cmfa_types.h');
const TIMEOUT_MS = 30_000;
const ARGUMENT_INVALID_EXIT_CODE = 2;
const USAGE_LINES = [
  'Usage:',
  '  node harmony/tools/test-native-host.mjs',
  '  node harmony/tools/test-native-host.mjs --case contract',
  '  node harmony/tools/test-native-host.mjs --case mihomo-backend',
  '  node harmony/tools/test-native-host.mjs --case napi-environment',
  '  node harmony/tools/test-native-host.mjs --case napi-proxy',
  '  node harmony/tools/test-native-host.mjs --case napi-tun',
];

function formatUsage() {
  return USAGE_LINES.join('\n');
}

function stripTestBuildAbiSections(body) {
  return body.replace(/#if defined\(CMFA_TEST_BUILD_ABI\)[\s\S]*?#endif/gmu, '');
}

class ArgumentError extends Error {
  constructor(message = formatUsage()) {
    super(message);
    this.code = 'ARGUMENT_INVALID';
  }
}

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
  if (!/#if defined\(CMFA_TEST_BUILD_ABI\)[\s\S]*cmfa_probe_https[\s\S]*cmfa_probe_result_free[\s\S]*#endif/gmu.test(coreHeader)) {
    throw new Error('Test-build probe ABI must stay behind CMFA_TEST_BUILD_ABI guard.');
  }
  if (hostHeader.includes('lifetime_token')) {
    throw new Error('Public host ABI still exposes lifetime_token.');
  }
  if (!/char\s+active_config_path\s*\[\s*CMFA_MAX_PATH_BYTES\s*\]\s*;/u.test(typesHeader)) {
    throw new Error('cmfa_runtime_snapshot.active_config_path is not an inline fixed-size array.');
  }
  if (!/#define\s+CMFA_MAX_PROXY_HASH_BYTES\s+\(\(size_t\)65\)/u.test(typesHeader)) {
    throw new Error('cmfa_types.h must define CMFA_MAX_PROXY_HASH_BYTES as ((size_t)65).');
  }
  if (!/#define\s+CMFA_MAX_PROXY_NAME_UTF8_BYTES\s+\(\(size_t\)256\)/u.test(typesHeader)) {
    throw new Error('cmfa_types.h must define CMFA_MAX_PROXY_NAME_UTF8_BYTES as ((size_t)256).');
  }
  if (!/#define\s+CMFA_MAX_PROXY_JSON_BYTES\s+\(\(size_t\)\(1024\s*\*\s*1024\)\)/u.test(typesHeader)) {
    throw new Error('cmfa_types.h must define CMFA_MAX_PROXY_JSON_BYTES as ((size_t)(1024 * 1024)).');
  }
  if (!/#define\s+CMFA_MAX_PROXY_DELAY_JOB_ID_BYTES\s+\(\(size_t\)33\)/u.test(typesHeader)) {
    throw new Error('cmfa_types.h must define CMFA_MAX_PROXY_DELAY_JOB_ID_BYTES as ((size_t)33).');
  }
  if (!/typedef\s+struct\s+cmfa_proxy_query_context\s*\{[\s\S]*char\s+profile_hash\s*\[\s*CMFA_MAX_PROXY_HASH_BYTES\s*\]\s*;[\s\S]*char\s+revision_hash\s*\[\s*CMFA_MAX_PROXY_HASH_BYTES\s*\]\s*;[\s\S]*char\s+session_hash\s*\[\s*CMFA_MAX_PROXY_HASH_BYTES\s*\]\s*;[\s\S]*uint64_t\s+generation\s*;[\s\S]*\}\s*cmfa_proxy_query_context\s*;/u.test(typesHeader)) {
    throw new Error('cmfa_proxy_query_context must be publicly declared with fixed-size hash arrays.');
  }
  if (!/typedef\s+struct\s+cmfa_json_buffer\s*\{[\s\S]*char\s*\*\s*data\s*;[\s\S]*size_t\s+capacity\s*;[\s\S]*size_t\s+length\s*;[\s\S]*\}\s*cmfa_json_buffer\s*;/u.test(typesHeader)) {
    throw new Error('cmfa_json_buffer must be publicly declared.');
  }
  for (const rawSymbol of [
    'cmfa_mihomo_core_version_cstr_v1',
    'cmfa_mihomo_probe_cancel_v1',
    'cmfa_mihomo_proxy_delay_start_v1',
    'cmfa_mihomo_proxy_delay_snapshot_v1',
    'cmfa_mihomo_proxy_delay_cancel_v1',
  ]) {
    if (coreHeader.includes(rawSymbol) || hostHeader.includes(rawSymbol) || typesHeader.includes(rawSymbol)) {
      throw new Error(`Public ABI headers must not mention raw backend symbol ${rawSymbol}.`);
    }
  }
  for (const callbackName of [
    'proxy_groups',
    'proxy_group',
    'proxy_select',
    'proxy_delay_start',
    'proxy_delay_snapshot',
    'proxy_delay_cancel',
  ]) {
    if (!new RegExp(`\\b${callbackName}\\b`, 'u').test(hostHeader)) {
      throw new Error(`Hidden cmfa_backend_api is missing ${callbackName}.`);
    }
  }

  const publicFunctions = [...stripTestBuildAbiSections(coreHeader).matchAll(/^cmfa_status\s+(cmfa_[a-z0-9_]+)\s*\(/gmu)]
      .map((entry) => entry[1]);
  if (publicFunctions.length !== 21) {
    throw new Error(`Expected exactly 21 app-facing cmfa_* declarations, found ${publicFunctions.length}.`);
  }
  const expectedFunctions = [
    'cmfa_initialize',
    'cmfa_core_version',
    'cmfa_validate_config',
    'cmfa_load_config',
    'cmfa_start_local',
    'cmfa_stop',
    'cmfa_runtime_state',
    'cmfa_runtime_mode_query',
    'cmfa_runtime_mode_set',
    'cmfa_proxy_groups',
    'cmfa_proxy_group',
    'cmfa_proxy_select',
    'cmfa_proxy_delay_start',
    'cmfa_proxy_delay_snapshot',
    'cmfa_proxy_delay_cancel',
    'cmfa_tun_start',
    'cmfa_tun_stop',
    'cmfa_tun_runtime_state',
    'cmfa_tun_copy_traces',
    'cmfa_tun_copy_traces_ring',
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
    '_Static_assert(CMFA_MAX_PROXY_HASH_BYTES == 65, "proxy hash bytes must stay fixed");',
    '_Static_assert(CMFA_MAX_PROXY_NAME_UTF8_BYTES == 256, "proxy name bytes must stay fixed");',
    '_Static_assert(CMFA_MAX_PROXY_JSON_BYTES == 1024u * 1024u, "proxy json bytes must stay fixed");',
    '_Static_assert(CMFA_MAX_PROXY_DELAY_JOB_ID_BYTES == 33, "proxy delay job id bytes must stay fixed");',
    '',
    'int main(void) {',
    '  cmfa_host_callbacks callbacks = {0};',
    '  cmfa_runtime_snapshot snapshot = {0};',
    '  cmfa_proxy_query_context query = {0};',
    '  cmfa_json_buffer json = {0};',
    '  cmfa_error error = {0};',
    '  (void)callbacks;',
    '  (void)snapshot;',
    '  query.struct_size = sizeof(query);',
    '  json.data = 0;',
    '  json.capacity = 0;',
    '  json.length = 0;',
    '  (void)cmfa_proxy_groups(&query, 0, &json, &error);',
    '  (void)cmfa_proxy_group(&query, "group", &json, &error);',
    '  (void)cmfa_proxy_select(&query, "group", "member", &json, &error);',
    '  (void)cmfa_proxy_delay_start(&query, "group", &json, &error);',
    '  (void)cmfa_proxy_delay_snapshot("0123456789abcdef0123456789abcdef", &json, &error);',
    '  (void)cmfa_proxy_delay_cancel("0123456789abcdef0123456789abcdef", &json, &error);',
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

const CASES = new Map([
  ['contract', {
    sources: [CONTRACT_SOURCE, CONTRACT_TEST_SOURCE],
    defines: ['CMFA_INTERNAL_BACKEND_API=1', 'CMFA_CONTRACT_TESTING=1', 'CMFA_TEST_BUILD_ABI=1'],
    prefix: 'cmfa-contract-test-',
    beforeCompile: verifyContractPreflight,
    outputName: 'cmfa_contract_test',
  }],
  ['tun-contract', {
    sources: [CONTRACT_SOURCE, TUN_CONTRACT_TEST_SOURCE],
    defines: ['CMFA_INTERNAL_BACKEND_API=1', 'CMFA_CONTRACT_TESTING=1', 'CMFA_TEST_BUILD_ABI=1'],
    prefix: 'cmfa-tun-contract-test-',
    outputName: 'cmfa_tun_contract_test',
  }],
  ['mihomo-backend', {
    sources: [CONTRACT_SOURCE, MIHOMO_BACKEND_SOURCE, MIHOMO_BACKEND_TEST_SOURCE],
    defines: ['CMFA_INTERNAL_BACKEND_API=1', 'CMFA_BACKEND_TESTING=1', 'CMFA_TEST_BUILD_ABI=1'],
    prefix: 'cmfa-mihomo-backend-test-',
    includeDirs: [ENTRY_INCLUDE_DIR],
    outputName: 'cmfa_mihomo_backend_test',
  }],
  ['napi-environment', {
    sources: [NAPI_ENVIRONMENT_SOURCE, NAPI_ENVIRONMENT_TEST_SOURCE],
    defines: [],
    prefix: 'napi-environment-test-',
    includeDirs: [ENTRY_INCLUDE_DIR],
    outputName: 'napi_environment_test',
  }],
  ['napi-tun', {
    sources: [
      NAPI_ENVIRONMENT_SOURCE,
      JS_ERRORS_SOURCE,
      JS_CODEC_SOURCE,
      JS_ASYNC_SOURCE,
      JS_EVENTS_SOURCE,
      JS_CORE_MODULE_SOURCE,
      JS_RUNTIME_CONTROL_SOURCE,
      JS_PROXY_SOURCE,
      JS_TUN_SOURCE,
      JS_TUN_NAPI_TEST_SOURCE,
    ],
    defines: ['CMFA_NAPI_PROXY_HOST_STUBS=1'],
    prefix: 'napi-tun-test-',
    includeDirs: [NAPI_SHIM_INCLUDE_DIR, ENTRY_INCLUDE_DIR],
    outputName: 'js_tun_napi_test',
  }],
  ['napi-proxy', {
    sources: [
      NAPI_ENVIRONMENT_SOURCE,
      JS_ERRORS_SOURCE,
      JS_CODEC_SOURCE,
      JS_ASYNC_SOURCE,
      JS_CORE_MODULE_SOURCE,
      JS_RUNTIME_CONTROL_SOURCE,
      JS_PROXY_SOURCE,
      JS_PROXY_NAPI_TEST_SOURCE,
    ],
    defines: [],
    prefix: 'napi-proxy-test-',
    includeDirs: [NAPI_SHIM_INCLUDE_DIR, ENTRY_INCLUDE_DIR],
    outputName: 'js_proxy_napi_test',
  }],
]);

async function verifyContractPreflight(tempDir) {
  await verifyPublicHeaders(tempDir);
  await verifyProductionBuildHidesTestHook(tempDir);
}

export function parseCliArguments(args) {
  if (args.length === 0) {
    return { caseName: 'contract' };
  }
  if (args.length === 2 && args[0] === '--case' && CASES.has(args[1])) {
    return { caseName: args[1] };
  }
  throw new ArgumentError();
}

async function compileAndRunCase(caseConfig) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), caseConfig.prefix));
  const outputBinary = path.join(tempDir, caseConfig.outputName);
  try {
    if (typeof caseConfig.beforeCompile === 'function') {
      await caseConfig.beforeCompile(tempDir);
    }

    const compiler = await detectCompiler();
    const compileArgs = [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-pthread',
      ...caseConfig.defines.map((define) => `-D${define}`),
      '-I',
      INCLUDE_DIR,
      ...(caseConfig.includeDirs ?? []).flatMap((includeDir) => ['-I', includeDir]),
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
      console.error(summarize(compileResult));
      return 1;
    }
    if (compileResult.exitCode !== 0) {
      console.error('Compile failed');
      console.error(summarize(compileResult));
      return compileResult.exitCode ?? 1;
    }

    const runResult = await runCommand(outputBinary, [], HARMONY_ROOT);
    if (runResult.error != null) {
      throw runResult.error;
    }
    if (runResult.timedOut) {
      console.error(`Test run timed out after ${TIMEOUT_MS}ms`);
      console.error(summarize(runResult));
      return 1;
    }
    process.stdout.write(`${runResult.stdout}`);
    process.stderr.write(`${runResult.stderr}`);
    if (runResult.exitCode !== 0) {
      console.error(summarize(runResult));
      return runResult.exitCode ?? 1;
    }
    return 0;
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

async function runDefaultCases() {
  const defaultCaseNames = ['contract', 'tun-contract'];
  for (const caseName of defaultCaseNames) {
    const exitCode = await compileAndRunCase(CASES.get(caseName));
    if (exitCode !== 0) {
      return exitCode;
    }
  }
  return 0;
}

export async function runCli(argv = process.argv.slice(2)) {
  try {
    if (argv.length === 0) {
      return await runDefaultCases();
    }
    const { caseName } = parseCliArguments(argv);
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
