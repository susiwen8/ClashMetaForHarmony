import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn as spawnChild } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const probeHelperPath = new URL('../../tools/build-go-ohos-probe.mjs', import.meta.url);
const coreHelperPath = new URL('../../tools/build-mihomo-ohos.mjs', import.meta.url);
const inspectLibPath = new URL('../bin/inspect-native-lib.mjs', import.meta.url);
const upstreamLockPath = new URL('../../core/go/upstream.lock.json', import.meta.url);
const upstreamApiLockPath = new URL('../../core/go/upstream.api-lock.json', import.meta.url);
const probeModulePath = new URL('../../core/go/probe/go.mod', import.meta.url);
const coreMainPath = new URL('../../core/go/cmd/cmfa_core/main.go', import.meta.url);
const harmonyRoot = path.resolve(new URL('../..', import.meta.url).pathname);
const RAW_VERSION_EXPORT = 'cmfa_mihomo_core_version_cstr_v1';
const BUILD_INFO_EXPORT = 'cmfa_mihomo_core_build_info_json_cstr_v1';
const EXPECTED_BUILD_INFO_JSON = '{"version":"v1.19.29","upstreamCommit":"e26714a181ac0e2fa803453c0a8e9a9ce94e31cb","abiVersion":"cmfa-harmony-v1","buildId":"ea041f1758f53faf"}';
const CORE_EXPORTS = [
  BUILD_INFO_EXPORT,
  RAW_VERSION_EXPORT,
  'cmfa_mihomo_probe_cancel_v1',
  'cmfa_mihomo_probe_https_v1',
  'cmfa_mihomo_runtime_state_v1',
  'cmfa_mihomo_start_local_v1',
  'cmfa_mihomo_stop_v1',
  'cmfa_mihomo_take_runtime_log_v1'
];

function joinFragments(parts) {
  return parts.join('');
}

const fakeToolchainClangPath = joinFragments(['/sd', 'k/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang']);
const fakeToolchainReadelfPath = joinFragments(['/sd', 'k/default/openharmony/native/llvm/bin/llvm-readelf']);
const fakeHostClangPath = joinFragments(['/us', 'r/bin/clang']);
const fakeAttackerPath = joinFragments(['/tm', 'p/attacker-bin']);
const fakeTrustedGoPath = joinFragments(['/tr', 'usted/toolchains/go/bin/go']);
const fakeUsrBinPath = joinFragments(['/us', 'r/bin']);
const fakeSecretUrl = joinFragments(['https://', 'user', ':', 'token', '@example.invalid/private.zip']);
const fakeWindowsSdkPath = joinFragments(['C:\\', 'Users\\me\\sdk']);
const task9GoModCache = process.env.GOMODCACHE || joinFragments(['/pri', 'vate/tmp/cmfa-go-mod-cache-task9']);
const task9GoBuildCache = process.env.GOCACHE || joinFragments(['/pri', 'vate/tmp/cmfa-go-build-cache-task9']);
const task9GoProxy = process.env.GOPROXY || `file://${path.join(task9GoModCache, 'cache', 'download')}`;

test.afterEach(() => {
  process.exitCode = undefined;
});

