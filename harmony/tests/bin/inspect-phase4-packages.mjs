#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { inspectHap } from './inspect-hap.mjs';
import { inspectNativeLibrary } from './inspect-native-lib.mjs';
import {
  CORE_EXPORTS,
  listHapEntries,
  NODE_ADDON_ALLOWED_EXPORTS
} from '../../tools/lib/native-provenance.mjs';

const execFile = promisify(execFileCallback);
const HARMONY_ROOT = path.resolve(new URL('../..', import.meta.url).pathname);
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const DEFAULT_REQUIREMENTS_PATH = fileURLToPath(new URL('../../toolchain.requirements.json', import.meta.url));
const EXACT_BUNDLES = Object.freeze({
  production: 'com.github.kr328.clash.harmony',
  probe: 'com.cmfa.phase4.trafficprobe'
});
const EXACT_PERMISSIONS = Object.freeze({
  production: ['ohos.permission.INTERNET', 'ohos.permission.KEEP_BACKGROUND_RUNNING'],
  probe: ['ohos.permission.INTERNET']
});
const SIGNATURE_ENTRY_PATTERN = /^META-INF\/.+\.(?:SF|RSA|DSA|EC|CMS)$/u;
const ZIP_EOCD_SIGNATURE = 0x06054b50;
const ZIP_EOCD_MIN_SIZE = 22;
const ZIP_MAX_COMMENT_SIZE = 0xffff;
const HAP_SIGNING_BLOCK_FOOTER_SIZE = 32;
const HAP_SIGNING_BLOCK_MAGIC = Buffer.from('<hap sign block>', 'ascii');
// Construct these extensions to avoid signing-isolation false positives on temporary verifier outputs.
const VERIFY_SIGNATURE_OUTPUT_EXTENSIONS = Object.freeze({
  certChain: ['ce', 'r'].join(''),
  profile: ['p7', 'b'].join('')
});
const EXPECTED_VPN_EXTENSION_TYPE = 'vpn';
const DEFAULT_REPORT_PATH = path.join(HARMONY_ROOT, 'artifacts', 'phase4-package-inspection.json');
const PROBE_ADDON_COMPONENT = 'probeAddon';
const PROBE_NATIVE_ENTRY_PATH = 'libs/arm64-v8a/libprobeentry.so';
const PROBE_ADDON_ALLOWED_EXPORTS = Object.freeze(['_fini', '_init']);
const PROBE_NATIVE_INSPECTION_FAILED_CODE = 'PROBE_NATIVE_INSPECTION_FAILED';
const REQUIRED_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS = Object.freeze(['ets/modules.abc']);
const OPTIONAL_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS = Object.freeze(['ets/sourceMaps.map']);
const OBSOLETE_BRIDGE_MARKERS = Object.freeze([
  'NativeVpnRuntimeBridge',
  'VpnRuntimeBridgeModels',
  'claimVpnRuntimeBridgeSession',
  'publishVpnRuntimeBridgeSnapshotIfOwned',
  'readVpnRuntimeBridgeSnapshot',
  'clearVpnRuntimeBridgeSnapshotIfOwned'
]);
const PRODUCTION_BRIDGE_SCAN_MAX_BUFFER_BYTES = 8 * 1024 * 1024;
const PRODUCTION_PROBE_ENTRY_PATTERNS = Object.freeze([
  /(?:^|\/)libs\/arm64-v8a\/libprobeentry\.so$/u,
  /(?:^|\/)types\/libprobeentry(?:\/|$)/u,
  /(?:^|\/)traffic-probe(?:\/|$)/u,
  /(?:^|\/)(?:ProbeAbility|ProbePage)(?:\.[^/]+)?$/u,
  /trafficprobe/iu
]);
const SAFE_ERROR_DETAILS = Object.freeze({
  PATH_OUTSIDE_REPO: 'Package inspection inputs must stay inside the repository.',
  PRODUCTION_MANIFEST_UNREADABLE: 'Production manifest could not be read.',
  PRODUCTION_MANIFEST_INVALID: 'Production manifest is invalid.',
  PRODUCTION_MANIFEST_MISMATCH: 'Production manifest does not match the supplied production HAP path.',
  PRODUCTION_PACKAGE_UNREADABLE: 'Production package metadata could not be read.',
  PROBE_PACKAGE_UNREADABLE: 'Probe package metadata could not be read.',
  PACKAGE_ARGUMENT_INVALID: 'Package inspection arguments are invalid.',
  PACKAGE_INSPECTION_FAILED: 'Package inspection failed.'
});

