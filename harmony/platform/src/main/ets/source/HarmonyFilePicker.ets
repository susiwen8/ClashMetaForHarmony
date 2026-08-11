import { picker } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { createAppError, type AppError, type Clock, type IdGenerator, type LocalAcquireCommand, type LocalProfileAcquisition, type LocalProfileAcquisitionCancelled, type LocalProfileAcquisitionFailure, type LocalProfileAcquisitionSuccess, type StagedSource } from '@cmfa/shared';
import type { FileDriver, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_READ_ONLY,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';

const MAX_PROFILE_BYTES: number = 16 * 1024 * 1024;
const PICKER_SUFFIX_FILTER: string = 'Clash YAML|.yaml,.yml';
const FALLBACK_LOCAL_NAME: string = '本地配置';
const COPY_BUFFER_SIZE: number = 64 * 1024;

interface PickerPort {
  select(options: PickerSelectOptions): Promise<string[]>;
}

export interface PickerSelectOptions {
  maxSelectNumber: number;
  fileSuffixFilters: string[];
}

class PickerSelectOptionsRecord implements PickerSelectOptions {
  maxSelectNumber: number;
  fileSuffixFilters: string[];

  constructor(maxSelectNumber: number, fileSuffixFilters: string[]) {
    this.maxSelectNumber = maxSelectNumber;
    this.fileSuffixFilters = fileSuffixFilters.slice();
  }
}

class CancelledLocalProfileAcquisitionValue implements LocalProfileAcquisitionCancelled {
  readonly kind: 'CANCELLED' = 'CANCELLED';
}

class AcquiredLocalProfileAcquisitionValue implements LocalProfileAcquisitionSuccess {
  readonly kind: 'ACQUIRED' = 'ACQUIRED';
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly staged: StagedSource;

  constructor(profileName: string, sourceDisplay: string, staged: StagedSource) {
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.staged = staged;
  }
}

class FailedLocalProfileAcquisitionValue implements LocalProfileAcquisitionFailure {
  readonly kind: 'FAILED' = 'FAILED';
  readonly error: AppError;
  readonly shouldPersistInvalidProfile: boolean;
  readonly profileName?: string;
  readonly sourceDisplay?: string;

  constructor(technicalDetail: string, timestamp: string, profileName?: string, sourceDisplay?: string) {
    this.error = createAppError('IMPORT', technicalDetail, {
      retryable: false,
      timestamp
    });
    this.shouldPersistInvalidProfile = true;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
  }
}

class CopyFailure extends Error {
  readonly detail: string;

  constructor(detail: string) {
    super(detail);
    this.detail = detail;
  }
}

class SystemDocumentPickerPort implements PickerPort {
  private readonly pickerInstance: picker.DocumentViewPicker;

  constructor(context: common.UIAbilityContext) {
    this.pickerInstance = new picker.DocumentViewPicker(context);
  }

  async select(options: PickerSelectOptions): Promise<string[]> {
    const request = new picker.DocumentSelectOptions();
    request.maxSelectNumber = options.maxSelectNumber;
    request.fileSuffixFilters = options.fileSuffixFilters.slice();
    return await this.pickerInstance.select(request);
  }
}

export interface HarmonyFilePickerDependencies {
  picker?: PickerPort;
  context?: common.UIAbilityContext;
  fileDriver: FileDriver;
  filesDir: string;
  clock: Clock;
  idGenerator: IdGenerator;
}

export class HarmonyFilePicker {
  private readonly picker: PickerPort;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly clock: Clock;
  private readonly idGenerator: IdGenerator;

  constructor(dependencies: HarmonyFilePickerDependencies) {
    this.picker = resolvePickerPort(dependencies);
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxRoot(dependencies.filesDir);
    this.clock = dependencies.clock;
    this.idGenerator = dependencies.idGenerator;
  }

  async acquire(_command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    let sourceHandle: FileToken | undefined = undefined;
    let stageHandle: FileToken | undefined = undefined;
    let stagePath: string | undefined = undefined;
    let safeName: string = FALLBACK_LOCAL_NAME;
    let safeSourceDisplay: string = FALLBACK_LOCAL_NAME;
    let shouldValidateNameSuffix: boolean = false;
    let failure: CopyFailure | undefined = undefined;
    let copiedLength: number = 0;

    try {
      const selection: string[] = await this.picker.select(new PickerSelectOptionsRecord(1, [PICKER_SUFFIX_FILTER]));
      if (selection.length === 0) {
        return new CancelledLocalProfileAcquisitionValue();
      }
      if (selection.length !== 1) {
        return this.fail('Select exactly one YAML file.', safeName, safeSourceDisplay);
      }

      sourceHandle = await this.fileDriver.open(selection[0], FILE_OPEN_MODE_READ_ONLY);
      safeName = normalizeDisplayName(sourceHandle.name);
      safeSourceDisplay = safeName;
      shouldValidateNameSuffix = safeName !== FALLBACK_LOCAL_NAME;
      if (shouldValidateNameSuffix && !isYamlName(safeName)) {
        failure = new CopyFailure('Selected file must use .yaml or .yml.');
      } else {
        const stageId: string = this.idGenerator.nextId();
        stagePath = `${this.filesDir}/tmp/${stageId}.yaml`;
        await this.fileDriver.mkdir(`${this.filesDir}/tmp`, true);
        stageHandle = await this.fileDriver.open(stagePath, FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_TRUNC);
        copiedLength = await this.copyIntoStage(sourceHandle.fd, stageHandle.fd);
      }
    } catch (error) {
      failure = toCopyFailure(error, 'Selected file copy into the app sandbox failed.');
    }

    const closeFailure = await this.closeHandles(sourceHandle, stageHandle);
    if (failure === undefined && closeFailure !== undefined) {
      failure = closeFailure;
    }
    if (failure !== undefined) {
      await this.cleanupStage(stagePath);
      return this.fail(failure.detail, safeName, safeSourceDisplay);
    }

    if (stagePath === undefined) {
      return this.fail('Selected file could not be copied into the app sandbox.', safeName, safeSourceDisplay);
    }

    let digest: string;
    try {
      digest = await this.fileDriver.hash(stagePath, 'sha256');
    } catch (_) {
      await this.cleanupStage(stagePath);
      return this.fail('Selected file could not be hashed after staging.', safeName, safeSourceDisplay);
    }

    const staged: StagedSource = {
      stagingId: stagePath.substring(stagePath.lastIndexOf('/') + 1, stagePath.length - 5),
      validationPath: stagePath,
      sha256Digest: digest.toLowerCase(),
      byteLength: copiedLength,
      validatedAt: this.clock.now()
    };
    return new AcquiredLocalProfileAcquisitionValue(safeName, safeSourceDisplay, staged);
  }

  private async copyIntoStage(sourceFd: number, targetFd: number): Promise<number> {
    const buffer = new ArrayBuffer(COPY_BUFFER_SIZE);
    let total: number = 0;
    while (true) {
      const bytesRead: number = await this.fileDriver.read(sourceFd, buffer);
      if (bytesRead <= 0) {
        return total;
      }
      total += bytesRead;
      if (total > MAX_PROFILE_BYTES) {
        throw new CopyFailure('Selected YAML file exceeds 16 MiB.');
      }
      await this.fileDriver.write(targetFd, buffer, {
        offset: 0,
        length: bytesRead
      });
    }
  }

  private async closeHandles(
    sourceHandle?: FileToken,
    stageHandle?: FileToken
  ): Promise<CopyFailure | undefined> {
    let failure: CopyFailure | undefined = undefined;
    if (sourceHandle !== undefined) {
      try {
        await this.fileDriver.close(sourceHandle);
      } catch (_) {
        failure = failure ?? new CopyFailure('Selected file close failed.');
      }
    }
    if (stageHandle !== undefined) {
      try {
        await this.fileDriver.close(stageHandle);
      } catch (_) {
        failure = failure ?? new CopyFailure('Staged file close failed.');
      }
    }
    return failure;
  }

  private async cleanupStage(stagePath?: string): Promise<void> {
    if (stagePath === undefined) {
      return;
    }
    try {
      await this.fileDriver.unlink(stagePath);
    } catch (_) {
    }
  }

  private fail(detail: string, profileName: string, sourceDisplay: string): LocalProfileAcquisitionFailure {
    return new FailedLocalProfileAcquisitionValue(detail, this.clock.now(), profileName, sourceDisplay);
  }
}

function resolvePickerPort(dependencies: HarmonyFilePickerDependencies): PickerPort {
  if (dependencies.picker !== undefined) {
    return dependencies.picker;
  }
  if (dependencies.context !== undefined) {
    return new SystemDocumentPickerPort(dependencies.context);
  }
  throw new Error('HarmonyFilePicker requires either a picker override or UIAbilityContext.');
}

function normalizeAbsoluteSandboxRoot(rawPath: string): string {
  if (rawPath.trim() !== rawPath || rawPath.length === 0 || !rawPath.startsWith('/')) {
    throw new Error('Sandbox root must be a canonical absolute path.');
  }
  if (rawPath.indexOf('\\') >= 0 || rawPath.indexOf('%') >= 0 || rawPath.indexOf(':') >= 0) {
    throw new Error('Sandbox root must be a canonical absolute path.');
  }
  const segments: string[] = rawPath.split('/');
  const normalizedSegments: string[] = [];
  for (let index = 1; index < segments.length; index += 1) {
    const segment: string = segments[index];
    if (segment.length === 0 || segment === '.' || segment === '..' || segment.trim() !== segment) {
      throw new Error('Sandbox root must be a canonical absolute path.');
    }
    normalizedSegments.push(segment);
  }
  return `/${normalizedSegments.join('/')}`;
}

function normalizeDisplayName(rawName: string): string {
  const trimmedName: string = rawName.trim();
  if (trimmedName.length === 0) {
    return FALLBACK_LOCAL_NAME;
  }
  const normalizedName: string = trimmedName.replace(/\\/gu, '/');
  const separatorIndex: number = normalizedName.lastIndexOf('/');
  const basename: string = separatorIndex >= 0 ? normalizedName.substring(separatorIndex + 1) : normalizedName;
  if (basename.length === 0 || basename === '.' || basename === '..' || basename.indexOf(':') >= 0) {
    return FALLBACK_LOCAL_NAME;
  }
  return basename;
}

function isYamlName(fileName: string): boolean {
  const lowered: string = fileName.toLowerCase();
  return lowered.endsWith('.yaml') || lowered.endsWith('.yml');
}

function toCopyFailure(error: Object | undefined, fallback: string): CopyFailure {
  if (error instanceof CopyFailure) {
    return error;
  }
  return new CopyFailure(fallback);
}
