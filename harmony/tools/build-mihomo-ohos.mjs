import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { buildGoComponent, GO_OHOS_PROOF_PATH } from './build-go-ohos-probe.mjs';
import { createRedactionReplacements, sanitizeForPersistence, sanitizeText } from './lib/proof-redaction.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const UPSTREAM_LOCK_PATH = path.join(HARMONY_ROOT, 'core', 'go', 'upstream.lock.json');
const PROBE_COMPONENT_CONFIG = {
  component: 'probe',
  artifactFileName: 'libcmfa_probe.so',
  expectedExports: ['cmfa_probe_add', 'cmfa_probe_version'],
  modulePath: 'core/go/probe',
  packagePath: '.',
  targetName: 'HarmonyOS 6/API 20/arm64'
};
const CORE_COMPONENT_CONFIG = {
  component: 'mihomoCore',
  artifactFileName: 'libcmfa_mihomo.so',
  expectedExports: ['cmfa_mihomo_core_version_cstr_v1'],
  modulePath: 'core/go',
  packagePath: './cmd/cmfa_core',
  targetName: 'HarmonyOS 6/API 20/arm64'
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

function createAggregateProof({ outputPath, harmonyRoot }) {
  return {
    schemaVersion: '1.0.0',
    result: 'incomplete',
    outputPath: normalizeHarmonyPath(harmonyRoot, outputPath),
    harmonyRoot: normalizeHarmonyPath(harmonyRoot, harmonyRoot),
    target: {
      name: 'HarmonyOS 6/API 20/arm64',
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

async function cleanupCanonicalArtifacts(harmonyRoot, fsApi = fs) {
  const artifactsRoot = path.join(harmonyRoot, 'artifacts');
  await fsApi.mkdir(artifactsRoot, { recursive: true });
  for (const artifactName of ['libcmfa_probe.so', 'libcmfa_probe.h', 'libcmfa_mihomo.so', 'libcmfa_mihomo.h']) {
    await fsApi.rm(path.join(artifactsRoot, artifactName), { force: true });
  }
}

async function persistProof(proof, proofPath, replacements, fsApi = fs) {
  const sanitized = sanitizeForPersistence(proof, replacements);
  await fsApi.mkdir(path.dirname(proofPath), { recursive: true });
  await fsApi.writeFile(proofPath, `${JSON.stringify(sanitized, null, 2)}\n`, 'utf8');
  return sanitized;
}

function mergeComponent(aggregateProof, componentProof) {
  aggregateProof.components[componentProof.component] = componentProof;
  aggregateProof.failures.push(...componentProof.failures.map((entry) => ({ ...entry, component: componentProof.component })));
}

function validateUpstreamLock(lock) {
  const expected = {
    schemaVersion: '1.0.0',
    module: 'github.com/metacubex/mihomo',
    version: 'v1.19.29',
    commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
    remote: 'https://github.com/MetaCubeX/mihomo',
    ref: 'refs/tags/v1.19.29'
  };

  for (const [key, value] of Object.entries(expected)) {
    if (lock?.[key] !== value) {
      throw Object.assign(new Error(`Invalid upstream lock field ${key}: expected ${value}, received ${lock?.[key] ?? 'missing'}`), {
        code: 'UPSTREAM_LOCK_INVALID'
      });
    }
  }

  return expected;
}

async function readUpstreamLock({ upstreamLock, upstreamLockPath = UPSTREAM_LOCK_PATH, fsApi = fs }) {
  if (upstreamLock) {
    return validateUpstreamLock(upstreamLock);
  }

  let raw;
  try {
    raw = await fsApi.readFile(upstreamLockPath, 'utf8');
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? 'Failed to read upstream lock'), { code: error?.code ?? 'UPSTREAM_LOCK_READ_FAILED' });
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? 'Failed to parse upstream lock'), { code: 'UPSTREAM_LOCK_INVALID' });
  }

  return validateUpstreamLock(parsed);
}

function deriveOverallResult(aggregateProof) {
  const probeResult = aggregateProof.components.probe?.result ?? 'incomplete';
  const coreResult = aggregateProof.components.mihomoCore?.result ?? 'incomplete';
  if (probeResult === 'pass' && coreResult === 'pass') {
    return 'pass';
  }
  if (probeResult === 'fail' || coreResult === 'fail') {
    return 'fail';
  }
  return 'incomplete';
}