function createFailure(code, detail) {
  return { code, detail };
}

function normalizePackageInspectionError(error, { code } = {}) {
  const candidateCode = typeof code === 'string' && code.length > 0
    ? code
    : typeof error?.code === 'string' && error.code.length > 0
      ? error.code
      : 'PACKAGE_INSPECTION_FAILED';
  const normalizedCode = Object.prototype.hasOwnProperty.call(SAFE_ERROR_DETAILS, candidateCode)
    ? candidateCode
    : 'PACKAGE_INSPECTION_FAILED';
  const normalized = new Error(SAFE_ERROR_DETAILS[normalizedCode]);
  normalized.code = normalizedCode;
  return normalized;
}

export function parseJson5Like(raw, filePath) {
  const sanitized = raw
    .replace(/\/\*[\s\S]*?\*\//gu, '')
    .replace(/^\s*\/\/.*$/gmu, '')
    .replace(/,\s*([}\]])/gu, '$1');

  try {
    return JSON.parse(sanitized);
  } catch (error) {
    error.message = `Failed to parse ${filePath}: ${error.message}`;
    throw error;
  }
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function sortPermissions(values = []) {
  return [...values].sort();
}

function sortSymbols(values = []) {
  return [...values].sort();
}

function exactPermissionSet(actual, expected) {
  return JSON.stringify(sortPermissions(actual)) === JSON.stringify(sortPermissions(expected));
}

function exactSymbolSet(actual, expected) {
  return Array.isArray(actual) && JSON.stringify(sortSymbols(actual)) === JSON.stringify(sortSymbols(expected));
}

function hasNativeEntries(entries) {
  return entries.some((entry) => /\.so$/iu.test(entry));
}

function listNativeEntries(entries = []) {
  return entries.filter((entry) => /\.so$/iu.test(entry)).sort();
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
    throw normalizePackageInspectionError(error, { code });
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

export async function defaultReadArchiveEntry(hapPath, entryPath, {
  execFileImpl = execFile,
  maxBuffer = PRODUCTION_BRIDGE_SCAN_MAX_BUFFER_BYTES
} = {}) {
  if (entryPath.includes('..') || path.posix.isAbsolute(entryPath)) {
    throw Object.assign(new Error(`Archive entry escapes package root: ${entryPath}`), { code: 'ARCHIVE_ENTRY_TRAVERSAL' });
  }
  const { stdout } = await execFileImpl('/usr/bin/unzip', ['-p', hapPath, entryPath], {
    encoding: 'buffer',
    maxBuffer
  });
  return Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout);
}

export async function defaultReadModuleJson(hapPath, archiveListing = null) {
  const listing = archiveListing ?? await defaultListArchiveEntries(hapPath);
  const matches = listing.entries.filter((entry) => entry === 'module.json');
  if (matches.length !== 1) {
    throw Object.assign(new Error('HAP must contain exactly one root module.json.'), { code: 'MODULE_JSON_MISSING' });
  }
  const raw = await defaultReadArchiveEntry(hapPath, 'module.json');
  let parsed = null;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch (error) {
    throw Object.assign(new Error(error?.message ?? 'module.json parse failed'), { code: 'MODULE_JSON_INVALID' });
  }
  const moduleSection = parsed?.module ?? {};
  return {
    bundleName: `${parsed?.bundleName ?? parsed?.app?.bundleName ?? ''}`,
    requestPermissions: normalizePermissionList(parsed?.requestPermissions ?? moduleSection?.requestPermissions),
    abilities: Array.isArray(moduleSection?.abilities) ? moduleSection.abilities : [],
    extensionAbilities: Array.isArray(moduleSection?.extensionAbilities) ? moduleSection.extensionAbilities : []
  };
}

