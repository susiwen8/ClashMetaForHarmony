import { spawn as spawnChild } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { inspectToolchain, normalizeNodeVersion } from './lib/toolchain.mjs';
import { createRedactionReplacements, sanitizeForPersistence, sanitizeText } from './lib/proof-redaction.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
export const GO_OHOS_PROOF_PATH = path.join(HARMONY_ROOT, 'artifacts', 'go-ohos-build-proof.json');
const DEFAULT_GO_CACHE_PATH = path.join(HARMONY_ROOT, 'artifacts', 'go-build-cache');
const DEFAULT_GO_MOD_CACHE_PATH = path.join(HARMONY_ROOT, 'artifacts', 'go-mod-cache');
const PROOF_SCHEMA_VERSION = '1.0.0';
const GO_BUILD_TIMEOUT_MS = 10 * 60 * 1000;
const HOST_CLANG_PATTERN = /(^|\/)clang(\+\+)?$/u;
const ANDROID_PATTERN = /android|ndk/iu;
const TARGET_NAME = 'HarmonyOS 6/API 20/arm64';
const CORE_PRIVATE_EXPORTS = [
  'cmfa_mihomo_core_build_info_json_cstr_v1',
  'cmfa_mihomo_core_version_cstr_v1',
  'cmfa_mihomo_runtime_state_v1',
  'cmfa_mihomo_start_local_v1',
  'cmfa_mihomo_stop_v1',
  'cmfa_mihomo_take_runtime_log_v1'
];

const COMPONENT_CONFIG = {
  probe: {
    component: 'probe',
    artifactFileName: 'libcmfa_probe.so',
    expectedExports: ['cmfa_probe_add', 'cmfa_probe_version'],
    modulePath: 'core/go/probe',
    packagePath: '.',
    targetName: TARGET_NAME
  },
  mihomoCore: {
    component: 'mihomoCore',
    artifactFileName: 'libcmfa_mihomo.so',
    expectedExports: CORE_PRIVATE_EXPORTS,
    modulePath: 'core/go',
    packagePath: './cmd/cmfa_core',
    targetName: TARGET_NAME
  }
};

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

function normalizeHarmonyPath(harmonyRoot, absolutePath) {
  if (!absolutePath) {
    return null;
  }

  const relativePath = path.relative(harmonyRoot, absolutePath);
  if (!relativePath.startsWith('..') && !path.isAbsolute(relativePath)) {
    return path.posix.join('harmony', relativePath.split(path.sep).join('/'));
  }

  return normalizePathForReport(REPO_ROOT, absolutePath);
}

