import { createProfileRevision, type ProfileContentStore, type ProfileRevision, type RevisionKind, type StagedSource } from '@cmfa/shared';
import type { FileDriver, FileStat } from './FileDriver';

const MAX_PROFILE_BYTES: number = 16 * 1024 * 1024;
const TMP_DIRECTORY: string = 'tmp';
const PROFILES_DIRECTORY: string = 'profiles';
const VALID_DIRECTORY: string = 'valid';
const FAILED_DIRECTORY: string = 'failed';
const YAML_SUFFIX: string = '.yaml';

class RelativePathResolution {
  readonly relativePath: string;
  readonly absolutePath: string;

  constructor(relativePath: string, absolutePath: string) {
    this.relativePath = relativePath;
    this.absolutePath = absolutePath;
  }
}

export class SandboxProfileContentStore implements ProfileContentStore {
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;

  constructor(fileDriver: FileDriver, filesDir: string) {
    this.fileDriver = fileDriver;
    this.filesDir = normalizeAbsoluteSandboxPath(filesDir, 'Sandbox root path');
  }

  async retain(profileId: string, staged: StagedSource, kind: RevisionKind): Promise<ProfileRevision> {
    validateStagedMetadata(staged);
    const stageResolution: RelativePathResolution = resolveManagedStage(this.filesDir, staged);
    const stageStat = await this.requireFileStat(stageResolution.absolutePath, 'Staged file status lookup failed.');
    if (!stageStat.isFile) {
      throw new Error('Staged file status lookup failed.');
    }
    if (stageStat.size > MAX_PROFILE_BYTES || staged.byteLength > MAX_PROFILE_BYTES) {
      throw new Error('Staged profile content exceeds 16 MiB.');
    }
    if (stageStat.size !== staged.byteLength) {
      throw new Error('Staged profile size metadata is invalid.');
    }

    const targetRelativePath: string = normalizeRelativePath(
      `${PROFILES_DIRECTORY}/${profileId}/${resolveRetentionDirectory(kind)}/${staged.stagingId}${YAML_SUFFIX}`,
      'Profile revision relative path'
    );
    const targetAbsolutePath: string = joinAbsoluteSandboxPath(this.filesDir, targetRelativePath);
    await this.ensureDirectory(parentDirectory(targetAbsolutePath));
    await this.fileDriver.renameNoOverwrite(stageResolution.absolutePath, targetAbsolutePath);
    return createProfileRevision(targetRelativePath, staged.sha256Digest, staged.byteLength, staged.validatedAt);
  }

  async discard(staged: StagedSource): Promise<void> {
    const stageResolution: RelativePathResolution = resolveManagedStage(this.filesDir, staged);
    await this.removeIfPresent(stageResolution.absolutePath);
  }

  async removeRevision(revision: ProfileRevision): Promise<void> {
    const revisionResolution: RelativePathResolution = resolveManagedRevision(this.filesDir, revision.relativePath);
    await this.removeIfPresent(revisionResolution.absolutePath);
    await this.removeManagedParents(revisionResolution.absolutePath);
  }

  async removeProfile(profileId: string): Promise<void> {
    const normalizedProfileId: string = normalizePathSegment(profileId, 'Profile id');
    const profileRoot: string = joinAbsoluteSandboxPath(this.filesDir, `${PROFILES_DIRECTORY}/${normalizedProfileId}`);
    await this.removeManagedTree(profileRoot);
  }

  async reconcile(referenced: ProfileRevision[]): Promise<void> {
    const referencedSet: Set<string> = new Set<string>();
    for (let index = 0; index < referenced.length; index += 1) {
      const resolved: RelativePathResolution = resolveManagedRevision(this.filesDir, referenced[index].relativePath);
      referencedSet.add(resolved.relativePath);
    }

    try {
      await this.cleanupManagedTempDirectory();
      await this.cleanupManagedRevisionDirectory(referencedSet);
    } catch (_) {
      throw new Error('Sandbox revision cleanup failed.');
    }
  }

