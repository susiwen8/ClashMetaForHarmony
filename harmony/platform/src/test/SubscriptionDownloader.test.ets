import { describe, expect, it } from '@ohos/hypium';
import type {
  RemoteAcquireCommand,
  RemoteProfileAcquisition,
  RemoteProfileAcquisitionFailure,
  RemoteProfileAcquisitionSuccess,
  StagedSource
} from '@cmfa/shared';
import { SubscriptionDownloader, type SubscriptionDownloaderDependencies } from '../main/ets/source/SubscriptionDownloader';
import {
  createHttpTransportFailure,
  type HttpTransport,
  type HttpTransportFailureKind,
  type HttpTransportRequest,
  type HttpTransportResponse
} from '../main/ets/source/HttpTransport';
import {
  FakeFileDriver,
  SequenceClock,
  SequenceIdGenerator,
  assertNoLeak,
  buildBytes,
  utf8Bytes
} from './fakes/PlatformFakes';

const FILES_DIR = '/sandbox/app/files';
const EXACT_LIMIT_BYTES: number = 16 * 1024 * 1024;
const SAFE_SOURCE_DISPLAY: string = 'https://profiles.example.com';
const MIXED_PORT_SHA256: string = 'eee24b575ecf5f25d3095fa791fe4e4fd3b28dae95d26edcc66a5468030baa40';

class RemoteAcquireCommandRecord implements RemoteAcquireCommand {
  readonly sourceUrl: string;
  readonly allowPlainHttp: boolean;
  readonly profileName: string;
  readonly sourceDisplay: string;

  constructor(
    sourceUrl: string,
    allowPlainHttp: boolean = false,
    profileName: string = 'Remote Profile',
    sourceDisplay: string = SAFE_SOURCE_DISPLAY
  ) {
    this.sourceUrl = sourceUrl;
    this.allowPlainHttp = allowPlainHttp;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
  }
}

class HttpTransportResponseRecord implements HttpTransportResponse {
  readonly statusCode: number;
  readonly headers: Map<string, Array<string>>;
  readonly body: ArrayBuffer;

  constructor(statusCode: number, body: Uint8Array, headers?: Map<string, Array<string>>) {
    this.statusCode = statusCode;
    this.headers = headers ?? new Map<string, Array<string>>();
    this.body = copyBuffer(body);
  }
}

class ScriptedTransportFailure {
  readonly kind: HttpTransportFailureKind;
  readonly detail: string;

  constructor(kind: HttpTransportFailureKind, detail: string) {
    this.kind = kind;
    this.detail = detail;
  }
}

class FakeHttpTransport implements HttpTransport {
  readonly requestedUrls: string[] = [];
  readonly requests: HttpTransportRequest[] = [];
  readonly scriptedResults: Array<HttpTransportResponseRecord | ScriptedTransportFailure> = [];

  enqueueResponse(statusCode: number, body: Uint8Array, headers?: Map<string, Array<string>>): void {
    this.scriptedResults.push(new HttpTransportResponseRecord(statusCode, body, headers));
  }

  enqueueFailure(kind: HttpTransportFailureKind, detail: string): void {
    this.scriptedResults.push(new ScriptedTransportFailure(kind, detail));
  }

  async fetch(request: HttpTransportRequest): Promise<HttpTransportResponse> {
    this.requestedUrls.push(request.url);
    this.requests.push(request);
    const next: HttpTransportResponseRecord | ScriptedTransportFailure | undefined = this.scriptedResults.shift();
    if (next instanceof ScriptedTransportFailure) {
      throw createHttpTransportFailure(next.kind, next.detail);
    }
    if (next === undefined) {
      throw createHttpTransportFailure('NETWORK', 'No scripted response remained.');
    }
    return next;
  }
}

class DownloaderDependencyShape implements SubscriptionDownloaderDependencies {
  readonly sdkApiVersion: number;
  readonly networkKitTransport: HttpTransport;
  readonly requestAgentTransport: HttpTransport;
  readonly fileDriver: FakeFileDriver;
  readonly filesDir: string;
  readonly clock: SequenceClock;
  readonly idGenerator: SequenceIdGenerator;