async function pathExists(filePath, fsApi = fs) {
  try {
    await fsApi.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function runCommand({
  command,
  args,
  cwd,
  env,
  spawnImpl = spawnChild,
  timeoutMs = GO_BUILD_TIMEOUT_MS
}) {
  return await new Promise((resolve) => {
    const child = spawnImpl(command, args, {
      cwd,
      env,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let spawnError = null;
    let timedOut = false;
    let settled = false;

    const finalize = ({ exitCode = null, signal = null } = {}) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutId);
      resolve({
        command,
        args,
        cwd,
        env,
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
      timedOut = true;
      child.kill('SIGKILL');
    }, timeoutMs);
  });
}

async function readToolchainVersions(harmonyRoot, fsApi = fs) {
  try {
    const lock = JSON.parse(await fsApi.readFile(path.join(harmonyRoot, 'toolchain.lock.json'), 'utf8'));
    return {
      devecoVersion: lock?.installed?.devecoVersion ?? null,
      sdkVersion: lock?.installed?.sdkVersion ?? null,
      ndkVersion: lock?.installed?.ndkVersion ?? null,
      hdcVersion: lock?.installed?.hdcVersion ?? null
    };
  } catch {
    return {
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hdcVersion: null
    };
  }
}

async function readGoVersion({ cwd, env, runCommandImpl = runCommand, spawnImpl = spawnChild }) {
  const goBinaryPath = arguments[0].goBinaryPath ?? 'go';
  const result = await runCommandImpl({
    command: goBinaryPath,
    args: ['version'],
    cwd,
    env,
    spawnImpl,
    timeoutMs: 15_000
  });

  if (result.error || result.exitCode !== 0) {
    return null;
  }

  const match = `${result.stdout}\n${result.stderr}`.match(/go version (go[^\s]+)/u);
  return match?.[1] ?? null;
}

async function isExecutableFile(candidatePath, fsApi = fs) {
  if (!candidatePath || !path.isAbsolute(candidatePath)) {
    return false;
  }
  try {
    const stats = await fsApi.stat(candidatePath);
    return stats.isFile() && (stats.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

export async function resolveTrustedGoBinary({
  env = process.env,
  fsApi = fs,
  trustedPath = process.env.PATH ?? ''
} = {}) {
  const searchEntries = trustedPath.split(path.delimiter).filter(Boolean);
  for (const entry of searchEntries) {
    const candidatePath = path.resolve(entry, 'go');
    if (await isExecutableFile(candidatePath, fsApi)) {
      return candidatePath;
    }
  }

  throw Object.assign(new Error('Unable to resolve a trusted go binary from the host PATH.'), { code: 'GO_BINARY_NOT_FOUND' });
}

function createAggregateProof({ outputPath, harmonyRoot }) {
  return {
    schemaVersion: PROOF_SCHEMA_VERSION,
    result: 'incomplete',
    outputPath: normalizeHarmonyPath(harmonyRoot, outputPath),
    harmonyRoot: normalizeHarmonyPath(harmonyRoot, harmonyRoot),
    target: {
      name: TARGET_NAME,
      architecture: 'arm64',
      compatibleApiVersion: 20,
      runtimeOS: 'HarmonyOS'
    },
    components: {
      probe: null,
      mihomoCore: null
    },
    failures: [],
    timestamps: {
      startedAt: isoTimestamp(),
      completedAt: null
    }
  };
}

function finalizeAggregateProof(proof, result) {
  proof.result = result;
  proof.timestamps.completedAt = isoTimestamp();
  return proof;
}

function createComponentProof({ component, artifactPath, headerPath, modulePath, packagePath, targetName, harmonyRoot }) {
  return {
    component,
    result: 'incomplete',
    target: {
      name: targetName,
      architecture: 'arm64',
      compatibleApiVersion: 20,
      runtimeOS: 'HarmonyOS',
      packagePath
    },
    artifact: {
      path: normalizeHarmonyPath(harmonyRoot, artifactPath),
      headerPath: normalizeHarmonyPath(harmonyRoot, headerPath),
      exists: false
    },
    build: {
      command: [],
      env: {},
      modulePath: path.posix.join('harmony', modulePath),
      cwd: path.posix.join('harmony', modulePath)
    },
    checks: {
      cleanup: { result: 'pending', detail: null },
      toolchain: { result: 'pending', detail: null },
      build: { result: 'pending', detail: null },
      elfInspection: { result: 'pending', detail: null }
    },
    toolVersions: {
      nodeVersion: normalizeNodeVersion(process.version),
      goBinary: null,
      goVersion: null,
      devecoVersion: null,
      sdkVersion: null,
      ndkVersion: null,
      hdcVersion: null
    },
    elfInspection: null,
    failures: [],
    timestamps: {
      startedAt: isoTimestamp(),
      completedAt: null
    }
  };
}

function finalizeComponentProof(componentProof, result) {
  componentProof.result = result;
  componentProof.timestamps.completedAt = isoTimestamp();
  return componentProof;
}

async function persistAggregateProof(proof, proofPath, replacements, fsApi = fs) {
  const sanitized = sanitizeForPersistence(proof, replacements);
  await fsApi.mkdir(path.dirname(proofPath), { recursive: true });
  await fsApi.writeFile(proofPath, `${JSON.stringify(sanitized, null, 2)}\n`, 'utf8');
  return sanitized;
}

function sanitizeError(error, replacements) {
  return sanitizeText(error?.message ?? String(error), replacements);
}

function validateRequestedEnv(env, failures) {
  if (env?.GOOS && env.GOOS !== 'linux') {
    failures.push(createFailure('GOOS_FORBIDDEN', `GOOS must be linux, received ${env.GOOS}`));
  }
  if (env?.GOARCH && env.GOARCH !== 'arm64') {
    failures.push(createFailure('GOARCH_FORBIDDEN', `GOARCH must be arm64, received ${env.GOARCH}`));
  }
  if (env?.CC && (HOST_CLANG_PATTERN.test(env.CC) || ANDROID_PATTERN.test(env.CC))) {
    failures.push(createFailure('TOOLCHAIN_OVERRIDE_FORBIDDEN', `CC=${env.CC}`));
  }
  if (env?.CXX && (HOST_CLANG_PATTERN.test(env.CXX) || ANDROID_PATTERN.test(env.CXX))) {
    failures.push(createFailure('TOOLCHAIN_OVERRIDE_FORBIDDEN', `CXX=${env.CXX}`));
  }
}

function validateResolvedToolchain(inspection, failures) {
  const target = inspection?.report?.target ?? {};
  const clangPath = inspection?.resolved?.paths?.clang ?? null;
  const llvmReadelfPath = inspection?.resolved?.paths?.llvmReadelf ?? null;

  if (inspection?.report?.result !== 'pass') {
    failures.push(...(inspection?.report?.failures ?? []).map((entry) => createFailure(entry.code ?? 'TOOLCHAIN_INCOMPLETE', entry.detail ?? 'toolchain incomplete')));
    return null;
  }
  if (target.architecture !== 'arm64' || target.compatibleApiVersion !== 20) {
    failures.push(createFailure('TARGET_CONTRACT_INVALID', `Expected arm64/API 20 contract, received ${target.architecture ?? 'unknown'}/${target.compatibleApiVersion ?? 'unknown'}`));
  }
  if (path.basename(clangPath ?? '') !== 'aarch64-unknown-linux-ohos-clang' || HOST_CLANG_PATTERN.test(clangPath ?? '') || ANDROID_PATTERN.test(clangPath ?? '')) {
    failures.push(createFailure('CLANG_CONTRACT_INVALID', clangPath ?? 'missing'));
  }
  if (path.basename(llvmReadelfPath ?? '') !== 'llvm-readelf' || ANDROID_PATTERN.test(llvmReadelfPath ?? '')) {
    failures.push(createFailure('LLVMREADELF_CONTRACT_INVALID', llvmReadelfPath ?? 'missing'));
  }

  if (failures.length > 0) {
    return null;
  }

  return {
    clangBinary: path.basename(clangPath),
    cxxBinary: 'aarch64-unknown-linux-ohos-clang++',
    clangDirectory: path.dirname(clangPath)
  };
}

async function cleanupArtifacts({ artifactPath, headerPath, fsApi = fs }) {
  await fsApi.mkdir(path.dirname(artifactPath), { recursive: true });
  await fsApi.rm(artifactPath, { force: true });
  await fsApi.rm(headerPath, { force: true });
}

export async function buildGoComponent(options) {
  const {
    component,
    modulePath,
    packagePath,
    artifactFileName,
    expectedExports,
    targetName = TARGET_NAME,
    extraGoArgs = [],
    harmonyRoot = HARMONY_ROOT,
    env = process.env,
    fsApi = fs,
    spawnImpl = spawnChild,
    runCommandImpl = runCommand,
    toolchainInspectorImpl = inspectToolchain,
    inspectNativeLibraryImpl,
    readGoVersionImpl = readGoVersion,
    readToolchainVersionsImpl = readToolchainVersions,
    resolveGoBinaryImpl = resolveTrustedGoBinary
  } = options;

  const artifactPath = path.join(harmonyRoot, 'artifacts', artifactFileName);
  const headerPath = artifactPath.replace(/\.so$/u, '.h');
  const componentProof = createComponentProof({ component, artifactPath, headerPath, modulePath, packagePath, targetName, harmonyRoot });
  const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env });
  const moduleAbsolutePath = path.join(harmonyRoot, modulePath);

  validateRequestedEnv(env, componentProof.failures);
  componentProof.toolVersions = {
    ...componentProof.toolVersions,
    ...await readToolchainVersionsImpl(harmonyRoot, fsApi)
  };

  try {
    await cleanupArtifacts({ artifactPath, headerPath, fsApi });
    componentProof.checks.cleanup = { result: 'pass', detail: 'Removed stale component artifact and header before build.' };
  } catch (error) {
    componentProof.checks.cleanup = { result: 'fail', detail: 'Failed to remove stale component artifact/header.' };
    componentProof.failures.push(createFailure(error?.code ?? 'ARTIFACT_CLEANUP_FAILED', sanitizeError(error, replacements)));
    return finalizeComponentProof(componentProof, 'fail');
  }

  let inspection;
  try {
    inspection = await toolchainInspectorImpl({ cwd: REPO_ROOT, env });
  } catch (error) {
    componentProof.checks.toolchain = { result: 'incomplete', detail: 'Toolchain inspection threw before a build could start.' };
    componentProof.failures.push(createFailure(error?.code ?? 'TOOLCHAIN_INSPECTION_FAILED', sanitizeError(error, replacements)));
    return finalizeComponentProof(componentProof, componentProof.failures.some((entry) => entry.code === 'TOOLCHAIN_OVERRIDE_FORBIDDEN') ? 'fail' : 'incomplete');
  }

  const resolvedToolchain = validateResolvedToolchain(inspection, componentProof.failures);
  if (!resolvedToolchain) {
    componentProof.checks.toolchain = { result: 'incomplete', detail: 'Toolchain inspection did not satisfy the OHOS arm64/API 20 contract.' };
    return finalizeComponentProof(componentProof, componentProof.failures.some((entry) => entry.code === 'TOOLCHAIN_OVERRIDE_FORBIDDEN') ? 'fail' : 'incomplete');
  }
  componentProof.checks.toolchain = { result: 'pass', detail: 'Integrated DevEco OHOS arm64 toolchain discovered.' };

  const goCachePath = env.GOCACHE ? path.resolve(env.GOCACHE) : DEFAULT_GO_CACHE_PATH;
  const goModCachePath = env.GOMODCACHE ? path.resolve(env.GOMODCACHE) : DEFAULT_GO_MOD_CACHE_PATH;
  await fsApi.mkdir(goCachePath, { recursive: true });
  await fsApi.mkdir(goModCachePath, { recursive: true });

  const buildEnv = {
    ...process.env,
    ...env,
    GOOS: 'linux',
    GOARCH: 'arm64',
    CGO_ENABLED: '1',
    CC: resolvedToolchain.clangBinary,
    CXX: resolvedToolchain.cxxBinary,
    PATH: `${resolvedToolchain.clangDirectory}${path.delimiter}${env.PATH ?? process.env.PATH ?? ''}`,
    GOCACHE: goCachePath,
    GOMODCACHE: goModCachePath
  };
  let goBinaryPath;
  try {
    goBinaryPath = await resolveGoBinaryImpl({ env, fsApi });
  } catch (error) {
    componentProof.checks.build = { result: 'incomplete', detail: 'Failed to resolve a trusted go binary.' };
    componentProof.failures.push(createFailure(error?.code ?? 'GO_BINARY_NOT_FOUND', sanitizeError(error, replacements)));
    return finalizeComponentProof(componentProof, 'incomplete');
  }
  componentProof.toolVersions.goBinary = normalizePathForReport(REPO_ROOT, goBinaryPath);
  componentProof.toolVersions.goVersion = await readGoVersionImpl({ cwd: moduleAbsolutePath, env: buildEnv, runCommandImpl, spawnImpl, goBinaryPath });

  const buildArgs = ['build', '-mod=readonly', '-tags', 'ohos', '-buildmode=c-shared', '-o', artifactPath, ...extraGoArgs, packagePath];
  componentProof.build.command = [normalizePathForReport(REPO_ROOT, goBinaryPath), ...buildArgs];
  componentProof.build.env = {
    GOOS: buildEnv.GOOS,
    GOARCH: buildEnv.GOARCH,
    CGO_ENABLED: buildEnv.CGO_ENABLED,
    CC: buildEnv.CC,
    CXX: buildEnv.CXX,
    GOCACHE: normalizePathForReport(REPO_ROOT, buildEnv.GOCACHE),
    GOMODCACHE: normalizePathForReport(REPO_ROOT, buildEnv.GOMODCACHE)
  };

  const buildResult = await runCommandImpl({
    command: goBinaryPath,
    args: buildArgs,
    cwd: moduleAbsolutePath,
    env: buildEnv,
    spawnImpl,
    timeoutMs: GO_BUILD_TIMEOUT_MS
  });

  if (buildResult.error || buildResult.exitCode !== 0) {
    componentProof.checks.build = { result: buildResult.timedOut ? 'incomplete' : 'fail', detail: buildResult.timedOut ? 'go build timed out.' : 'go build returned a non-zero exit code.' };
    componentProof.failures.push(createFailure(
      buildResult.timedOut ? 'GO_BUILD_TIMEOUT' : 'GO_BUILD_FAILED',
      sanitizeText(buildResult.stderr || buildResult.stdout || buildResult.error?.message || 'go build failed', replacements)
    ));
    return finalizeComponentProof(componentProof, buildResult.timedOut ? 'incomplete' : 'fail');
  }
  componentProof.checks.build = { result: 'pass', detail: 'go build produced a c-shared library.' };

  const artifactExists = await pathExists(artifactPath, fsApi);
  const headerExists = await pathExists(headerPath, fsApi);
  componentProof.artifact.exists = artifactExists;
  if (!artifactExists || !headerExists) {
    if (!artifactExists) {
      componentProof.failures.push(createFailure('ARTIFACT_MISSING', artifactPath));
    }
    if (!headerExists) {
      componentProof.failures.push(createFailure('HEADER_MISSING', headerPath));
    }
    componentProof.checks.elfInspection = { result: 'incomplete', detail: 'Expected shared library/header was not created.' };
    return finalizeComponentProof(componentProof, 'incomplete');
  }

  try {
    const inspectNativeLibrary = inspectNativeLibraryImpl ?? (await import('../tests/bin/inspect-native-lib.mjs')).inspectNativeLibrary;
    componentProof.elfInspection = await inspectNativeLibrary({
      libPath: artifactPath,
      component,
      harmonyRoot,
      repoRoot: REPO_ROOT,
      toolchainInspectorImpl
    });
  } catch (error) {
    componentProof.checks.elfInspection = { result: 'fail', detail: 'ELF inspection threw before the component could be validated.' };
    componentProof.failures.push(createFailure(error?.code ?? 'ELF_INSPECTION_FAILED', sanitizeError(error, replacements)));
    return finalizeComponentProof(componentProof, 'fail');
  }

  if (componentProof.elfInspection.result !== 'pass') {
    componentProof.checks.elfInspection = { result: 'fail', detail: 'ELF inspection reported contract violations.' };
    componentProof.failures.push(...componentProof.elfInspection.failures);
    return finalizeComponentProof(componentProof, 'fail');
  }
  for (const symbol of expectedExports) {
    if (!componentProof.elfInspection.exportedSymbols.includes(symbol)) {
      componentProof.failures.push(createFailure('EXPORT_MISSING', symbol));
    }
  }
  if (componentProof.failures.length > 0) {
    componentProof.checks.elfInspection = { result: 'fail', detail: 'The shared library did not expose the expected public exports.' };
    return finalizeComponentProof(componentProof, 'fail');
  }

  componentProof.checks.elfInspection = { result: 'pass', detail: 'ELF machine, DT_NEEDED, and public exports match the contract.' };
  return finalizeComponentProof(componentProof, 'pass');
}

function mergeComponentResult(aggregateProof, componentProof) {
  aggregateProof.components[componentProof.component] = componentProof;
  aggregateProof.failures.push(...componentProof.failures.map((entry) => ({ ...entry, component: componentProof.component })));
}

function deriveProbeOverallResult(componentProof) {
  if (!componentProof) {
    return 'incomplete';
  }
  if (componentProof.result === 'pass') {
    return 'incomplete';
  }
  return componentProof.result;
}

export async function buildGoOhosProbe(options = {}) {
  const proofPath = options.proofPath ?? GO_OHOS_PROOF_PATH;
  const harmonyRoot = options.harmonyRoot ?? HARMONY_ROOT;
  const aggregateProof = createAggregateProof({ outputPath: proofPath, harmonyRoot });
  const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: options.env ?? process.env });

  try {
    const componentProof = await buildGoComponent({
      ...COMPONENT_CONFIG.probe,
      harmonyRoot: options.harmonyRoot,
      env: options.env,
      fsApi: options.fsApi,
      spawnImpl: options.spawnImpl,
      runCommandImpl: options.runCommandImpl,
      toolchainInspectorImpl: options.toolchainInspectorImpl,
      inspectNativeLibraryImpl: options.inspectNativeLibraryImpl,
      readGoVersionImpl: options.readGoVersionImpl,
      readToolchainVersionsImpl: options.readToolchainVersionsImpl,
      resolveGoBinaryImpl: options.resolveGoBinaryImpl
    });
    mergeComponentResult(aggregateProof, componentProof);
    return await persistAggregateProof(finalizeAggregateProof(aggregateProof, deriveProbeOverallResult(componentProof)), proofPath, replacements, options.fsApi ?? fs);
  } catch (error) {
    aggregateProof.failures.push(createFailure(error?.code ?? 'UNEXPECTED_ERROR', sanitizeError(error, replacements)));
    return await persistAggregateProof(finalizeAggregateProof(aggregateProof, 'fail'), proofPath, replacements, options.fsApi ?? fs);
  }
}

function parseCliArguments(argv = process.argv.slice(2)) {
  let proofPath = GO_OHOS_PROOF_PATH;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--out') {
      const nextValue = argv[index + 1] ?? null;
      if (!nextValue || nextValue.startsWith('--')) {
        throw Object.assign(new Error('--out requires a value'), { code: 'ARGUMENT_INVALID' });
      }
      proofPath = path.resolve(nextValue);
      index += 1;
      continue;
    }
    throw Object.assign(new Error(`Unknown argument: ${value}`), { code: 'ARGUMENT_INVALID' });
  }
  return { proofPath };
}

export async function runCli({ argv = process.argv.slice(2) } = {}) {
  let parsed = null;
  try {
    parsed = parseCliArguments(argv);
  } catch (error) {
    const proofPath = GO_OHOS_PROOF_PATH;
    const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: process.env });
    const proof = createAggregateProof({ outputPath: proofPath, harmonyRoot: HARMONY_ROOT });
    proof.failures.push(createFailure(error?.code ?? 'ARGUMENT_INVALID', sanitizeError(error, replacements)));
    const persisted = await persistAggregateProof(finalizeAggregateProof(proof, 'fail'), proofPath, replacements);
    process.stdout.write(`${JSON.stringify(persisted, null, 2)}\n`);
    return 1;
  }

  const proof = await buildGoOhosProbe({ proofPath: parsed.proofPath });
  process.stdout.write(`${JSON.stringify(proof, null, 2)}\n`);
  return proof.components.probe?.result === 'pass' ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
