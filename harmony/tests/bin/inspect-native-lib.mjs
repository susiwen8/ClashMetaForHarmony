import { spawn as spawnChild } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { inspectToolchain } from '../../tools/lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeText } from '../../tools/lib/proof-redaction.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const ALLOWLIST_PATH = path.join(HARMONY_ROOT, 'toolchain.native-allowlist.json');
const COMPONENT_ALLOWLIST_KEYS = {
  probe: 'goProbe',
  mihomoCore: 'mihomoCore',
  nodeAddon: 'nodeAddon'
};
const RAW_VERSION_EXPORT = 'cmfa_mihomo_core_version_cstr_v1';
const REQUIRED_EXPORTS = {
  probe: ['cmfa_probe_add', 'cmfa_probe_version'],
  mihomoCore: [RAW_VERSION_EXPORT],
  nodeAddon: []
};
const ANDROID_PATTERN = /android|liblog\.so|libc\+\+_shared\.so|libdl_android/i;
const EXPORT_SENTINEL_PATTERN = /(?:test|fake|stub)/iu;
const NODE_ADDON_FORBIDDEN_SYMBOL_PATTERNS = [
  { code: 'PUBLIC_CMFA_EXPORT_FORBIDDEN', pattern: /^cmfa_/u },
  { code: 'INTERNAL_SYMBOL_FORBIDDEN', pattern: /cmfa_internal_register_backend/u },
  { code: 'BACKEND_REGISTER_SYMBOL_FORBIDDEN', pattern: /register_mihomo_backend|unregister_mihomo_backend/u }
];
const DEFAULT_LLVM_READELF_TIMEOUT_MS = 30_000;

function isoTimestamp(date = new Date()) {
  return date.toISOString();
}

function createFailure(code, detail, extra = {}) {
  return { code, detail, ...extra };
}

function normalizePathForReport(repoRoot, absolutePath) {
  if (!absolutePath) {
    return null;
  }

  const relativePath = path.relative(repoRoot, absolutePath);
  if (!relativePath.startsWith('..') && !path.isAbsolute(relativePath)) {
    return relativePath.split(path.sep).join('/');
  }

  return path.basename(absolutePath);
}

async function runReadelf(command, args, { cwd = REPO_ROOT, spawnImpl = spawnChild, timeoutMs = DEFAULT_LLVM_READELF_TIMEOUT_MS } = {}) {
  return await new Promise((resolve) => {
    const child = spawnImpl(command, args, {
      cwd,
      env: process.env,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let spawnError = null;
    let settled = false;

    const finalize = ({ exitCode = null, signal = null, timedOut = false } = {}) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutId);
      resolve({
        command,
        args,
        exitCode,
        signal,
        stdout,
        stderr,
        error: spawnError,
        timedOut
      });
    };

    child.stdout?.setEncoding('utf8');
    child.stderr?.setEncoding('utf8');
    child.stdout?.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr?.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', (error) => {
      spawnError = error;
      finalize();
    });
    child.on('close', (exitCode, signal) => {
      finalize({ exitCode, signal });
    });

    const timeoutId = setTimeout(() => {
      child.kill?.('SIGKILL');
      finalize({ timedOut: true });
    }, timeoutMs);
  });
}

function parseNeededLibraries(stdout) {
  return [...stdout.matchAll(/Shared library: \[(.+?)\]/gu)].map((match) => match[1]).sort();
}

function parseExportedSymbols(stdout) {
  const exported = new Set();

  for (const rawLine of stdout.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || !line.includes('GLOBAL') || !line.includes('DEFAULT') || line.includes(' UND ')) {
      continue;
    }

    const columns = line.split(/\s+/u);
    const symbolName = columns.at(-1);
    if (symbolName) {
      exported.add(symbolName);
    }
  }

  return [...exported].sort();
}

function inferComponent(component, libPath) {
  if (component) {
    return component;
  }

  const baseName = path.basename(libPath).toLowerCase();
  if (baseName.includes('probe')) {
    return 'probe';
  }
  if (baseName.includes('core') || baseName.includes('mihomo')) {
    return 'mihomoCore';
  }
  if (baseName === 'libentry.so' || baseName.includes('entry')) {
    return 'nodeAddon';
  }

  throw Object.assign(new Error(`Unable to infer component from ${baseName}`), { code: 'COMPONENT_REQUIRED' });
}

