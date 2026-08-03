import { execFile as execFileCallback } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const DEFAULT_REQUIREMENTS_PATH = fileURLToPath(new URL('../../toolchain.requirements.json', import.meta.url));
const HOST_TOOL_NAMES = ['node', 'java', 'hvigor', 'ohpm', 'hdc'];
const EXECUTABLE_BITS = 0o111;
const BASE_NATIVE_NEEDED = ['libc.so', 'libdl.so', 'libm.so'];
const NODE_ADDON_NEEDED = ['libace_napi.z.so', 'libcmfa_mihomo.so', 'libhilog_ndk.z.so'];
const execFile = promisify(execFileCallback);
const FAILURE_DETAILS = {
  SDK_METADATA_MISSING: 'Integrated HarmonyOS SDK metadata is missing or malformed',
  ARKTS_DECLARATIONS_MISSING: 'Integrated HarmonyOS ArkTS declarations are not discoverable',
  NDK_MISSING: 'Integrated HarmonyOS native toolchain files are not discoverable',
  TOOL_MISSING: 'One or more required host or integrated tools are not discoverable',
  TOOL_VERSION_MISSING: 'A required discovered tool or metadata version is missing'
};

function getPathModule(cwd) {
  if (path.posix.isAbsolute(cwd) && !cwd.startsWith('/private/var/')) {
    return path.posix;
  }

  return path;
}

function normalizePath(pathModule, value) {
  return pathModule.normalize(value);
}

function normalizeVersion(version) {
  if (typeof version !== 'string') {
    return null;
  }

  const normalized = version.trim();
  return normalized ? normalized : null;
}

export function normalizeNodeVersion(version) {
  const normalized = normalizeVersion(version);
  if (!normalized) {
    return null;
  }

  return normalized.replace(/^v(?=\d)/u, '');
}

function isPlaceholderValue(value) {
  return /^(?:unknown|todo|tbd|placeholder)$/iu.test(String(value ?? '').trim());
}

function createStableError(code, detail) {
  const error = new Error(detail);
  error.code = code;
  return error;
}

function normalizeInteger(value) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  return Number.isNaN(parsed) ? null : parsed;
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function createToolStatus(found, version) {
  return {
    found,
    version: found ? version ?? null : null
  };
}

function createTargetContract(target = {}) {
  return {
    name: target.name ?? 'HarmonyOS 6/API 20/arm64',
    targetSdkVersion: target.targetSdkVersion ?? '6.1.0(23)',
    targetApiVersion: normalizeInteger(target.targetApiVersion) ?? 23,
    compatibleSdkVersion: target.compatibleSdkVersion ?? '6.0.0(20)',
    compatibleApiVersion: normalizeInteger(target.compatibleApiVersion) ?? 20,
    runtimeOS: target.runtimeOS ?? 'HarmonyOS',
    architecture: target.architecture ?? 'arm64'
  };
}

function firstNonEmptyLine(stdout, stderr) {
  for (const stream of [stdout, stderr]) {
    for (const rawLine of String(stream ?? '').split(/\r?\n/u)) {
      const line = normalizeVersion(rawLine);
      if (line) {
        return line;
      }
    }
  }

  return null;
}

function extractJavaVersion(firstLine) {
  const normalizedLine = normalizeVersion(firstLine);
  if (!normalizedLine) {
    return null;
  }

  const quotedMatch = normalizedLine.match(/"([^"]+)"/u);
  if (quotedMatch) {
    return normalizeVersion(quotedMatch[1]);
  }

  const numericMatch = normalizedLine.match(/\b\d+(?:\.\d+)+(?:_\d+)?\b/u);
  if (numericMatch) {
    return normalizeVersion(numericMatch[0]);
  }

  return normalizedLine;
}

function extractGenericToolVersion(firstLine) {
  return normalizeVersion(firstLine);
}

function getToolVersionCommands(toolName, requirements) {
  return requirements.tools?.[toolName]?.versionCommands ?? [];
}

