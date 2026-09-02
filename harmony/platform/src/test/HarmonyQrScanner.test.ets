import common from '@ohos.app.ability.common';
import { describe, expect, it } from '@ohos/hypium';
import type {
  ProfileTransferQrScanResult,
  ProfileTransferQrScannerError
} from '@cmfa/shared';
import {
  HarmonyQrScanner,
  type HarmonyQrScannerConfigurationError,
  type HarmonyQrScannerDriver,
  type HarmonyQrScannerRequest,
  type HarmonyScanResultShape
} from '../main/ets/source/HarmonyQrScanner';
import { assertNoLeak } from './fakes/PlatformFakes';

const QR_CODE_SCAN_TYPE: number = 4096;
const CANCELLED_SCAN_ERROR_CODE: number = 1000500002;

interface ScannedResultView {
  kind: 'SCANNED';
  value: string;
}

class FakeAbilityInfo {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class ScanRequestRecord {
  readonly context: common.UIAbilityContext;
  readonly options: HarmonyQrScannerRequest;

  constructor(context: common.UIAbilityContext, options: HarmonyQrScannerRequest) {
    this.context = context;
    this.options = options;
  }
}

class FakeContext {
  readonly filesDir: string;
  readonly abilityInfo?: Object;

  constructor(filesDir: string, abilityInfo?: Object) {
    this.filesDir = filesDir;
    this.abilityInfo = abilityInfo;
  }
}

class DeferredDriverResult {
  readonly promise: Promise<HarmonyScanResultShape>;
  private readonly resolveFn: (value: HarmonyScanResultShape) => void;
  private readonly rejectFn: (error: Error) => void;

  constructor() {
    let resolveRef: ((value: HarmonyScanResultShape) => void) | undefined = undefined;
    let rejectRef: ((error: Error) => void) | undefined = undefined;
    this.promise = new Promise<HarmonyScanResultShape>((resolve, reject) => {
      resolveRef = resolve;
      rejectRef = reject;
    });
    this.resolveFn = (value: HarmonyScanResultShape) => {
      if (resolveRef !== undefined) {
        resolveRef(value);
      }
    };
    this.rejectFn = (error: Error) => {
      if (rejectRef !== undefined) {
        rejectRef(error);
      }
    };
  }

  resolve(value: HarmonyScanResultShape): void {
    this.resolveFn(value);
  }

  reject(error: Error): void {
    this.rejectFn(error);
  }
}

class FakeHarmonyQrScannerDriver implements HarmonyQrScannerDriver {
  readonly requests: ScanRequestRecord[] = [];
  readonly outcomes: Array<() => Promise<HarmonyScanResultShape>> = [];

  enqueueResolved(result: HarmonyScanResultShape): void {
    this.outcomes.push(() => Promise.resolve(result));
  }

  enqueueRejected(error: Object): void {
    this.outcomes.push(() => Promise.reject(error));
  }

  enqueuePending(result: DeferredDriverResult): void {
    this.outcomes.push(() => result.promise);
  }

  async startScanForResult(
    context: common.UIAbilityContext,
    options: HarmonyQrScannerRequest
  ): Promise<HarmonyScanResultShape> {
    this.requests.push(new ScanRequestRecord(context, options));
    const nextOutcome: (() => Promise<HarmonyScanResultShape>) | undefined = this.outcomes.shift();
    if (nextOutcome === undefined) {
      throw new Error('Missing scripted QR scan outcome.');
    }
    return await nextOutcome();
  }
}

class CancelledError extends Error {
  code: number = CANCELLED_SCAN_ERROR_CODE;