  constructor(
    sdkApiVersion: number,
    networkKitTransport: HttpTransport,
    requestAgentTransport: HttpTransport,
    fileDriver: FakeFileDriver,
    clock: SequenceClock,
    idGenerator: SequenceIdGenerator
  ) {
    this.sdkApiVersion = sdkApiVersion;
    this.networkKitTransport = networkKitTransport;
    this.requestAgentTransport = requestAgentTransport;
    this.fileDriver = fileDriver;
    this.filesDir = FILES_DIR;
    this.clock = clock;
    this.idGenerator = idGenerator;
  }
}

function buildDownloader(
  sdkApiVersion: number,
  networkKitTransport: FakeHttpTransport,
  requestAgentTransport: FakeHttpTransport,
  fileDriver: FakeFileDriver,
  timestamps: string[] = ['2026-08-11T13:00:00.000Z'],
  ids: string[] = ['download-stage']
): SubscriptionDownloader {
  fileDriver.seedDirectory(FILES_DIR);
  fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
  return new SubscriptionDownloader(
    new DownloaderDependencyShape(
      sdkApiVersion,
      networkKitTransport,
      requestAgentTransport,
      fileDriver,
      new SequenceClock(timestamps),
      new SequenceIdGenerator(ids)
    )
  );
}

function requireSuccess(result: RemoteProfileAcquisition): RemoteProfileAcquisitionSuccess {
  expect(result.kind).assertEqual('ACQUIRED');
  return result as RemoteProfileAcquisitionSuccess;
}

function requireFailure(result: RemoteProfileAcquisition): RemoteProfileAcquisitionFailure {
  expect(result.kind).assertEqual('FAILED');
  return result as RemoteProfileAcquisitionFailure;
}

function assertFailureCode(result: RemoteProfileAcquisition, expectedCode: string): RemoteProfileAcquisitionFailure {
  const failure = requireFailure(result);
  expect(failure.error.stage).assertEqual('DOWNLOAD');
  expect(failure.error.code).assertEqual(expectedCode);
  expect(failure.shouldPersistInvalidProfile).assertFalse();
  return failure;
}

function assertBytesEqual(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function copyBuffer(bytes: Uint8Array): ArrayBuffer {
  const target = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    target[index] = bytes[index];
  }
  return target.buffer;
}

function buildHeaders(entries: Array<[string, Array<string>]>): Map<string, Array<string>> {
  const headers = new Map<string, Array<string>>();
  for (let index = 0; index < entries.length; index += 1) {
    headers.set(entries[index][0], entries[index][1].slice());
  }
  return headers;
}