function pushFailure(failures, code, detail) {
  if (failures.some((entry) => entry.code === code && entry.detail === detail)) {
    return;
  }

  failures.push({ code, detail });
}

async function pathExists(fsApi, filePath) {
  if (!filePath) {
    return false;
  }

  try {
    await fsApi.access(filePath);
    return true;
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return false;
    }

    throw error;
  }
}

async function readJsonIfExists(fsApi, filePath) {
  if (!(await pathExists(fsApi, filePath))) {
    return null;
  }

  try {
    const raw = await fsApi.readFile(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error instanceof SyntaxError) {
      return null;
    }

    throw error;
  }
}

async function statIfExists(fsApi, filePath) {
  if (!filePath) {
    return null;
  }

  if (typeof fsApi.stat !== 'function') {
    return (await pathExists(fsApi, filePath)) ? { mode: EXECUTABLE_BITS } : null;
  }

  try {
    return await fsApi.stat(filePath);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }

    throw error;
  }
}

async function isExecutable(fsApi, filePath) {
  const stats = await statIfExists(fsApi, filePath);
  if (!stats) {
    return false;
  }

  return (stats.mode & EXECUTABLE_BITS) !== 0;
}

async function readDirectoryEntries(fsApi, dirPath) {
  if (typeof fsApi.readdir !== 'function') {
    return [];
  }

  try {
    return await fsApi.readdir(dirPath);
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return [];
    }

    throw error;
  }
}

function unescapePropertiesValue(value) {
  let result = '';

  for (let index = 0; index < value.length; index += 1) {
    const current = value[index];
    const next = value[index + 1];

    if (current === '\\' && next) {
      if (next === '\\' || next === ':' || next === '=' || next === ' ') {
        result += next;
        index += 1;
        continue;
      }

      result += next;
      index += 1;
      continue;
    }

    result += current;
  }

  return result;
}

function localPropertiesCandidates(cwd, relativePath, pathModule) {
  return unique([
    normalizePath(pathModule, pathModule.join(cwd, relativePath)),
    normalizePath(pathModule, pathModule.join(cwd, '..', relativePath))
  ]);
}

async function readLocalProperties(options, requirements) {
  const pathModule = getPathModule(options.cwd);

  for (const localPropertiesPath of localPropertiesCandidates(options.cwd, requirements.files.localProperties, pathModule)) {
    if (!(await pathExists(options.fs, localPropertiesPath))) {
      continue;
    }

    const content = await options.fs.readFile(localPropertiesPath, 'utf8');
    const properties = new Map();

    for (const rawLine of content.split(/\r?\n/u)) {
      const line = rawLine.trim();
      if (!line || line.startsWith('#')) {
        continue;
      }

      const separatorIndex = line.indexOf('=');
      if (separatorIndex === -1) {
        continue;
      }

      const key = line.slice(0, separatorIndex).trim();
      const value = unescapePropertiesValue(line.slice(separatorIndex + 1).trim());
      if (key && value) {
        properties.set(key, value);
      }
    }

    return properties;
  }

  return new Map();
}

function looksLikeIntegratedSdkRoot(sdkRoot) {
  return /[\\/]Contents[\\/]sdk[\\/]default$/u.test(String(sdkRoot ?? ''));
}

function resolveVersionProbeTimeout(requirements) {
  return normalizeInteger(requirements.defaults?.versionProbeTimeoutMs) ?? 5000;
}

async function runCommand(command, args, options) {
  if (typeof options.execFile === 'function') {
    return options.execFile(command, args, { timeoutMs: resolveVersionProbeTimeout(options.requirements) });
  }

  try {
    return await execFile(command, args, {
      windowsHide: true,
      timeout: resolveVersionProbeTimeout(options.requirements),
      killSignal: 'SIGKILL'
    });
  } catch (error) {
    return {
      stdout: error?.stdout ?? '',
      stderr: error?.stderr ?? ''
    };
  }
}

