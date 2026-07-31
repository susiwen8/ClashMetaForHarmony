import { execFile as execFileCallback } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const DEFAULT_REQUIREMENTS_PATH = fileURLToPath(new URL('../../toolchain.requirements.json', import.meta.url));
const HOST_TOOL_NAMES = ['node', 'java', 'hvigor', 'ohpm', 'hdc'];
const execFile = promisify(execFileCallback);
const FAILURE_DETAILS = {
  TOOL_MISSING: 'One or more required host tools are not discoverable',
  TOOL_VERSION_MISSING: 'A required discovered tool has no usable version string',
  API20_MISSING: 'HarmonyOS API 20 declarations are not discoverable',
  NDK_MISSING: 'HarmonyOS API 20 native toolchain files are not discoverable'
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

async function pathExists(fsApi, filePath) {
  try {
    await fsApi.access(filePath);
    return true;
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      return false;
    }

    throw error;
  }
}

async function readJsonIfExists(fsApi, filePath) {
  if (!(await pathExists(fsApi, filePath))) {
    return null;
  }

  const raw = await fsApi.readFile(filePath, 'utf8');
  return JSON.parse(raw);
}

function normalizeVersion(version) {
  if (typeof version !== 'string') {
    return null;
  }

  const normalized = version.trim();
  return normalized ? normalized : null;
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

function getToolVersionCommands(toolName, requirements) {
  return requirements.tools?.[toolName]?.versionCommands ?? [];
}

function extractGenericToolVersion(firstLine) {
  return normalizeVersion(firstLine);
}

async function runCommand(command, args, options) {
  if (typeof options.execFile === 'function') {
    return options.execFile(command, args);
  }

  try {
    return await execFile(command, args, { windowsHide: true });
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

async function resolveVersion(toolName, resolvedPath, options) {
  if (Object.hasOwn(options.versions, toolName)) {
    return normalizeVersion(options.versions[toolName]);
  }

  if (toolName === 'node') {
    return normalizeVersion(process.version);
  }

  return resolveVersionFromCommands(toolName, resolvedPath, options);
}

async function findPathTool(toolName, options) {
  const pathModule = getPathModule(options.cwd);
  const pathEntries = String(options.env.PATH || '')
    .split(path.delimiter)
    .filter(Boolean);

  for (const entry of pathEntries) {
    const candidate = normalizePath(pathModule, pathModule.join(entry, toolName));
    if (await pathExists(options.fs, candidate)) {
      return candidate;
    }
  }

  return null;
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

async function readLocalProperties(options, requirements) {
  const pathModule = getPathModule(options.cwd);
  const localPropertiesPath = normalizePath(pathModule, pathModule.join(options.cwd, '..', requirements.files.localProperties));
  if (!(await pathExists(options.fs, localPropertiesPath))) {
    return new Map();
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

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function replaceApiVersion(template, apiVersion) {
  return template.replaceAll('{apiVersion}', String(apiVersion));
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

  return unique(candidates);
}

async function pickSdkRoot(options, requirements) {
  const pathModule = getPathModule(options.cwd);
  const apiVersion = requirements.target.apiVersion;
  const rootCandidates = await resolveSdkRootCandidates(options, requirements);

  for (const root of rootCandidates) {
    for (const metadataTemplate of requirements.files.sdkMetadata) {
      const metadataPath = normalizePath(pathModule, pathModule.join(root, replaceApiVersion(metadataTemplate, apiVersion)));
      const metadata = await readJsonIfExists(options.fs, metadataPath);
      if (!metadata) {
        continue;
      }

      const discoveredApiVersion = Number.parseInt(String(metadata.apiVersion ?? apiVersion), 10);
      return {
        root,
        metadata,
        apiVersion: Number.isNaN(discoveredApiVersion) ? null : discoveredApiVersion,
        sdkVersion: metadata.sdkVersion ?? null
      };
    }
  }

  return {
    root: rootCandidates[0] ?? null,
    metadata: null,
    apiVersion: null,
    sdkVersion: null
  };
}

async function everyPathExists(fsApi, filePaths) {
  for (const filePath of filePaths) {
    if (!(await pathExists(fsApi, filePath))) {
      return false;
    }
  }

  return true;
}

function createToolStatus(found, version) {
  return {
    found,
    version: found ? version ?? null : null
  };
}

function pushFailure(failures, code, detail) {
  if (failures.some((entry) => entry.code === code && entry.detail === detail)) {
    return;
  }

  failures.push({ code, detail });
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

function hasCompleteRequirements(requirements) {
  return Boolean(
    requirements &&
    requirements.schemaVersion &&
    requirements.target?.platform &&
    Number.isInteger(requirements.target?.apiVersion) &&
    Array.isArray(requirements.env?.sdkRoots) &&
    requirements.tools &&
    requirements.files?.localProperties &&
    Array.isArray(requirements.files?.sdkMetadata) &&
    Array.isArray(requirements.files?.apiMarkers) &&
    Array.isArray(requirements.files?.ndkMarkers) &&
    requirements.files?.clang &&
    requirements.files?.llvmReadelf
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

export async function discoverToolchain(input = {}) {
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
  const apiVersion = requirements.target.apiVersion;
  const pathModule = getPathModule(options.cwd);
  const failures = [];
  const tools = {};

  for (const toolName of HOST_TOOL_NAMES) {
    const resolved = await findPathTool(toolName, options);
    const version = resolved ? await resolveVersion(toolName, resolved, options) : null;
    tools[toolName] = createToolStatus(Boolean(resolved), version);
    if (!resolved) {
      pushFailure(failures, 'TOOL_MISSING', toolName);
    } else if (!version) {
      pushFailure(failures, 'TOOL_VERSION_MISSING', toolName);
    }
  }

  const sdkRoot = await pickSdkRoot(options, requirements);
  const apiMarkerPaths = sdkRoot.root
    ? requirements.files.apiMarkers.map((template) => normalizePath(pathModule, pathModule.join(sdkRoot.root, replaceApiVersion(template, apiVersion))))
    : [];
  const ndkMarkerPaths = sdkRoot.root
    ? requirements.files.ndkMarkers.map((template) => normalizePath(pathModule, pathModule.join(sdkRoot.root, replaceApiVersion(template, apiVersion))))
    : [];
  const clangPath = sdkRoot.root
    ? normalizePath(pathModule, pathModule.join(sdkRoot.root, replaceApiVersion(requirements.files.clang, apiVersion)))
    : null;
  const llvmReadelfPath = sdkRoot.root
    ? normalizePath(pathModule, pathModule.join(sdkRoot.root, replaceApiVersion(requirements.files.llvmReadelf, apiVersion)))
    : null;

  const apiMarkersFound = apiMarkerPaths.length > 0 && (await everyPathExists(options.fs, apiMarkerPaths));
  const ndkMarkersFound = ndkMarkerPaths.length > 0 && (await everyPathExists(options.fs, ndkMarkerPaths));
  const clangFound = Boolean(clangPath) && (await pathExists(options.fs, clangPath));
  const llvmReadelfFound = Boolean(llvmReadelfPath) && (await pathExists(options.fs, llvmReadelfPath));

  tools.ohosClang = createToolStatus(clangFound, clangFound ? String(apiVersion) : null);
  tools.llvmReadelf = createToolStatus(llvmReadelfFound, llvmReadelfFound ? String(apiVersion) : null);

  if (requirements.target.apiVersion !== 20 || sdkRoot.apiVersion !== 20 || !apiMarkersFound) {
    pushFailure(failures, 'API20_MISSING', `api-${apiVersion}`);
  }

  if (!ndkMarkersFound || !clangFound || !llvmReadelfFound) {
    pushFailure(failures, 'NDK_MISSING', `api-${apiVersion}`);
  }

  const result = failures.length === 0 ? 'pass' : 'incomplete';

  return {
    schemaVersion: requirements.schemaVersion,
    result,
    target: {
      platform: requirements.target.platform,
      apiVersion,
      sdkVersion: sdkRoot.sdkVersion,
      ndkFound: ndkMarkersFound && clangFound && llvmReadelfFound
    },
    tools,
    failures
  };
}

export function describeFailureCodes() {
  return { ...FAILURE_DETAILS };
}
