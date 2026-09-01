import crypto from 'node:crypto';
import { constants as FS_CONSTANTS } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');

export const GEODATA_SCHEMA_VERSION = '1.0.0';
export const DEFAULT_LOCK_RELATIVE_PATH = 'harmony/geodata.lock.json';
export const DEFAULT_CACHE_RELATIVE_PATH = 'harmony/artifacts/geodata/geoip.metadb';
export const DEFAULT_RAWFILE_RELATIVE_PATH = 'harmony/entry/src/main/resources/rawfile/geoip.metadb';
export const PREPARE_GEODATA_COMMAND = Object.freeze(['prepare-geodata']);

function createError(code, message) {
  return Object.assign(new Error(message), { code });
}

function isLowerHexDigest(value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/u.test(value);
}

function normalizePathForReport(repoRoot, absolutePath) {
  const relativePath = path.relative(repoRoot, absolutePath);
  if (!relativePath.startsWith('..') && !path.isAbsolute(relativePath)) {
    return relativePath.split(path.sep).join('/');
  }

  return path.basename(absolutePath);
}

function ensureSafeUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(String(rawUrl));
  } catch {
    throw createError('GEODATA_LOCK_INVALID', `Invalid geodata URL: ${rawUrl}`);
  }

  if (!['https:', 'http:'].includes(parsed.protocol)) {
    throw createError('GEODATA_LOCK_INVALID', `Unsupported geodata URL protocol: ${parsed.protocol}`);
  }
  if (parsed.username || parsed.password) {
    throw createError('GEODATA_LOCK_INVALID', 'Geodata URLs must not embed credentials.');
  }
  if (/%5c|\\|\/Users\/|[A-Za-z]:\\Users\\/iu.test(rawUrl)) {
    throw createError('GEODATA_LOCK_INVALID', 'Geodata URLs must not embed machine paths.');
  }

  return parsed.toString();
}

function isWithinRepo(realRepoRoot, candidatePath) {
  const relative = path.relative(realRepoRoot, candidatePath);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

async function resolveRepoScopedFilePath(fsApi, repoRoot, relativePath) {
  const resolved = path.resolve(repoRoot, relativePath);
  const lexicalRelative = path.relative(repoRoot, resolved);
  if (lexicalRelative.startsWith('..') || path.isAbsolute(lexicalRelative)) {
    throw createError('PATH_OUTSIDE_REPO', `${relativePath} escapes the repository root.`);
  }

  const realRepoRoot = await fsApi.realpath(repoRoot);
  let existingAncestor = path.dirname(resolved);
  while (true) {
    try {
      const realAncestor = await fsApi.realpath(existingAncestor);
      if (!isWithinRepo(realRepoRoot, realAncestor)) {
        throw createError('PATH_OUTSIDE_REPO', `${relativePath} resolves outside the repository through a symlink.`);
      }
      break;
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        throw error;
      }
      const parent = path.dirname(existingAncestor);
      if (parent === existingAncestor) {
        throw error;
      }
      existingAncestor = parent;
    }
  }

  await fsApi.mkdir(path.dirname(resolved), { recursive: true });
  const realParent = await fsApi.realpath(path.dirname(resolved));
  if (!isWithinRepo(realRepoRoot, realParent)) {
    throw createError('PATH_OUTSIDE_REPO', `${relativePath} resolves outside the repository through a symlink.`);
  }

  try {
    const targetStats = await fsApi.lstat(resolved);
    if (targetStats.isSymbolicLink()) {
      throw createError('PATH_OUTSIDE_REPO', `${relativePath} must not be a symlink.`);
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }

  return path.join(realParent, path.basename(resolved));
}

function validateLockShape(lock) {
  if (!lock || typeof lock !== 'object' || Array.isArray(lock)) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata.lock.json must be an object.');
  }
  if (lock.schemaVersion !== GEODATA_SCHEMA_VERSION) {
    throw createError('GEODATA_LOCK_INVALID', `geodata.lock.json schemaVersion must be ${GEODATA_SCHEMA_VERSION}.`);
  }
  if (!Array.isArray(lock.assets) || lock.assets.length !== 1) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata.lock.json must pin exactly one asset.');
  }

  const [asset] = lock.assets;
  if (!asset || typeof asset !== 'object' || Array.isArray(asset)) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata asset must be an object.');
  }
  if (asset.name !== 'geoip.metadb') {
    throw createError('GEODATA_LOCK_INVALID', 'geodata asset name must be geoip.metadb.');
  }
  if (!Number.isInteger(asset.sizeBytes) || asset.sizeBytes <= 0) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata asset sizeBytes must be a positive integer.');
  }
  if (!isLowerHexDigest(asset.sha256)) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata asset sha256 must be a lowercase SHA-256 digest.');
  }
  if (!Array.isArray(asset.urls) || asset.urls.length === 0 || !asset.urls.every((entry) => typeof entry === 'string' && entry.length > 0)) {
    throw createError('GEODATA_LOCK_INVALID', 'geodata asset urls must be a non-empty string array.');
  }

  return {
    schemaVersion: GEODATA_SCHEMA_VERSION,
    asset: {
      name: asset.name,
      sizeBytes: asset.sizeBytes,
      sha256: asset.sha256,
      urls: asset.urls.map(ensureSafeUrl)
    }
  };
}