async function resolveVersionFromCommands(toolName, resolvedPath, options) {
  for (const args of getToolVersionCommands(toolName, options.requirements)) {
    const { stdout = '', stderr = '' } = await runCommand(resolvedPath, args, options);
    const firstLine = firstNonEmptyLine(stdout, stderr);
    const version = toolName === 'java'
      ? extractJavaVersion(firstLine)
      : extractGenericToolVersion(firstLine);
    if (version) {
      return version;
    }
  }

  return null;
}

async function findPathToolInEnv(toolName, options) {
  const pathModule = getPathModule(options.cwd);
  const delimiter = pathModule.delimiter ?? path.delimiter;
  const pathEntries = String(options.env.PATH || '')
    .split(delimiter)
    .filter(Boolean);

  for (const entry of pathEntries) {
    const candidate = normalizePath(pathModule, pathModule.join(entry, toolName));
    if (await pathExists(options.fs, candidate)) {
      return candidate;
    }
  }

  return null;
}

function extractSdkPkgData(metadata) {
  const data = metadata?.data && typeof metadata.data === 'object' ? metadata.data : metadata;
  return {
    apiVersion: normalizeInteger(data?.apiVersion),
    sdkVersion: normalizeVersion(data?.version),
    platformVersion: normalizeVersion(data?.platformVersion),
    stage: normalizeVersion(data?.stage ?? data?.releaseType)
  };
}

function extractComponentPackageData(metadata) {
  return {
    apiVersion: normalizeInteger(metadata?.apiVersion),
    version: normalizeVersion(metadata?.version)
  };
}

function extractProductInfoData(metadata) {
  return {
    version: normalizeVersion(metadata?.version)
  };
}

async function resolveSdkRootCandidates(options, requirements) {
  const localProperties = await readLocalProperties(options, requirements);
  const candidates = [];

  for (const envKey of requirements.env.sdkRoots) {
    if (options.env[envKey]) {
      candidates.push(options.env[envKey]);
    }
  }

  if (localProperties.has('sdk.dir')) {
    candidates.push(localProperties.get('sdk.dir'));
  }

  candidates.push(...(requirements.defaults?.sdkRoots ?? []));

  return unique(candidates);
}

async function pickSdkRoot(options, requirements) {
  const pathModule = getPathModule(options.cwd);
  const rootCandidates = await resolveSdkRootCandidates(options, requirements);

  for (const root of rootCandidates) {
    const sdkPkgPath = normalizePath(pathModule, pathModule.join(root, requirements.files.sdkPkg));
    const sdkPkg = await readJsonIfExists(options.fs, sdkPkgPath);
    if (!sdkPkg) {
      continue;
    }

    return {
      root,
      sdkPkgPath,
      sdkPkg,
      sdkData: extractSdkPkgData(sdkPkg)
    };
  }

  return {
    root: rootCandidates[0] ?? null,
    sdkPkgPath: rootCandidates[0]
      ? normalizePath(pathModule, pathModule.join(rootCandidates[0], requirements.files.sdkPkg))
      : null,
    sdkPkg: null,
    sdkData: extractSdkPkgData(null)
  };
}

function resolveContentsRoot(sdkRoot, requirements, pathModule) {
  if (!sdkRoot) {
    return null;
  }

  if (looksLikeIntegratedSdkRoot(sdkRoot)) {
    return normalizePath(pathModule, pathModule.resolve(sdkRoot, '..', '..'));
  }

  return null;
}

function resolvePathFromRoot(pathModule, root, relativePath) {
  if (!root || !relativePath) {
    return null;
  }

  return normalizePath(pathModule, pathModule.join(root, relativePath));
}

async function collectArktsDeclarations(fsApi, root, declarationRoots, pathModule) {
  const declarations = [];

  for (const relativeRoot of declarationRoots) {
    const declarationRoot = resolvePathFromRoot(pathModule, root, relativeRoot);
    if (!declarationRoot) {
      continue;
    }

    const entries = await readDirectoryEntries(fsApi, declarationRoot);
    for (const entry of entries) {
      if (!entry.endsWith('.d.ts') && !entry.endsWith('.d.ets')) {
        continue;
      }

      declarations.push(normalizePath(pathModule, pathModule.join(declarationRoot, entry)));
    }
  }

  return declarations.sort();
}