  resolveCorePath(revision: ProfileRevision): string {
    return resolveManagedRevision(this.filesDir, revision.relativePath).absolutePath;
  }

  private async cleanupManagedTempDirectory(): Promise<void> {
    const tempRoot: string = joinAbsoluteSandboxPath(this.filesDir, TMP_DIRECTORY);
    const names: string[] = await this.listIfPresent(tempRoot);
    for (let index = 0; index < names.length; index += 1) {
      const childName: string = names[index];
      if (!isManagedYamlLeaf(childName)) {
        continue;
      }
      const childPath: string = joinAbsoluteSandboxPath(tempRoot, childName);
      const stat = await this.requireFileStat(childPath, 'Sandbox file status lookup failed.');
      if (stat.isFile) {
        await this.fileDriver.unlink(childPath);
      }
    }
  }

  private async cleanupManagedRevisionDirectory(referencedSet: Set<string>): Promise<void> {
    const profilesRoot: string = joinAbsoluteSandboxPath(this.filesDir, PROFILES_DIRECTORY);
    const profileNames: string[] = await this.listIfPresent(profilesRoot);
    for (let profileIndex = 0; profileIndex < profileNames.length; profileIndex += 1) {
      const profileName: string = profileNames[profileIndex];
      if (!isSafePathSegment(profileName)) {
        continue;
      }
      const profileRoot: string = joinAbsoluteSandboxPath(profilesRoot, profileName);
      const profileStat = await this.requireFileStat(profileRoot, 'Sandbox file status lookup failed.');
      if (!profileStat.isDirectory) {
        continue;
      }
      await this.cleanupKindDirectory(profileName, VALID_DIRECTORY, referencedSet);
      await this.cleanupKindDirectory(profileName, FAILED_DIRECTORY, referencedSet);
      await this.removeManagedParents(profileRoot);
    }
  }

  private async cleanupKindDirectory(profileId: string, kindDirectory: string, referencedSet: Set<string>): Promise<void> {
    const kindRoot: string = joinAbsoluteSandboxPath(this.filesDir, `${PROFILES_DIRECTORY}/${profileId}/${kindDirectory}`);
    const fileNames: string[] = await this.listIfPresent(kindRoot);
    for (let index = 0; index < fileNames.length; index += 1) {
      const fileName: string = fileNames[index];
      if (!isManagedYamlLeaf(fileName)) {
        continue;
      }
      const relativePath: string = `${PROFILES_DIRECTORY}/${profileId}/${kindDirectory}/${fileName}`;
      if (referencedSet.has(relativePath)) {
        continue;
      }
      const absolutePath: string = joinAbsoluteSandboxPath(this.filesDir, relativePath);
      const stat = await this.requireFileStat(absolutePath, 'Sandbox file status lookup failed.');
      if (stat.isFile) {
        await this.fileDriver.unlink(absolutePath);
      }
    }
  }

  private async removeManagedTree(rootPath: string): Promise<void> {
    const stat = await this.fileDriver.statIfPresent(rootPath);
    if (stat === undefined) {
      return;
    }
    if (stat.isFile) {
      await this.fileDriver.unlink(rootPath);
      return;
    }
    const names: string[] = await this.fileDriver.list(rootPath);
    for (let index = 0; index < names.length; index += 1) {
      const childName: string = names[index];
      const childPath: string = joinAbsoluteSandboxPath(rootPath, childName);
      await this.removeManagedTree(childPath);
    }
    await this.fileDriver.rmdir(rootPath);
  }