export async function readGeodataLock({
  harmonyRoot = HARMONY_ROOT,
  fsApi = fs
} = {}) {
  const raw = await fsApi.readFile(path.join(harmonyRoot, 'geodata.lock.json'), 'utf8');
  return validateLockShape(JSON.parse(raw));
}

async function removeIfExists(fsApi, targetPath) {
  await fsApi.rm(targetPath, { force: true }).catch(() => {});
}

async function verifyFile({
  filePath,
  fsApi,
  expectedSizeBytes,
  expectedSha256
}) {
  const digest = crypto.createHash('sha256');
  const fileHandle = await fsApi.open(filePath, FS_CONSTANTS.O_RDONLY);
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let sizeBytes = 0;

  try {
    while (true) {
      const { bytesRead } = await fileHandle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) {
        break;
      }
      sizeBytes += bytesRead;
      digest.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    await fileHandle.close();
  }

  if (sizeBytes !== expectedSizeBytes) {
    throw createError('GEODATA_SIZE_MISMATCH', `Expected ${expectedSizeBytes} bytes but found ${sizeBytes}.`);
  }

  const sha256 = digest.digest('hex');
  if (sha256 !== expectedSha256) {
    throw createError('GEODATA_DIGEST_MISMATCH', 'Downloaded geodata digest did not match the lock file.');
  }

  return {
    sha256,
    sizeBytes
  };
}

async function writeFully(fileHandle, buffer) {
  let offset = 0;

  while (offset < buffer.byteLength) {
    const { bytesWritten } = await fileHandle.write(buffer.subarray(offset));
    const remainingBytes = buffer.byteLength - offset;
    if (!Number.isInteger(bytesWritten) || bytesWritten <= 0 || bytesWritten > remainingBytes) {
      throw createError('GEODATA_WRITE_INCOMPLETE', `Expected to write up to ${remainingBytes} bytes but write() reported ${bytesWritten}.`);
    }
    offset += bytesWritten;
  }
}

