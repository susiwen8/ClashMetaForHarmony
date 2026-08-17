#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { inspectHap } from './inspect-hap.mjs';
import { listHapEntries } from '../../tools/lib/native-provenance.mjs';

const execFile = promisify(execFileCallback);
const HARMONY_ROOT = path.resolve(new URL('../..', import.meta.url).pathname);
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const DEFAULT_REQUIREMENTS_PATH = fileURLToPath(new URL('../../toolchain.requirements.json', import.meta.url));
const EXACT_BUNDLES = Object.freeze({
  production: 'com.github.kr328.clash.harmony',
  probe: 'com.github.kr328.clash.harmony.trafficprobe'
});
const EXACT_PERMISSIONS = Object.freeze({
  production: ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING'],
  probe: ['ohos.permission.INTERNET']
});
const SIGNATURE_ENTRY_PATTERN = /^META-INF\/.+\.(?:SF|RSA|DSA|EC|CMS)$/u;

function createFailure(code, detail) {
  return { code, detail };
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sortPermissions(values = []) {
  return [...values].sort();
}

function exactPermissionSet(actual, expected) {
  return JSON.stringify(sortPermissions(actual)) === JSON.stringify(sortPermissions(expected));
}

function hasUnsignedName(filePath) {
  return /-unsigned\.hap$/iu.test(path.basename(filePath));
}

function hasNativeEntries(entries) {
  return entries.some((entry) => /\.so$/iu.test(entry));
}

function isWithinRepo(repoRoot, filePath) {
  const relativePath = path.relative(repoRoot, filePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function ensureRepoScopedInputPath(repoRoot, inputPath, option) {
  const resolved = path.resolve(inputPath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error(`${option} must stay inside the repository.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return resolved;
}

function normalizeArchiveEntries(listing) {
  if (Array.isArray(listing)) {
    const occurrences = {};
    for (const entry of listing) {
      occurrences[entry] = (occurrences[entry] ?? 0) + 1;
    }
    return {
      entries: [...listing],
      entryCount: listing.length,
      occurrences
    };
  }
  return {
    entries: [...(listing?.entries ?? [])],
    entryCount: listing?.entryCount ?? 0,
    occurrences: { ...(listing?.occurrences ?? {}) }
  };
}

async function readJson(fsApi, filePath, code) {
  try {
    return JSON.parse(await fsApi.readFile(filePath, 'utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? `Unable to read ${filePath}`), { code });
  }
}

function normalizePermissionList(rawPermissions) {
  if (!Array.isArray(rawPermissions)) {
    return [];
  }
  return rawPermissions
    .map((entry) => typeof entry === 'string' ? entry : `${entry?.name ?? ''}`)
    .filter((entry) => entry.length > 0);
}

async function defaultHashFile(filePath, fsApi = fs) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: sha256(buffer),
    sizeBytes: buffer.byteLength
  };
}

export async function defaultListArchiveEntries(hapPath) {
  return normalizeArchiveEntries(await listHapEntries(hapPath));
}

async function unzipReadEntry(hapPath, entryPath) {
  if (entryPath.includes('..') || path.posix.isAbsolute(entryPath)) {
    throw Object.assign(new Error(`Archive entry escapes package root: ${entryPath}`), { code: 'ARCHIVE_ENTRY_TRAVERSAL' });
  }
  const { stdout } = await execFile('/usr/bin/unzip', ['-p', hapPath, entryPath], {
    encoding: 'buffer',
    maxBuffer: 10 * 1024 * 1024
  });
  return Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout);
}

export async function defaultReadModuleJson(hapPath, archiveListing = null) {
  const listing = archiveListing ?? await defaultListArchiveEntries(hapPath);
  const matches = listing.entries.filter((entry) => entry === 'module.json');
  if (matches.length !== 1) {
    throw Object.assign(new Error('HAP must contain exactly one root module.json.'), { code: 'MODULE_JSON_MISSING' });
  }
  const raw = await unzipReadEntry(hapPath, 'module.json');
  let parsed = null;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? 'module.json parse failed'), { code: 'MODULE_JSON_INVALID' });
  }
  return {
    bundleName: `${parsed?.bundleName ?? parsed?.app?.bundleName ?? ''}`,
    requestPermissions: normalizePermissionList(parsed?.requestPermissions ?? parsed?.module?.requestPermissions)
  };
}

export async function defaultReadSignature(hapPath, archiveListing = null) {
  const listing = archiveListing ?? await defaultListArchiveEntries(hapPath);
  const signatureEntries = listing.entries.filter((entry) => SIGNATURE_ENTRY_PATTERN.test(entry)).sort();
  if (signatureEntries.length === 0) {
    return null;
  }
  const chunks = [];
  for (const entry of signatureEntries) {
    chunks.push(Buffer.from(`${entry}\n`, 'utf8'));
    chunks.push(await unzipReadEntry(hapPath, entry));
  }
  return {
    entries: signatureEntries,
    signatureSha256: sha256(Buffer.concat(chunks))
  };
}

export function buildVerifySignatureCommand({ hapPath, outCertChainPath, outProfilePath }) {
  throw new Error('buildVerifySignatureCommand requires resolved tool paths');
}

async function resolveDefaultVerifyToolPaths(fsApi = fs, requirementsPath = DEFAULT_REQUIREMENTS_PATH) {
  const requirements = await readJson(fsApi, requirementsPath, 'TOOL_MISSING');
  const sdkRoot = `${requirements?.defaults?.sdkRoots?.[0] ?? ''}`.trim();
  const devecoContentsRoot = `${requirements?.defaults?.devecoContentsRoots?.[0] ?? ''}`.trim();
  if (sdkRoot.length === 0 || devecoContentsRoot.length === 0) {
    throw Object.assign(new Error('DevEco SDK metadata is unavailable for signature verification.'), { code: 'TOOL_MISSING' });
  }
  return {
    javaCommand: path.join(devecoContentsRoot, 'jbr', 'Contents', 'Home', 'bin', 'java'),
    hapSignToolJar: path.join(sdkRoot, 'openharmony', 'toolchains', 'lib', 'hap-sign-tool.jar')
  };
}

export function buildVerifySignatureCommandWithTools({ hapPath, outCertChainPath, outProfilePath, javaCommand, hapSignToolJar }) {
  return {
    command: javaCommand,
    args: [
      '-jar',
      hapSignToolJar,
      'verify-app',
      '-inFile',
      hapPath,
      '-outCertChain',
      outCertChainPath,
      '-outProfile',
      outProfilePath
    ]
  };
}

export async function defaultVerifySignature({
  hapPath,
  fsApi = fs,
  execFileImpl = execFile,
  tempRoot = os.tmpdir(),
  requirementsPath = DEFAULT_REQUIREMENTS_PATH
} = {}) {
  const tempDirectory = await fsApi.mkdtemp(path.join(tempRoot, 'phase4-signature-'));
  const outCertChainPath = path.join(tempDirectory, 'chain-output.bin');
  const outProfilePath = path.join(tempDirectory, 'profile-output.bin');
  try {
    const tools = await resolveDefaultVerifyToolPaths(fsApi, requirementsPath);
    const invocation = buildVerifySignatureCommandWithTools({
      hapPath,
      outCertChainPath,
      outProfilePath,
      javaCommand: tools.javaCommand,
      hapSignToolJar: tools.hapSignToolJar
    });
    await execFileImpl(invocation.command, invocation.args, {
      cwd: REPO_ROOT,
      shell: false,
      windowsHide: true
    });
    const [certChain, profile] = await Promise.all([
      fsApi.readFile(outCertChainPath),
      fsApi.readFile(outProfilePath)
    ]);
    if (certChain.byteLength < 1 || profile.byteLength < 1) {
      return null;
    }
    return {
      signatureSha256: sha256(Buffer.concat([certChain, profile]))
    };
  } catch {
    return null;
  } finally {
    await fsApi.rm(tempDirectory, { recursive: true, force: true }).catch(() => {});
  }
}

async function defaultLoadProductionManifest(productionManifestPath, fsApi = fs) {
  const manifest = await readJson(fsApi, productionManifestPath, 'PRODUCTION_MANIFEST_INVALID');
  if (manifest?.signing?.result !== 'pass') {
    throw Object.assign(new Error('Production manifest must record signing result pass.'), { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  if (manifest?.nativeBuildResult !== 'pass') {
    throw Object.assign(new Error('Production manifest must record nativeBuildResult pass.'), { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  if (typeof manifest?.artifacts?.hap?.identity !== 'string' || manifest.artifacts.hap.identity.length === 0) {
    throw Object.assign(new Error('Production manifest must expose artifacts.hap.identity.'), { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  return manifest;
}

export async function defaultInspectNative({ hapPath, role, productionManifestPath, manifest }) {
  if (role !== 'production') {
    return null;
  }
  const inspection = await inspectHap({
    hapPath,
    manifest,
    manifestPath: productionManifestPath,
    buildKind: 'production'
  });
  return {
    addon: inspection.packaged?.addon?.elf ?? null,
    core: inspection.packaged?.core?.elf ?? null,
    stubDetected: inspection.stubDetected === true,
    failures: [...(inspection.failures ?? [])]
  };
}

async function inspectSinglePackage({
  hapPath,
  role,
  productionManifestPath,
  manifest,
  listArchiveEntriesImpl,
  hashFileImpl,
  readModuleJsonImpl,
  readSignatureImpl,
  verifySignatureImpl,
  inspectNativeImpl
}) {
  const listing = normalizeArchiveEntries(await listArchiveEntriesImpl(hapPath));
  const [hash, moduleInfo, signature, verifiedSignature, nativeInfo] = await Promise.all([
    hashFileImpl(hapPath),
    readModuleJsonImpl(hapPath, listing),
    readSignatureImpl(hapPath, listing),
    verifySignatureImpl({ hapPath }),
    inspectNativeImpl({ hapPath, role, productionManifestPath, manifest, archiveListing: listing })
  ]);
  return {
    role,
    entries: listing.entries,
    hash,
    moduleInfo,
    signature,
    verifiedSignature,
    nativeInfo
  };
}

export async function inspectPhase4Packages({
  productionHapPath,
  productionManifestPath,
  probeHapPath,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  loadProductionManifestImpl = (filePath) => defaultLoadProductionManifest(filePath, fsApi),
  listArchiveEntriesImpl = defaultListArchiveEntries,
  hashFileImpl = (filePath) => defaultHashFile(filePath, fsApi),
  readModuleJsonImpl = defaultReadModuleJson,
  readSignatureImpl = defaultReadSignature,
  verifySignatureImpl = (options) => defaultVerifySignature({ ...options, fsApi }),
  inspectNativeImpl = defaultInspectNative
} = {}) {
  const resolvedProductionHapPath = ensureRepoScopedInputPath(repoRoot, productionHapPath, '--production-hap');
  const resolvedProbeHapPath = ensureRepoScopedInputPath(repoRoot, probeHapPath, '--probe-hap');
  const resolvedManifestPath = ensureRepoScopedInputPath(repoRoot, productionManifestPath, '--production-manifest');
  const manifest = await loadProductionManifestImpl(resolvedManifestPath);

  const expectedProductionIdentity = path.relative(repoRoot, resolvedProductionHapPath).split(path.sep).join('/');
  if (manifest.artifacts.hap.identity !== expectedProductionIdentity) {
    throw Object.assign(new Error('Production manifest HAP identity does not match the supplied production HAP path.'), { code: 'PRODUCTION_MANIFEST_MISMATCH' });
  }

  const failures = [];
  const [production, probe] = await Promise.all([
    inspectSinglePackage({
      hapPath: resolvedProductionHapPath,
      role: 'production',
      productionManifestPath: resolvedManifestPath,
      manifest,
      listArchiveEntriesImpl,
      hashFileImpl,
      readModuleJsonImpl,
      readSignatureImpl,
      verifySignatureImpl,
      inspectNativeImpl
    }),
    inspectSinglePackage({
      hapPath: resolvedProbeHapPath,
      role: 'probe',
      productionManifestPath: resolvedManifestPath,
      manifest,
      listArchiveEntriesImpl,
      hashFileImpl,
      readModuleJsonImpl,
      readSignatureImpl,
      verifySignatureImpl,
      inspectNativeImpl
    })
  ]);

  if (hasUnsignedName(resolvedProductionHapPath) || hasUnsignedName(resolvedProbeHapPath)) {
    failures.push(createFailure('HAP_UNSIGNED_FORBIDDEN', 'Unsigned production/probe HAPs cannot satisfy Phase 4 package proof.'));
  }
  if (!production.signature?.signatureSha256 || !probe.signature?.signatureSha256) {
    failures.push(createFailure('SIGNATURE_MISSING', 'Both HAPs must contain verifiable signature blocks.'));
  }
  if (!production.verifiedSignature?.signatureSha256 || !probe.verifiedSignature?.signatureSha256) {
    failures.push(createFailure('SIGNATURE_VERIFY_FAILED', 'Both HAPs must pass hap-sign-tool verify-app with non-empty outputs.'));
  }
  if (production.moduleInfo?.bundleName !== EXACT_BUNDLES.production) {
    failures.push(createFailure('PRODUCTION_BUNDLE_INVALID', 'Production HAP bundle name drifted.'));
  }
  if (probe.moduleInfo?.bundleName !== EXACT_BUNDLES.probe) {
    failures.push(createFailure('PROBE_BUNDLE_INVALID', 'Probe HAP bundle name drifted.'));
  }
  if (production.hash.sha256 === probe.hash.sha256) {
    failures.push(createFailure('HAP_HASH_COLLISION', 'Production and probe HAP hashes must differ.'));
  }
  if (production.verifiedSignature?.signatureSha256 === probe.verifiedSignature?.signatureSha256) {
    failures.push(createFailure('SIGNATURE_COLLISION', 'Production and probe signatures must differ.'));
  }
  if (!exactPermissionSet(production.moduleInfo?.requestPermissions, EXACT_PERMISSIONS.production)) {
    failures.push(createFailure('PRODUCTION_PERMISSIONS_INVALID', 'Production HAP permissions drifted.'));
  }
  if (!exactPermissionSet(probe.moduleInfo?.requestPermissions, EXACT_PERMISSIONS.probe)) {
    failures.push(createFailure('PROBE_PERMISSIONS_INVALID', 'Probe HAP permissions drifted.'));
  }

  const productionSymbols = [
    ...(production.nativeInfo?.addon?.exportedSymbols ?? []),
    ...(production.nativeInfo?.core?.exportedSymbols ?? [])
  ];
  for (const required of ['JNI_OnLoad', 'cmfa_mihomo_start_local_v1', 'cmfa_mihomo_runtime_state_v1']) {
    if (!productionSymbols.includes(required)) {
      failures.push(createFailure('PRODUCTION_CORE_MISSING', `Production native payload missing ${required}.`));
      break;
    }
  }
  for (const nativeFailure of production.nativeInfo?.failures ?? []) {
    failures.push(createFailure(nativeFailure.code ?? 'PRODUCTION_NATIVE_INVALID', nativeFailure.detail ?? 'Production native inspection failed.'));
  }

  const probeHasNativePayload = hasNativeEntries(probe.entries) || probe.nativeInfo !== null;
  if (probeHasNativePayload) {
    failures.push(createFailure('PROBE_NATIVE_PAYLOAD_FORBIDDEN', 'Probe HAP must not contain native payload.'));
  }
  const probeEmbeddedInProduction = production.entries.some((entry) => /ProbeAbility|ProbePage|trafficprobe/iu.test(entry));
  if (probeEmbeddedInProduction) {
    failures.push(createFailure('PROBE_EMBEDDED_IN_PRODUCTION', 'Production HAP must not embed probe resources or entry points.'));
  }

  return {
    schemaVersion: '1.0.0',
    result: failures.length === 0 ? 'pass' : 'fail',
    production: {
      bundleName: production.moduleInfo?.bundleName ?? '',
      hapSha256: production.hash.sha256,
      signatureSha256: production.verifiedSignature?.signatureSha256 ?? production.signature?.signatureSha256 ?? '',
      permissions: sortPermissions(production.moduleInfo?.requestPermissions ?? []),
      stubDetected: production.nativeInfo?.stubDetected === true || productionSymbols.some((entry) => /stub/iu.test(entry))
    },
    probe: {
      bundleName: probe.moduleInfo?.bundleName ?? '',
      hapSha256: probe.hash.sha256,
      signatureSha256: probe.verifiedSignature?.signatureSha256 ?? probe.signature?.signatureSha256 ?? '',
      permissions: sortPermissions(probe.moduleInfo?.requestPermissions ?? []),
      hasNativePayload: probeHasNativePayload
    },
    probeEmbeddedInProduction,
    failures
  };
}

export async function writeInspectionReport({ outputPath, report, fsApi = fs } = {}) {
  await fsApi.mkdir(path.dirname(outputPath), { recursive: true });
  const tempPath = `${outputPath}.${process.pid}.${Date.now()}.tmp`;
  await fsApi.writeFile(tempPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  await fsApi.rename(tempPath, outputPath);
  return report;
}

function parseCliArguments(argv = process.argv.slice(2)) {
  const parsed = {
    productionHapPath: '',
    productionManifestPath: '',
    probeHapPath: '',
    outputPath: ''
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    const value = argv[index + 1] ?? '';
    if (option === '--production-hap') parsed.productionHapPath = value;
    else if (option === '--production-manifest') parsed.productionManifestPath = value;
    else if (option === '--probe-hap') parsed.probeHapPath = value;
    else if (option === '--out') parsed.outputPath = value;
    else throw new Error(`unknown argument: ${option}`);
    index += 1;
  }
  return parsed;
}

async function main() {
  const parsed = parseCliArguments();
  const report = await inspectPhase4Packages(parsed);
  await writeInspectionReport({ outputPath: parsed.outputPath, report });
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch(async (error) => {
    const parsed = parseCliArguments(process.argv.slice(2));
    if (parsed.outputPath) {
      await writeInspectionReport({
        outputPath: parsed.outputPath,
        report: {
          schemaVersion: '1.0.0',
          result: 'fail',
          production: { bundleName: '', hapSha256: '', signatureSha256: '', permissions: [], stubDetected: false },
          probe: { bundleName: '', hapSha256: '', signatureSha256: '', permissions: [], hasNativePayload: false },
          probeEmbeddedInProduction: false,
          failures: [createFailure(error?.code ?? 'PACKAGE_INSPECTION_FAILED', error?.message ?? 'inspect failed')]
        }
      });
    }
    process.stderr.write(`${error?.message ?? error}\n`);
    process.exitCode = 1;
  });
}