async function collectSharedLibraries(fsApi, libraryDirectory) {
  const entries = await readDirectoryEntries(fsApi, libraryDirectory);
  return entries.filter((entry) => entry.endsWith('.so')).sort();
}

function hasCompleteRequirements(requirements) {
  return Boolean(
    requirements?.schemaVersion &&
    requirements?.target?.name &&
    Number.isInteger(normalizeInteger(requirements?.target?.targetApiVersion)) &&
    Number.isInteger(normalizeInteger(requirements?.target?.compatibleApiVersion)) &&
    Array.isArray(requirements?.env?.sdkRoots) &&
    Array.isArray(requirements?.defaults?.sdkRoots) &&
    Array.isArray(requirements?.defaults?.devecoContentsRoots) &&
    requirements?.files?.sdkPkg &&
    Array.isArray(requirements?.files?.arktsDeclarationRoots) &&
    requirements?.files?.ndkSysroot &&
    requirements?.files?.ndkCmake &&
    requirements?.files?.nativeCmakeBinary &&
    requirements?.files?.clang &&
    requirements?.files?.llvmReadelf &&
    requirements?.files?.hdc
  );
}

function mergeRequirements(base, override = {}) {
  return {
    ...base,
    ...override,
    target: {
      ...base.target,
      ...override.target
    },
    env: {
      ...base.env,
      ...override.env
    },
    defaults: {
      ...base.defaults,
      ...override.defaults
    },
    tools: {
      ...base.tools,
      ...override.tools
    },
    files: {
      ...base.files,
      ...override.files
    }
  };
}

function buildResolvedPaths(requirements, sdkRoot, contentsRoot, pathModule) {
  return {
    sdkPkg: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.sdkPkg),
    productInfo: resolvePathFromRoot(pathModule, contentsRoot, requirements.files.devecoProductInfo),
    etsPackage: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.etsPackage),
    nativePackage: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.nativePackage),
    toolchainsPackage: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.toolchainsPackage),
    sysroot: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.ndkSysroot),
    cmake: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.ndkCmake),
    cmakeExecutable: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.nativeCmakeBinary),
    clang: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.clang),
    llvmReadelf: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.llvmReadelf),
    hdc: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.hdc),
    hvigorPackage: resolvePathFromRoot(pathModule, contentsRoot, requirements.files.hvigorPackage),
    hvigorBinary: resolvePathFromRoot(pathModule, contentsRoot, requirements.files.hvigorBinary),
    ohpmPackage: resolvePathFromRoot(pathModule, contentsRoot, requirements.files.ohpmPackage),
    ohpmBinary: resolvePathFromRoot(pathModule, contentsRoot, requirements.files.ohpmBinary),
    nativeLibraryDirectory: resolvePathFromRoot(pathModule, sdkRoot, requirements.files.nativeLibraryDirectory)
  };
}

async function findToolPath(toolName, options, resolvedPaths) {
  if (toolName === 'hvigor' && await pathExists(options.fs, resolvedPaths.hvigorBinary)) {
    return resolvedPaths.hvigorBinary;
  }

  if (toolName === 'ohpm' && await pathExists(options.fs, resolvedPaths.ohpmBinary)) {
    return resolvedPaths.ohpmBinary;
  }

  if (toolName === 'hdc' && await pathExists(options.fs, resolvedPaths.hdc)) {
    return resolvedPaths.hdc;
  }

  return findPathToolInEnv(toolName, options);
}

function isIntegratedToolPath(toolName, resolvedPath, resolvedPaths) {
  if (!resolvedPath) {
    return false;
  }

  if (toolName === 'hvigor') {
    return resolvedPath === resolvedPaths.hvigorBinary;
  }

  if (toolName === 'ohpm') {
    return resolvedPath === resolvedPaths.ohpmBinary;
  }

  if (toolName === 'hdc') {
    return resolvedPath === resolvedPaths.hdc;
  }

  return false;
}