export async function buildMihomoOhos(options = {}) {
  const proofPath = options.proofPath ?? GO_OHOS_PROOF_PATH;
  const harmonyRoot = options.harmonyRoot ?? HARMONY_ROOT;
  const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: options.env ?? process.env });
  const aggregateProof = createAggregateProof({ outputPath: proofPath, harmonyRoot });
  const fsApi = options.fsApi ?? fs;

  try {
    await cleanupCanonicalArtifacts(harmonyRoot, fsApi);
    const upstreamLock = await readUpstreamLock({
      upstreamLock: options.upstreamLock,
      upstreamLockPath: options.upstreamLockPath,
      fsApi
    });

    const buildProbeComponentImpl = options.buildProbeComponentImpl ?? buildGoComponent;
    const buildCoreComponentImpl = options.buildCoreComponentImpl ?? buildGoComponent;

    const probeProof = await buildProbeComponentImpl({
      ...PROBE_COMPONENT_CONFIG,
      harmonyRoot: options.harmonyRoot,
      env: options.env,
      fsApi,
      spawnImpl: options.spawnImpl,
      runCommandImpl: options.runCommandImpl,
      toolchainInspectorImpl: options.toolchainInspectorImpl,
      inspectNativeLibraryImpl: options.inspectNativeLibraryImpl,
      readGoVersionImpl: options.readGoVersionImpl,
      readToolchainVersionsImpl: options.readToolchainVersionsImpl,
      resolveGoBinaryImpl: options.resolveGoBinaryImpl
    });
    mergeComponent(aggregateProof, probeProof);

    const coreProof = await buildCoreComponentImpl({
      ...CORE_COMPONENT_CONFIG,
      harmonyRoot: options.harmonyRoot,
      env: options.env,
      fsApi,
      spawnImpl: options.spawnImpl,
      runCommandImpl: options.runCommandImpl,
      toolchainInspectorImpl: options.toolchainInspectorImpl,
      inspectNativeLibraryImpl: options.inspectNativeLibraryImpl,
      readGoVersionImpl: options.readGoVersionImpl,
      readToolchainVersionsImpl: options.readToolchainVersionsImpl,
      resolveGoBinaryImpl: options.resolveGoBinaryImpl,
      extraGoArgs: ['-ldflags', `-X github.com/metacubex/mihomo/constant.Version=${upstreamLock.version}`]
    });
    mergeComponent(aggregateProof, coreProof);

    return await persistProof(finalizeAggregateProof(aggregateProof, deriveOverallResult(aggregateProof)), proofPath, replacements, fsApi);
  } catch (error) {
    aggregateProof.failures.push(createFailure(error?.code ?? 'UNEXPECTED_ERROR', sanitizeText(error?.message ?? String(error), replacements)));
    return await persistProof(finalizeAggregateProof(aggregateProof, 'fail'), proofPath, replacements, fsApi);
  }
}

function parseCliArguments(argv = process.argv.slice(2)) {
  if (argv.length > 0) {
    throw Object.assign(new Error(`Unknown argument: ${argv[0]}`), { code: 'ARGUMENT_INVALID' });
  }
  return {};
}

export async function runCli({ argv = process.argv.slice(2) } = {}) {
  let parsed;
  try {
    parsed = parseCliArguments(argv);
  } catch (error) {
    const replacements = createRedactionReplacements({ repoRoot: REPO_ROOT, env: process.env });
    const proof = createAggregateProof({ outputPath: GO_OHOS_PROOF_PATH, harmonyRoot: HARMONY_ROOT });
    proof.failures.push(createFailure(error?.code ?? 'ARGUMENT_INVALID', sanitizeText(error?.message ?? String(error), replacements)));
    const persisted = await persistProof(finalizeAggregateProof(proof, 'fail'), GO_OHOS_PROOF_PATH, replacements);
    process.stdout.write(`${JSON.stringify(persisted, null, 2)}\n`);
    return 1;
  }

  const proof = await buildMihomoOhos(parsed);
  process.stdout.write(`${JSON.stringify(proof, null, 2)}\n`);
  return proof.result === 'pass' ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