async function writeVerifiedStreamToTemp({
  fsApi,
  targetDirectory,
  body,
  expectedSizeBytes,
  expectedSha256
}) {
  const tempPath = path.join(
    targetDirectory,
    `.tmp-geoip-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  const fileHandle = await fsApi.open(tempPath, FS_CONSTANTS.O_CREAT | FS_CONSTANTS.O_EXCL | FS_CONSTANTS.O_WRONLY, 0o600);
  const digest = crypto.createHash('sha256');
  let sizeBytes = 0;

  try {
    for await (const chunkValue of body) {
      const chunk = Buffer.isBuffer(chunkValue) ? chunkValue : Buffer.from(chunkValue);
      sizeBytes += chunk.byteLength;
      if (sizeBytes > expectedSizeBytes) {
        throw createError('GEODATA_SIZE_MISMATCH', `Expected ${expectedSizeBytes} bytes but received at least ${sizeBytes}.`);
      }
      digest.update(chunk);
      await writeFully(fileHandle, chunk);
    }
  } catch (error) {
    await fileHandle.close().catch(() => {});
    await removeIfExists(fsApi, tempPath);
    throw error;
  }

  await fileHandle.close();

  if (sizeBytes !== expectedSizeBytes) {
    await removeIfExists(fsApi, tempPath);
    throw createError('GEODATA_SIZE_MISMATCH', `Expected ${expectedSizeBytes} bytes but received ${sizeBytes}.`);
  }

  const sha256 = digest.digest('hex');
  if (sha256 !== expectedSha256) {
    await removeIfExists(fsApi, tempPath);
    throw createError('GEODATA_DIGEST_MISMATCH', 'Downloaded geodata digest did not match the lock file.');
  }

  return {
    tempPath,
    sha256,
    sizeBytes
  };
}

async function createBodyIterator(response) {
  if (response?.body && typeof response.body[Symbol.asyncIterator] === 'function') {
    return response.body;
  }
  if (typeof response?.arrayBuffer === 'function') {
    const buffer = Buffer.from(await response.arrayBuffer());
    return [buffer];
  }
  throw createError('GEODATA_FETCH_FAILED', 'Geodata response body was not streamable.');
}

async function downloadVerifiedCache({
  cachePath,
  expectedSizeBytes,
  expectedSha256,
  fetchImpl,
  urls,
  fsApi
}) {
  let lastError = null;

  for (const url of urls) {
    try {
      const response = await fetchImpl(url);
      if (!response?.ok) {
        throw createError('GEODATA_FETCH_FAILED', `Geodata download failed with status ${response?.status ?? 'unknown'} from ${url}.`);
      }
      const { tempPath, sha256, sizeBytes } = await writeVerifiedStreamToTemp({
        fsApi,
        targetDirectory: path.dirname(cachePath),
        body: await createBodyIterator(response),
        expectedSizeBytes,
        expectedSha256
      });
      await fsApi.rename(tempPath, cachePath);
      return {
        source: 'download',
        digest: {
          sha256,
          sizeBytes
        }
      };
    } catch (error) {
      if (['GEODATA_SIZE_MISMATCH', 'GEODATA_DIGEST_MISMATCH', 'PATH_OUTSIDE_REPO'].includes(error?.code)) {
        lastError = error;
      } else {
        lastError = createError('GEODATA_FETCH_FAILED', error?.message ?? `Failed to download geodata from ${url}.`);
      }
    }
  }

  throw lastError ?? createError('GEODATA_FETCH_FAILED', 'Failed to download digest-pinned geodata.');
}

async function ensureVerifiedRawfile({
  fsApi,
  sourcePath,
  rawfilePath,
  expectedSizeBytes,
  expectedSha256
}) {
  const sourceHandle = await fsApi.open(sourcePath, FS_CONSTANTS.O_RDONLY);
  const tempPath = path.join(
    path.dirname(rawfilePath),
    `.tmp-${path.basename(rawfilePath)}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
  );
  let targetHandle = null;
  const digest = crypto.createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let sizeBytes = 0;

  try {
    targetHandle = await fsApi.open(tempPath, FS_CONSTANTS.O_CREAT | FS_CONSTANTS.O_EXCL | FS_CONSTANTS.O_WRONLY, 0o600);

    while (true) {
      const { bytesRead } = await sourceHandle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) {
        break;
      }
      sizeBytes += bytesRead;
      if (sizeBytes > expectedSizeBytes) {
        throw createError('GEODATA_SIZE_MISMATCH', `Expected ${expectedSizeBytes} bytes but copied at least ${sizeBytes}.`);
      }
      const chunk = buffer.subarray(0, bytesRead);
      digest.update(chunk);
      await writeFully(targetHandle, chunk);
    }

    if (sizeBytes !== expectedSizeBytes) {
      throw createError('GEODATA_SIZE_MISMATCH', `Expected ${expectedSizeBytes} bytes but copied ${sizeBytes}.`);
    }

    const sha256 = digest.digest('hex');
    if (sha256 !== expectedSha256) {
      throw createError('GEODATA_DIGEST_MISMATCH', 'Rawfile geodata digest did not match the lock file.');
    }

    await targetHandle.close();
    targetHandle = null;
    await sourceHandle.close();
    await fsApi.rename(tempPath, rawfilePath);
    return {
      sha256,
      sizeBytes
    };
  } catch (error) {
    await targetHandle?.close().catch(() => {});
    await sourceHandle.close().catch(() => {});
    await removeIfExists(fsApi, tempPath);
    throw error;
  }
}

