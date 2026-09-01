import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';

const repoRoot = path.resolve(new URL('../../..', import.meta.url).pathname);
const harmonyRoot = path.join(repoRoot, 'harmony');
const lockPath = path.join(harmonyRoot, 'geodata.lock.json');
const platformFactoryPath = path.join(harmonyRoot, 'platform', 'src', 'main', 'ets', 'PlatformFactory.ets');
const gitignorePath = path.join(repoRoot, '.gitignore');
const prepareModulePath = new URL('../../tools/prepare-geodata.mjs', import.meta.url);
const OFFICIAL_URL = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb';
const LOCK_SHA256 = '71def3ab45393093baf9d39b69787b3e0d0685607c13dd135bfdbb603bd475dd';
const LOCK_SIZE = 8593535;
const CACHE_IDENTITY = 'harmony/artifacts/geodata/geoip.metadb';
const RAWFILE_IDENTITY = 'harmony/entry/src/main/resources/rawfile/geoip.metadb';
const MAC_HOME_FRAGMENT = ['/', 'Us', 'ers', '/'].join('');
const WINDOWS_HOME_FRAGMENT = ['C:', '\\\\', 'Us', 'ers', '\\\\'].join('');

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function createSyntheticBytes(label) {
  return Buffer.from(`geoip-${label}-fixture`, 'utf8');
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function requireRuntimeBinding(label, condition) {
  assert.equal(condition, true, label);
}

function readPlatformFactoryRuntimeIdentity(source) {
  const sizeMatch = source.match(/const GEOIP_METADB_SIZE_BYTES: number = (\d+);/u);
  const digestMatch = source.match(/const GEOIP_METADB_SHA256: string = '([a-f0-9]{64})';/u);
  return {
    sizeBytes: sizeMatch === null ? null : Number(sizeMatch[1]),
    sha256: digestMatch === null ? null : digestMatch[1]
  };
}

async function withTempRepo(prefix, callback) {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  const tempRepoRoot = path.join(tempRoot, 'repo');
  const tempHarmonyRoot = path.join(tempRepoRoot, 'harmony');

  await fs.mkdir(tempHarmonyRoot, { recursive: true });

  try {
    await callback({
      tempRoot,
      repoRoot: tempRepoRoot,
      harmonyRoot: tempHarmonyRoot
    });
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
}

async function writeLockFile(tempHarmonyRoot, {
  sizeBytes,
  sha256: digest,
  urls = [OFFICIAL_URL]
}) {
  const payload = {
    schemaVersion: '1.0.0',
    assets: [
      {
        name: 'geoip.metadb',
        sizeBytes,
        sha256: digest,
        urls
      }
    ]
  };

  await fs.writeFile(path.join(tempHarmonyRoot, 'geodata.lock.json'), `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createFetchResponse(buffer, options = {}) {
  return {
    ok: options.ok ?? true,
    status: options.status ?? 200,
    statusText: options.statusText ?? 'OK',
    url: options.url ?? OFFICIAL_URL,
    body: Readable.from(options.chunks ?? [buffer])
  };
}

function createFsApiWithShortWrites({ matchPath, plannedWrites, invalidBytesWritten = null }) {
  return {
    ...fs,
    async open(targetPath, flags, mode) {
      const handle = await fs.open(targetPath, flags, mode);
      const normalizedPath = String(targetPath);
      if (!matchPath(normalizedPath, flags)) {
        return handle;
      }

      const planQueue = [...plannedWrites];
      return new Proxy(handle, {
        get(target, property, receiver) {
          if (property === 'write') {
            return async (buffer, ...rest) => {
              if (!Buffer.isBuffer(buffer)) {
                return await target.write(buffer, ...rest);
              }

              if (invalidBytesWritten !== null) {
                return { bytesWritten: invalidBytesWritten, buffer };
              }

              const requestedBytes = buffer.byteLength;
              const planned = planQueue.length > 0 ? planQueue.shift() : requestedBytes;
              const actualBytes = Math.max(0, Math.min(planned, requestedBytes));
              if (actualBytes > 0) {
                await target.write(buffer.subarray(0, actualBytes), ...rest);
              }
              return { bytesWritten: planned, buffer };
            };
          }

          const value = Reflect.get(target, property, receiver);
          return typeof value === 'function' ? value.bind(target) : value;
        }
      });
    }
  };
}

test('geodata lock pins the canonical geoip asset and .gitignore only ignores the exact generated outputs', async () => {
  const lock = JSON.parse(await fs.readFile(lockPath, 'utf8'));
  assert.equal(lock.schemaVersion, '1.0.0');
  assert.ok(Array.isArray(lock.assets), 'lock.assets must exist');
  assert.equal(lock.assets.length, 1, 'lock must pin exactly one asset');
  assert.deepEqual(lock.assets[0], {
    name: 'geoip.metadb',
    sizeBytes: LOCK_SIZE,
    sha256: LOCK_SHA256,
    urls: [OFFICIAL_URL]
  });
  assert.match(lock.assets[0].urls[0], /\/latest\/geoip\.metadb$/u);
  assert.doesNotMatch(
    JSON.stringify(lock),
    new RegExp(`@|${escapeRegex(MAC_HOME_FRAGMENT)}|${escapeRegex(WINDOWS_HOME_FRAGMENT)}`, 'u'),
    'lock must not embed credentials or machine paths'
  );

  const gitignore = await fs.readFile(gitignorePath, 'utf8');
  const lines = new Set(gitignore.split(/\r?\n/u));
  assert.equal(lines.has('/harmony/artifacts/geodata/geoip.metadb'), true);
  assert.equal(lines.has('/harmony/entry/src/main/resources/rawfile/geoip.metadb'), true);
  assert.equal(lines.has('/harmony/traffic-probe/.idea/'), true, 'nested traffic-probe IDE cache must be ignored exactly');
  assert.equal(lines.has('/harmony/artifacts/geodata/'), false, 'cache directory must not be broadly ignored');
  assert.equal(lines.has('/harmony/entry/src/main/resources/'), false, 'resource source directory must not be ignored');
  assert.equal(lines.has('/harmony/entry/src/main/resources/rawfile/'), false, 'rawfile directory must not be broadly ignored');
  assert.equal(lines.has('*.metadb'), false, 'all .metadb files must not be ignored globally');
});

test('platform factory runtime geodata constants stay bound to the canonical geodata lock', async () => {
  const [lockRaw, platformFactorySource] = await Promise.all([
    fs.readFile(lockPath, 'utf8'),
    fs.readFile(platformFactoryPath, 'utf8')
  ]);
  const lock = JSON.parse(lockRaw);
  const asset = lock?.assets?.[0];
  const runtimeIdentity = readPlatformFactoryRuntimeIdentity(platformFactorySource);

  requireRuntimeBinding('platform factory runtime size constant', runtimeIdentity.sizeBytes !== null);
  requireRuntimeBinding('platform factory runtime digest constant', runtimeIdentity.sha256 !== null);
  requireRuntimeBinding('platform factory runtime size binding', runtimeIdentity.sizeBytes === asset?.sizeBytes);
  requireRuntimeBinding('platform factory runtime digest binding', runtimeIdentity.sha256 === asset?.sha256);
});

test('prepareGeodata reuses a valid cache and writes the verified rawfile without fetching', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('cache-hit');

  await withTempRepo('geodata-cache-hit-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });
    const cachePath = path.join(tempRepoRoot, CACHE_IDENTITY);
    await fs.mkdir(path.dirname(cachePath), { recursive: true });
    await fs.writeFile(cachePath, bytes);

    let fetchCalls = 0;
    const prepared = await prepareGeodata({
      harmonyRoot: tempHarmonyRoot,
      fetchImpl: async () => {
        fetchCalls += 1;
        throw new Error('fetch should not run when the cache is valid');
      }
    });

    const rawfilePath = path.join(tempRepoRoot, RAWFILE_IDENTITY);
    assert.equal(fetchCalls, 0);
    assert.equal(prepared.result, 'pass');
    assert.equal(prepared.source, 'cache');
    assert.deepEqual(prepared.asset, {
      path: RAWFILE_IDENTITY,
      sha256: sha256(bytes),
      sizeBytes: bytes.byteLength
    });
    assert.deepEqual(await fs.readFile(rawfilePath), bytes);
  });
});

test('prepareGeodata streams valid bytes atomically into the cache and generated rawfile', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('download-pass');

  await withTempRepo('geodata-download-pass-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });

    const seenUrls = [];
    const prepared = await prepareGeodata({
      harmonyRoot: tempHarmonyRoot,
      fetchImpl: async (url) => {
        seenUrls.push(url);
        return createFetchResponse(bytes, {
          chunks: [bytes.subarray(0, 4), bytes.subarray(4)]
        });
      }
    });

    const cachePath = path.join(tempRepoRoot, CACHE_IDENTITY);
    const rawfilePath = path.join(tempRepoRoot, RAWFILE_IDENTITY);
    assert.deepEqual(seenUrls, [OFFICIAL_URL]);
    assert.equal(prepared.result, 'pass');
    assert.equal(prepared.source, 'download');
    assert.deepEqual(await fs.readFile(cachePath), bytes);
    assert.deepEqual(await fs.readFile(rawfilePath), bytes);
  });
});

test('prepareGeodata fails closed on digest or size mismatches and removes temporary outputs', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const expectedBytes = Buffer.from('digest-mismatch-bytes', 'utf8');
  const downloadedBytes = Buffer.from('digest-mismatch-BYTES', 'utf8');

  await withTempRepo('geodata-digest-fail-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: expectedBytes.byteLength,
      sha256: sha256(expectedBytes)
    });

    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fetchImpl: async () => createFetchResponse(downloadedBytes)
      }),
      (error) => error?.code === 'GEODATA_DIGEST_MISMATCH'
    );

    await assert.rejects(fs.access(path.join(tempRepoRoot, RAWFILE_IDENTITY)));
    await assert.rejects(fs.access(path.join(tempRepoRoot, CACHE_IDENTITY)));
    const artifactEntries = await fs.readdir(path.join(tempRepoRoot, 'harmony', 'artifacts'), { withFileTypes: true }).catch(() => []);
    assert.equal(artifactEntries.some((entry) => entry.name.startsWith('.tmp-')), false);
  });
});

test('prepareGeodata fails after all URLs are exhausted and leaves no rawfile behind', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('urls-fail');
  const mirrorUrl = 'https://mirror.example.invalid/geoip.metadb';

  await withTempRepo('geodata-url-fail-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes),
      urls: [OFFICIAL_URL, mirrorUrl]
    });

    const seenUrls = [];
    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fetchImpl: async (url) => {
          seenUrls.push(url);
          throw Object.assign(new Error(`cannot fetch ${url}`), { code: 'FETCH_FAIL' });
        }
      }),
      (error) => error?.code === 'GEODATA_FETCH_FAILED'
    );

    assert.deepEqual(seenUrls, [OFFICIAL_URL, mirrorUrl]);
    await assert.rejects(fs.access(path.join(tempRepoRoot, RAWFILE_IDENTITY)));
  });
});

test('prepareGeodata rejects symlinked or repo-escaping output paths before writing', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('symlink');

  await withTempRepo('geodata-path-reject-', async ({ tempRoot, repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });

    const outsideRoot = path.join(tempRoot, 'outside');
    const linkedResources = path.join(tempHarmonyRoot, 'entry', 'src', 'main', 'resources');
    await fs.mkdir(path.join(tempHarmonyRoot, 'entry', 'src', 'main'), { recursive: true });
    await fs.mkdir(outsideRoot, { recursive: true });
    await fs.symlink(outsideRoot, linkedResources, 'dir');

    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fetchImpl: async () => createFetchResponse(bytes)
      }),
      (error) => error?.code === 'PATH_OUTSIDE_REPO'
    );

    await assert.rejects(fs.access(path.join(outsideRoot, 'rawfile', 'geoip.metadb')));
    await assert.rejects(fs.access(path.join(tempRepoRoot, CACHE_IDENTITY)));
  });
});

test('prepareGeodata enforces the expected-size-plus-one stream bound', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const expectedBytes = createSyntheticBytes('bounded');
  const oversized = Buffer.concat([expectedBytes, Buffer.from('!')]);

  await withTempRepo('geodata-size-bound-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: expectedBytes.byteLength,
      sha256: sha256(expectedBytes)
    });

    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fetchImpl: async () => createFetchResponse(oversized, {
          chunks: [oversized.subarray(0, 2), oversized.subarray(2)]
        })
      }),
      (error) => error?.code === 'GEODATA_SIZE_MISMATCH'
    );

    await assert.rejects(fs.access(path.join(tempRepoRoot, CACHE_IDENTITY)));
    await assert.rejects(fs.access(path.join(tempRepoRoot, RAWFILE_IDENTITY)));
  });
});

test('prepareGeodata tolerates short writes while streaming the download temp file and still persists exact bytes', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('download-short-write');

  await withTempRepo('geodata-download-short-write-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });

    const fsApi = createFsApiWithShortWrites({
      matchPath(targetPath) {
        return targetPath.includes(path.join('artifacts', 'geodata', '.tmp-geoip-'));
      },
      plannedWrites: [1]
    });

    const prepared = await prepareGeodata({
      harmonyRoot: tempHarmonyRoot,
      fsApi,
      fetchImpl: async () => createFetchResponse(bytes)
    });

    assert.equal(prepared.result, 'pass');
    assert.deepEqual(await fs.readFile(path.join(tempRepoRoot, CACHE_IDENTITY)), bytes);
    assert.deepEqual(await fs.readFile(path.join(tempRepoRoot, RAWFILE_IDENTITY)), bytes);
  });
});

test('prepareGeodata tolerates multiple short writes while copying cache bytes into the rawfile temp file', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('rawfile-short-write');

  await withTempRepo('geodata-rawfile-short-write-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });
    const cachePath = path.join(tempRepoRoot, CACHE_IDENTITY);
    await fs.mkdir(path.dirname(cachePath), { recursive: true });
    await fs.writeFile(cachePath, bytes);

    const fsApi = createFsApiWithShortWrites({
      matchPath(targetPath) {
        return targetPath.includes(path.join('resources', 'rawfile', '.tmp-geoip.metadb-'));
      },
      plannedWrites: [1, 2]
    });

    const prepared = await prepareGeodata({
      harmonyRoot: tempHarmonyRoot,
      fsApi,
      fetchImpl: async () => {
        throw new Error('fetch should not run when rawfile copy is under test');
      }
    });

    assert.equal(prepared.result, 'pass');
    assert.deepEqual(await fs.readFile(path.join(tempRepoRoot, RAWFILE_IDENTITY)), bytes);
  });
});

test('prepareGeodata fails and cleans up when a download temp write reports zero bytes written', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('download-zero-write');

  await withTempRepo('geodata-download-zero-write-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });

    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fsApi: createFsApiWithShortWrites({
          matchPath(targetPath) {
            return targetPath.includes(path.join('artifacts', 'geodata', '.tmp-geoip-'));
          },
          plannedWrites: [0]
        }),
        fetchImpl: async () => createFetchResponse(bytes)
      }),
      (error) => error?.code === 'GEODATA_WRITE_INCOMPLETE' || /write\(\) reported 0/u.test(error?.message ?? '')
    );

    await assert.rejects(fs.access(path.join(tempRepoRoot, CACHE_IDENTITY)));
    await assert.rejects(fs.access(path.join(tempRepoRoot, RAWFILE_IDENTITY)));
  });
});

test('prepareGeodata fails and cleans up when a rawfile temp write reports an invalid byte count', async () => {
  const { prepareGeodata } = await import(prepareModulePath);
  const bytes = createSyntheticBytes('rawfile-invalid-write');

  await withTempRepo('geodata-rawfile-invalid-write-', async ({ repoRoot: tempRepoRoot, harmonyRoot: tempHarmonyRoot }) => {
    await writeLockFile(tempHarmonyRoot, {
      sizeBytes: bytes.byteLength,
      sha256: sha256(bytes)
    });
    const cachePath = path.join(tempRepoRoot, CACHE_IDENTITY);
    await fs.mkdir(path.dirname(cachePath), { recursive: true });
    await fs.writeFile(cachePath, bytes);

    await assert.rejects(
      prepareGeodata({
        harmonyRoot: tempHarmonyRoot,
        fsApi: createFsApiWithShortWrites({
          matchPath(targetPath) {
            return targetPath.includes(path.join('resources', 'rawfile', '.tmp-geoip.metadb-'));
          },
          plannedWrites: [],
          invalidBytesWritten: bytes.byteLength + 1
        }),
        fetchImpl: async () => {
          throw new Error('fetch should not run when rawfile invalid-write behavior is under test');
        }
      }),
      (error) => error?.code === 'GEODATA_WRITE_INCOMPLETE'
    );

    await fs.access(cachePath);
    await assert.rejects(fs.access(path.join(tempRepoRoot, RAWFILE_IDENTITY)));
  });
});