async function resolveToolVersion(toolName, resolvedPath, options, installed, resolvedPaths) {
  if (Object.hasOwn(options.versions, toolName)) {
    return toolName === 'node'
      ? normalizeNodeVersion(options.versions[toolName])
      : normalizeVersion(options.versions[toolName]);
  }

  if (toolName === 'node') {
    return normalizeNodeVersion(process.version);
  }

  if (toolName === 'hvigor' && isIntegratedToolPath(toolName, resolvedPath, resolvedPaths)) {
    return normalizeVersion(installed.hvigorVersion);
  }

  if (toolName === 'ohpm' && isIntegratedToolPath(toolName, resolvedPath, resolvedPaths)) {
    return normalizeVersion(installed.ohpmVersion);
  }

  if (toolName === 'hdc' && isIntegratedToolPath(toolName, resolvedPath, resolvedPaths)) {
    return normalizeVersion(installed.hdcVersion);
  }

  if (!resolvedPath) {
    return null;
  }

  return resolveVersionFromCommands(toolName, resolvedPath, options);
}

export async function loadToolchainRequirements(requirementsPath = DEFAULT_REQUIREMENTS_PATH, fsApi = fs) {
  const raw = await fsApi.readFile(requirementsPath, 'utf8');
  return JSON.parse(raw);
}

export function resolveRepoRootFromImportMetaUrl(importMetaUrl, options = {}) {
  const fileURLToPathImpl = options.fileURLToPathImpl ?? fileURLToPath;
  const pathModule = options.pathModule ?? path;
  return pathModule.resolve(fileURLToPathImpl(new URL('../..', importMetaUrl)));
}

function requireLockField(container, keyPath) {
  const value = keyPath.split('.').reduce((current, key) => current?.[key], container);
  if (typeof value === 'string') {
    const normalized = value.trim();
    if (!normalized || isPlaceholderValue(normalized)) {
      throw createStableError('TOOLCHAIN_LOCK_INVALID', `Invalid ${keyPath}`);
    }

    return normalized;
  }

  if (value === null || value === undefined) {
    throw createStableError('TOOLCHAIN_LOCK_INVALID', `Invalid ${keyPath}`);
  }

  return value;
}

export function buildToolchainLock(report) {
  return {
    schemaVersion: requireLockField(report, 'schemaVersion'),
    target: {
      name: requireLockField(report, 'target.name'),
      targetSdkVersion: requireLockField(report, 'target.targetSdkVersion'),
      targetApiVersion: requireLockField(report, 'target.targetApiVersion'),
      compatibleSdkVersion: requireLockField(report, 'target.compatibleSdkVersion'),
      compatibleApiVersion: requireLockField(report, 'target.compatibleApiVersion'),
      runtimeOS: requireLockField(report, 'target.runtimeOS'),
      architecture: requireLockField(report, 'target.architecture')
    },
    installed: {
      devecoVersion: requireLockField(report, 'installed.devecoVersion'),
      sdkVersion: requireLockField(report, 'installed.sdkVersion'),
      sdkApiVersion: requireLockField(report, 'installed.sdkApiVersion'),
      ndkVersion: requireLockField(report, 'installed.ndkVersion'),
      ndkApiVersion: requireLockField(report, 'installed.ndkApiVersion'),
      hvigorVersion: requireLockField(report, 'installed.hvigorVersion'),
      ohpmVersion: requireLockField(report, 'installed.ohpmVersion'),
      hdcVersion: requireLockField(report, 'installed.hdcVersion')
    }
  };
}