  private async removeManagedParents(targetPath: string): Promise<void> {
    let current: string = parentDirectory(targetPath);
    const stopAt: string = this.filesDir;
    while (current.length > stopAt.length && current.startsWith(stopAt)) {
      const stat = await this.fileDriver.statIfPresent(current);
      if (stat === undefined || !stat.isDirectory) {
        return;
      }
      const names: string[] = await this.fileDriver.list(current);
      if (names.length > 0) {
        return;
      }
      await this.fileDriver.rmdir(current);
      current = parentDirectory(current);
    }
  }

  private async removeIfPresent(path: string): Promise<void> {
    const stat = await this.fileDriver.statIfPresent(path);
    if (stat === undefined) {
      return;
    }
    if (!stat.isFile) {
      throw new Error('Sandbox file removal failed.');
    }
    await this.fileDriver.unlink(path);
  }

  private async listIfPresent(path: string): Promise<string[]> {
    const stat = await this.fileDriver.statIfPresent(path);
    if (stat === undefined) {
      return [];
    }
    if (!stat.isDirectory) {
      throw new Error('Sandbox directory listing failed.');
    }
    return await this.fileDriver.list(path);
  }

  private async ensureDirectory(path: string): Promise<void> {
    let stat: FileStat | undefined;
    try {
      stat = await this.fileDriver.statIfPresent(path);
    } catch (_) {
      throw new Error('Sandbox directory preparation failed.');
    }
    if (stat !== undefined) {
      if (stat.isDirectory) {
        return;
      }
      throw new Error('Sandbox directory preparation failed.');
    }
    try {
      await this.fileDriver.mkdir(path, true);
      return;
    } catch (_) {
      try {
        stat = await this.fileDriver.statIfPresent(path);
      } catch (_) {
        throw new Error('Sandbox directory preparation failed.');
      }
      if (stat !== undefined && stat.isDirectory) {
        return;
      }
      throw new Error('Sandbox directory preparation failed.');
    }
  }

  private async requireFileStat(path: string, fallback: string): Promise<FileStat> {
    try {
      return await this.fileDriver.stat(path);
    } catch (_) {
      throw new Error(fallback);
    }
  }
}

function validateStagedMetadata(staged: StagedSource): void {
  if (!Number.isInteger(staged.byteLength) || staged.byteLength < 0) {
    throw new Error('Staged profile size metadata is invalid.');
  }
  if (staged.sha256Digest !== staged.sha256Digest.toLowerCase() || !/^[0-9a-f]{64}$/u.test(staged.sha256Digest)) {
    throw new Error('Staged profile hash metadata is invalid.');
  }
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(staged.validatedAt)) {
    throw new Error('Staged profile timestamp metadata is invalid.');
  }
}

function resolveManagedStage(filesDir: string, staged: StagedSource): RelativePathResolution {
  const stageRelativePath: string = `${TMP_DIRECTORY}/${normalizePathSegment(staged.stagingId, 'Stage id')}${YAML_SUFFIX}`;
  const validationResolution: RelativePathResolution = resolveManagedAbsolutePath(filesDir, staged.validationPath, 'Stage validation path');
  if (validationResolution.relativePath !== stageRelativePath) {
    throw new Error('Stage validation path must stay within the managed tmp directory.');
  }
  return validationResolution;
}

function resolveManagedRevision(filesDir: string, relativePath: string): RelativePathResolution {
  const normalizedRelativePath: string = normalizeRelativePath(relativePath, 'Profile revision relative path');
  const segments: string[] = normalizedRelativePath.split('/');
  if (segments.length !== 4 || segments[0] !== PROFILES_DIRECTORY) {
    throw new Error('Profile revision relative path is invalid.');
  }
  normalizePathSegment(segments[1], 'Profile id');
  if (segments[2] !== VALID_DIRECTORY && segments[2] !== FAILED_DIRECTORY) {
    throw new Error('Profile revision relative path is invalid.');
  }
  if (!isManagedYamlLeaf(segments[3])) {
    throw new Error('Profile revision relative path is invalid.');
  }
  return new RelativePathResolution(normalizedRelativePath, joinAbsoluteSandboxPath(filesDir, normalizedRelativePath));
}