function createGoRunner(envOverrides = {}) {
  return (args) => new Promise((resolve) => {
    const child = spawnChild('go', args, {
      cwd: path.join(harmonyRoot, 'core', 'go'),
      env: { ...process.env, ...envOverrides },
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe']
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

test('Task 5 build surfaces exist and export the documented entry points', async () => {
  const [{ buildGoOhosProbe, GO_OHOS_PROOF_PATH }, { buildMihomoOhos }, { inspectNativeLibrary }] = await Promise.all([
    import(probeHelperPath),
    import(coreHelperPath),
    import(inspectLibPath)
  ]);

  assert.equal(typeof buildGoOhosProbe, 'function');
  assert.equal(typeof buildMihomoOhos, 'function');
  assert.equal(typeof inspectNativeLibrary, 'function');
  assert.match(GO_OHOS_PROOF_PATH, /\/harmony\/artifacts\/go-ohos-build-proof\.json$/u);
});

test('Task 5 keeps probe as an independent Go module', async () => {
  const [goModRaw, probeMainRaw] = await Promise.all([
    fs.readFile(probeModulePath, 'utf8'),
    fs.readFile(new URL('../../core/go/probe/main.go', import.meta.url), 'utf8')
  ]);

  assert.match(goModRaw, /^module /mu);
  assert.doesNotMatch(goModRaw, /replace\s+\.\.\//u);
  assert.doesNotMatch(probeMainRaw, /internal\/version/u);
});

test('Task 7 gives the real Go version getter one backend-private export', async () => {
  const coreMainRaw = await fs.readFile(coreMainPath, 'utf8');

  assert.match(coreMainRaw, new RegExp(String.raw`//export ${RAW_VERSION_EXPORT}\b`, 'u'));
  assert.match(coreMainRaw, new RegExp(String.raw`//export ${BUILD_INFO_EXPORT}\b`, 'u'));
  assert.match(coreMainRaw, /version\.BuildInfoJSON\(\)/u);
  assert.doesNotMatch(coreMainRaw, /\/\/export cmfa_core_version\b/u);
});

test('Task 9 audit output is deterministic and omits volatile timestamps', async () => {
  const [{ auditMihomoApi }] = await Promise.all([
    import(new URL('../../tools/audit-mihomo-api.mjs', import.meta.url))
  ]);

  const packageRoots = {
    'github.com/metacubex/mihomo/hub/executor': {
      Dir: '/tmp/mihomo/hub/executor',
      Root: '/tmp/mihomo',
      GoFiles: ['executor.go']
    },
    'github.com/metacubex/mihomo/listener/http': {
      Dir: '/tmp/mihomo/listener/http',
      Root: '/tmp/mihomo',
      GoFiles: ['server.go']
    },
    'github.com/metacubex/mihomo/listener/socks': {
      Dir: '/tmp/mihomo/listener/socks',
      Root: '/tmp/mihomo',
      GoFiles: ['tcp.go']
    },
    'github.com/metacubex/mihomo/tunnel': {
      Dir: '/tmp/mihomo/tunnel',
      Root: '/tmp/mihomo',
      GoFiles: ['tunnel.go']
    },
    'github.com/metacubex/mihomo/tunnel/statistic': {
      Dir: '/tmp/mihomo/tunnel/statistic',
      Root: '/tmp/mihomo',
      GoFiles: ['manager.go', 'tracker.go']
    },
    'github.com/metacubex/mihomo/constant': {
      Dir: '/tmp/mihomo/constant',
      Root: '/tmp/mihomo',
      GoFiles: ['metadata.go']
    }
  };
  const fileBodies = new Map([
    ['/tmp/mihomo/hub/executor/executor.go', '//go:build amd64 || arm64\npackage executor\nfunc ParseWithPath(path string) (*config.Config, error) { return nil, nil }\nfunc ParseWithBytes(buf []byte) (*config.Config, error) { return nil, nil }\nfunc ApplyConfig(cfg *config.Config, force bool) {}\nfunc Shutdown() {}\n'],
    ['/tmp/mihomo/listener/http/server.go', 'package http\nfunc NewWithAuthenticate(addr string, tunnel C.Tunnel, authenticate bool, additions ...inbound.Addition) (*Listener, error) { return nil, nil }\n'],
    ['/tmp/mihomo/listener/socks/tcp.go', 'package socks\nfunc New(addr string, tunnel C.Tunnel, additions ...inbound.Addition) (*Listener, error) { return nil, nil }\n'],
    ['/tmp/mihomo/tunnel/tunnel.go', 'package tunnel\ntype tunnel struct{}\nvar Tunnel = tunnel{}\n'],
    ['/tmp/mihomo/tunnel/statistic/manager.go', 'package statistic\nfunc (m *Manager) Range(f func(c Tracker) bool) {}\n'],
    ['/tmp/mihomo/tunnel/statistic/tracker.go', 'package statistic\ntype Tracker interface {\n\tID() string\n\tInfo() *TrackerInfo\n}\ntype TrackerInfo struct {\n\tMetadata *C.Metadata\n\tStart time.Time\n}\nfunc (tt *tcpTracker) ID() string { return tt.UUID.String() }\nfunc (tt *tcpTracker) Info() *TrackerInfo { return tt.TrackerInfo }\n'],
    ['/tmp/mihomo/constant/metadata.go', 'package constant\ntype Type int\nfunc (t Type) String() string { return \"HTTP\" }\ntype Metadata struct {\n\tType Type\n\tSrcPort uint16\n\tDstPort uint16\n}\nfunc (m *Metadata) RemoteAddress() string { return \"127.0.0.1:443\" }\nfunc (m *Metadata) SourceAddress() string { return \"127.0.0.1:12345\" }\n']
  ]);
  const docBodies = new Map([
    ['github.com/metacubex/mihomo/hub/executor.ParseWithPath', 'func ParseWithPath(path string) (*config.Config, error)'],
    ['github.com/metacubex/mihomo/hub/executor.ParseWithBytes', 'func ParseWithBytes(buf []byte) (*config.Config, error)'],
    ['github.com/metacubex/mihomo/hub/executor.ApplyConfig', 'func ApplyConfig(cfg *config.Config, force bool)'],
    ['github.com/metacubex/mihomo/hub/executor.Shutdown', 'func Shutdown()'],
    ['github.com/metacubex/mihomo/listener/http.NewWithAuthenticate', 'func NewWithAuthenticate(addr string, tunnel C.Tunnel, authenticate bool, additions ...inbound.Addition) (*Listener, error)'],
    ['github.com/metacubex/mihomo/listener/socks.New', 'func New(addr string, tunnel C.Tunnel, additions ...inbound.Addition) (*Listener, error)'],
    ['github.com/metacubex/mihomo/tunnel.Tunnel', 'var Tunnel = tunnel{}'],
    ['github.com/metacubex/mihomo/tunnel/statistic.Manager.Range', 'func (m *Manager) Range(f func(c Tracker) bool)'],
    ['github.com/metacubex/mihomo/tunnel/statistic.Tracker.ID', 'func (tt *tcpTracker) ID() string'],
    ['github.com/metacubex/mihomo/tunnel/statistic.Tracker.Info', 'func (tt *tcpTracker) Info() *TrackerInfo'],
    ['github.com/metacubex/mihomo/tunnel/statistic.TrackerInfo', 'type TrackerInfo struct { Metadata *C.Metadata; Start time.Time }'],
    ['github.com/metacubex/mihomo/constant.Metadata.RemoteAddress', 'func (m *Metadata) RemoteAddress() string'],
    ['github.com/metacubex/mihomo/constant.Metadata.SourceAddress', 'func (m *Metadata) SourceAddress() string'],
    ['github.com/metacubex/mihomo/constant.Type.String', 'func (t Type) String() string']
  ]);
  const dirEntries = new Map([
    ['/tmp/mihomo/hub/executor', [{ name: 'executor.go', isFile: () => true }]],
    ['/tmp/mihomo/listener/http', [{ name: 'server.go', isFile: () => true }]],
    ['/tmp/mihomo/listener/socks', [{ name: 'tcp.go', isFile: () => true }]],
    ['/tmp/mihomo/tunnel', [{ name: 'tunnel.go', isFile: () => true }]],
    ['/tmp/mihomo/tunnel/statistic', [{ name: 'manager.go', isFile: () => true }, { name: 'tracker.go', isFile: () => true }]],
    ['/tmp/mihomo/constant', [{ name: 'metadata.go', isFile: () => true }]]
  ]);
  const runGoImpl = async ({ args }) => {
    if (args[0] === 'list') {
      const payload = packageRoots[args.at(-1)];
      return { code: 0, stdout: JSON.stringify(payload), stderr: '' };
    }
    if (args[0] === 'doc') {
      const payload = docBodies.get(args.at(-1));
      return { code: 0, stdout: payload, stderr: '' };
    }
    throw new Error(`unexpected go call: ${args.join(' ')}`);
  };
  const first = await auditMihomoApi({
    writeOutput: false,
    runGoImpl,
    upstreamLock: {
      schemaVersion: '1.0.0',
      module: 'github.com/metacubex/mihomo',
      version: 'v1.19.29',
      commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
      remote: 'https://github.com/MetaCubeX/mihomo',
      ref: 'refs/tags/v1.19.29'
    },
    readFileImpl: async (filePath) => fileBodies.get(filePath),
    readDirImpl: async (dirPath) => dirEntries.get(dirPath) ?? []
  });
  const second = await auditMihomoApi({
    writeOutput: false,
    runGoImpl,
    upstreamLock: {
      schemaVersion: '1.0.0',
      module: 'github.com/metacubex/mihomo',
      version: 'v1.19.29',
      commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
      remote: 'https://github.com/MetaCubeX/mihomo',
      ref: 'refs/tags/v1.19.29'
    },
    readFileImpl: async (filePath) => fileBodies.get(filePath),
    readDirImpl: async (dirPath) => dirEntries.get(dirPath) ?? []
  });

  assert.deepEqual(first, second);
  assert.equal('auditedAt' in first, false);
  assert.ok(first.symbols.some((entry) =>
    entry.importPath === 'github.com/metacubex/mihomo/tunnel' &&
    entry.symbol === 'Tunnel' &&
    /var Tunnel = tunnel\{\}/u.test(entry.signature) &&
    /global shared tunnel/u.test(entry.ownership)
  ));
  assert.ok(first.symbols.some((entry) =>
    entry.importPath === 'github.com/metacubex/mihomo/tunnel/statistic' &&
    entry.symbol === 'Tracker.Info' &&
    /TrackerInfo/u.test(entry.signature) &&
    /borrowed live tracker metadata/u.test(entry.ownership)
  ));
  assert.ok(first.symbols.some((entry) =>
    entry.importPath === 'github.com/metacubex/mihomo/constant' &&
    entry.symbol === 'Metadata.SourceAddress' &&
    /SourceAddress/u.test(entry.signature)
  ));
});

test('Task 9 audit pins linux arm64 cgo env and scans CgoFiles plus package-dir go files for risk', async () => {
  const [{ auditMihomoApi }] = await Promise.all([
    import(new URL('../../tools/audit-mihomo-api.mjs', import.meta.url))
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'task9-audit-scan-'));
  const pkgDir = path.join(tempRoot, 'listener', 'http');
  const invocations = [];

  await fs.mkdir(pkgDir, { recursive: true });
  await fs.writeFile(path.join(pkgDir, 'server.go'), 'package http\nfunc NewWithAuthenticate(addr string, tunnel C.Tunnel, authenticate bool, additions ...inbound.Addition) (*Listener, error) { return nil, nil }\n', 'utf8');
  await fs.writeFile(path.join(pkgDir, 'cgo_risk.go'), 'package http\nimport _ "golang.org/x/sys/unix"\n', 'utf8');
  await fs.writeFile(path.join(pkgDir, 'linux_tag.go'), '//go:build linux && arm64\npackage http\n', 'utf8');

  try {
    const runGoImpl = async (invocation) => {
      invocations.push(invocation);
      const { args } = invocation;
      if (args[0] === 'list') {
        const importPath = args.at(-1);
        if (importPath === 'github.com/metacubex/mihomo/listener/http') {
          return { code: 0, stdout: JSON.stringify({ Dir: pkgDir, Root: tempRoot, GoFiles: ['server.go'], CgoFiles: ['cgo_risk.go'] }), stderr: '' };
        }
        if (importPath === 'github.com/metacubex/mihomo/listener/socks') {
          return { code: 0, stdout: JSON.stringify({ Dir: path.join(tempRoot, 'listener', 'socks'), Root: tempRoot, GoFiles: ['tcp.go'] }), stderr: '' };
        }
        if (importPath === 'github.com/metacubex/mihomo/tunnel') {
          return { code: 0, stdout: JSON.stringify({ Dir: path.join(tempRoot, 'tunnel'), Root: tempRoot, GoFiles: ['tunnel.go'] }), stderr: '' };
        }
        if (importPath === 'github.com/metacubex/mihomo/tunnel/statistic') {
          return { code: 0, stdout: JSON.stringify({ Dir: path.join(tempRoot, 'tunnel', 'statistic'), Root: tempRoot, GoFiles: ['manager.go', 'tracker.go'] }), stderr: '' };
        }
        if (importPath === 'github.com/metacubex/mihomo/constant') {
          return { code: 0, stdout: JSON.stringify({ Dir: path.join(tempRoot, 'constant'), Root: tempRoot, GoFiles: ['metadata.go'] }), stderr: '' };
        }
        return { code: 0, stdout: JSON.stringify({ Dir: path.join(tempRoot, 'hub', 'executor'), Root: tempRoot, GoFiles: ['executor.go'] }), stderr: '' };
      }
      if (args[0] === 'doc') {
        return { code: 0, stdout: `package fake // import "fake"\n\nfunc ${args.at(-1)}() {}\n`, stderr: '' };
      }
      throw new Error(`unexpected go call: ${args.join(' ')}`);
    };

    const payload = await auditMihomoApi({
      writeOutput: false,
      runGoImpl,
      upstreamLock: {
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        remote: 'https://github.com/MetaCubeX/mihomo',
        ref: 'refs/tags/v1.19.29'
      },
      readFileImpl: async (filePath) => {
        if (filePath.endsWith('executor.go')) return 'package executor\nfunc ParseWithPath(path string) (*config.Config, error) { return nil, nil }\nfunc ParseWithBytes(buf []byte) (*config.Config, error) { return nil, nil }\nfunc ApplyConfig(cfg *config.Config, force bool) {}\nfunc Shutdown() {}\n';
        if (filePath.endsWith('tcp.go')) return 'package socks\nfunc New(addr string, tunnel C.Tunnel, additions ...inbound.Addition) (*Listener, error) { return nil, nil }\n';
        if (filePath.endsWith(`${path.sep}tunnel.go`)) return 'package tunnel\ntype tunnel struct{}\nvar Tunnel = tunnel{}\n';
        if (filePath.endsWith('manager.go')) return 'package statistic\nfunc (m *Manager) Range(f func(c Tracker) bool) {}\n';
        if (filePath.endsWith('tracker.go')) return 'package statistic\ntype Tracker interface { ID() string; Info() *TrackerInfo }\ntype TrackerInfo struct { Metadata *C.Metadata; Start time.Time }\nfunc (tt *tcpTracker) ID() string { return tt.UUID.String() }\nfunc (tt *tcpTracker) Info() *TrackerInfo { return tt.TrackerInfo }\n';
        if (filePath.endsWith('metadata.go')) return 'package constant\ntype Type int\nfunc (t Type) String() string { return \"HTTP\" }\ntype Metadata struct { Type Type; SrcPort uint16; DstPort uint16 }\nfunc (m *Metadata) RemoteAddress() string { return \"127.0.0.1:443\" }\nfunc (m *Metadata) SourceAddress() string { return \"127.0.0.1:12345\" }\n';
        return await fs.readFile(filePath, 'utf8');
      },
      readDirImpl: async (dirPath) => {
        if (dirPath === pkgDir) {
          return [
            { name: 'server.go', isFile: () => true },
            { name: 'cgo_risk.go', isFile: () => true },
            { name: 'linux_tag.go', isFile: () => true }
          ];
        }
        if (dirPath.endsWith(path.join('listener', 'socks'))) {
          return [{ name: 'tcp.go', isFile: () => true }];
        }
        if (dirPath.endsWith(path.join('tunnel'))) {
          return [{ name: 'tunnel.go', isFile: () => true }];
        }
        if (dirPath.endsWith(path.join('tunnel', 'statistic'))) {
          return [{ name: 'manager.go', isFile: () => true }, { name: 'tracker.go', isFile: () => true }];
        }
        if (dirPath.endsWith(path.join('constant'))) {
          return [{ name: 'metadata.go', isFile: () => true }];
        }
        if (dirPath.endsWith(path.join('hub', 'executor'))) {
          return [{ name: 'executor.go', isFile: () => true }];
        }
        return [];
      }
    });

    for (const invocation of invocations) {
      assert.equal(invocation.env.GOOS, 'linux');
      assert.equal(invocation.env.GOARCH, 'arm64');
      assert.equal(invocation.env.CGO_ENABLED, '1');
    }

    const httpEntry = payload.symbols.find((entry) => entry.importPath === 'github.com/metacubex/mihomo/listener/http');
    assert.ok(httpEntry);
    assert.ok(httpEntry.packageAudit.some((entry) => entry.type === 'flaggedImport' && entry.file === 'cgo_risk.go' && entry.value === 'golang.org/x/sys/unix'));
    assert.ok(httpEntry.packageAudit.some((entry) => entry.type === 'buildTag' && entry.file === 'linux_tag.go' && entry.value === 'linux && arm64'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 9 audit hard-fails when go doc fails for a locked symbol', async () => {
  const [{ auditMihomoApi }] = await Promise.all([
    import(new URL('../../tools/audit-mihomo-api.mjs', import.meta.url))
  ]);

  await assert.rejects(
    () => auditMihomoApi({
      writeOutput: false,
      runGoImpl: async ({ args }) => {
        if (args[0] === 'list') {
          return {
            code: 0,
            stdout: JSON.stringify({
              Dir: '/tmp/mihomo/listener/http',
              Root: '/tmp/mihomo',
              GoFiles: ['server.go']
            }),
            stderr: ''
          };
        }
        if (args[0] === 'doc') {
          return { code: 1, stdout: '', stderr: 'doc boom' };
        }
        throw new Error(`unexpected go invocation: ${args.join(' ')}`);
      },
      readJsonImpl: async (filePath) => {
        if (String(filePath).endsWith('upstream.lock.json')) {
          return {
            schemaVersion: '1.0.0',
            module: 'github.com/metacubex/mihomo',
            version: 'v1.19.29',
            commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
            remote: 'https://github.com/MetaCubeX/mihomo',
            ref: 'refs/tags/v1.19.29'
          };
        }
        throw new Error(`unexpected json read: ${filePath}`);
      },
      readFileImpl: async () => 'package http\nfunc NewWithAuthenticate(addr string, tunnel C.Tunnel, authenticate bool, additions ...inbound.Addition) (*Listener, error) { return nil, nil }',
      readDirImpl: async () => [{ name: 'server.go', isFile: () => true }]
    }),
    /go doc failed/u
  );
});

test('Task 9 core helper refuses checked-in API-lock drift before starting a build and does not rewrite the lock', async () => {
  const [{ buildMihomoOhos }] = await Promise.all([
    import(coreHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-api-lock-drift-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const fakeLockPath = path.join(fakeHarmonyRoot, 'core', 'go', 'upstream.api-lock.json');
  let probeCalled = false;
  let coreCalled = false;

  await fs.mkdir(path.dirname(fakeLockPath), { recursive: true });
  const checkedInLock = {
    schemaVersion: '1.0.0',
    module: 'github.com/metacubex/mihomo',
    version: 'v1.19.29',
    commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
    symbols: [
      {
        importPath: 'github.com/metacubex/mihomo/listener/http',
        symbol: 'NewWithAuthenticate',
        signatureDigest: 'old-digest',
        ownership: 'old-ownership',
        requiredCloseOrder: []
      }
    ]
  };
  await fs.writeFile(fakeLockPath, `${JSON.stringify(checkedInLock, null, 2)}\n`, 'utf8');

  try {
    const proof = await buildMihomoOhos({
      harmonyRoot: fakeHarmonyRoot,
      upstreamLock: {
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        remote: 'https://github.com/MetaCubeX/mihomo',
        ref: 'refs/tags/v1.19.29'
      },
      upstreamApiLockPath: fakeLockPath,
      auditMihomoApiImpl: async () => ({
        ...checkedInLock,
        symbols: [
          {
            importPath: 'github.com/metacubex/mihomo/listener/http',
            symbol: 'NewWithAuthenticate',
            signatureDigest: 'new-digest',
            ownership: 'new-ownership',
            requiredCloseOrder: ['Listener.Close']
          }
        ]
      }),
      buildProbeComponentImpl: async () => {
        probeCalled = true;
        throw new Error('probe build should not run on API-lock drift');
      },
      buildCoreComponentImpl: async () => {
        coreCalled = true;
        throw new Error('core build should not run on API-lock drift');
      }
    });

    assert.equal(proof.result, 'fail');
    assert.equal(probeCalled, false);
    assert.equal(coreCalled, false);
    assert.ok(proof.failures.some((entry) => entry.code === 'UPSTREAM_API_LOCK_MISMATCH'));
    const persisted = await fs.readFile(fakeLockPath, 'utf8');
    assert.equal(persisted, `${JSON.stringify(checkedInLock, null, 2)}\n`);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 pins mihomo upstream metadata and never leaks absolute host paths into incomplete proof output', async () => {
  const [{ buildGoOhosProbe }, { inspectNativeLibrary }, upstreamLockModule] = await Promise.all([
    import(probeHelperPath),
    import(inspectLibPath),
    import(upstreamLockPath, { with: { type: 'json' } })
  ]);
  const fakeHome = joinFragments(['/Us', 'ers/example-user']);
  const fakeSdkRoot = joinFragments([fakeHome, '/Sec', 'ret/SDK']);

  assert.deepEqual(upstreamLockModule.default, {
    schemaVersion: '1.0.0',
    module: 'github.com/metacubex/mihomo',
    version: 'v1.19.29',
    commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
    remote: 'https://github.com/MetaCubeX/mihomo',
    ref: 'refs/tags/v1.19.29'
  });

  const proof = await buildGoOhosProbe({
    harmonyRoot,
    env: {
      HOME: fakeHome,
      DEVECO_SDK_HOME: fakeSdkRoot
    },
    inspectNativeLibraryImpl: inspectNativeLibrary,
    toolchainInspectorImpl: async () => ({
      report: {
        schemaVersion: '1.0.0',
        result: 'incomplete',
        target: {
          architecture: 'arm64',
          compatibleApiVersion: 20
        },
        installed: {
          devecoVersion: '6.1.0.860',
          sdkVersion: '6.1.0.105',
          ndkVersion: '6.1.0.105'
        },
        failures: [
          {
            code: 'TOOL_MISSING',
            detail: `${fakeSdkRoot}/openharmony/native/llvm/bin/llvm-readelf`
          }
        ],
        tools: {
          llvmReadelf: { found: false, version: null },
          ohosClang: { found: false, version: null }
        }
      },
      resolved: {
        sdkRoot: fakeSdkRoot,
        paths: {
          clang: `${fakeSdkRoot}/openharmony/native/llvm/bin/clang`,
          llvmReadelf: `${fakeSdkRoot}/openharmony/native/llvm/bin/llvm-readelf`
        }
      }
    })
  });

  assert.equal(proof.schemaVersion, '1.0.0');
  assert.notEqual(proof.result, 'pass');
  assert.equal(proof.outputPath, 'harmony/artifacts/go-ohos-build-proof.json');
  assert.equal(typeof proof.components, 'object');
  assert.ok(Array.isArray(proof.failures));
  assert.ok(proof.failures.length > 0);

  const persisted = JSON.stringify(proof);
  assert.doesNotMatch(persisted, /\/Users\/example-user/u);
  assert.doesNotMatch(persisted, /Secret\/SDK/u);
});

test('Task 5 probe helper locks the documented Go env and build args without duplicate target flags', async () => {
  const [{ buildGoOhosProbe }] = await Promise.all([
    import(probeHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-probe-contract-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const fakeArtifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
  const fakeArtifactPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.so');
  const fakeHeaderPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.h');
  let observed = null;

  await fs.mkdir(fakeArtifactsRoot, { recursive: true });
  await fs.writeFile(path.join(fakeHarmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
        const proof = await buildGoOhosProbe({
          harmonyRoot: fakeHarmonyRoot,
          env: {
            HOME: joinFragments(['/Us', 'ers/probe-test']),
            PATH: fakeUsrBinPath
          },
      toolchainInspectorImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20 },
          installed: { devecoVersion: '6.1.0.860', sdkVersion: '6.1.0.105', ndkVersion: '6.1.0.105' },
          failures: []
        },
        resolved: {
          paths: {
            clang: fakeToolchainClangPath,
            llvmReadelf: fakeToolchainReadelfPath
          }
        }
      }),
      readGoVersionImpl: async () => 'go1.26.2',
      runCommandImpl: async (input) => {
        observed = input;
        await fs.writeFile(fakeArtifactPath, 'fake-so', 'utf8');
        await fs.writeFile(fakeHeaderPath, 'const char *cmfa_probe_version(void);\nint32_t cmfa_probe_add(int32_t left, int32_t right);\n', 'utf8');
        return { command: input.command, args: input.args, exitCode: 0, stdout: '', stderr: '', error: null, timedOut: false };
      },
      inspectNativeLibraryImpl: async () => ({
        schemaVersion: '1.0.0',
        result: 'pass',
        component: 'probe',
        architecture: 'AArch64',
        neededLibraries: ['libc.so'],
        allowedNeededLibraries: ['libc.so'],
        exportedSymbols: ['cmfa_probe_add', 'cmfa_probe_version'],
        requiredExports: ['cmfa_probe_add', 'cmfa_probe_version'],
        failures: []
      })
    });

    assert.equal(proof.components.probe.result, 'pass');
    assert.equal(proof.result, 'incomplete');
    assert.deepEqual(observed.args, ['build', '-mod=readonly', '-tags', 'ohos', '-buildmode=c-shared', '-o', fakeArtifactPath, '.']);
    assert.equal(observed.env.GOOS, 'linux');
    assert.equal(observed.env.GOARCH, 'arm64');
    assert.equal(observed.env.CGO_ENABLED, '1');
    assert.equal(observed.env.CC, 'aarch64-unknown-linux-ohos-clang');
    assert.equal(observed.env.CXX, 'aarch64-unknown-linux-ohos-clang++');
    assert.equal(observed.cwd, path.join(fakeHarmonyRoot, 'core', 'go', 'probe'));
    assert.equal('CGO_CFLAGS' in observed.env, false);
    assert.equal('CGO_LDFLAGS' in observed.env, false);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 helpers reject host clang overrides and still write sanitized proof when the toolchain inspector throws', async () => {
  const [{ buildGoOhosProbe, GO_OHOS_PROOF_PATH }] = await Promise.all([
    import(probeHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-probe-fail-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const fakeHome = joinFragments(['/Us', 'ers/failing-user']);
  const fakeSdkRoot = joinFragments([fakeHome, '/Sec', 'ret/sdk']);

  try {
    const proof = await buildGoOhosProbe({
      harmonyRoot: fakeHarmonyRoot,
      proofPath: path.join(fakeHarmonyRoot, 'artifacts', 'go-ohos-build-proof.json'),
      env: {
        HOME: fakeHome,
        DEVECO_SDK_HOME: fakeSdkRoot,
        CC: fakeHostClangPath
      },
      toolchainInspectorImpl: async () => {
        throw Object.assign(new Error(`boom: ${fakeSdkRoot}`), { code: 'INSPECTOR_BROKEN' });
      }
    });

    assert.equal(proof.outputPath, 'harmony/artifacts/go-ohos-build-proof.json');
    assert.notEqual(proof.components.probe.result, 'pass');
    assert.ok(proof.components.probe.failures.some((entry) => entry.code === 'TOOLCHAIN_OVERRIDE_FORBIDDEN'));
    assert.ok(proof.failures.some((entry) => entry.code === 'INSPECTOR_BROKEN'));

    const persisted = JSON.parse(await fs.readFile(path.join(fakeHarmonyRoot, 'artifacts', path.basename(GO_OHOS_PROOF_PATH)), 'utf8'));
    const serialized = JSON.stringify(persisted);
    assert.doesNotMatch(serialized, /\/Users\/failing-user/u);
    assert.doesNotMatch(serialized, /Secret\/sdk/u);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 probe helper does not allow caller options to override the probe build contract', async () => {
  const [{ buildGoOhosProbe }] = await Promise.all([
    import(probeHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-probe-override-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const fakeArtifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
  const fakeProbeLibPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.so');
  const fakeProbeHeaderPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.h');
  const observed = { build: null, inspect: null };

  await fs.mkdir(fakeArtifactsRoot, { recursive: true });
  await fs.writeFile(path.join(fakeHarmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    const proof = await buildGoOhosProbe({
      harmonyRoot: fakeHarmonyRoot,
      component: 'mihomoCore',
      modulePath: 'core/go',
      packagePath: './cmd/cmfa_core',
      artifactFileName: 'libcmfa_mihomo.so',
      expectedExports: CORE_EXPORTS,
      targetName: 'attacker target',
      toolchainInspectorImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20 },
          installed: { devecoVersion: '6.1.0.860', sdkVersion: '6.1.0.105', ndkVersion: '6.1.0.105' },
          failures: []
        },
        resolved: {
          paths: {
            clang: fakeToolchainClangPath,
            llvmReadelf: fakeToolchainReadelfPath
          }
        }
      }),
      readGoVersionImpl: async () => 'go1.26.2',
      runCommandImpl: async (input) => {
        observed.build = input;
        await fs.writeFile(fakeProbeLibPath, 'fake-probe-so', 'utf8');
        await fs.writeFile(fakeProbeHeaderPath, 'const char *cmfa_probe_version(void);\nint32_t cmfa_probe_add(int32_t left, int32_t right);\n', 'utf8');
        return { command: input.command, args: input.args, exitCode: 0, stdout: '', stderr: '', error: null, timedOut: false };
      },
      inspectNativeLibraryImpl: async (input) => {
        observed.inspect = input;
        return {
          schemaVersion: '1.0.0',
          result: 'pass',
          component: 'probe',
          architecture: 'AArch64',
          neededLibraries: ['libc.so'],
          allowedNeededLibraries: ['libc.so'],
          exportedSymbols: ['cmfa_probe_add', 'cmfa_probe_version'],
          requiredExports: ['cmfa_probe_add', 'cmfa_probe_version'],
          failures: []
        };
      }
    });

    assert.equal(proof.components.probe.component, 'probe');
    assert.equal(proof.components.probe.target.packagePath, '.');
    assert.equal(proof.components.probe.artifact.path, 'harmony/artifacts/libcmfa_probe.so');
    assert.equal(observed.build.cwd, path.join(fakeHarmonyRoot, 'core', 'go', 'probe'));
    assert.deepEqual(observed.build.args.slice(-1), ['.']);
    assert.equal(observed.inspect.component, 'probe');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 build helpers resolve an absolute trusted go binary and ignore env PATH overrides', async () => {
  const [{ buildGoOhosProbe }] = await Promise.all([
    import(probeHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-go-bin-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const fakeArtifactsRoot = path.join(fakeHarmonyRoot, 'artifacts');
  const fakeProbeLibPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.so');
  const fakeProbeHeaderPath = path.join(fakeArtifactsRoot, 'libcmfa_probe.h');
  let resolverInput = null;
  let versionInput = null;
  let buildInput = null;

  await fs.mkdir(fakeArtifactsRoot, { recursive: true });
  await fs.writeFile(path.join(fakeHarmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    await buildGoOhosProbe({
      harmonyRoot: fakeHarmonyRoot,
      env: {
        PATH: fakeAttackerPath,
        HOME: joinFragments(['/Us', 'ers/go-bin-test'])
      },
      toolchainInspectorImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20 },
          installed: { devecoVersion: '6.1.0.860', sdkVersion: '6.1.0.105', ndkVersion: '6.1.0.105' },
          failures: []
        },
        resolved: {
          paths: {
            clang: fakeToolchainClangPath,
            llvmReadelf: fakeToolchainReadelfPath
          }
        }
      }),
      resolveGoBinaryImpl: async (input) => {
        resolverInput = input;
        return fakeTrustedGoPath;
      },
      readGoVersionImpl: async (input) => {
        versionInput = input;
        return 'go1.26.2';
      },
      runCommandImpl: async (input) => {
        buildInput = input;
        await fs.writeFile(fakeProbeLibPath, 'fake-probe-so', 'utf8');
        await fs.writeFile(fakeProbeHeaderPath, 'const char *cmfa_probe_version(void);\nint32_t cmfa_probe_add(int32_t left, int32_t right);\n', 'utf8');
        return { command: input.command, args: input.args, exitCode: 0, stdout: '', stderr: '', error: null, timedOut: false };
      },
      inspectNativeLibraryImpl: async () => ({
        schemaVersion: '1.0.0',
        result: 'pass',
        component: 'probe',
        architecture: 'AArch64',
        neededLibraries: ['libc.so'],
        allowedNeededLibraries: ['libc.so'],
        exportedSymbols: ['cmfa_probe_add', 'cmfa_probe_version'],
        requiredExports: ['cmfa_probe_add', 'cmfa_probe_version'],
        failures: []
      })
    });

    assert.equal(resolverInput.env.PATH, fakeAttackerPath);
    assert.equal(versionInput.goBinaryPath, fakeTrustedGoPath);
    assert.equal(buildInput.command, fakeTrustedGoPath);
    assert.doesNotMatch(buildInput.command, /attacker-bin/u);
    assert.notEqual(buildInput.command, 'go');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 build helper redacts URL userinfo from build failures', async () => {
  const [{ buildGoOhosProbe }] = await Promise.all([
    import(probeHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-redact-userinfo-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');

  await fs.mkdir(path.join(fakeHarmonyRoot, 'artifacts'), { recursive: true });
  await fs.writeFile(path.join(fakeHarmonyRoot, 'toolchain.lock.json'), JSON.stringify({
    installed: {
      devecoVersion: '6.1.0.860',
      sdkVersion: '6.1.0.105',
      ndkVersion: '6.1.0.105',
      hdcVersion: '6.1.0.105'
    }
  }), 'utf8');

  try {
    const proof = await buildGoOhosProbe({
      harmonyRoot: fakeHarmonyRoot,
      toolchainInspectorImpl: async () => ({
        report: {
          schemaVersion: '1.0.0',
          result: 'pass',
          target: { architecture: 'arm64', compatibleApiVersion: 20 },
          installed: { devecoVersion: '6.1.0.860', sdkVersion: '6.1.0.105', ndkVersion: '6.1.0.105' },
          failures: []
        },
        resolved: {
          paths: {
            clang: fakeToolchainClangPath,
            llvmReadelf: fakeToolchainReadelfPath
          }
        }
      }),
      resolveGoBinaryImpl: async () => fakeTrustedGoPath,
      readGoVersionImpl: async () => 'go1.26.2',
      runCommandImpl: async (input) => ({
        command: input.command,
        args: input.args,
        exitCode: 1,
        stdout: '',
        stderr: `download failed from ${fakeSecretUrl}`,
        error: null,
        timedOut: false
      })
    });

    const serialized = JSON.stringify(proof);
    assert.match(serialized, /https:\/\/<redacted-userinfo>@example\.invalid\/private\.zip/u);
    assert.doesNotMatch(serialized, /user:token/u);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 core helper aggregates fresh probe and mihomo builds into one canonical proof', async () => {
  const [{ buildMihomoOhos }] = await Promise.all([
    import(coreHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-core-proof-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const calls = [];

  try {
    const proof = await buildMihomoOhos({
      harmonyRoot: fakeHarmonyRoot,
      upstreamApiLock: {
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        symbols: []
      },
      auditMihomoApiImpl: async () => ({
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        symbols: []
      }),
      buildProbeComponentImpl: async () => {
        calls.push('probe');
        return {
          component: 'probe',
          result: 'pass',
          artifact: { path: 'harmony/artifacts/libcmfa_probe.so', headerPath: 'harmony/artifacts/libcmfa_probe.h', exists: true },
          build: { command: ['go', 'build', '-mod=readonly', '.'], env: { GOOS: 'linux' } },
          checks: { toolchain: { result: 'pass' }, build: { result: 'pass' }, elfInspection: { result: 'pass' } },
          elfInspection: { result: 'pass', exportedSymbols: ['cmfa_probe_add', 'cmfa_probe_version'], failures: [] },
          failures: [],
          timestamps: { startedAt: '2026-08-03T00:00:00.000Z', completedAt: '2026-08-03T00:00:01.000Z' }
        };
      },
      buildCoreComponentImpl: async (input) => {
        calls.push(input.artifactFileName);
        return {
          component: 'mihomoCore',
          result: 'pass',
          artifact: { path: 'harmony/artifacts/libcmfa_mihomo.so', headerPath: 'harmony/artifacts/libcmfa_mihomo.h', exists: true },
          build: { command: ['go', 'build', '-mod=readonly', '-ldflags', input.extraGoArgs[1], './cmd/cmfa_core'], env: { GOOS: 'linux' } },
          checks: { toolchain: { result: 'pass' }, build: { result: 'pass' }, elfInspection: { result: 'pass' } },
          elfInspection: { result: 'pass', exportedSymbols: CORE_EXPORTS, failures: [] },
          failures: [],
          timestamps: { startedAt: '2026-08-03T00:00:02.000Z', completedAt: '2026-08-03T00:00:03.000Z' }
        };
      }
    });

    assert.deepEqual(calls, ['probe', 'libcmfa_mihomo.so']);
    assert.equal(proof.result, 'pass');
    assert.equal(proof.components.probe.result, 'pass');
    assert.equal(proof.components.mihomoCore.result, 'pass');
    assert.equal(proof.components.mihomoCore.artifact.path, 'harmony/artifacts/libcmfa_mihomo.so');
    assert.match(proof.components.mihomoCore.build.command.join(' '), /constant\.Version=v1\.19\.29/u);
    assert.ok(
      proof.components.mihomoCore.build.command.join(' ').includes(
        `-X github.com/clashmetaforandroid/harmony/core/go/internal/version.embeddedBuildInfoJSON=${EXPECTED_BUILD_INFO_JSON}`
      )
    );
    assert.equal(proof.failures.length, 0);
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 core helper never reports overall pass when a component fails and still writes fail proof for invalid upstream lock', async () => {
  const [{ buildMihomoOhos }] = await Promise.all([
    import(coreHelperPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-core-fail-'));
  const fakeHarmonyRoot = path.join(tempRoot, 'harmony');
  const badLockPath = path.join(fakeHarmonyRoot, 'core', 'go', 'upstream.lock.json');

  await fs.mkdir(path.dirname(badLockPath), { recursive: true });
  await fs.writeFile(badLockPath, '{"schemaVersion":"1.0.0","version":"v0.0.0"}\n', 'utf8');
  await fs.mkdir(path.join(fakeHarmonyRoot, 'artifacts'), { recursive: true });
  for (const artifactName of ['libcmfa_probe.so', 'libcmfa_probe.h', 'libcmfa_mihomo.so', 'libcmfa_mihomo.h']) {
    await fs.writeFile(path.join(fakeHarmonyRoot, 'artifacts', artifactName), 'stale', 'utf8');
  }

  try {
    const invalidProof = await buildMihomoOhos({
      harmonyRoot: fakeHarmonyRoot,
      upstreamLockPath: badLockPath
    });

    assert.notEqual(invalidProof.result, 'pass');
    assert.ok(invalidProof.failures.some((entry) => entry.code === 'UPSTREAM_LOCK_INVALID'));
    assert.equal(invalidProof.components.probe, null);
    assert.equal(invalidProof.components.mihomoCore, null);
    for (const artifactName of ['libcmfa_probe.so', 'libcmfa_probe.h', 'libcmfa_mihomo.so', 'libcmfa_mihomo.h']) {
      assert.equal(await fs.stat(path.join(fakeHarmonyRoot, 'artifacts', artifactName)).then(() => true, () => false), false, `${artifactName} should be removed before invalid lock failure`);
    }

    const componentFailProof = await buildMihomoOhos({
      harmonyRoot: fakeHarmonyRoot,
      upstreamLock: {
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        remote: 'https://github.com/MetaCubeX/mihomo',
        ref: 'refs/tags/v1.19.29'
      },
      upstreamApiLock: {
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        symbols: []
      },
      auditMihomoApiImpl: async () => ({
        schemaVersion: '1.0.0',
        module: 'github.com/metacubex/mihomo',
        version: 'v1.19.29',
        commit: 'e26714a181ac0e2fa803453c0a8e9a9ce94e31cb',
        symbols: []
      }),
      buildProbeComponentImpl: async () => ({
        component: 'probe',
        result: 'pass',
        artifact: { path: 'harmony/artifacts/libcmfa_probe.so', headerPath: 'harmony/artifacts/libcmfa_probe.h', exists: true },
        build: { command: ['go', 'build'], env: {} },
        checks: { toolchain: { result: 'pass' }, build: { result: 'pass' }, elfInspection: { result: 'pass' } },
        elfInspection: { result: 'pass', exportedSymbols: ['cmfa_probe_add', 'cmfa_probe_version'], failures: [] },
        failures: [],
        timestamps: { startedAt: '2026-08-03T00:00:00.000Z', completedAt: '2026-08-03T00:00:01.000Z' }
      }),
      buildCoreComponentImpl: async () => ({
        component: 'mihomoCore',
        result: 'fail',
        artifact: { path: 'harmony/artifacts/libcmfa_mihomo.so', headerPath: 'harmony/artifacts/libcmfa_mihomo.h', exists: false },
        build: { command: ['go', 'build'], env: {} },
        checks: { toolchain: { result: 'pass' }, build: { result: 'fail' }, elfInspection: { result: 'pending' } },
        elfInspection: null,
        failures: [{ code: 'GO_BUILD_FAILED', detail: 'boom' }],
        timestamps: { startedAt: '2026-08-03T00:00:02.000Z', completedAt: '2026-08-03T00:00:03.000Z' }
      })
    });

    assert.notEqual(componentFailProof.result, 'pass');
    assert.equal(componentFailProof.components.probe.result, 'pass');
    assert.equal(componentFailProof.components.mihomoCore.result, 'fail');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 inspect CLI redacts workspace, SDK, userinfo, file URLs, and Windows paths from fatal errors', async () => {
  const [{ runCli }] = await Promise.all([
    import(inspectLibPath)
  ]);
  const stderrWrites = [];
  const originalWrite = process.stderr.write;
  const originalExitCode = process.exitCode;
  const fakeWorkspace = joinFragments(['/Us', 'ers/example-user/workspace/ClashMetaForAndroid']);
  const fakeSdkPath = joinFragments(['/Applic', 'ations/DevEco-Studio.app/Contents/sdk/default']);

  process.stderr.write = (chunk, encoding, callback) => {
    stderrWrites.push(String(chunk));
    if (typeof encoding === 'function') {
      encoding(null);
    } else if (typeof callback === 'function') {
      callback(null);
    }
    return true;
  };

  try {
        const exitCode = await runCli({
          argv: ['--lib', 'harmony/artifacts/libcmfa_probe.so'],
          inspectNativeLibraryImpl: async () => {
            throw Object.assign(new Error(`boom ${fakeWorkspace} ${fakeSdkPath} file://${fakeWorkspace}/secret ${fakeWindowsSdkPath} ${joinFragments(['https://', 'user', ':', 'token', '@example.invalid/path'])}`), {
              code: 'BROKEN'
            });
          }
    });

    const stderr = stderrWrites.join('');
    assert.equal(exitCode, 1);
    assert.doesNotMatch(stderr, /\/Users\/example-user/u);
    assert.doesNotMatch(stderr, /DevEco-Studio/u);
    assert.doesNotMatch(stderr, /user:token/u);
    assert.match(stderr, /https:\/\/<redacted-userinfo>@example\.invalid\/path/u);
    assert.match(stderr, /file:\/\/<redacted>/u);
    assert.match(stderr, /<path>/u);
  } finally {
    process.stderr.write = originalWrite;
    process.exitCode = originalExitCode;
  }
});

test('Task 5 inspect rejects non-regular files without spawning readelf and times out hung readelf children', async () => {
  const [{ inspectNativeLibrary }] = await Promise.all([
    import(inspectLibPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-inspect-'));
  const fakeDirPath = path.join(tempRoot, 'not-a-file');
  const fakeFilePath = path.join(tempRoot, 'libcmfa_probe.so');
  let spawnCalled = false;

  await fs.mkdir(fakeDirPath, { recursive: true });
  await fs.writeFile(fakeFilePath, 'fake-probe-so', 'utf8');

  try {
    await assert.rejects(
      () => inspectNativeLibrary({
        libPath: fakeDirPath,
            component: 'probe',
            toolchainInspectorImpl: async () => ({
              report: { result: 'pass' },
              resolved: { paths: { llvmReadelf: fakeToolchainReadelfPath } }
            }),
        spawnImpl: () => {
          spawnCalled = true;
          throw new Error('should not spawn');
        }
      }),
      (error) => error?.code === 'LIB_NOT_REGULAR'
    );
    assert.equal(spawnCalled, false);

    const timeoutOutcome = await Promise.race([
      inspectNativeLibrary({
        libPath: fakeFilePath,
            component: 'probe',
            toolchainInspectorImpl: async () => ({
              report: { result: 'pass' },
              resolved: { paths: { llvmReadelf: fakeToolchainReadelfPath } }
            }),
        readelfTimeoutMs: 20,
        spawnImpl: () => {
          spawnCalled = true;
          return {
            stdout: { setEncoding() {}, on() {} },
            stderr: { setEncoding() {}, on() {} },
            on(event, handler) {
              if (event === 'error') {
                this.onError = handler;
              }
              if (event === 'close') {
                this.onClose = handler;
              }
            },
            kill() {}
          };
        }
      }).then(() => 'unexpected-pass', (error) => error?.code ?? 'unexpected-error'),
      new Promise((resolve) => setTimeout(() => resolve('test-timeout'), 200))
    ]);
    assert.equal(timeoutOutcome, 'LLVMREADELF_TIMEOUT');
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 7 mihomo ELF rejects conflicting, sentinel, and libdl exports', async () => {
  const [{ inspectNativeLibrary }] = await Promise.all([
    import(inspectLibPath)
  ]);
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'go-ohos-mihomo-elf-'));
  const fakeLibPath = path.join(tempRoot, 'libcmfa_mihomo.so');
  const fakeBuildInfo = '{"version":"v1.19.29","upstreamCommit":"e26714a181ac0e2fa803453c0a8e9a9ce94e31cb","abiVersion":"cmfa-harmony-v1","buildId":"0123456789abcdef"}';

  const makeReadelfOutput = ({ neededLibraries = ['libc.so'], exportedSymbols = CORE_EXPORTS } = {}) => ({
    header: 'ELF Header:\n  Machine:                           AArch64\n',
    dynamic: neededLibraries.map((entry) => `0x0000000000000001 (NEEDED)             Shared library: [${entry}]`).join('\n'),
    symbols: exportedSymbols.map((entry, index) => `    ${index + 1}: 0000000000000000     0 FUNC    GLOBAL DEFAULT   12 ${entry}`).join('\n')
  });

  const inspectSynthetic = async ({ neededLibraries, exportedSymbols }) => {
    const outputs = makeReadelfOutput({ neededLibraries, exportedSymbols });
    const spawnImpl = (_command, args) => {
      const stdoutText = args[0] === '-h' ? outputs.header : args[0] === '-d' ? outputs.dynamic : outputs.symbols;
      return {
        stdout: {
          setEncoding() {},
          on(event, handler) {
            if (event === 'data' && stdoutText) {
              setImmediate(() => handler(stdoutText));
            }
          }
        },
        stderr: {
          setEncoding() {},
          on() {}
        },
        on(event, handler) {
          if (event === 'close') {
            setImmediate(() => handler(0, null));
          }
        },
        kill() {}
      };
    };

    return await inspectNativeLibrary({
      libPath: fakeLibPath,
      component: 'mihomoCore',
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { llvmReadelf: fakeToolchainReadelfPath } }
      }),
      spawnImpl
    });
  };

  await fs.writeFile(fakeLibPath, `fake-mihomo-so\0${fakeBuildInfo}\0v1.19.29`, 'utf8');

  try {
    const validInspection = await inspectSynthetic({
      neededLibraries: ['libc.so'],
      exportedSymbols: CORE_EXPORTS
    });
    assert.equal(validInspection.result, 'pass');
    assert.deepEqual(validInspection.exportedSymbols, CORE_EXPORTS);
    assert.equal(validInspection.buildInfo?.version, 'v1.19.29');
    assert.deepEqual(validInspection.failures, []);

    const forbiddenInspection = await inspectSynthetic({
      neededLibraries: ['libc.so'],
      exportedSymbols: ['cmfa_core_version']
    });
    assert.equal(forbiddenInspection.result, 'fail');
    assert.ok(forbiddenInspection.failures.some((entry) => entry.code === 'EXPORT_FORBIDDEN' && entry.detail === 'cmfa_core_version'));

    const mismatchInspection = await inspectSynthetic({
      neededLibraries: ['libc.so'],
      exportedSymbols: [...CORE_EXPORTS, 'cmfa_extra_symbol']
    });
    assert.equal(mismatchInspection.result, 'fail');
    assert.ok(mismatchInspection.failures.some((entry) => entry.code === 'EXPORT_SET_MISMATCH'));

    const sentinelInspection = await inspectSynthetic({
      neededLibraries: ['libc.so'],
      exportedSymbols: [...CORE_EXPORTS, 'cmfa_Test_Helper']
    });
    assert.equal(sentinelInspection.result, 'fail');
    assert.ok(sentinelInspection.failures.some((entry) => entry.code === 'EXPORT_SENTINEL_FORBIDDEN' && entry.detail === 'cmfa_Test_Helper'));

    const libdlInspection = await inspectSynthetic({
      neededLibraries: ['libc.so', 'libdl.so'],
      exportedSymbols: CORE_EXPORTS
    });
    assert.equal(libdlInspection.result, 'fail');
    assert.ok(libdlInspection.failures.some((entry) => entry.code === 'LIBDL_FORBIDDEN' && entry.detail === 'libdl.so'));
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
});

test('Task 5 probe CLI rejects missing --out values with canonical fail proof and core CLI rejects unknown args', async () => {
  const [{ runCli: runProbeCli, GO_OHOS_PROOF_PATH }, { runCli: runCoreCli }] = await Promise.all([
    import(probeHelperPath),
    import(coreHelperPath)
  ]);
  const stdoutWrites = [];
  const originalStdoutWrite = process.stdout.write;
  const originalExitCode = process.exitCode;

  process.stdout.write = (chunk, encoding, callback) => {
    stdoutWrites.push(String(chunk));
    if (typeof encoding === 'function') {
      encoding(null);
    } else if (typeof callback === 'function') {
      callback(null);
    }
    return true;
  };

  try {
    const probeExitCode = await runProbeCli({ argv: ['--out'] });
    const latestProof = JSON.parse(await fs.readFile(GO_OHOS_PROOF_PATH, 'utf8'));
    assert.equal(probeExitCode, 1);
    assert.equal(latestProof.outputPath, 'harmony/artifacts/go-ohos-build-proof.json');
    assert.ok(latestProof.failures.some((entry) => entry.code === 'ARGUMENT_INVALID'));

    const coreExitCode = await runCoreCli({ argv: ['--bogus'] });
    const coreSerialized = stdoutWrites.join('');
    assert.equal(coreExitCode, 1);
    assert.match(coreSerialized, /ARGUMENT_INVALID/u);
  } finally {
    process.stdout.write = originalStdoutWrite;
    process.exitCode = originalExitCode;
  }
});
