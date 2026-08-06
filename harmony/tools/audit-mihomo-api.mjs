import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const GO_MODULE_ROOT = path.join(HARMONY_ROOT, 'core', 'go');
const UPSTREAM_LOCK_PATH = path.join(GO_MODULE_ROOT, 'upstream.lock.json');
const OUTPUT_PATH = path.join(GO_MODULE_ROOT, 'upstream.api-lock.json');
const DEFAULT_GOMODCACHE = process.env.GOMODCACHE || path.join(HARMONY_ROOT, 'artifacts', 'go-mod-cache');
const DEFAULT_GOCACHE = process.env.GOCACHE || path.join(HARMONY_ROOT, 'artifacts', 'go-cache-task9');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function normalizePath(relativePath) {
  return relativePath.split(path.sep).join('/');
}

function createTargetGoEnv(overrides = {}) {
  return {
    ...process.env,
    GOMODCACHE: DEFAULT_GOMODCACHE,
    GOCACHE: DEFAULT_GOCACHE,
    ...overrides,
    GOOS: 'linux',
    GOARCH: 'arm64',
    CGO_ENABLED: '1',
  };
}

function runGo({ args, env = {} }) {
  return new Promise((resolve) => {
    const child = spawn('go', args, {
      cwd: GO_MODULE_ROOT,
      env: createTargetGoEnv(env),
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('close', (code) => {
      resolve({ code, stdout, stderr });
    });
  });
}

async function goList(importPath, runGoImpl = runGo) {
  const result = await runGoImpl({ args: ['list', '-find', '-e', '-json', importPath], env: createTargetGoEnv() });
  if (result.code !== 0) {
    throw new Error(`go list failed for ${importPath}: ${result.stderr || result.stdout}`.trim());
  }
  return JSON.parse(result.stdout);
}

async function goDoc(importPath, symbolName, runGoImpl = runGo) {
  return await runGoImpl({ args: ['doc', '-src', `${importPath}.${symbolName}`], env: createTargetGoEnv() });
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readFile(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

async function readDir(dirPath) {
  return await fs.readdir(dirPath, { withFileTypes: true });
}

async function loadPackage(importPath, { runGoImpl = runGo, readFileImpl = readFile, readDirImpl = readDir } = {}) {
  const pkg = await goList(importPath, runGoImpl);
  const targetFileNames = [...new Set([...(pkg.GoFiles || []), ...(pkg.CgoFiles || [])])].sort();
  const files = await Promise.all(
    targetFileNames.map(async (name) => {
      const absolutePath = path.join(pkg.Dir, name);
      return {
        name,
        absolutePath,
        source: await readFileImpl(absolutePath),
      };
    }),
  );
  const allEntries = await readDirImpl(pkg.Dir);
  const auditFileNames = allEntries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.go'))
    .map((entry) => entry.name)
    .sort();
  const auditFiles = await Promise.all(
    auditFileNames.map(async (name) => {
      const absolutePath = path.join(pkg.Dir, name);
      return {
        name,
        absolutePath,
        source: await readFileImpl(absolutePath),
      };
    }),
  );
  return { pkg, files, auditFiles };
}

function scanForSymbol(files, matcher) {
  for (const file of files) {
    const match = file.source.match(matcher);
    if (match) {
      return {
        file: file.name,
        snippet: match[0].trim(),
      };
    }
  }
  return null;
}

function auditFlags(files) {
  const findings = [];
  const buildTagPattern = /^\s*\/\/go:build\s+(.+)$/gmu;
  const flaggedImportPattern = /\b(golang\.org\/x\/sys\/unix|github\.com\/(?:mdlayher\/netlink|metacubex\/nftables)|liblog|android)\b/gmu;

  for (const file of files) {
    for (const match of file.source.matchAll(buildTagPattern)) {
      findings.push({ type: 'buildTag', file: file.name, value: match[1] });
    }
    for (const match of file.source.matchAll(flaggedImportPattern)) {
      findings.push({ type: 'flaggedImport', file: file.name, value: match[1] });
    }
    if (/\bos\.(Stat|ReadFile|WriteFile|OpenFile|MkdirAll)\(/u.test(file.source)) {
      findings.push({ type: 'filesystemAssumption', file: file.name });
    }
  }

  return [...new Map(
    findings
      .sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)))
      .map((entry) => [JSON.stringify(entry), entry])
  ).values()];
}

async function resolveSymbol(importPath, definition, { runGoImpl = runGo, readFileImpl = readFile, readDirImpl = readDir } = {}) {
  const loaded = await loadPackage(importPath, { runGoImpl, readFileImpl, readDirImpl });
  const symbolRef = `${importPath}.${definition.goDocName}`;
  const docResult = await goDoc(importPath, definition.goDocName, runGoImpl);
  if (docResult.code !== 0 || docResult.stdout.trim() === '') {
    throw new Error(`go doc failed for ${symbolRef}: ${(docResult.stderr || docResult.stdout || 'empty output').trim()}`);
  }
  const fallback = scanForSymbol(loaded.files, definition.sourcePattern);
  if (!fallback) {
    throw new Error(`Unable to locate ${symbolRef} in pinned source`);
  }

  const signature = docResult.stdout.trim();
  return {
    importPath,
    packageDir: normalizePath(path.relative(loaded.pkg.Root, loaded.pkg.Dir)) || '.',
    symbol: definition.symbol,
    docRef: symbolRef,
    file: fallback.file,
    signature,
    signatureDigest: sha256(signature),
    constructorInputs: definition.constructorInputs,
    ownership: definition.ownership,
    requiredCloseOrder: definition.requiredCloseOrder,
    packageAudit: auditFlags(loaded.auditFiles),
  };
}

function discoverSocksSymbol(loaded) {
  const candidates = [];
  for (const file of loaded.files) {
    for (const match of file.source.matchAll(/func\s+(New(?:With[A-Za-z]+)?)\s*\(([^)]*)\)\s*\(\*Listener,\s*error\)/gmu)) {
      candidates.push({
        name: match[1],
        args: match[2],
        file: file.name,
      });
    }
  }

  const exact = candidates.find((entry) => /\baddr string\b/u.test(entry.args) && /\btunnel C\.Tunnel\b/u.test(entry.args));
  if (!exact) {
    throw new Error('Unable to discover pinned SOCKS listener constructor');
  }

  return exact;
}

export async function auditMihomoApi(options = {}) {
  const fsApi = options.fsApi ?? fs;
  const runGoImpl = options.runGoImpl ?? runGo;
  const readJsonImpl = options.readJsonImpl ?? readJson;
  const readFileImpl = options.readFileImpl ?? readFile;
  const readDirImpl = options.readDirImpl ?? readDir;
  const outputPath = options.outputPath ?? OUTPUT_PATH;
  const writeOutput = options.writeOutput ?? true;

  await fsApi.mkdir(DEFAULT_GOCACHE, { recursive: true });

  const upstreamLock = options.upstreamLock ?? await readJsonImpl(UPSTREAM_LOCK_PATH);
  const socksPackage = await loadPackage('github.com/metacubex/mihomo/listener/socks', {
    runGoImpl,
    readFileImpl,
    readDirImpl
  });
  const discoveredSocks = discoverSocksSymbol(socksPackage);

  const entries = await Promise.all([
    resolveSymbol('github.com/metacubex/mihomo/hub/executor', {
      symbol: 'ParseWithPath',
      goDocName: 'ParseWithPath',
      sourcePattern: /func ParseWithPath\s*\([^)]*\)\s*\(\*config\.Config,\s*error\)/u,
      constructorInputs: ['path string'],
      ownership: 'caller owns the path and receives an immutable parsed config snapshot',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/hub/executor', {
      symbol: 'ParseWithBytes',
      goDocName: 'ParseWithBytes',
      sourcePattern: /func ParseWithBytes\s*\([^)]*\)\s*\(\*config\.Config,\s*error\)/u,
      constructorInputs: ['buf []byte'],
      ownership: 'caller owns the buffer and receives an immutable parsed config snapshot',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/hub/executor', {
      symbol: 'ApplyConfig',
      goDocName: 'ApplyConfig',
      sourcePattern: /func ApplyConfig\s*\([^)]*\)/u,
      constructorInputs: ['cfg *config.Config', 'force bool'],
      ownership: 'caller retains cfg; callee mutates global mihomo runtime state',
      requiredCloseOrder: ['Close local listeners before executor.Shutdown when embedding runtime'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/listener/http', {
      symbol: 'NewWithAuthenticate',
      goDocName: 'NewWithAuthenticate',
      sourcePattern: /func NewWithAuthenticate\s*\([^)]*\)\s*\(\*Listener,\s*error\)/u,
      constructorInputs: ['addr string', 'tunnel C.Tunnel', 'authenticate bool', 'additions ...inbound.Addition'],
      ownership: 'caller owns returned *Listener and must Close it explicitly',
      requiredCloseOrder: ['Listener.Close', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/listener/socks', {
      symbol: discoveredSocks.name,
      goDocName: discoveredSocks.name,
      sourcePattern: new RegExp(`func ${discoveredSocks.name}\\s*\\([^)]*\\)\\s*\\(\\*Listener,\\s*error\\)`, 'u'),
      constructorInputs: ['addr string', 'tunnel C.Tunnel', 'additions ...inbound.Addition'],
      ownership: 'caller owns returned *Listener and must Close it explicitly',
      requiredCloseOrder: ['Listener.Close', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/tunnel', {
      symbol: 'Tunnel',
      goDocName: 'Tunnel',
      sourcePattern: /var Tunnel = tunnel\{\}/u,
      constructorInputs: [],
      ownership: 'global shared tunnel singleton borrowed by listener constructors; callers must not replace or close it',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/tunnel/statistic', {
      symbol: 'DefaultManager.Range',
      goDocName: 'Manager.Range',
      sourcePattern: /func \(m \*Manager\) Range\(f func\(c Tracker\) bool\)/u,
      constructorInputs: ['f func(c Tracker) bool'],
      ownership: 'borrowed tracker handles; callback may close trackers before global shutdown',
      requiredCloseOrder: ['DefaultManager.Range(Tracker.Close)', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/tunnel/statistic', {
      symbol: 'Tracker.ID',
      goDocName: 'Tracker.ID',
      sourcePattern: /ID\(\) string/u,
      constructorInputs: [],
      ownership: 'borrowed tracker handle exposes a stable connection identifier while the tracked flow remains registered',
      requiredCloseOrder: ['Consume tracker ID before closing tracked connections', 'DefaultManager.Range(Tracker.Close)', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/tunnel/statistic', {
      symbol: 'Tracker.Info',
      goDocName: 'Tracker.Info',
      sourcePattern: /Info\(\) \*TrackerInfo/u,
      constructorInputs: [],
      ownership: 'borrowed live tracker metadata; callers must snapshot fields before the tracker is closed or leaves the manager',
      requiredCloseOrder: ['Snapshot tracker info before closing tracked connections', 'DefaultManager.Range(Tracker.Close)', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/tunnel/statistic', {
      symbol: 'TrackerInfo',
      goDocName: 'TrackerInfo',
      sourcePattern: /type TrackerInfo struct \{/u,
      constructorInputs: [],
      ownership: 'tracker-owned struct containing live metadata, counters, timestamps, and rule context',
      requiredCloseOrder: ['Snapshot TrackerInfo fields before closing tracked connections', 'DefaultManager.Range(Tracker.Close)', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/constant', {
      symbol: 'Metadata.RemoteAddress',
      goDocName: 'Metadata.RemoteAddress',
      sourcePattern: /func \(m \*Metadata\) RemoteAddress\(\) string/u,
      constructorInputs: [],
      ownership: 'borrowed metadata method deriving the outbound destination address from the tracked connection fields',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/constant', {
      symbol: 'Metadata.SourceAddress',
      goDocName: 'Metadata.SourceAddress',
      sourcePattern: /func \(m \*Metadata\) SourceAddress\(\) string/u,
      constructorInputs: [],
      ownership: 'borrowed metadata method deriving the client source address from the tracked connection fields',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/constant', {
      symbol: 'Type.String',
      goDocName: 'Type.String',
      sourcePattern: /func \(t Type\) String\(\) string/u,
      constructorInputs: [],
      ownership: 'pure stringification of inbound type enums used for tracker correlation and evidence output',
      requiredCloseOrder: [],
    }, { runGoImpl, readFileImpl, readDirImpl }),
    resolveSymbol('github.com/metacubex/mihomo/hub/executor', {
      symbol: 'Shutdown',
      goDocName: 'Shutdown',
      sourcePattern: /func Shutdown\(\)/u,
      constructorInputs: [],
      ownership: 'global shutdown entry point; caller owns call ordering and idempotence fences',
      requiredCloseOrder: ['Close listeners', 'Close tracked connections', 'executor.Shutdown'],
    }, { runGoImpl, readFileImpl, readDirImpl }),
  ]);

  const payload = {
    schemaVersion: '1.0.0',
    module: upstreamLock.module,
    version: upstreamLock.version,
    commit: upstreamLock.commit,
    symbols: entries,
  };

  if (writeOutput) {
    await fsApi.writeFile(outputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  }
  return payload;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  auditMihomoApi().then((payload) => {
    process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