function resolveManagedAbsolutePath(filesDir: string, absolutePath: string, label: string): RelativePathResolution {
  const normalizedAbsolutePath: string = normalizeAbsoluteSandboxPath(absolutePath, label);
  const prefix: string = `${filesDir}/`;
  if (!normalizedAbsolutePath.startsWith(prefix)) {
    throw new Error(`${label} must stay within the sandbox root.`);
  }
  const relativePath: string = normalizeRelativePath(normalizedAbsolutePath.substring(prefix.length), label);
  return new RelativePathResolution(relativePath, normalizedAbsolutePath);
}

function normalizeAbsoluteSandboxPath(rawPath: string, label: string): string {
  if (rawPath.trim() !== rawPath || rawPath.length === 0 || !rawPath.startsWith('/')) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  if (rawPath.indexOf('\\') >= 0 || rawPath.indexOf('%') >= 0 || rawPath.indexOf(':') >= 0) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  const rawSegments: string[] = rawPath.split('/');
  const normalizedSegments: string[] = [];
  for (let index = 1; index < rawSegments.length; index += 1) {
    const segment: string = rawSegments[index];
    if (segment.length === 0 || segment === '.' || segment === '..') {
      throw new Error(`${label} must be a canonical absolute sandbox path.`);
    }
    if (!isSafePathSegment(segment)) {
      throw new Error(`${label} must be a canonical absolute sandbox path.`);
    }
    normalizedSegments.push(segment);
  }
  return `/${normalizedSegments.join('/')}`;
}

function normalizeRelativePath(rawPath: string, label: string): string {
  if (rawPath.trim() !== rawPath || rawPath.length === 0 || rawPath.startsWith('/')) {
    throw new Error(`${label} is invalid.`);
  }
  if (rawPath.indexOf('\\') >= 0 || rawPath.indexOf('%') >= 0 || rawPath.indexOf(':') >= 0) {
    throw new Error(`${label} is invalid.`);
  }
  const segments: string[] = rawPath.split('/');
  for (let index = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    if (segment.length === 0 || segment === '.' || segment === '..' || !isSafePathSegment(segment)) {
      throw new Error(`${label} is invalid.`);
    }
  }
  return segments.join('/');
}

function normalizePathSegment(rawSegment: string, label: string): string {
  if (!isSafePathSegment(rawSegment)) {
    throw new Error(`${label} must be a safe single path segment.`);
  }
  return rawSegment;
}

function isSafePathSegment(value: string): boolean {
  if (value.trim() !== value || value.length === 0 || value === '.' || value === '..') {
    return false;
  }
  if (value.indexOf('/') >= 0 || value.indexOf('\\') >= 0 || value.indexOf('%') >= 0 || value.indexOf(':') >= 0) {
    return false;
  }
  return true;
}

function isManagedYamlLeaf(fileName: string): boolean {
  return isSafePathSegment(fileName) && fileName.endsWith(YAML_SUFFIX);
}

function resolveRetentionDirectory(kind: RevisionKind): string {
  return kind === 'CURRENT' ? VALID_DIRECTORY : FAILED_DIRECTORY;
}

function parentDirectory(path: string): string {
  const separatorIndex: number = path.lastIndexOf('/');
  if (separatorIndex <= 0) {
    return '/';
  }
  return path.substring(0, separatorIndex);
}

function joinAbsoluteSandboxPath(base: string, relativeOrChild: string): string {
  if (relativeOrChild.startsWith('/')) {
    return normalizeAbsoluteSandboxPath(relativeOrChild, 'Sandbox path');
  }
  if (base === '/') {
    return normalizeAbsoluteSandboxPath(`/${relativeOrChild}`, 'Sandbox path');
  }
  return normalizeAbsoluteSandboxPath(`${base}/${relativeOrChild}`, 'Sandbox path');
}