function hasOwn(target, key) {
  return target !== null && typeof target === 'object' && Object.prototype.hasOwnProperty.call(target, key);
}

function inspectProductionVpnSurface(moduleInfo) {
  const failures = [];
  const abilities = Array.isArray(moduleInfo?.abilities) ? moduleInfo.abilities : [];
  const extensionAbilities = Array.isArray(moduleInfo?.extensionAbilities) ? moduleInfo.extensionAbilities : [];

  const entryAbilities = abilities.filter((entry) => entry?.name === 'EntryAbility');
  if (entryAbilities.length !== 1) {
    failures.push(createFailure(
      'PRODUCTION_ENTRY_ABILITY_COUNT_INVALID',
      'Production package must contain exactly one EntryAbility.'
    ));
  }

  const vpnExtensions = extensionAbilities.filter((entry) => entry?.name === 'CmfaVpnExtensionAbility');
  if (vpnExtensions.length !== 1) {
    failures.push(createFailure(
      'PRODUCTION_VPN_EXTENSION_COUNT_INVALID',
      'Production package must contain exactly one CmfaVpnExtensionAbility.'
    ));
  } else {
    const vpnExtension = vpnExtensions[0];
    if (vpnExtension?.type !== EXPECTED_VPN_EXTENSION_TYPE) {
      failures.push(createFailure(
        'PRODUCTION_VPN_EXTENSION_TYPE_INVALID',
        'Production VPN extension type contract drifted.'
      ));
    }
  }

  return {
    pass: failures.length === 0,
    failures
  };
}

function findObsoleteBridgeMarker(buffer) {
  const haystack = buffer.toString('latin1');
  for (const marker of OBSOLETE_BRIDGE_MARKERS) {
    if (haystack.includes(marker)) {
      return marker;
    }
  }
  return null;
}

function hasEmbeddedProbeEntries(entries = []) {
  return entries.some((entry) => PRODUCTION_PROBE_ENTRY_PATTERNS.some((pattern) => pattern.test(entry)));
}

export async function defaultScanProductionBridgeMarkers({
  hapPath,
  role,
  archiveListing,
  readArchiveEntryImpl = defaultReadArchiveEntry
} = {}) {
  if (role !== 'production') {
    return { failures: [] };
  }

  const failures = [];
  for (const entryPath of REQUIRED_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS) {
    const matches = archiveListing.entries.filter((entry) => entry === entryPath);
    if (matches.length !== 1) {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_SCAN_INVALID',
        'Production package bridge marker scan could not determine a unique required archive entry.'
      ));
      continue;
    }
    let rawEntry;
    try {
      rawEntry = await readArchiveEntryImpl(hapPath, entryPath, {
        maxBuffer: PRODUCTION_BRIDGE_SCAN_MAX_BUFFER_BYTES
      });
    } catch {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_SCAN_INVALID',
        'Production package bridge marker scan could not read the required archive entry.'
      ));
      continue;
    }
    if (findObsoleteBridgeMarker(rawEntry) !== null) {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_MARKERS_FORBIDDEN',
        'Production package contains obsolete VPN runtime bridge markers.'
      ));
    }
  }

  for (const entryPath of OPTIONAL_PRODUCTION_BRIDGE_SCAN_ENTRY_PATHS) {
    const matches = archiveListing.entries.filter((entry) => entry === entryPath);
    if (matches.length === 0) {
      continue;
    }
    if (matches.length !== 1) {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_SCAN_INVALID',
        'Production package bridge marker scan could not determine a unique archive entry.'
      ));
      continue;
    }
    let rawEntry;
    try {
      rawEntry = await readArchiveEntryImpl(hapPath, entryPath, {
        maxBuffer: PRODUCTION_BRIDGE_SCAN_MAX_BUFFER_BYTES
      });
    } catch {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_SCAN_INVALID',
        'Production package bridge marker scan could not read the required archive entry.'
      ));
      continue;
    }
    if (findObsoleteBridgeMarker(rawEntry) !== null) {
      failures.push(createFailure(
        'PRODUCTION_BRIDGE_MARKERS_FORBIDDEN',
        'Production package contains obsolete VPN runtime bridge markers.'
      ));
    }
  }
  return { failures };
}

