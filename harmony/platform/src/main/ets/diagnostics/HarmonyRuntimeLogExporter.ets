import { picker } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  encodeVpnRpcUtf8,
  type RuntimeLogExportPort,
  type RuntimeLogExportResult
} from '@cmfa/shared';
import type { FileDriver, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_READ_ONLY,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';
import { HarmonyFileDriver } from '../files/HarmonyFileDriver';

const EXPORT_FILE_NAME: string = 'clash-meta-runtime-log.txt';
const MAX_BACKUP_BYTES: number = 4 * 1024 * 1024;
const EXPORT_LOG_DOMAIN: number = 0x0000;
const EXPORT_LOG_TAG: string = 'CMFALog';

export interface RuntimeLogSaveOptions {
  newFileNames: string[];
  fileSuffixChoices: string[];
}

export interface RuntimeLogSavePickerPort {
  save(options: RuntimeLogSaveOptions): Promise<string[]>;
}

export interface HarmonyRuntimeLogExporterDependencies {
  picker?: RuntimeLogSavePickerPort;
  context?: common.UIAbilityContext;
  fileDriver: FileDriver;
}

class RuntimeLogSaveOptionsValue implements RuntimeLogSaveOptions {
  newFileNames: string[] = [EXPORT_FILE_NAME];
  fileSuffixChoices: string[] = ['Text|.txt'];
}

class TargetBackup {
  existed: boolean;
  bytes: Uint8Array;

  constructor(existed: boolean, bytes: Uint8Array) {
    this.existed = existed;
    this.bytes = bytes.slice();
  }
}

class SystemRuntimeLogSavePicker implements RuntimeLogSavePickerPort {
  private readonly pickerInstance: picker.DocumentViewPicker;

  constructor(context: common.UIAbilityContext) {
    this.pickerInstance = new picker.DocumentViewPicker(context);
  }

  async save(options: RuntimeLogSaveOptions): Promise<string[]> {
    const request = new picker.DocumentSaveOptions();
    request.newFileNames = options.newFileNames.slice();
    request.fileSuffixChoices = options.fileSuffixChoices.slice();
    return await this.pickerInstance.save(request);
  }
}

export class HarmonyRuntimeLogExporter implements RuntimeLogExportPort {
  private readonly picker: RuntimeLogSavePickerPort;
  private readonly fileDriver: FileDriver;

  constructor(dependencies: HarmonyRuntimeLogExporterDependencies) {
    if (dependencies.picker === undefined && dependencies.context === undefined) {
      throw new Error('Runtime log exporter requires a document picker.');
    }
    this.picker = dependencies.picker ?? new SystemRuntimeLogSavePicker(dependencies.context!);
    this.fileDriver = dependencies.fileDriver;
  }

  async export(text: string): Promise<RuntimeLogExportResult> {
    let selection: string[];
    try {
      selection = await this.picker.save(new RuntimeLogSaveOptionsValue());
    } catch (_) {
      return 'FAILED';
    }
    if (selection.length === 0) {
      return 'CANCELLED';
    }
    if (selection.length !== 1) {
      return 'FAILED';
    }
    let backup: TargetBackup;
    try {
      backup = await this.backupTarget(selection[0]);
    } catch (_) {
      return 'FAILED';
    }
    let handle: FileToken | undefined = undefined;
    try {
      handle = await this.fileDriver.open(
        selection[0],
        FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_TRUNC
      );
      await this.writeAll(handle.fd, encodeVpnRpcUtf8(text));
      await this.fileDriver.close(handle);
      handle = undefined;
      return 'EXPORTED';
    } catch (_) {
      if (handle !== undefined) {
        try {
          await this.fileDriver.close(handle);
        } catch (_) {
        }
      }
      await this.restoreFailedTarget(selection[0], backup);
      return 'FAILED';
    }
  }

  private async backupTarget(path: string): Promise<TargetBackup> {
    const stat = await this.fileDriver.statIfPresent(path);
    if (stat === undefined) {
      return new TargetBackup(false, new Uint8Array(0));
    }
    if (!stat.isFile || stat.size < 0 || stat.size > MAX_BACKUP_BYTES) {
      throw new Error('Runtime log export target cannot be backed up safely.');
    }
    const handle: FileToken = await this.fileDriver.open(path, FILE_OPEN_MODE_READ_ONLY);
    try {
      const bytes: Uint8Array = new Uint8Array(stat.size);
      let offset: number = 0;
      while (offset < bytes.length) {
        const buffer: ArrayBuffer = new ArrayBuffer(bytes.length - offset);
        const count: number = await this.fileDriver.read(handle.fd, buffer);
        if (count <= 0) {
          break;
        }
        bytes.set(new Uint8Array(buffer).slice(0, count), offset);
        offset += count;
      }
      if (offset !== bytes.length) {
        throw new Error('Runtime log export target backup was incomplete.');
      }
      return new TargetBackup(true, bytes);
    } finally {
      await this.fileDriver.close(handle);
    }
  }

  private async restoreFailedTarget(path: string, backup: TargetBackup): Promise<void> {
    try {
      if (!backup.existed) {
        if (await this.fileDriver.statIfPresent(path) !== undefined) {
          await this.fileDriver.unlink(path);
        }
        return;
      }
      const handle: FileToken = await this.fileDriver.open(
        path,
        FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_TRUNC
      );
      try {
        await this.writeAll(handle.fd, backup.bytes);
      } finally {
        await this.fileDriver.close(handle);
      }
    } catch (_) {
      hilog.error(EXPORT_LOG_DOMAIN, EXPORT_LOG_TAG, '%{public}s', 'runtime-log.export.restore.failed');
    }
  }

  private async writeAll(fd: number, bytes: Uint8Array): Promise<void> {
    let offset: number = 0;
    while (offset < bytes.length) {
      const remaining: Uint8Array = bytes.slice(offset);
      const written: number = await this.fileDriver.write(fd, remaining.buffer);
      if (written <= 0 || written > remaining.length) {
        throw new Error('Runtime log export write failed.');
      }
      offset += written;
    }
  }
}

export function createHarmonyRuntimeLogExporter(context: common.UIAbilityContext): HarmonyRuntimeLogExporter {
  return new HarmonyRuntimeLogExporter({
    context,
    fileDriver: new HarmonyFileDriver()
  });
}
