import { describe, expect, it } from '@ohos/hypium';
import type {
  ProfileTransferQrScanResult,
  ProfileTransferQrScannerError
} from '@cmfa/shared';
import { HarmonyQrScanner, type HarmonyQrScannerDriver, type HarmonyQrScannerRequest } from '../main/ets/source/HarmonyQrScanner';
import { assertNoLeak } from './fakes/PlatformFakes';

const QR_CODE_SCAN_TYPE: number = 4096;
const CANCELLED_SCAN_ERROR_CODE: number = 1000500002;

interface ScannedResultView {
  kind: 'SCANNED';
  value: string;
}

class FakeContext {
  readonly label: string;

  constructor(label: string) {
    this.label = label;
  }
}

class DeferredDriverResult {
  readonly promise: Promise<Object>;
  private readonly resolveFn: (value: Object) => void;
  private readonly rejectFn: (error: Error) => void;

  constructor() {
    let resolveRef: ((value: Object) => void) | undefined = undefined;
    let rejectRef: ((error: Error) => void) | undefined = undefined;
    this.promise = new Promise<Object>((resolve, reject) => {
      resolveRef = resolve;
      rejectRef = reject;
    });
    this.resolveFn = (value: Object) => {
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

  resolve(value: Object): void {
    this.resolveFn(value);
  }

  reject(error: Error): void {
    this.rejectFn(error);
  }
}

class FakeHarmonyQrScannerDriver implements HarmonyQrScannerDriver {
  readonly requests: { context: Object; options: HarmonyQrScannerRequest }[] = [];
  readonly outcomes: Array<() => Promise<Object>> = [];

  enqueueResolved(result: Object): void {
    this.outcomes.push(() => Promise.resolve(result));
  }

  enqueueRejected(error: Error): void {
    this.outcomes.push(() => Promise.reject(error));
  }

  enqueuePending(result: DeferredDriverResult): void {
    this.outcomes.push(() => result.promise);
  }

  async startScanForResult(context: Object, options: HarmonyQrScannerRequest): Promise<Object> {
    this.requests.push({
      context,
      options
    });
    const nextOutcome: (() => Promise<Object>) | undefined = this.outcomes.shift();
    if (nextOutcome === undefined) {
      throw new Error('Missing scripted QR scan outcome.');
    }
    return await nextOutcome();
  }
}

function buildScanner(driver: FakeHarmonyQrScannerDriver, context: FakeContext): HarmonyQrScanner {
  return new HarmonyQrScanner({
    driver,
    context,
    qrCodeScanType: QR_CODE_SCAN_TYPE
  });
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
      const context = new FakeContext('context-a');
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
      const scanner = buildScanner(driver, new FakeContext('context-b'));

      const result = await scanner.scan();

      expect(result.kind).assertEqual('SCANNED');
      expect((result as ScannedResultView).value).assertEqual('https://example.com/profile.yaml?token=raw#frag');
    });

    it('mapsTheOfficialCancellationBusinessErrorToCancelled', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      const cancelled = new Error('user cancelled /private/path');
      (cancelled as Error & { code: number }).code = CANCELLED_SCAN_ERROR_CODE;
      driver.enqueueRejected(cancelled);
      const scanner = buildScanner(driver, new FakeContext('context-c'));

      const result = await scanner.scan();

      expect(result.kind).assertEqual('CANCELLED');
    });

    it('returnsFixedErrorsForPlatformFailuresWithoutLeakingRawPayloads', 0, async () => {
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueueRejected(new Error('secret platform failure at content://private/qr/result'));
      const scanner = buildScanner(driver, new FakeContext('context-d'));

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
      const nonQrScanner = buildScanner(nonQrDriver, new FakeContext('context-e'));
      await expectRejectsFixedError(nonQrScanner.scan(), ['https://example.com/not-used']);

      const blankDriver = new FakeHarmonyQrScannerDriver();
      blankDriver.enqueueResolved({
        originalValue: '   ',
        scanType: QR_CODE_SCAN_TYPE
      });
      const blankScanner = buildScanner(blankDriver, new FakeContext('context-f'));
      await expectRejectsFixedError(blankScanner.scan(), ['   ']);
    });

    it('treatsDuplicateCallsAsIndependentDriverRequests', 0, async () => {
      const first = new DeferredDriverResult();
      const second = new DeferredDriverResult();
      const driver = new FakeHarmonyQrScannerDriver();
      driver.enqueuePending(first);
      driver.enqueuePending(second);
      const scanner = buildScanner(driver, new FakeContext('context-g'));

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
  });
}
