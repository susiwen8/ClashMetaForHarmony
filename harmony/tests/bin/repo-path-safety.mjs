import path from 'node:path';

function pathError(option) {
  return Object.assign(new Error(`${option} must stay inside the repository without symlink hops.`), {
    code: 'PATH_OUTSIDE_REPO'
  });
}

function isWithin(rootPath, candidatePath) {
  const relativePath = path.relative(rootPath, candidatePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

async function assertNoSymlinkSegments(fsApi, rootPath, candidatePath, option, allowMissing) {
  const relativePath = path.relative(rootPath, candidatePath);
  if (!isWithin(rootPath, candidatePath) || relativePath === '') {
    if (candidatePath === rootPath) {
      return;
    }
    throw pathError(option);
  }
  const segments = relativePath.split(path.sep).filter(Boolean);
  let currentPath = rootPath;
  for (let index = 0; index < segments.length; index += 1) {
    currentPath = path.join(currentPath, segments[index]);
    try {
      const stat = await fsApi.lstat(currentPath);
      if (stat.isSymbolicLink()) {
        throw pathError(option);
      }
      if (index + 1 < segments.length && !stat.isDirectory()) {
        throw pathError(option);
      }
    } catch (error) {
      if (allowMissing && error?.code === 'ENOENT') {
        return;
      }
      throw error;
    }
  }
}

export async function ensureRepoScopedExistingFile(fsApi, repoRoot, inputPath, option) {
  const lexicalRoot = path.resolve(repoRoot);
  const resolved = path.resolve(inputPath);
  if (!isWithin(lexicalRoot, resolved) || resolved === lexicalRoot) {
    throw pathError(option);
  }
  await assertNoSymlinkSegments(fsApi, lexicalRoot, resolved, option, false);
  const [realRoot, realInput] = await Promise.all([
    fsApi.realpath(lexicalRoot),
    fsApi.realpath(resolved)
  ]);
  if (!isWithin(realRoot, realInput) || realInput === realRoot) {
    throw pathError(option);
  }
  const stat = await fsApi.lstat(resolved);
  if (!stat.isFile()) {
    throw pathError(option);
  }
  return resolved;
}

export async function ensureRepoScopedOutputFile(fsApi, repoRoot, outputPath, option) {
  const lexicalRoot = path.resolve(repoRoot);
  const resolved = path.resolve(outputPath);
  if (!isWithin(lexicalRoot, resolved) || resolved === lexicalRoot) {
    throw pathError(option);
  }
  const parentPath = path.dirname(resolved);
  await assertNoSymlinkSegments(fsApi, lexicalRoot, parentPath, option, true);
  await fsApi.mkdir(parentPath, { recursive: true });
  await assertNoSymlinkSegments(fsApi, lexicalRoot, parentPath, option, false);
  const [realRoot, realParent] = await Promise.all([
    fsApi.realpath(lexicalRoot),
    fsApi.realpath(parentPath)
  ]);
  if (!isWithin(realRoot, realParent)) {
    throw pathError(option);
  }
  try {
    const outputStat = await fsApi.lstat(resolved);
    if (outputStat.isSymbolicLink() || !outputStat.isFile()) {
      throw pathError(option);
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }
  }
  return resolved;
}