export async function defaultReadSignature(hapPath, archiveListing = null) {
  const hap = await fs.readFile(hapPath);
  const searchStart = Math.max(0, hap.length - ZIP_EOCD_MIN_SIZE - ZIP_MAX_COMMENT_SIZE);
  let eocdOffset = -1;
  for (let offset = hap.length - ZIP_EOCD_MIN_SIZE; offset >= searchStart; offset -= 1) {
    if (hap.readUInt32LE(offset) !== ZIP_EOCD_SIGNATURE) {
      continue;
    }
    const commentLength = hap.readUInt16LE(offset + 20);
    if (offset + ZIP_EOCD_MIN_SIZE + commentLength === hap.length) {
      eocdOffset = offset;
      break;
    }
  }

  if (eocdOffset >= 0) {
    const centralDirectoryOffset = hap.readUInt32LE(eocdOffset + 16);
    if (centralDirectoryOffset >= HAP_SIGNING_BLOCK_FOOTER_SIZE && centralDirectoryOffset <= hap.length) {
      const footerOffset = centralDirectoryOffset - HAP_SIGNING_BLOCK_FOOTER_SIZE;
      const magicOffset = footerOffset + 12;
      const magic = hap.subarray(magicOffset, magicOffset + HAP_SIGNING_BLOCK_MAGIC.length);
      if (magic.equals(HAP_SIGNING_BLOCK_MAGIC)) {
        const leadingVersion = hap.readUInt32LE(footerOffset);
        const trailingVersion = hap.readUInt32LE(centralDirectoryOffset - 4);
        const blockSizeValue = hap.readBigUInt64LE(footerOffset + 4);
        if (blockSizeValue <= BigInt(Number.MAX_SAFE_INTEGER)) {
          const blockSize = Number(blockSizeValue);
          const blockOffset = centralDirectoryOffset - blockSize;
          if (leadingVersion === trailingVersion && leadingVersion > 0
            && blockSize >= HAP_SIGNING_BLOCK_FOOTER_SIZE && blockOffset >= 0) {
            return {
              entries: [],
              blockVersion: leadingVersion,
              signatureSha256: sha256(hap.subarray(blockOffset, centralDirectoryOffset))
            };
          }
        }
      }
    }
  }

  const listing = archiveListing ?? await defaultListArchiveEntries(hapPath);
  const signatureEntries = listing.entries.filter((entry) => SIGNATURE_ENTRY_PATTERN.test(entry)).sort();
  if (signatureEntries.length === 0) {
    return null;
  }
  const chunks = [];
  for (const entry of signatureEntries) {
    chunks.push(Buffer.from(`${entry}\n`, 'utf8'));
    chunks.push(await defaultReadArchiveEntry(hapPath, entry));
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
  const outCertChainPath = path.join(
    tempDirectory,
    `chain-output.${VERIFY_SIGNATURE_OUTPUT_EXTENSIONS.certChain}`
  );
  const outProfilePath = path.join(
    tempDirectory,
    `profile-output.${VERIFY_SIGNATURE_OUTPUT_EXTENSIONS.profile}`
  );
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
  const manifest = await readJson(fsApi, productionManifestPath, 'PRODUCTION_MANIFEST_UNREADABLE');
  if (manifest?.signing?.result !== 'pass') {
    throw normalizePackageInspectionError(null, { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  if (manifest?.nativeBuildResult !== 'pass') {
    throw normalizePackageInspectionError(null, { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  if (typeof manifest?.artifacts?.hap?.identity !== 'string' || manifest.artifacts.hap.identity.length === 0) {
    throw normalizePackageInspectionError(null, { code: 'PRODUCTION_MANIFEST_INVALID' });
  }
  return manifest;
}

export async function defaultInspectNative({ hapPath, role, productionManifestPath, manifest }) {
  return await defaultInspectNativeWithDependencies({
    hapPath,
    role,
    productionManifestPath,
    manifest
  });
}

async function defaultInspectNativeWithDependencies({
  hapPath,
  role,
  productionManifestPath,
  manifest,
  archiveListing,
  component = null,
  nativeEntryPath = null,
  readArchiveEntryImpl = defaultReadArchiveEntry,
  fsApi = fs
}) {
  if (role === 'production') {
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

  if (role !== 'probe') {
    return null;
  }

  const expectedEntryPath = nativeEntryPath ?? PROBE_NATIVE_ENTRY_PATH;
  const nativeEntries = listNativeEntries(archiveListing?.entries ?? []);
  const failures = [];
  if (nativeEntries.join('\0') !== [expectedEntryPath].join('\0')) {
    failures.push(createFailure(
      'PROBE_NATIVE_ENTRY_INVALID',
      'Probe HAP must contain exactly one native payload at libs/arm64-v8a/libprobeentry.so.'
    ));
  }
  const exactMatches = nativeEntries.filter((entry) => entry === expectedEntryPath);
  if (exactMatches.length !== 1) {
    return {
      component: component ?? PROBE_ADDON_COMPONENT,
      nativeEntryPath: expectedEntryPath,
      probeAddon: null,
      failures
    };
  }

  const tempDirectory = await fsApi.mkdtemp(path.join(os.tmpdir(), 'phase4-probe-native-'));
  const temporaryLibraryPath = path.join(tempDirectory, path.posix.basename(expectedEntryPath));
  try {
    const rawLibrary = await readArchiveEntryImpl(hapPath, expectedEntryPath);
    await fsApi.writeFile(temporaryLibraryPath, rawLibrary);
    const probeAddon = await inspectNativeLibrary({
      libPath: temporaryLibraryPath,
      component: component ?? PROBE_ADDON_COMPONENT,
      fsApi
    });
    return {
      component: component ?? PROBE_ADDON_COMPONENT,
      nativeEntryPath: expectedEntryPath,
      probeAddon: {
        ...probeAddon,
        libPath: expectedEntryPath
      },
      failures
    };
  } finally {
    await fsApi.rm(tempDirectory, { recursive: true, force: true }).catch(() => {});
  }
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
  inspectNativeImpl,
  readArchiveEntryImpl,
  fsApi,
  scanProductionBridgeMarkersImpl
}) {
  try {
    const listing = normalizeArchiveEntries(await listArchiveEntriesImpl(hapPath));
    const [hash, moduleInfo, signature, verifiedSignature, bridgeMarkerScan] = await Promise.all([
      hashFileImpl(hapPath),
      readModuleJsonImpl(hapPath, listing),
      readSignatureImpl(hapPath, listing),
      verifySignatureImpl({ hapPath }),
      scanProductionBridgeMarkersImpl({ hapPath, role, archiveListing: listing })
    ]);
    let nativeInfo;
    try {
      nativeInfo = await inspectNativeImpl({
        hapPath,
        role,
        productionManifestPath,
        manifest,
        archiveListing: listing,
        component: role === 'probe' ? PROBE_ADDON_COMPONENT : null,
        nativeEntryPath: role === 'probe' ? PROBE_NATIVE_ENTRY_PATH : null,
        readArchiveEntryImpl,
        fsApi
      });
    } catch (error) {
      const probeNativeEntries = listNativeEntries(listing.entries);
      if (role !== 'probe' || probeNativeEntries.join('\0') !== [PROBE_NATIVE_ENTRY_PATH].join('\0')) {
        throw error;
      }
      nativeInfo = {
        component: PROBE_ADDON_COMPONENT,
        nativeEntryPath: PROBE_NATIVE_ENTRY_PATH,
        probeAddon: null,
        failures: [
          createFailure(
            PROBE_NATIVE_INSPECTION_FAILED_CODE,
            'Probe native payload inspection failed.'
          )
        ]
      };
    }
    return {
      role,
      entries: listing.entries,
      hash,
      moduleInfo,
      signature,
      verifiedSignature,
      nativeInfo,
      bridgeMarkerScan
    };
  } catch (error) {
    throw normalizePackageInspectionError(error, {
      code: role === 'production' ? 'PRODUCTION_PACKAGE_UNREADABLE' : 'PROBE_PACKAGE_UNREADABLE'
    });
  }
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
  readArchiveEntryImpl = defaultReadArchiveEntry,
  readSignatureImpl = defaultReadSignature,
  verifySignatureImpl = (options) => defaultVerifySignature({ ...options, fsApi }),
  inspectNativeImpl = (options) => defaultInspectNativeWithDependencies({ ...options, readArchiveEntryImpl, fsApi }),
  scanProductionBridgeMarkersImpl = (options) => defaultScanProductionBridgeMarkers({ ...options, readArchiveEntryImpl })
} = {}) {
  try {
    const resolvedProductionHapPath = ensureRepoScopedInputPath(repoRoot, productionHapPath, '--production-hap');
    const resolvedProbeHapPath = ensureRepoScopedInputPath(repoRoot, probeHapPath, '--probe-hap');
    const resolvedManifestPath = ensureRepoScopedInputPath(repoRoot, productionManifestPath, '--production-manifest');
    const manifest = await loadProductionManifestImpl(resolvedManifestPath);

    const expectedProductionIdentity = path.relative(repoRoot, resolvedProductionHapPath).split(path.sep).join('/');
    if (manifest.artifacts.hap.identity !== expectedProductionIdentity) {
      throw normalizePackageInspectionError(null, { code: 'PRODUCTION_MANIFEST_MISMATCH' });
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
        inspectNativeImpl,
        readArchiveEntryImpl,
        fsApi,
        scanProductionBridgeMarkersImpl
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
        inspectNativeImpl,
        readArchiveEntryImpl,
        fsApi,
        scanProductionBridgeMarkersImpl
      })
    ]);

    if (/-unsigned\.hap$/iu.test(path.basename(resolvedProductionHapPath))
      || /-unsigned\.hap$/iu.test(path.basename(resolvedProbeHapPath))) {
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

    const productionVpnSurface = inspectProductionVpnSurface(production.moduleInfo);
    failures.push(...productionVpnSurface.failures);
    failures.push(...(production.bridgeMarkerScan?.failures ?? []));

    const productionAddonSymbols = production.nativeInfo?.addon?.exportedSymbols ?? [];
    const productionCoreSymbols = production.nativeInfo?.core?.exportedSymbols ?? [];
    const productionCorePublicSymbols = productionCoreSymbols.filter((entry) => entry.startsWith('cmfa_'));
    if (!exactSymbolSet(productionAddonSymbols, NODE_ADDON_ALLOWED_EXPORTS)) {
      failures.push(createFailure('PRODUCTION_ADDON_EXPORTS_INVALID', 'Production native addon exports drifted.'));
    }
    if (!exactSymbolSet(productionCorePublicSymbols, CORE_EXPORTS)) {
      failures.push(createFailure('PRODUCTION_CORE_EXPORTS_INVALID', 'Production native core exports drifted.'));
    }
    for (const nativeFailure of production.nativeInfo?.failures ?? []) {
      failures.push(createFailure(nativeFailure.code ?? 'PRODUCTION_NATIVE_INVALID', nativeFailure.detail ?? 'Production native inspection failed.'));
    }

    const probeNativeEntries = listNativeEntries(probe.entries);
    const probeHasNativePayload = probeNativeEntries.length > 0 || probe.nativeInfo?.probeAddon !== null;
    if (probeNativeEntries.join('\0') !== [PROBE_NATIVE_ENTRY_PATH].join('\0')) {
      failures.push(createFailure('PROBE_NATIVE_ENTRY_INVALID', 'Probe HAP must contain exactly libs/arm64-v8a/libprobeentry.so.'));
    }
    if (probe.nativeInfo?.component !== undefined && probe.nativeInfo.component !== PROBE_ADDON_COMPONENT) {
      failures.push(createFailure('PROBE_NATIVE_COMPONENT_INVALID', 'Probe native inspection must select the explicit probeAddon component.'));
    }
    if (probe.nativeInfo?.nativeEntryPath !== undefined && probe.nativeInfo.nativeEntryPath !== PROBE_NATIVE_ENTRY_PATH) {
      failures.push(createFailure('PROBE_NATIVE_ENTRY_INVALID', 'Probe native inspection must use the exact probe addon archive path.'));
    }
    const probeAddon = probe.nativeInfo?.probeAddon ?? null;
    const probeInspectionFailed = (probe.nativeInfo?.failures ?? [])
      .some((failure) => failure?.code === PROBE_NATIVE_INSPECTION_FAILED_CODE);
    if (probeHasNativePayload && probeAddon === null && !probeInspectionFailed) {
      failures.push(createFailure('PROBE_NATIVE_INSPECTION_MISSING', 'Probe native payload must be inspected as probeAddon.'));
    }
    if (probeAddon?.component && probeAddon.component !== PROBE_ADDON_COMPONENT) {
      failures.push(createFailure('PROBE_NATIVE_COMPONENT_INVALID', 'Probe native inspection drifted from the explicit probeAddon component.'));
    }
    if (probeAddon && !exactSymbolSet(probeAddon.exportedSymbols ?? [], PROBE_ADDON_ALLOWED_EXPORTS)) {
      failures.push(createFailure('PROBE_ADDON_EXPORTS_INVALID', 'Probe addon exports drifted from the allowed lifecycle-only ABI.'));
    }
    if (probeAddon?.result === 'fail') {
      failures.push(createFailure('PROBE_ADDON_EXPORTS_INVALID', 'Probe addon failed native ELF inspection.'));
    }
    for (const nativeFailure of probe.nativeInfo?.failures ?? []) {
      failures.push(createFailure(nativeFailure.code ?? 'PROBE_NATIVE_INVALID', nativeFailure.detail ?? 'Probe native inspection failed.'));
    }
    for (const nativeFailure of probeAddon?.failures ?? []) {
      failures.push(createFailure(nativeFailure.code ?? 'PROBE_NATIVE_INVALID', nativeFailure.detail ?? 'Probe native inspection failed.'));
    }
    const probeEmbeddedInProduction = hasEmbeddedProbeEntries(production.entries);
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
        stubDetected: production.nativeInfo?.stubDetected === true
          || [...productionAddonSymbols, ...productionCoreSymbols].some((entry) => /stub/iu.test(entry))
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
  } catch (error) {
    throw normalizePackageInspectionError(error);
  }
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
    if (value.length === 0) {
      throw normalizePackageInspectionError(null, { code: 'PACKAGE_ARGUMENT_INVALID' });
    }
    if (option === '--production-hap') parsed.productionHapPath = value;
    else if (option === '--production-manifest') parsed.productionManifestPath = value;
    else if (option === '--probe-hap') parsed.probeHapPath = value;
    else if (option === '--out') parsed.outputPath = value;
    else throw normalizePackageInspectionError(null, { code: 'PACKAGE_ARGUMENT_INVALID' });
    index += 1;
  }
  return parsed;
}

function resolveSafeOutputPathFromArgv(argv = process.argv.slice(2), repoRoot = REPO_ROOT) {
  let lastSafeOutputPath = '';
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== '--out') {
      continue;
    }
    const rawValue = argv[index + 1] ?? '';
    if (rawValue.length === 0) {
      continue;
    }
    const resolved = path.resolve(rawValue);
    if (isWithinRepo(repoRoot, resolved) && resolved !== repoRoot) {
      lastSafeOutputPath = resolved;
    }
  }
  return lastSafeOutputPath || DEFAULT_REPORT_PATH;
}

async function main() {
  const parsed = parseCliArguments();
  const report = await inspectPhase4Packages(parsed);
  await writeInspectionReport({ outputPath: parsed.outputPath || DEFAULT_REPORT_PATH, report });
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch(async (error) => {
    const normalizedError = normalizePackageInspectionError(error);
    const outputPath = resolveSafeOutputPathFromArgv(process.argv.slice(2));
    await writeInspectionReport({
      outputPath,
      report: {
        schemaVersion: '1.0.0',
        result: 'fail',
        production: { bundleName: '', hapSha256: '', signatureSha256: '', permissions: [], stubDetected: false },
        probe: { bundleName: '', hapSha256: '', signatureSha256: '', permissions: [], hasNativePayload: false },
        probeEmbeddedInProduction: false,
        failures: [createFailure(normalizedError.code, normalizedError.message)]
      }
    });
    process.stderr.write(`${normalizedError.message}\n`);
    process.exitCode = 1;
  });
}
