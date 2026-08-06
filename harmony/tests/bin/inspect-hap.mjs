import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { inspectHapNativeEntries } from '../../tools/lib/native-provenance.mjs';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const DEFAULT_MANIFEST_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase1-native-provenance.json');
const DEFAULT_UPSTREAM_LOCK_PATH = path.join(HARMONY_ROOT, 'core', 'go', 'upstream.lock.json');
const HAP_CORE_ENTRY = 'libs/arm64-v8a/libcmfa_mihomo.so';
const HAP_ADDON_ENTRY = 'libs/arm64-v8a/libentry.so';

function isoTimestamp(date = new Date()) {
  return date.toISOString();
}

function createFailure(code, detail, stage = 'archive') {
  return { code, detail, stage };
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

function isWithinRepo(repoRoot, filePath) {
  const relativePath = path.relative(repoRoot, filePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

async function resolveExistingRepoScopedPath(fsApi, repoRoot, filePath, option) {
  const resolved = path.resolve(filePath);
  if (!isWithinRepo(repoRoot, resolved) || resolved === repoRoot) {
    throw Object.assign(new Error(`${option} must stay inside the repository.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  const [realRepoRoot, realFilePath] = await Promise.all([
    fsApi.realpath(repoRoot),
    fsApi.realpath(resolved)
  ]);
  if (!isWithinRepo(realRepoRoot, realFilePath) || realFilePath === realRepoRoot) {
    throw Object.assign(new Error(`${option} resolves outside the repository.`), { code: 'PATH_OUTSIDE_REPO' });
  }
  return realFilePath;
}

async function hashFile(filePath, fsApi = fs) {
  const buffer = await fsApi.readFile(filePath);
  return {
    sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
    sizeBytes: buffer.byteLength
  };
}

async function readJson(fsApi, filePath, code) {
  try {
    return JSON.parse(await fsApi.readFile(filePath, 'utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? `Unable to read ${filePath}`), { code });
  }
}

async function readUpstreamLock(fsApi, upstreamLockPath = DEFAULT_UPSTREAM_LOCK_PATH) {
  const lock = await readJson(fsApi, upstreamLockPath, 'UPSTREAM_LOCK_INVALID');
  return {
    version: lock?.version ?? null,
    commit: lock?.commit ?? null
  };
}

function normalizeArchiveListing(entries) {
  if (Array.isArray(entries)) {
    const occurrences = {};
    for (const entry of entries) {
      occurrences[entry] = (occurrences[entry] ?? 0) + 1;
    }
    return {
      entries,
      entryCount: entries.length,
      occurrences
    };
  }
  return entries;
}

async function inspectArchiveWithMocks({
  hapPath,
  listHapEntriesImpl,
  inspectNativeLibraryImpl,
  hashFileImpl
}) {
  const listed = normalizeArchiveListing(await listHapEntriesImpl(hapPath));
  const failures = [];
  const artifacts = { core: null, addon: null };

  for (const [componentKey, entryPath, component] of [
    ['core', HAP_CORE_ENTRY, 'mihomoCore'],
    ['addon', HAP_ADDON_ENTRY, 'nodeAddon']
  ]) {
    const exactCount = listed.occurrences?.[entryPath] ?? 0;
    const baseName = path.posix.basename(entryPath);
    const basenameMatches = (listed.entries ?? []).filter((candidate) => path.posix.basename(candidate) === baseName);

    if (exactCount === 0) {
      failures.push(createFailure('HAP_NATIVE_ENTRY_MISSING', entryPath));
      if (basenameMatches.length > 0) {
        failures.push(createFailure('HAP_NATIVE_ENTRY_WRONG_PATH', baseName));
      }
      continue;
    }
    if (exactCount !== 1) {
      failures.push(createFailure('HAP_NATIVE_ENTRY_AMBIGUOUS', entryPath));
      continue;
    }
    if (basenameMatches.some((candidate) => candidate !== entryPath)) {
      failures.push(createFailure('HAP_NATIVE_ENTRY_WRONG_PATH', baseName));
      continue;
    }

    const syntheticPath = path.join(path.dirname(hapPath), entryPath);
    const [digest, elf] = await Promise.all([
      hashFileImpl(syntheticPath),
      inspectNativeLibraryImpl({ libPath: syntheticPath, component })
    ]);
    artifacts[componentKey] = {
      identity: entryPath,
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes,
      elf
    };
  }

  return {
    entryCount: listed.entryCount ?? 0,
    occurrences: {
      core: listed.occurrences?.[HAP_CORE_ENTRY] ?? 0,
      addon: listed.occurrences?.[HAP_ADDON_ENTRY] ?? 0
    },
    artifacts,
    failures
  };
}

function pushIfMissing(reportFailures, archiveFailures, archiveArtifact, componentPrefix) {
  if (!archiveArtifact) {
    reportFailures.push(createFailure(`${componentPrefix}_MISSING`, `${componentPrefix} is absent from the packaged HAP.`));
    return true;
  }
  if (archiveArtifact.elf?.result !== 'pass') {
    reportFailures.push(createFailure(`${componentPrefix}_ELF_INVALID`, `${componentPrefix} failed native ELF inspection.`));
    for (const failure of archiveArtifact.elf?.failures ?? []) {
      reportFailures.push(createFailure(failure.code, failure.detail, failure.stage ?? 'archive'));
    }
  }
  for (const failure of archiveFailures) {
    reportFailures.push(createFailure(failure.code, failure.detail, failure.stage ?? 'archive'));
  }
  return false;
}

function sameDigest(left, right) {
  return Boolean(left && right && left.sha256 === right.sha256 && left.sizeBytes === right.sizeBytes);
}

export async function inspectHap({
  hapPath,
  manifest,
  manifestPath = DEFAULT_MANIFEST_PATH,
  repoRoot = REPO_ROOT,
  fsApi = fs,
  hashFileImpl = (filePath) => hashFile(filePath, fsApi),
  inspectHapNativeEntriesImpl = inspectHapNativeEntries,
  listHapEntriesImpl = null,
  inspectNativeLibraryImpl = null
} = {}) {
  if (!hapPath) {
    throw Object.assign(new Error('--hap is required'), { code: 'HAP_PATH_REQUIRED' });
  }

  const [resolvedHapPath, resolvedManifestPath] = await Promise.all([
    resolveExistingRepoScopedPath(fsApi, repoRoot, hapPath, '--hap'),
    manifest ? Promise.resolve(null) : resolveExistingRepoScopedPath(fsApi, repoRoot, manifestPath, '--manifest')
  ]);
  const loadedManifest = manifest ?? await readJson(fsApi, resolvedManifestPath, 'PHASE1_MANIFEST_INVALID');
  const expectedUpstream = loadedManifest?.provenance?.upstream ?? await readUpstreamLock(fsApi);

  const report = {
    schemaVersion: '1.0.0',
    inspectedAt: isoTimestamp(),
    result: 'fail',
    hap: {
      path: normalizePathForReport(repoRoot, resolvedHapPath),
      sha256: null,
      sizeBytes: null
    },
    packaged: {
      core: null,
      addon: null
    },
    provenance: {
      expected: expectedUpstream,
      observed: null
    },
    archive: {
      entryCount: 0,
      occurrences: {
        core: 0,
        addon: 0
      }
    },
    stubDetected: null,
    failures: []
  };

  const liveHap = await hashFileImpl(resolvedHapPath);
  report.hap.sha256 = liveHap.sha256;
  report.hap.sizeBytes = liveHap.sizeBytes;

  if (!sameDigest(liveHap, loadedManifest?.artifacts?.hap)) {
    report.failures.push(createFailure('HAP_REHASH_MISMATCH', 'The supplied HAP bytes do not match the fresh build manifest.'));
  }

  const archive = listHapEntriesImpl && inspectNativeLibraryImpl
    ? await inspectArchiveWithMocks({
      hapPath: resolvedHapPath,
      listHapEntriesImpl,
      inspectNativeLibraryImpl,
      hashFileImpl
    })
    : await inspectHapNativeEntriesImpl({
      hapPath: resolvedHapPath,
      runId: 'phase2-proof'
    }, {
      fsApi,
      inspectNativeLibraryImpl: inspectNativeLibraryImpl ?? undefined,
      captureInspectErrors: true
    });

  report.archive = {
    entryCount: archive.entryCount ?? 0,
    occurrences: {
      core: archive.occurrences?.core ?? 0,
      addon: archive.occurrences?.addon ?? 0
    }
  };
  report.packaged.core = archive.artifacts?.core ?? null;
  report.packaged.addon = archive.artifacts?.addon ?? null;

  const missingCore = pushIfMissing(report.failures, archive.failures ?? [], archive.artifacts?.core, 'HAP_CORE');
  pushIfMissing(report.failures, archive.failures ?? [], archive.artifacts?.addon, 'HAP_ADDON');

  if (archive.artifacts?.core && !sameDigest(archive.artifacts.core, loadedManifest?.artifacts?.hapCore)) {
    report.failures.push(createFailure('HAP_CORE_REHASH_MISMATCH', 'Packaged core bytes do not match the fresh build manifest.'));
  }
  if (archive.artifacts?.addon && !sameDigest(archive.artifacts.addon, loadedManifest?.artifacts?.hapAddon)) {
    report.failures.push(createFailure('HAP_ADDON_REHASH_MISMATCH', 'Packaged addon bytes do not match the fresh build manifest.'));
  }

  const observedBuildInfo = archive.artifacts?.core?.elf?.buildInfo ?? null;
  report.provenance.observed = observedBuildInfo;
  if (!missingCore) {
    if (!observedBuildInfo?.version || !observedBuildInfo?.upstreamCommit || !observedBuildInfo?.buildId) {
      report.failures.push(createFailure('HAP_CORE_PROVENANCE_MISSING', 'Packaged core is missing exact build provenance.'));
    } else if (
      observedBuildInfo.version !== expectedUpstream?.version ||
      observedBuildInfo.upstreamCommit !== expectedUpstream?.commit
    ) {
      report.failures.push(createFailure('HAP_CORE_PROVENANCE_MISMATCH', 'Packaged core provenance does not match the pinned upstream lock.'));
    }
  }

  const stubDetected = report.failures.some((entry) => /STUB|FAKE|PROBE_BACKEND/u.test(entry.code));
  report.stubDetected = stubDetected ? true : false;
  report.result = report.failures.length === 0 ? 'pass' : 'fail';
  return report;
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw Object.assign(new Error(`${option} requires a value.`), { code: 'ARGUMENT_INVALID' });
  }
  return value;
}

export function parseCliArguments(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let hapPath = null;
  let manifestPath = path.join(repoRoot, 'harmony', 'artifacts', 'phase1-native-provenance.json');

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--hap') {
      hapPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    if (option === '--manifest') {
      manifestPath = path.resolve(repoRoot, requireValue(argv, index, option));
      index += 1;
      continue;
    }
    throw Object.assign(new Error(`Unknown argument: ${option}`), { code: 'ARGUMENT_INVALID' });
  }

  if (!hapPath) {
    throw Object.assign(new Error('--hap is required'), { code: 'HAP_PATH_REQUIRED' });
  }

  return { hapPath, manifestPath };
}

export async function runCli({ argv = process.argv.slice(2), inspectHapImpl = inspectHap } = {}) {
  try {
    const parsed = parseCliArguments(argv);
    const report = await inspectHapImpl(parsed);
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return report.result === 'pass' ? 0 : 1;
  } catch (error) {
    process.stderr.write(`${JSON.stringify({
      schemaVersion: '1.0.0',
      result: 'fail',
      code: error?.code ?? 'UNEXPECTED_ERROR',
      detail: error?.message ?? String(error)
    }, null, 2)}\n`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