export async function prepareGeodata({
  harmonyRoot = HARMONY_ROOT,
  fsApi = fs,
  fetchImpl = globalThis.fetch
} = {}) {
  if (typeof fetchImpl !== 'function') {
    throw createError('GEODATA_FETCH_UNAVAILABLE', 'A fetch implementation is required to prepare geodata.');
  }

  const repoRoot = path.resolve(harmonyRoot, '..');
  const { asset } = await readGeodataLock({ harmonyRoot, fsApi });
  const cachePath = await resolveRepoScopedFilePath(fsApi, repoRoot, DEFAULT_CACHE_RELATIVE_PATH);
  const rawfilePath = await resolveRepoScopedFilePath(fsApi, repoRoot, DEFAULT_RAWFILE_RELATIVE_PATH);

  let source = 'cache';
  let digest = null;

  try {
    digest = await verifyFile({
      filePath: cachePath,
      fsApi,
      expectedSizeBytes: asset.sizeBytes,
      expectedSha256: asset.sha256
    });
  } catch (error) {
    if (!['ENOENT', 'GEODATA_SIZE_MISMATCH', 'GEODATA_DIGEST_MISMATCH'].includes(error?.code)) {
      throw error;
    }
    await removeIfExists(fsApi, cachePath);
    const downloaded = await downloadVerifiedCache({
      cachePath,
      expectedSizeBytes: asset.sizeBytes,
      expectedSha256: asset.sha256,
      fetchImpl,
      urls: asset.urls,
      fsApi
    });
    source = downloaded.source;
    digest = downloaded.digest;
  }

  await ensureVerifiedRawfile({
    fsApi,
    sourcePath: cachePath,
    rawfilePath,
    expectedSizeBytes: asset.sizeBytes,
    expectedSha256: asset.sha256
  });

  return {
    result: 'pass',
    source,
    asset: {
      path: DEFAULT_RAWFILE_RELATIVE_PATH,
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes
    },
    cache: {
      path: DEFAULT_CACHE_RELATIVE_PATH,
      sha256: digest.sha256,
      sizeBytes: digest.sizeBytes
    }
  };
}

export async function runCli({
  argv = process.argv.slice(2),
  stdout = process.stdout,
  stderr = process.stderr,
  prepareGeodataImpl = prepareGeodata
} = {}) {
  if (argv.length > 0) {
    stderr.write('prepare-geodata does not accept positional arguments.\n');
    return 2;
  }

  try {
    const prepared = await prepareGeodataImpl();
    stdout.write(`${JSON.stringify(prepared, null, 2)}\n`);
    return prepared.result === 'pass' ? 0 : 2;
  } catch (error) {
    stderr.write(`${error?.stack ?? error?.message ?? String(error)}\n`);
    return 2;
  }
}

function isDirectExecution() {
  if (!process.argv[1]) {
    return false;
  }

  return pathToFileURL(process.argv[1]).href === import.meta.url;
}

if (isDirectExecution()) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