export async function inspectNativeLibrary({
  libPath,
  component,
  harmonyRoot = HARMONY_ROOT,
  repoRoot = REPO_ROOT,
  allowlistPath = ALLOWLIST_PATH,
  toolchainInspectorImpl = inspectToolchain,
  spawnImpl = spawnChild,
  fsApi = fs,
  readelfTimeoutMs = DEFAULT_LLVM_READELF_TIMEOUT_MS
}) {
  if (!libPath) {
    throw Object.assign(new Error('libPath is required'), { code: 'LIB_PATH_REQUIRED' });
  }

  const absoluteLibPath = path.resolve(libPath);
  let libStats;
  try {
    libStats = await fsApi.stat(absoluteLibPath);
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? 'Failed to stat native library'), { code: error?.code ?? 'LIB_STAT_FAILED' });
  }
  if (!libStats.isFile()) {
    throw Object.assign(new Error(`Native library path is not a regular file: ${absoluteLibPath}`), { code: 'LIB_NOT_REGULAR' });
  }
  const selectedComponent = inferComponent(component, absoluteLibPath);
  const allowlistKey = COMPONENT_ALLOWLIST_KEYS[selectedComponent];
  if (!allowlistKey) {
    throw Object.assign(new Error(`Unsupported component ${selectedComponent}`), { code: 'COMPONENT_UNSUPPORTED' });
  }

  const [allowlist, inspection] = await Promise.all([
    fsApi.readFile(allowlistPath, 'utf8').then((raw) => JSON.parse(raw)),
    toolchainInspectorImpl({ cwd: repoRoot })
  ]);

  if (inspection?.report?.result !== 'pass' || !inspection?.resolved?.paths?.llvmReadelf) {
    throw Object.assign(new Error('Integrated llvm-readelf is unavailable'), { code: 'LLVMREADELF_UNAVAILABLE' });
  }

  const readelfPath = inspection.resolved.paths.llvmReadelf;
  const [headerResult, dynamicResult, symbolsResult] = await Promise.all([
    runReadelf(readelfPath, ['-h', absoluteLibPath], { cwd: repoRoot, spawnImpl, timeoutMs: readelfTimeoutMs }),
    runReadelf(readelfPath, ['-d', absoluteLibPath], { cwd: repoRoot, spawnImpl, timeoutMs: readelfTimeoutMs }),
    runReadelf(readelfPath, ['-sW', absoluteLibPath], { cwd: repoRoot, spawnImpl, timeoutMs: readelfTimeoutMs })
  ]);

  const commandResults = [headerResult, dynamicResult, symbolsResult];
  for (const result of commandResults) {
    if (result.timedOut) {
      throw Object.assign(new Error(`llvm-readelf timed out after ${readelfTimeoutMs} ms`), { code: 'LLVMREADELF_TIMEOUT' });
    }
    if (result.error) {
      throw Object.assign(result.error, { code: 'LLVMREADELF_EXEC_FAILED' });
    }
    if (result.exitCode !== 0) {
      throw Object.assign(new Error(result.stderr || result.stdout || `${result.command} failed`), {
        code: 'LLVMREADELF_EXIT_NON_ZERO'
      });
    }
  }

  const neededLibraries = parseNeededLibraries(dynamicResult.stdout);
  const exportedSymbols = parseExportedSymbols(symbolsResult.stdout);
  const allowlistedNeeded = [...(allowlist?.[allowlistKey] ?? [])].sort();
  const requiredExports = REQUIRED_EXPORTS[selectedComponent];
  const failures = [];

  if (!/Machine:\s+AArch64/u.test(headerResult.stdout)) {
    failures.push(createFailure('ELF_MACHINE_INVALID', 'Expected Machine: AArch64'));
  }

  if (neededLibraries.some((entry) => ANDROID_PATTERN.test(entry))) {
    failures.push(createFailure('ANDROID_DEPENDENCY_FORBIDDEN', `Android dependency detected: ${neededLibraries.find((entry) => ANDROID_PATTERN.test(entry))}`));
  }

  for (const lib of neededLibraries) {
    if (!allowlistedNeeded.includes(lib)) {
      failures.push(createFailure('DT_NEEDED_NOT_ALLOWLISTED', lib));
    }
  }
  if (selectedComponent === 'nodeAddon') {
    if (neededLibraries.includes('libdl.so')) {
      failures.push(createFailure('LIBDL_FORBIDDEN', 'libdl.so'));
    }
    if (neededLibraries.includes('libc++_shared.so')) {
      failures.push(createFailure('LIBCXX_SHARED_FORBIDDEN', 'libc++_shared.so'));
    }
    if (neededLibraries.join('\0') !== allowlistedNeeded.join('\0')) {
      failures.push(createFailure('DT_NEEDED_SET_MISMATCH', neededLibraries.join(',')));
    }
    for (const symbol of exportedSymbols) {
      for (const forbidden of NODE_ADDON_FORBIDDEN_SYMBOL_PATTERNS) {
        if (forbidden.pattern.test(symbol)) {
          failures.push(createFailure(forbidden.code, symbol));
        }
      }
      if (EXPORT_SENTINEL_PATTERN.test(symbol)) {
        failures.push(createFailure('EXPORT_SENTINEL_FORBIDDEN', symbol));
      }
    }
  }

  for (const symbol of requiredExports) {
    if (!exportedSymbols.includes(symbol)) {
      failures.push(createFailure('EXPORT_MISSING', symbol));
    }
  }

  if (selectedComponent === 'probe') {
    const publicExports = exportedSymbols.filter((entry) => entry.startsWith('cmfa_'));
    if (publicExports.length !== requiredExports.length || publicExports.some((entry, index) => entry !== requiredExports[index])) {
      failures.push(createFailure('EXPORT_SET_MISMATCH', publicExports.join(',')));
    }
  }

  if (selectedComponent === 'mihomoCore') {
    const publicExports = exportedSymbols.filter((entry) => entry.startsWith('cmfa_'));

    if (exportedSymbols.includes('cmfa_core_version')) {
      failures.push(createFailure('EXPORT_FORBIDDEN', 'cmfa_core_version'));
    }

    if (publicExports.length !== requiredExports.length || publicExports.some((entry, index) => entry !== requiredExports[index])) {
      failures.push(createFailure('EXPORT_SET_MISMATCH', publicExports.join(',')));
    }

    for (const symbol of exportedSymbols) {
      if (EXPORT_SENTINEL_PATTERN.test(symbol)) {
        failures.push(createFailure('EXPORT_SENTINEL_FORBIDDEN', symbol));
      }
    }

    if (neededLibraries.includes('libdl.so')) {
      failures.push(createFailure('LIBDL_FORBIDDEN', 'libdl.so'));
    }
  }

  return {
    schemaVersion: '1.0.0',
    inspectedAt: isoTimestamp(),
    result: failures.length === 0 ? 'pass' : 'fail',
    component: selectedComponent,
    libPath: normalizePathForReport(repoRoot, absoluteLibPath),
    readelfPath: normalizePathForReport(repoRoot, readelfPath),
    architecture: /Machine:\s+AArch64/u.test(headerResult.stdout) ? 'AArch64' : null,
    neededLibraries,
    allowedNeededLibraries: allowlistedNeeded,
    exportedSymbols,
    requiredExports,
    failures
  };
}

export function parseCliArguments(argv = process.argv.slice(2)) {
  let libPath = null;
  let component = null;

  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--lib') {
      libPath = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    if (value === '--component') {
      component = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw Object.assign(new Error(`Unknown argument: ${value}`), { code: 'ARGUMENT_INVALID' });
  }

  if (!libPath) {
    throw Object.assign(new Error('--lib is required'), { code: 'LIB_PATH_REQUIRED' });
  }

  return { libPath, component };
}

export async function runCli({ argv = process.argv.slice(2), inspectNativeLibraryImpl = inspectNativeLibrary } = {}) {
  try {
    const parsed = parseCliArguments(argv);
    const result = await inspectNativeLibraryImpl(parsed);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.result === 'pass' ? 0 : 1;
  } catch (error) {
    const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: process.env });
    process.stderr.write(`${JSON.stringify({
      schemaVersion: '1.0.0',
      result: 'fail',
      code: error?.code ?? 'UNEXPECTED_ERROR',
      detail: sanitizeText(error?.message ?? String(error), replacements)
    }, null, 2)}\n`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