export default function subscriptionDownloaderTestsuite() {
  describe('SubscriptionDownloaderTest', () => {
    it('downloadsHttpsResponsesIntoOneSandboxStageWithSha256Metadata', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const payload = utf8Bytes('mixed-port: 7890\n');
      networkTransport.enqueueResponse(200, payload);
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord(
        'https://user:pass@profiles.example.com/sub.yaml?token=secret#fragment',
        false
      ));
      const acquired = requireSuccess(result);
      const staged: StagedSource = acquired.staged;

      expect(acquired.profileName).assertEqual('Remote Profile');
      expect(acquired.sourceDisplay).assertEqual(SAFE_SOURCE_DISPLAY);
      expect(staged.stagingId).assertEqual('download-stage');
      expect(staged.validationPath).assertEqual(`${FILES_DIR}/tmp/download-stage.yaml`);
      expect(staged.byteLength).assertEqual(payload.length);
      expect(staged.validatedAt).assertEqual('2026-08-11T13:00:00.000Z');
      expect(staged.sha256Digest).assertEqual(MIXED_PORT_SHA256);
      expect(networkTransport.requestedUrls.length).assertEqual(1);
      expect(networkTransport.requestedUrls[0]).assertEqual('https://user:pass@profiles.example.com/sub.yaml?token=secret');
      expect(networkTransport.requests[0].timeoutMs).assertEqual(30000);
      expect(networkTransport.requests[0].maxResponseBytes).assertEqual(EXACT_LIMIT_BYTES);
      expect(requestTransport.requestedUrls.length).assertEqual(0);
      assertBytesEqual(fileDriver.readFileBytes(staged.validationPath), payload);
    });

    it('rejectsNonHttpSchemesBeforeAnyTransportCall', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('ftp://profiles.example.com/plain.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_INVALID_URL');

      expect(failure.error.retryable).assertFalse();
      expect(networkTransport.requestedUrls.length).assertEqual(0);
      expect(requestTransport.requestedUrls.length).assertEqual(0);
    });

    it('rejectsPlainHttpWithoutExplicitConfirmationAndSkipsTransportCalls', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('http://profiles.example.com/plain.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_PLAIN_HTTP_DISABLED');

      expect(failure.profileName).assertEqual('Remote Profile');
      expect(failure.sourceDisplay).assertEqual(SAFE_SOURCE_DISPLAY);
      expect(networkTransport.requestedUrls.length).assertEqual(0);
      expect(requestTransport.requestedUrls.length).assertEqual(0);
    });

    it('allowsConfirmedPlainHttpDownloads', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const payload = utf8Bytes('port: 7890\n');
      requestTransport.enqueueResponse(200, payload);
      const downloader = buildDownloader(22, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord(
        'http://profiles.example.com/plain.yaml?from=test',
        true,
        'HTTP Profile',
        'http://profiles.example.com'
      ));
      const acquired = requireSuccess(result);

      expect(acquired.profileName).assertEqual('HTTP Profile');
      expect(requestTransport.requestedUrls.length).assertEqual(1);
      expect(requestTransport.requestedUrls[0]).assertEqual('http://profiles.example.com/plain.yaml?from=test');
      expect(networkTransport.requestedUrls.length).assertEqual(0);
      expect(acquired.staged.byteLength).assertEqual(payload.length);
    });

    it('failsOnEmptyTwoHundredBodies', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(200, new Uint8Array(0));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/empty.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_EMPTY_BODY');

      expect(failure.error.retryable).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/download-stage.yaml`)).assertFalse();
    });

    it('rejectsNoContentEvenWhenTheTransportReturnsBytes', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(204, utf8Bytes('ignored body'));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/no-content.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_EMPTY_BODY');

      expect(failure.error.retryable).assertFalse();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/download-stage.yaml`)).assertFalse();
    });

    it('failsOnNonSuccessStatusWithoutLeakingHeadersOrRawUrls', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(
        503,
        utf8Bytes('maintenance'),
        buildHeaders([['set-cookie', ['session=secret']]])
      );
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord(
        'https://user:pass@profiles.example.com/sub.yaml?token=secret',
        false
      ));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_HTTP_STATUS');

      expect(failure.error.retryable).assertTrue();
      assertNoLeak(failure.error.technicalDetail, [
        'user:pass',
        'token=secret',
        'session=secret',
        'set-cookie'
      ]);
    });

    it('mapsTimeoutAndTlsTransportFailuresToDistinctCodes', 0, async () => {
      const timeoutTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      timeoutTransport.enqueueFailure('TIMEOUT', 'socket timeout for https://profiles.example.com/sub.yaml');
      const timeoutDownloader = buildDownloader(23, timeoutTransport, requestTransport, fileDriver);

      const timeoutResult = await timeoutDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/sub.yaml'));
      const timeoutFailure = assertFailureCode(timeoutResult, 'CMFA_DOWNLOAD_TIMEOUT');
      expect(timeoutFailure.error.retryable).assertTrue();

      const tlsTransport = new FakeHttpTransport();
      tlsTransport.enqueueFailure('TLS', 'SSL certificate verify failed for https://profiles.example.com/sub.yaml');
      const tlsDownloader = buildDownloader(23, tlsTransport, requestTransport, new FakeFileDriver());

      const tlsResult = await tlsDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/sub.yaml'));
      const tlsFailure = assertFailureCode(tlsResult, 'CMFA_DOWNLOAD_TLS');
      expect(tlsFailure.error.retryable).assertFalse();
      assertNoLeak(tlsFailure.error.technicalDetail, ['SSL certificate verify failed']);
    });

    it('acceptsExactlySixteenMiBButRejectsOversizeBodies', 0, async () => {
      const exactTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const exactDriver = new FakeFileDriver();
      exactTransport.enqueueResponse(200, buildBytes(EXACT_LIMIT_BYTES));
      const exactDownloader = buildDownloader(23, exactTransport, requestTransport, exactDriver, ['2026-08-11T13:10:00.000Z'], ['exact-stage']);

      const exactResult = await exactDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/exact.yaml'));
      const acquired = requireSuccess(exactResult);
      expect(acquired.staged.byteLength).assertEqual(EXACT_LIMIT_BYTES);
      expect(exactDriver.fileExists(`${FILES_DIR}/tmp/exact-stage.yaml`)).assertTrue();

      const oversizeTransport = new FakeHttpTransport();
      oversizeTransport.enqueueResponse(200, buildBytes(EXACT_LIMIT_BYTES + 1));
      const oversizeDownloader = buildDownloader(23, oversizeTransport, requestTransport, new FakeFileDriver());

      const oversizeResult = await oversizeDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/too-large.yaml'));
      const oversizeFailure = assertFailureCode(oversizeResult, 'CMFA_DOWNLOAD_OVERSIZE');
      expect(oversizeFailure.error.retryable).assertFalse();
    });

    it('supportsShortWritesWhileStillProducingTheFullStage', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const payload = utf8Bytes('abcdefghij');
      networkTransport.enqueueResponse(200, payload);
      fileDriver.scriptWriteCounts(`${FILES_DIR}/tmp/short-stage.yaml`, [3, 4, 3]);
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:40:00.000Z'], ['short-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/short-write.yaml'));
      const acquired = requireSuccess(result);

      expect(acquired.staged.byteLength).assertEqual(payload.length);
      assertBytesEqual(fileDriver.readFileBytes(acquired.staged.validationPath), payload);
    });

    it('cleansUpTheStageWhenWriteFails', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const payload = utf8Bytes('broken');
      networkTransport.enqueueResponse(200, payload);
      fileDriver.injectFailure('write', `${FILES_DIR}/tmp/write-fail-stage.yaml`, new Error('write failed at /private/tmp/download'));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:41:00.000Z'], ['write-fail-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://user:pass@profiles.example.com/write-fail.yaml?token=secret'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_STAGE_FAILED');

      expect(failure.error.retryable).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/write-fail-stage.yaml`)).assertFalse();
      assertNoLeak(failure.error.technicalDetail, ['/private/tmp/download', 'user:pass', 'token=secret']);
    });

    it('cleansUpTheStageWhenCloseFails', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(200, utf8Bytes('close me'));
      fileDriver.injectFailure('close', `${FILES_DIR}/tmp/close-fail-stage.yaml`, new Error('close failed at /sandbox/app/files/tmp/close-fail-stage.yaml'));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:42:00.000Z'], ['close-fail-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/close-fail.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_STAGE_FAILED');

      expect(failure.error.retryable).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/close-fail-stage.yaml`)).assertFalse();
      assertNoLeak(failure.error.technicalDetail, ['/sandbox/app/files/tmp/close-fail-stage.yaml']);
    });

    it('cleansUpTheStageWhenHashFails', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(200, utf8Bytes('hash me'));
      fileDriver.injectFailure('hash', `${FILES_DIR}/tmp/hash-fail-stage.yaml`, new Error('hash failed at /tmp/private'));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:43:00.000Z'], ['hash-fail-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/hash-fail.yaml'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_STAGE_FAILED');

      expect(failure.error.retryable).assertTrue();
      expect(fileDriver.fileExists(`${FILES_DIR}/tmp/hash-fail-stage.yaml`)).assertFalse();
      assertNoLeak(failure.error.technicalDetail, ['/tmp/private']);
    });

    it('followsFiveRedirectsButRejectsTheSixthAndResolvesRelativeLocations', 0, async () => {
      const allowedTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const allowedDriver = new FakeFileDriver();
      const redirectHeaders = [
        buildHeaders([['location', ['/b.yaml']]]),
        buildHeaders([['location', ['c.yaml']]]),
        buildHeaders([['location', ['../d.yaml']]]),
        buildHeaders([['location', ['https://profiles.example.com/e.yaml']]]),
        buildHeaders([['location', ['https://profiles.example.com/final.yaml']]])
      ];
      for (let index = 0; index < redirectHeaders.length; index += 1) {
        allowedTransport.enqueueResponse(302, utf8Bytes('redirect body should be ignored'), redirectHeaders[index]);
      }
      allowedTransport.enqueueResponse(200, utf8Bytes('mode: rule\n'));
      const allowedDownloader = buildDownloader(23, allowedTransport, requestTransport, allowedDriver, ['2026-08-11T13:20:00.000Z'], ['redirect-stage']);

      const allowedResult = await allowedDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/a/path/start.yaml'));
      const allowedSuccess = requireSuccess(allowedResult);

      expect(allowedTransport.requestedUrls.length).assertEqual(6);
      expect(allowedTransport.requestedUrls[0]).assertEqual('https://profiles.example.com/a/path/start.yaml');
      expect(allowedTransport.requestedUrls[1]).assertEqual('https://profiles.example.com/b.yaml');
      expect(allowedTransport.requestedUrls[2]).assertEqual('https://profiles.example.com/c.yaml');
      expect(allowedTransport.requestedUrls[3]).assertEqual('https://profiles.example.com/d.yaml');
      expect(allowedTransport.requestedUrls[4]).assertEqual('https://profiles.example.com/e.yaml');
      expect(allowedTransport.requestedUrls[5]).assertEqual('https://profiles.example.com/final.yaml');
      expect(allowedSuccess.staged.validationPath).assertEqual(`${FILES_DIR}/tmp/redirect-stage.yaml`);

      const rejectedTransport = new FakeHttpTransport();
      for (let index = 0; index < 6; index += 1) {
        rejectedTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', [`https://profiles.example.com/r${index + 1}.yaml`]]]));
      }
      const rejectedDownloader = buildDownloader(23, rejectedTransport, requestTransport, new FakeFileDriver());

      const rejectedResult = await rejectedDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/r0.yaml'));
      const rejectedFailure = assertFailureCode(rejectedResult, 'CMFA_DOWNLOAD_REDIRECT');
      expect(rejectedFailure.error.retryable).assertFalse();
      expect(rejectedTransport.requestedUrls.length).assertEqual(6);
    });

    it('failsOnMissingLocationRedirectLoopsAndNonHttpRedirectTargets', 0, async () => {
      const missingLocationTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      missingLocationTransport.enqueueResponse(301, new Uint8Array(0));
      const missingLocationDownloader = buildDownloader(23, missingLocationTransport, requestTransport, new FakeFileDriver());

      const missingLocationResult = await missingLocationDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/start.yaml'));
      assertFailureCode(missingLocationResult, 'CMFA_DOWNLOAD_REDIRECT');

      const loopTransport = new FakeHttpTransport();
      loopTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', ['/b.yaml']]]));
      loopTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', ['/a.yaml']]]));
      loopTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', ['/b.yaml']]]));
      const loopDownloader = buildDownloader(23, loopTransport, requestTransport, new FakeFileDriver());

      const loopResult = await loopDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/a.yaml'));
      const loopFailure = assertFailureCode(loopResult, 'CMFA_DOWNLOAD_REDIRECT');
      expect(loopFailure.error.retryable).assertFalse();

      const badSchemeTransport = new FakeHttpTransport();
      badSchemeTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', ['ftp://profiles.example.com/file.yaml']]]));
      const badSchemeDownloader = buildDownloader(23, badSchemeTransport, requestTransport, new FakeFileDriver());

      const badSchemeResult = await badSchemeDownloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/a.yaml'));
      assertFailureCode(badSchemeResult, 'CMFA_DOWNLOAD_REDIRECT');
    });

    it('selectsNetworkKitAtApi23AndRequestAgentBelowApi23', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const payload = utf8Bytes('port: 7890\n');
      networkTransport.enqueueResponse(200, payload);
      requestTransport.enqueueResponse(200, payload);

      const api23Downloader = buildDownloader(23, networkTransport, requestTransport, new FakeFileDriver(), ['2026-08-11T13:30:00.000Z'], ['api23-stage']);
      const api22Downloader = buildDownloader(22, networkTransport, requestTransport, new FakeFileDriver(), ['2026-08-11T13:31:00.000Z'], ['api22-stage']);

      await api23Downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/api23.yaml'));
      await api22Downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/api22.yaml'));

      expect(networkTransport.requestedUrls.length).assertEqual(1);
      expect(networkTransport.requestedUrls[0]).assertEqual('https://profiles.example.com/api23.yaml');
      expect(requestTransport.requestedUrls.length).assertEqual(1);
      expect(requestTransport.requestedUrls[0]).assertEqual('https://profiles.example.com/api22.yaml');
    });
  });
}