  constructor(message: string) {
    super(message);
  }
}

function createUiContext(
  filesDir: string = '/data/storage/el2/base/files',
  includeAbilityInfo: boolean = true
): common.UIAbilityContext {
  return new FakeContext(
    filesDir,
    includeAbilityInfo ? new FakeAbilityInfo('MainAbility') : undefined
  ) as common.UIAbilityContext;
}

function buildScanner(driver: FakeHarmonyQrScannerDriver, context: common.UIAbilityContext): HarmonyQrScanner {
  return new HarmonyQrScanner({
    driver,
    context,
    qrCodeScanType: QR_CODE_SCAN_TYPE
  });
}

function expectConfigurationError(block: () => void): HarmonyQrScannerConfigurationError {
  let capturedError: HarmonyQrScannerConfigurationError | undefined = undefined;
  try {
    block();
  } catch (error) {
    capturedError = error as HarmonyQrScannerConfigurationError;
  }
  expect(capturedError !== undefined).assertTrue();
  const resolvedError: HarmonyQrScannerConfigurationError =
    capturedError as HarmonyQrScannerConfigurationError;
  expect(resolvedError.name).assertEqual('HarmonyQrScannerConfigurationError');
  expect(resolvedError.code).assertEqual('HARMONY_QR_SCANNER_CONFIGURATION_INVALID');
  expect(resolvedError.message).assertEqual('Harmony QR scanner requires a valid UI ability context.');
  return resolvedError;
}

async function expectRejectsFixedError(
  promise: Promise<ProfileTransferQrScanResult>,
  forbiddenFragments: string[]
): Promise<ProfileTransferQrScannerError> {
  let capturedError: ProfileTransferQrScannerError | undefined = undefined;
  try {
    await promise;
  } catch (error) {
    capturedError = error as ProfileTransferQrScannerError;
  }
  expect(capturedError !== undefined).assertTrue();
  const resolvedError: ProfileTransferQrScannerError = capturedError as ProfileTransferQrScannerError;
  expect(resolvedError.name).assertEqual('ProfileTransferQrScannerError');
  expect(resolvedError.code).assertEqual('PROFILE_TRANSFER_QR_SCAN_FAILED');
  expect(resolvedError.message).assertEqual('QR scan did not produce a usable profile transfer payload.');
  assertNoLeak(resolvedError.message, forbiddenFragments);
  return resolvedError;
}

export default function harmonyQrScannerTestsuite() {
  describe('HarmonyQrScannerTest', () => {
    it('passesExactContextAndOfficialRequestOptionsToTheDriver', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueueResolved({
        originalValue: 'https://example.com/profile.yaml',
        scanType: QR_CODE_SCAN_TYPE
      });
      const context = createUiContext('/data/storage/el2/base/files-a');
      const scanner = buildScanner(driver, context);

      await scanner.scan();

      expect(driver.requests.length).assertEqual(1);
      expect(driver.requests[0].context === context).assertTrue();
      expect(driver.requests[0].options.scanTypes.length).assertEqual(1);
      expect(driver.requests[0].options.scanTypes[0]).assertEqual(QR_CODE_SCAN_TYPE);
      expect(driver.requests[0].options.enableMultiMode).assertFalse();
      expect(driver.requests[0].options.enableAlbum).assertTrue();
    });

    it('returnsScannedResultForQrPayloads', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueueResolved({
        originalValue: 'https://example.com/profile.yaml?token=raw#frag',
        scanType: QR_CODE_SCAN_TYPE
      });
      const scanner = buildScanner(driver, createUiContext('/data/storage/el2/base/files-b'));

      const result = await scanner.scan();

      expect(result.kind).assertEqual('SCANNED');
      expect((result as ScannedResultView).value).assertEqual('https://example.com/profile.yaml?token=raw#frag');
    });

    it('mapsTheOfficialCancellationBusinessErrorToCancelled', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      const cancelled = new CancelledError('user cancelled /private/path');
      driver.enqueueRejected(cancelled);
      const scanner = buildScanner(driver, createUiContext('/data/storage/el2/base/files-c'));

      const result = await scanner.scan();

      expect(result.kind).assertEqual('CANCELLED');
    });

    it('returnsFixedErrorsForPlatformFailuresWithoutLeakingRawPayloads', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueueRejected(new Error('secret platform failure at content://private/qr/result'));
      const scanner = buildScanner(driver, createUiContext('/data/storage/el2/base/files-d'));

      await expectRejectsFixedError(scanner.scan(), [
        'secret platform failure',
        'content://private/qr/result'
      ]);
    });

    it('returnsFixedErrorsForNonQrAndBlankPayloads', 0, async () => {
      const nonQrDriver = new FakeHarmonyQrScannerDriver();
      nonQrDriver.enqueueResolved({
        originalValue: 'https://example.com/not-used',
        scanType: 7
      });
      const nonQrScanner = buildScanner(nonQrDriver, createUiContext('/data/storage/el2/base/files-e'));
      await expectRejectsFixedError(nonQrScanner.scan(), ['https://example.com/not-used']);

      const blankDriver = new FakeHarmonyQrScannerDriver();
      blankDriver.enqueueResolved({
        originalValue: '   ',
        scanType: QR_CODE_SCAN_TYPE
      });
      const blankScanner = buildScanner(blankDriver, createUiContext('/data/storage/el2/base/files-f'));
      await expectRejectsFixedError(blankScanner.scan(), ['   ']);
    });

    it('treatsDuplicateCallsAsIndependentDriverRequests', 0, async () => {
      const first = new DeferredDriverResult();
      const second = new DeferredDriverResult();
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueuePending(first);
      driver.enqueuePending(second);
      const scanner = buildScanner(driver, createUiContext('/data/storage/el2/base/files-g'));

      const firstPromise = scanner.scan();
      const secondPromise = scanner.scan();

      expect(driver.requests.length).assertEqual(2);
      first.resolve({
        originalValue: 'first-value',
        scanType: QR_CODE_SCAN_TYPE
      });
      second.resolve({
        originalValue: 'second-value',
        scanType: QR_CODE_SCAN_TYPE
      });

      const firstResult = await firstPromise;
      const secondResult = await secondPromise;

      expect(firstResult.kind).assertEqual('SCANNED');
      expect(secondResult.kind).assertEqual('SCANNED');
      expect((firstResult as ScannedResultView).value).assertEqual('first-value');
      expect((secondResult as ScannedResultView).value).assertEqual('second-value');
    });

    it('throwsFixedConfigurationErrorForDefaultDriverWhenContextIsMissingOrInvalid', 0, () => {
      expectConfigurationError((): void => {
        new HarmonyQrScanner({
          context: undefined
        });
      });

      expectConfigurationError((): void => {
        new HarmonyQrScanner({
          context: createUiContext('', true)
        });
      });

      expectConfigurationError((): void => {
        new HarmonyQrScanner({
          context: createUiContext('/data/storage/el2/base/files-invalid', false)
        });
      });
    });

    it('allowsCustomDriversToUseNarrowTypedContextsWithoutDefaultUiInvariantChecks', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueueResolved({
        originalValue: 'https://example.com/custom.yaml',
        scanType: QR_CODE_SCAN_TYPE
      });

      const scanner = new HarmonyQrScanner({
        driver,
        context: new FakeContext('', undefined) as common.UIAbilityContext,
        qrCodeScanType: QR_CODE_SCAN_TYPE
      });

      const result = await scanner.scan();

      expect(result.kind).assertEqual('SCANNED');
      expect((result as ScannedResultView).value).assertEqual('https://example.com/custom.yaml');
      expect(driver.requests.length).assertEqual(1);
    });
  });
}