export function buildNativeAllowlist(inspection) {
  const baseNeeded = BASE_NATIVE_NEEDED.filter((entry) => inspection.resolved.sharedLibraries.includes(entry));
  const nodeAddon = unique([...baseNeeded, ...NODE_ADDON_NEEDED.filter((entry) => entry === 'libcmfa_mihomo.so' || inspection.resolved.sharedLibraries.includes(entry))]).sort();

  return {
    schemaVersion: inspection.report.schemaVersion,
    architecture: inspection.report.target.architecture,
    source: {
      sdkVersion: inspection.report.installed.sdkVersion,
      sdkApiVersion: inspection.report.installed.sdkApiVersion
    },
    goProbe: [...baseNeeded],
    mihomoCore: [...baseNeeded],
    nodeAddon
  };
}

export async function inspectToolchain(input = {}) {
  const defaultRequirements = hasCompleteRequirements(input.requirements)
    ? null
    : await loadToolchainRequirements(DEFAULT_REQUIREMENTS_PATH, fs);
  const options = {
    cwd: input.cwd ?? process.cwd(),
    env: input.env ?? process.env,
    fs: input.fs ?? fs,
    execFile: input.execFile,
    versions: input.versions ?? {},
    requirements: defaultRequirements ? mergeRequirements(defaultRequirements, input.requirements) : input.requirements
  };
  const requirements = options.requirements;
  const target = createTargetContract(requirements.target);
  const pathModule = getPathModule(options.cwd);
  const failures = [];
  const sdkRootInfo = await pickSdkRoot(options, requirements);
  const contentsRoot = resolveContentsRoot(sdkRootInfo.root, requirements, pathModule);
  const resolvedPaths = buildResolvedPaths(requirements, sdkRootInfo.root, contentsRoot, pathModule);

  const [productInfo, etsPackage, nativePackage, toolchainsPackage, hvigorPackage, ohpmPackage] = await Promise.all([
    readJsonIfExists(options.fs, resolvedPaths.productInfo),
    readJsonIfExists(options.fs, resolvedPaths.etsPackage),
    readJsonIfExists(options.fs, resolvedPaths.nativePackage),
    readJsonIfExists(options.fs, resolvedPaths.toolchainsPackage),
    readJsonIfExists(options.fs, resolvedPaths.hvigorPackage),
    readJsonIfExists(options.fs, resolvedPaths.ohpmPackage)
  ]);

  const installed = {
    devecoVersion: extractProductInfoData(productInfo).version,
    sdkVersion: sdkRootInfo.sdkData.sdkVersion,
    sdkApiVersion: sdkRootInfo.sdkData.apiVersion,
    ndkVersion: extractComponentPackageData(nativePackage).version,
    ndkApiVersion: extractComponentPackageData(nativePackage).apiVersion,
    hvigorVersion: normalizeVersion(hvigorPackage?.version),
    ohpmVersion: normalizeVersion(ohpmPackage?.version),
    hdcVersion: extractComponentPackageData(toolchainsPackage).version
  };

  if (!sdkRootInfo.sdkPkg || !installed.sdkVersion || installed.sdkApiVersion !== target.targetApiVersion) {
    pushFailure(failures, 'SDK_METADATA_MISSING', 'sdk-pkg.json');
  }

  if (!etsPackage || extractComponentPackageData(etsPackage).apiVersion !== target.targetApiVersion || !extractComponentPackageData(etsPackage).version) {
    pushFailure(failures, 'SDK_METADATA_MISSING', 'openharmony/ets/oh-uni-package.json');
  }

  if (!nativePackage || !installed.ndkVersion || installed.ndkApiVersion !== target.targetApiVersion) {
    pushFailure(failures, 'SDK_METADATA_MISSING', 'openharmony/native/oh-uni-package.json');
  }

  if (!toolchainsPackage || !installed.hdcVersion) {
    pushFailure(failures, 'SDK_METADATA_MISSING', 'openharmony/toolchains/oh-uni-package.json');
  }

  if (!installed.devecoVersion) {
    pushFailure(failures, 'TOOL_VERSION_MISSING', 'deveco');
  }

  const tools = {};
  for (const toolName of HOST_TOOL_NAMES) {
    const resolvedPath = await findToolPath(toolName, options, resolvedPaths);
    const found = toolName === 'hdc'
      ? await isExecutable(options.fs, resolvedPath)
      : Boolean(resolvedPath && await pathExists(options.fs, resolvedPath));
    const version = found ? await resolveToolVersion(toolName, resolvedPath, options, installed, resolvedPaths) : null;
    tools[toolName] = createToolStatus(found, version);
    if (!found) {
      pushFailure(failures, 'TOOL_MISSING', toolName);
    } else if (!version) {
      pushFailure(failures, 'TOOL_VERSION_MISSING', toolName);
    }
  }

  const arktsDeclarations = sdkRootInfo.root
    ? await collectArktsDeclarations(options.fs, sdkRootInfo.root, requirements.files.arktsDeclarationRoots, pathModule)
    : [];
  tools.arktsDeclarations = {
    found: arktsDeclarations.length > 0,
    count: arktsDeclarations.length,
    sample: arktsDeclarations.length > 0 ? pathModule.basename(arktsDeclarations[0]) : null
  };
  if (arktsDeclarations.length === 0) {
    pushFailure(failures, 'ARKTS_DECLARATIONS_MISSING', 'openharmony/ets/api');
  }

  const sysrootFound = Boolean(resolvedPaths.sysroot && await pathExists(options.fs, resolvedPaths.sysroot));
  const cmakeFound = Boolean(resolvedPaths.cmake && await pathExists(options.fs, resolvedPaths.cmake));
  if (!sysrootFound || !cmakeFound) {
    pushFailure(failures, 'NDK_MISSING', 'native');
  }

  const clangFound = Boolean(resolvedPaths.clang && await isExecutable(options.fs, resolvedPaths.clang));
  const llvmReadelfFound = Boolean(resolvedPaths.llvmReadelf && await isExecutable(options.fs, resolvedPaths.llvmReadelf));
  const nativeCmakeFound = Boolean(resolvedPaths.cmakeExecutable && await isExecutable(options.fs, resolvedPaths.cmakeExecutable));
  tools.nativeCmake = createToolStatus(nativeCmakeFound, null);
  tools.ohosClang = createToolStatus(clangFound, null);
  tools.llvmReadelf = createToolStatus(llvmReadelfFound, null);
  if (!nativeCmakeFound) {
    pushFailure(failures, 'TOOL_MISSING', 'nativeCmake');
  }
  if (!clangFound) {
    pushFailure(failures, 'TOOL_MISSING', 'ohosClang');
  }
  if (!llvmReadelfFound) {
    pushFailure(failures, 'TOOL_MISSING', 'llvmReadelf');
  }

  const sharedLibraries = resolvedPaths.nativeLibraryDirectory
    ? await collectSharedLibraries(options.fs, resolvedPaths.nativeLibraryDirectory)
    : [];

  const result = failures.length === 0 ? 'pass' : 'incomplete';
  const report = {
    schemaVersion: requirements.schemaVersion,
    result,
    target,
    installed,
    tools,
    failures
  };

  return {
    requirements,
    report,
    resolved: {
      sdkRoot: sdkRootInfo.root,
      contentsRoot,
      sdkPkgPath: sdkRootInfo.sdkPkgPath,
      arktsDeclarations,
      sharedLibraries,
      paths: {
        sysroot: resolvedPaths.sysroot,
        cmake: resolvedPaths.cmake,
        cmakeExecutable: resolvedPaths.cmakeExecutable,
        clang: resolvedPaths.clang,
        llvmReadelf: resolvedPaths.llvmReadelf,
        hdc: resolvedPaths.hdc,
        hvigor: resolvedPaths.hvigorBinary,
        ohpm: resolvedPaths.ohpmBinary
      }
    }
  };
}

export async function discoverToolchain(input = {}) {
  const inspection = await inspectToolchain(input);
  return inspection.report;
}

export function describeFailureCodes() {
  return { ...FAILURE_DETAILS };
}
