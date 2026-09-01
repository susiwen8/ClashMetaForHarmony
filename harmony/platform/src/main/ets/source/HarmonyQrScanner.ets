import common from '@ohos.app.ability.common';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import {
  createCancelledQrScanResult,
  createProfileTransferQrScannerError,
  createScannedQrScanResult,
  type ProfileTransferQrScanResult,
  type QrScannerPort
} from '@cmfa/shared';

const QR_SCAN_CANCELLED_ERROR_CODE: number = 1000500002;

interface HarmonyScanResultShape {
  originalValue?: string;
  scanType?: number;
}

interface BusinessErrorLike {
  code?: number;
}

class SystemHarmonyQrScannerDriver implements HarmonyQrScannerDriver {
  async startScanForResult(context: Object, options: HarmonyQrScannerRequest): Promise<Object> {
    return await scanBarcode.startScanForResult(context as common.UIAbilityContext, {
      scanTypes: options.scanTypes.slice(),
      enableMultiMode: options.enableMultiMode,
      enableAlbum: options.enableAlbum
    });
  }
}

export interface HarmonyQrScannerRequest {
  scanTypes: number[];
  enableMultiMode: boolean;
  enableAlbum: boolean;
}

export interface HarmonyQrScannerDriver {
  startScanForResult(context: Object, options: HarmonyQrScannerRequest): Promise<Object>;
}

export interface HarmonyQrScannerDependencies {
  context: Object;
  driver?: HarmonyQrScannerDriver;
  qrCodeScanType?: number;
}

export class HarmonyQrScanner implements QrScannerPort {
  private readonly context: Object;
  private readonly driver: HarmonyQrScannerDriver;
  private readonly qrCodeScanType: number;

  constructor(dependencies: HarmonyQrScannerDependencies) {
    this.context = dependencies.context;
    this.driver = dependencies.driver ?? new SystemHarmonyQrScannerDriver();
    this.qrCodeScanType = dependencies.qrCodeScanType ?? scanCore.ScanType.QR_CODE;
  }

  async scan(): Promise<ProfileTransferQrScanResult> {
    let result: HarmonyScanResultShape;
    try {
      result = await this.driver.startScanForResult(this.context, {
        scanTypes: [this.qrCodeScanType],
        enableMultiMode: false,
        enableAlbum: true
      }) as HarmonyScanResultShape;
    } catch (error) {
      if (this.isCancelled(error)) {
        return createCancelledQrScanResult();
      }
      throw createProfileTransferQrScannerError();
    }
    if (result.scanType !== this.qrCodeScanType) {
      throw createProfileTransferQrScannerError();
    }
    if (typeof result.originalValue !== 'string' || result.originalValue.trim().length === 0) {
      throw createProfileTransferQrScannerError();
    }
    return createScannedQrScanResult(result.originalValue);
  }

  private isCancelled(error: Object): boolean {
    return (error as BusinessErrorLike).code === QR_SCAN_CANCELLED_ERROR_CODE;
  }
}

export function createHarmonyQrScanner(context: common.UIAbilityContext): HarmonyQrScanner {
  return new HarmonyQrScanner({
    context
  });
}
