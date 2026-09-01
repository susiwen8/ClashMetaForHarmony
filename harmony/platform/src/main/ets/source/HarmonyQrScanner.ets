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
const QR_SCANNER_CONFIGURATION_ERROR_MESSAGE: string =
  'Harmony QR scanner requires a valid UI ability context.';

export interface HarmonyScanResultShape {
  originalValue: string;
  scanType: number;
}

export interface HarmonyQrScannerConfigurationError extends Error {
  name: 'HarmonyQrScannerConfigurationError';
  code: 'HARMONY_QR_SCANNER_CONFIGURATION_INVALID';
}

class HarmonyQrScannerConfigurationErrorValue extends Error implements HarmonyQrScannerConfigurationError {
  name: 'HarmonyQrScannerConfigurationError' = 'HarmonyQrScannerConfigurationError';
  code: 'HARMONY_QR_SCANNER_CONFIGURATION_INVALID' = 'HARMONY_QR_SCANNER_CONFIGURATION_INVALID';

  constructor() {
    super(QR_SCANNER_CONFIGURATION_ERROR_MESSAGE);
  }
}

interface BusinessErrorLike {
  code?: number;
}

class SystemHarmonyQrScannerDriver implements HarmonyQrScannerDriver {
  async startScanForResult(
    context: common.UIAbilityContext,
    options: HarmonyQrScannerRequest
  ): Promise<HarmonyScanResultShape> {
    return await scanBarcode.startScanForResult(context, {
      scanTypes: options.scanTypes.slice(),
      enableMultiMode: options.enableMultiMode,
      enableAlbum: options.enableAlbum
    }) as HarmonyScanResultShape;
  }
}

export interface HarmonyQrScannerRequest {
  scanTypes: number[];
  enableMultiMode: boolean;
  enableAlbum: boolean;
}

export interface HarmonyQrScannerDriver {
  startScanForResult(
    context: common.UIAbilityContext,
    options: HarmonyQrScannerRequest
  ): Promise<HarmonyScanResultShape>;
}

export interface HarmonyQrScannerDependencies {
  context: common.UIAbilityContext | null | undefined;
  driver?: HarmonyQrScannerDriver;
  qrCodeScanType?: number;
}

export class HarmonyQrScanner implements QrScannerPort {
  private readonly context: common.UIAbilityContext;
  private readonly driver: HarmonyQrScannerDriver;
  private readonly qrCodeScanType: number;

  constructor(dependencies: HarmonyQrScannerDependencies) {
    this.context = requireContext(dependencies.context);
    this.driver = dependencies.driver ?? new SystemHarmonyQrScannerDriver();
    if (dependencies.driver === undefined) {
      requireMinimalSystemContextInvariant(this.context);
    }
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

function requireContext(
  context: common.UIAbilityContext | null | undefined
): common.UIAbilityContext {
  if (context === undefined || context === null) {
    throw new HarmonyQrScannerConfigurationErrorValue();
  }
  return context;
}

function requireMinimalSystemContextInvariant(context: common.UIAbilityContext): void {
  if (typeof context.filesDir !== 'string' || context.filesDir.trim().length === 0) {
    throw new HarmonyQrScannerConfigurationErrorValue();
  }
  if (context.abilityInfo === undefined) {
    throw new HarmonyQrScannerConfigurationErrorValue();
  }
}
