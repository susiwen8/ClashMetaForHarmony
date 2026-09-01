import common from '@ohos.app.ability.common';
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
  RequestAgentRedirectTransport,
  type RequestAgentCreateConfig,
  type RequestAgentModulePort,
  type RequestAgentTaskPort,
  type RequestAgentTimerPort,
  type RequestAgentRedirectTransportDependencies
} from '../main/ets/source/RequestAgentRedirectTransport';
import {
  NetworkKitHttpTransport,
  type NetworkKitHeaderRecord,
  type NetworkKitClientPort,
  type NetworkKitRequestOptions,
  type NetworkKitResponsePort
} from '../main/ets/source/NetworkKitHttpTransport';
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

class DeferredVoid {
  readonly promise: Promise<void>;
  private readonly resolveFn: () => void;

  constructor() {
    let resolveRef: (() => void) | undefined = undefined;
    this.promise = new Promise<void>((resolve) => {
      resolveRef = resolve;
    });
    this.resolveFn = () => {
      if (resolveRef !== undefined) {
        resolveRef();
      }
    };
  }

  resolve(): void {
    this.resolveFn();
  }
}

type RequestAgentProgressListener = (progress: RequestAgentProgressRecord) => void;
type RequestAgentResponseListener = (response: RequestAgentResponseRecord) => void;
type RequestAgentFaultListener = (fault: number) => void;
type RequestAgentFailedListener = (progress: RequestAgentProgressRecord) => void;
type RequestAgentCompletedListener = (progress: RequestAgentProgressRecord) => void;

class RequestAgentProgressRecord {
  readonly processed: number;

  constructor(processed: number) {
    this.processed = processed;
  }
}

class RequestAgentResponseRecord {
  readonly statusCode: number;
  readonly headers: Map<string, Array<string>>;

  constructor(statusCode: number, headers?: Map<string, Array<string>>) {
    this.statusCode = statusCode;
    this.headers = headers ?? new Map<string, Array<string>>();
  }
}

class FakeRequestAgentTask implements RequestAgentTaskPort {
  readonly tid: string;
  readonly log: string[];
  readonly stopDeferred: DeferredVoid;
  private progressListener?: RequestAgentProgressListener;
  private responseListener?: RequestAgentResponseListener;
  private faultListener?: RequestAgentFaultListener;
  private failedListener?: RequestAgentFailedListener;
  private completedListener?: RequestAgentCompletedListener;

  constructor(tid: string, log: string[], stopDeferred?: DeferredVoid) {
    this.tid = tid;
    this.log = log;
    this.stopDeferred = stopDeferred ?? new DeferredVoid();
  }

  on(event: 'progress', callback: RequestAgentProgressListener): void;
  on(event: 'response', callback: RequestAgentResponseListener): void;
  on(event: 'faultOccur', callback: RequestAgentFaultListener): void;
  on(event: 'failed', callback: RequestAgentFailedListener): void;
  on(event: 'completed', callback: RequestAgentCompletedListener): void;
  on(event: string, callback: Object): void {
    if (event === 'progress') {
      this.progressListener = callback as RequestAgentProgressListener;
      return;
    }
    if (event === 'response') {
      this.responseListener = callback as RequestAgentResponseListener;
      return;
    }
    if (event === 'faultOccur') {
      this.faultListener = callback as RequestAgentFaultListener;
      return;
    }
    if (event === 'failed') {
      this.failedListener = callback as RequestAgentFailedListener;
      return;
    }
    this.completedListener = callback as RequestAgentCompletedListener;
  }

  async start(): Promise<void> {
    this.log.push('start');
  }

  async stop(): Promise<void> {
    this.log.push('stop:begin');
    await this.stopDeferred.promise;
    this.log.push('stop:end');
  }

  emitResponse(statusCode: number, headers?: Map<string, Array<string>>): void {
    this.responseListener?.(new RequestAgentResponseRecord(statusCode, headers));
  }

  emitProgress(processed: number): void {
    this.progressListener?.(new RequestAgentProgressRecord(processed));
  }

  emitCompleted(processed: number = 0): void {
    this.completedListener?.(new RequestAgentProgressRecord(processed));
  }

  emitFault(fault: number): void {
    this.faultListener?.(fault);
  }

  emitFailed(processed: number = 0): void {
    this.failedListener?.(new RequestAgentProgressRecord(processed));
  }
}

class FakeRequestAgentModule implements RequestAgentModulePort {
  readonly log: string[];
  readonly createConfigs: RequestAgentCreateConfig[] = [];
  task?: FakeRequestAgentTask;

  constructor(log?: string[]) {
    this.log = log ?? [];
  }

  async create(
    _context: common.BaseContext | undefined,
    config: RequestAgentCreateConfig
  ): Promise<RequestAgentTaskPort> {
    this.createConfigs.push(config);
    this.log.push('create');
    if (this.task === undefined) {
      throw new Error('Task was not seeded.');
    }
    return this.task;
  }

  async remove(tid: string): Promise<void> {
    this.log.push(`remove:${tid}`);
  }
}

class OrderedFakeFileDriver extends FakeFileDriver {
  private readonly sharedLog: string[];

  constructor(sharedLog: string[]) {
    super();
    this.sharedLog = sharedLog;
  }

  async unlink(path: string): Promise<void> {
    this.sharedLog.push(`unlink:${path}`);
    await super.unlink(path);
  }
}

class FakeRequestAgentTimer implements RequestAgentTimerPort {
  private nextId: number = 1;
  private readonly callbacks: Map<number, () => void> = new Map<number, () => void>();

  setTimeout(callback: () => void, _delayMs: number): number {
    const id: number = this.nextId;
    this.nextId += 1;
    this.callbacks.set(id, callback);
    return id;
  }

  clearTimeout(id: number): void {
    this.callbacks.delete(id);
  }

  fire(id: number): void {
    const callback: (() => void) | undefined = this.callbacks.get(id);
    if (callback !== undefined) {
      this.callbacks.delete(id);
      callback();
    }
  }

  firstTimerId(): number {
    return this.callbacks.keys().next().value as number;
  }

  hasPendingTimer(): boolean {
    return this.callbacks.size > 0;
  }
}

class EmptyObjectRecord {
}

interface UserAgentHeaderObject {
  'User-Agent'?: string;
  Authorization?: string;
  authorization?: string;
  Cookie?: string;
  cookie?: string;
}

interface NetworkKitRequestOptionsWithHeader {
  header?: NetworkKitHeaderRecord;
}

interface RequestAgentCreateConfigWithHeaders {
  headers?: UserAgentHeaderObject;
}

class FakeNetworkKitClientResponseRecord implements NetworkKitResponsePort {
  readonly responseCode: number;
  readonly header: Object;
  readonly result: string | Object | ArrayBuffer;

  constructor(
    responseCode: number,
    header: Object,
    result: string | Object | ArrayBuffer
  ) {
    this.responseCode = responseCode;
    this.header = header;
    this.result = result;
  }
}

class FakeNetworkKitClient implements NetworkKitClientPort {
  readonly requestedUrls: string[] = [];
  readonly requestOptions: NetworkKitRequestOptions[] = [];
  destroyCount: number = 0;
  response: NetworkKitResponsePort = new FakeNetworkKitClientResponseRecord(
    200,
    new EmptyObjectRecord(),
    utf8Bytes('network-kit response').buffer
  );

  async request(url: string, options: NetworkKitRequestOptions): Promise<NetworkKitResponsePort> {
    this.requestedUrls.push(url);
    this.requestOptions.push(options);
    return this.response;
  }

  destroy(): void {
    this.destroyCount += 1;
  }
}

class RequestAgentDependencyShape implements RequestAgentRedirectTransportDependencies {
  readonly context?: undefined;
  readonly fileDriver: FakeFileDriver;
  readonly filesDir: string;
  readonly idGenerator: SequenceIdGenerator;
  readonly requestAgent: RequestAgentModulePort;
  readonly timer: RequestAgentTimerPort;

  constructor(
    fileDriver: FakeFileDriver,
    idGenerator: SequenceIdGenerator,
    requestAgent: RequestAgentModulePort,
    timer: RequestAgentTimerPort
  ) {
    this.fileDriver = fileDriver;
    this.filesDir = FILES_DIR;
    this.idGenerator = idGenerator;
    this.requestAgent = requestAgent;
    this.timer = timer;
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

class CompatibilityNegotiatingTransport implements HttpTransport {
  readonly requests: HttpTransportRequest[] = [];
  readonly missingUserAgentBody: Uint8Array;
  readonly productYamlBody: Uint8Array;

  constructor(missingUserAgentBody: Uint8Array, productYamlBody: Uint8Array) {
    this.missingUserAgentBody = missingUserAgentBody;
    this.productYamlBody = productYamlBody;
  }

  async fetch(request: HttpTransportRequest): Promise<HttpTransportResponse> {
    this.requests.push(request);
    const body: Uint8Array = request.userAgent === 'ClashMetaForAndroid/HarmonyOS'
      ? this.productYamlBody
      : this.missingUserAgentBody;
    return new HttpTransportResponseRecord(200, body);
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
  networkKitTransport: HttpTransport,
  requestAgentTransport: HttpTransport,
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

function buildRequestAgentTransport(
  fileDriver: FakeFileDriver,
  modulePort: FakeRequestAgentModule,
  timer: FakeRequestAgentTimer,
  ids: string[] = ['agent-task']
): RequestAgentRedirectTransport {
  return new RequestAgentRedirectTransport(
    new RequestAgentDependencyShape(
      fileDriver,
      new SequenceIdGenerator(ids),
      modulePort,
      timer
    )
  );
}

function assertRequestContractShape(request: HttpTransportRequest): void {
  expect(Object.keys(request as Object).sort().join(',')).assertEqual('maxResponseBytes,timeoutMs,url,userAgent');
}

function requireHeaderObject(value: Object | undefined): UserAgentHeaderObject {
  expect(value === undefined).assertFalse();
  return value as UserAgentHeaderObject;
}

function assertExactUserAgentHeader(headers: UserAgentHeaderObject): void {
  expect(JSON.stringify(headers as Object)).assertEqual('{"User-Agent":"ClashMetaForAndroid/HarmonyOS"}');
}

async function flushAsyncTurns(count: number = 2): Promise<void> {
  let remaining: number = count;
  while (remaining > 0) {
    await Promise.resolve();
    remaining -= 1;
  }
}

async function waitForCondition(condition: () => boolean, maxTurns: number = 20): Promise<void> {
  let remaining: number = maxTurns;
  while (remaining > 0) {
    if (condition()) {
      return;
    }
    await Promise.resolve();
    remaining -= 1;
  }
  throw new Error('Condition did not become true.');
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

    it('sendsExactSubscriptionUserAgentOnInitialHttpsAndEveryRedirectViaNetworkKit', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(302, utf8Bytes('ignored redirect body'), buildHeaders([['location', ['/next.yaml#ignored']]]));
      networkTransport.enqueueResponse(302, utf8Bytes('ignored redirect body'), buildHeaders([['location', ['https://profiles.example.com/final.yaml#also-ignored']]]));
      networkTransport.enqueueResponse(200, utf8Bytes('mode: rule\n'));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:21:00.000Z'], ['ua-network-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/start.yaml#fragment'));
      requireSuccess(result);

      expect(networkTransport.requests.length).assertEqual(3);
      expect(networkTransport.requests[0].url).assertEqual('https://profiles.example.com/start.yaml');
      expect(networkTransport.requests[1].url).assertEqual('https://profiles.example.com/next.yaml');
      expect(networkTransport.requests[2].url).assertEqual('https://profiles.example.com/final.yaml');
      for (let index = 0; index < networkTransport.requests.length; index += 1) {
        expect(networkTransport.requests[index].userAgent).assertEqual('ClashMetaForAndroid/HarmonyOS');
        assertRequestContractShape(networkTransport.requests[index]);
      }
      expect(requestTransport.requests.length).assertEqual(0);
    });

    it('sendsExactSubscriptionUserAgentOnInitialHttpsAndEveryRedirectViaRequestAgent', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      requestTransport.enqueueResponse(302, utf8Bytes('ignored redirect body'), buildHeaders([['location', ['/next.yaml#ignored']]]));
      requestTransport.enqueueResponse(302, utf8Bytes('ignored redirect body'), buildHeaders([['location', ['https://profiles.example.com/final.yaml#also-ignored']]]));
      requestTransport.enqueueResponse(200, utf8Bytes('mode: rule\n'));
      const downloader = buildDownloader(22, networkTransport, requestTransport, fileDriver, ['2026-08-11T13:21:30.000Z'], ['ua-request-agent-stage']);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/start.yaml#fragment'));
      requireSuccess(result);

      expect(requestTransport.requests.length).assertEqual(3);
      expect(requestTransport.requests[0].url).assertEqual('https://profiles.example.com/start.yaml');
      expect(requestTransport.requests[1].url).assertEqual('https://profiles.example.com/next.yaml');
      expect(requestTransport.requests[2].url).assertEqual('https://profiles.example.com/final.yaml');
      for (let index = 0; index < requestTransport.requests.length; index += 1) {
        expect(requestTransport.requests[index].userAgent).assertEqual('ClashMetaForAndroid/HarmonyOS');
        assertRequestContractShape(requestTransport.requests[index]);
      }
      expect(networkTransport.requests.length).assertEqual(0);
    });

    it('keepsResponseNegotiationBranchesSeparatedAndStagesOnlyTheProductYamlPayload', 0, async () => {
      const base64ClassBody = utf8Bytes('QkFTRTY0X0NMQVNTX09OTFk=');
      const yamlBody = utf8Bytes('mixed-port: 7890\nmode: rule\nrules:\n  - GEOIP,CN,DIRECT\n  - MATCH,DIRECT\n');
      const transport = new CompatibilityNegotiatingTransport(base64ClassBody, yamlBody);
      const fileDriver = new FakeFileDriver();
      const downloader = buildDownloader(23, transport, new FakeHttpTransport(), fileDriver, ['2026-08-21T10:00:00.000Z'], ['compatibility-stage']);

      const wrongUserAgentResponse = await transport.fetch({
        url: 'https://profiles.example.com/compatibility.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: 'WrongAgent/0'
      });
      assertBytesEqual(new Uint8Array(wrongUserAgentResponse.body), base64ClassBody);

      const missingUserAgentResponse = await transport.fetch({
        url: 'https://profiles.example.com/compatibility.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: ''
      });
      assertBytesEqual(new Uint8Array(missingUserAgentResponse.body), base64ClassBody);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/compatibility.yaml'));
      const acquired = requireSuccess(result);

      expect(transport.requests.length).assertEqual(3);
      expect(transport.requests[2].userAgent).assertEqual('ClashMetaForAndroid/HarmonyOS');
      assertBytesEqual(fileDriver.readFileBytes(acquired.staged.validationPath), yamlBody);
      expect(acquired.staged.byteLength).assertEqual(yamlBody.length);
      expect(acquired.staged.validationPath).assertEqual(`${FILES_DIR}/tmp/compatibility-stage.yaml`);
      const stagedBytes = fileDriver.readFileBytes(acquired.staged.validationPath);
      expect(stagedBytes.length === base64ClassBody.length).assertFalse();
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

    it('reusesAnExistingStagingDirectoryWithoutAttemptingToRecreateIt', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      const payload = utf8Bytes('mixed-port: 7890\n');
      networkTransport.enqueueResponse(200, payload);
      const downloader = buildDownloader(
        23,
        networkTransport,
        requestTransport,
        fileDriver,
        ['2026-08-11T13:40:30.000Z'],
        ['existing-directory-stage']
      );
      fileDriver.injectFailure(
        'mkdir',
        `${FILES_DIR}/tmp`,
        new Error('Existing directory must not be recreated.')
      );

      const result = await downloader.acquire(new RemoteAcquireCommandRecord(
        'https://profiles.example.com/existing-directory.yaml'
      ));
      const acquired = requireSuccess(result);

      expect(acquired.staged.byteLength).assertEqual(payload.length);
      assertBytesEqual(fileDriver.readFileBytes(acquired.staged.validationPath), payload);
      expect(fileDriver.operationLog.includes(`mkdir:${FILES_DIR}/tmp:recursive`)).assertFalse();
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

    it('treatsFragmentOnlyRedirectsAsCurrentUrlAndRejectsTheLoopWithoutRetrying', 0, async () => {
      const networkTransport = new FakeHttpTransport();
      const requestTransport = new FakeHttpTransport();
      const fileDriver = new FakeFileDriver();
      networkTransport.enqueueResponse(302, new Uint8Array(0), buildHeaders([['location', ['#next']]]));
      const downloader = buildDownloader(23, networkTransport, requestTransport, fileDriver);

      const result = await downloader.acquire(new RemoteAcquireCommandRecord('https://profiles.example.com/a/path/sub.yaml?x=1'));
      const failure = assertFailureCode(result, 'CMFA_DOWNLOAD_REDIRECT');

      expect(failure.error.retryable).assertFalse();
      expect(networkTransport.requestedUrls.length).assertEqual(1);
      expect(networkTransport.requestedUrls[0]).assertEqual('https://profiles.example.com/a/path/sub.yaml?x=1');
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

    it('buildsExactlyOneUserAgentHeaderForNetworkKitRequests', 0, async () => {
      const client = new FakeNetworkKitClient();
      const transport = new NetworkKitHttpTransport(() => client);

      await transport.fetch({
        url: 'https://profiles.example.com/subscription.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: 'ClashMetaForAndroid/HarmonyOS'
      });

      expect(client.requestedUrls.length).assertEqual(1);
      expect(client.requestOptions.length).assertEqual(1);
      const optionRecord: NetworkKitRequestOptionsWithHeader = client.requestOptions[0] as NetworkKitRequestOptionsWithHeader;
      const headerRecord: UserAgentHeaderObject = requireHeaderObject(optionRecord.header);
      assertExactUserAgentHeader(headerRecord);
      expect(client.destroyCount).assertEqual(1);
    });

    it('rejectsBlankOrControlCharacterUserAgentBeforeNetworkKitRequest', 0, async () => {
      const blankClient = new FakeNetworkKitClient();
      const blankTransport = new NetworkKitHttpTransport(() => blankClient);
      let blankDetail: string = '';
      try {
        await blankTransport.fetch({
          url: 'https://profiles.example.com/subscription.yaml',
          timeoutMs: 30000,
          maxResponseBytes: EXACT_LIMIT_BYTES,
          userAgent: ' '
        });
      } catch (error) {
        blankDetail = `${(error as Error).message}`;
      }
      expect(blankDetail.length > 0).assertTrue();
      expect(blankDetail.includes(' ')).assertFalse();
      expect(blankClient.requestedUrls.length).assertEqual(0);

      const controlClient = new FakeNetworkKitClient();
      const controlTransport = new NetworkKitHttpTransport(() => controlClient);
      let controlDetail: string = '';
      try {
        await controlTransport.fetch({
          url: 'https://profiles.example.com/subscription.yaml',
          timeoutMs: 30000,
          maxResponseBytes: EXACT_LIMIT_BYTES,
          userAgent: 'Bad\nAgent'
        });
      } catch (error) {
        controlDetail = `${(error as Error).message}`;
      }
      expect(controlDetail.length > 0).assertTrue();
      expect(controlDetail.includes('Bad\\nAgent')).assertFalse();
      expect(controlDetail.includes('Bad\nAgent')).assertFalse();
      expect(controlClient.requestedUrls.length).assertEqual(0);
    });

    it('requestAgentWaitsForStopBeforeRemovingTaskAndUnlinkingOnTimeout', 0, async () => {
      const sharedLog: string[] = [];
      const fileDriver = new OrderedFakeFileDriver(sharedLog);
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(`${FILES_DIR}/tmp/agent-task.download`, utf8Bytes('still held'));
      const stopDeferred = new DeferredVoid();
      const modulePort = new FakeRequestAgentModule(sharedLog);
      const timer = new FakeRequestAgentTimer();
      modulePort.task = new FakeRequestAgentTask('tid-timeout', sharedLog, stopDeferred);
      const transport = buildRequestAgentTransport(fileDriver, modulePort, timer);

      let settled: boolean = false;
      const fetchPromise = transport.fetch({
        url: 'https://profiles.example.com/timeout.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: 'ClashMetaForAndroid/HarmonyOS'
      }).then(() => {
        settled = true;
      }, () => {
        settled = true;
      });

      await waitForCondition(() => sharedLog.join(',') === 'create,start' && timer.hasPendingTimer());
      timer.fire(timer.firstTimerId());
      await flushAsyncTurns();

      expect(settled).assertFalse();
      expect(sharedLog.join(',')).assertEqual('create,start,stop:begin');
      expect(fileDriver.operationLog.some((entry: string) => entry.startsWith('unlink:'))).assertFalse();

      stopDeferred.resolve();
      await fetchPromise;

      expect(sharedLog.join(',')).assertEqual(
        `create,start,stop:begin,stop:end,remove:tid-timeout,unlink:${FILES_DIR}/tmp/agent-task.download`
      );
    });

    it('requestAgentReturnsRedirectHeadersWithoutReadingTheDownloadedBody', 0, async () => {
      const sharedLog: string[] = [];
      const fileDriver = new OrderedFakeFileDriver(sharedLog);
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(`${FILES_DIR}/tmp/redirect-task.download`, utf8Bytes('must stay unread'));
      const modulePort = new FakeRequestAgentModule(sharedLog);
      const timer = new FakeRequestAgentTimer();
      const stopDeferred = new DeferredVoid();
      modulePort.task = new FakeRequestAgentTask('tid-redirect', sharedLog, stopDeferred);
      const transport = buildRequestAgentTransport(fileDriver, modulePort, timer, ['redirect-task']);

      const fetchPromise = transport.fetch({
        url: 'https://profiles.example.com/redirect.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: 'ClashMetaForAndroid/HarmonyOS'
      });
      await waitForCondition(() => sharedLog.join(',') === 'create,start' && timer.hasPendingTimer());
      modulePort.task.emitResponse(302, buildHeaders([['location', ['/next.yaml']]]));
      modulePort.task.emitCompleted();
      const response = await fetchPromise;

      expect(response.statusCode).assertEqual(302);
      expect(response.body.byteLength).assertEqual(0);
      expect(fileDriver.operationLog.some((entry: string) => entry === `open:${FILES_DIR}/tmp/redirect-task.download:0`)).assertFalse();
      expect(fileDriver.operationLog.some((entry: string) => entry === `read:${FILES_DIR}/tmp/redirect-task.download`)).assertFalse();
      expect(modulePort.log.includes('remove:tid-redirect')).assertTrue();
    });

    it('createsRequestAgentConfigWithExactlyOneUserAgentHeader', 0, async () => {
      const sharedLog: string[] = [];
      const fileDriver = new OrderedFakeFileDriver(sharedLog);
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      fileDriver.seedFile(`${FILES_DIR}/tmp/ua-task.download`, utf8Bytes('mode: rule\n'));
      const modulePort = new FakeRequestAgentModule(sharedLog);
      const timer = new FakeRequestAgentTimer();
      const stopDeferred = new DeferredVoid();
      modulePort.task = new FakeRequestAgentTask('tid-user-agent', sharedLog, stopDeferred);
      const transport = buildRequestAgentTransport(fileDriver, modulePort, timer, ['ua-task']);

      const fetchPromise = transport.fetch({
        url: 'https://profiles.example.com/subscription.yaml',
        timeoutMs: 30000,
        maxResponseBytes: EXACT_LIMIT_BYTES,
        userAgent: 'ClashMetaForAndroid/HarmonyOS'
      });
      await waitForCondition(() => sharedLog.join(',') === 'create,start' && timer.hasPendingTimer());
      modulePort.task.emitResponse(200);
      modulePort.task.emitCompleted(11);
      stopDeferred.resolve();
      await fetchPromise;

      expect(modulePort.createConfigs.length).assertEqual(1);
      const configRecord: RequestAgentCreateConfigWithHeaders = modulePort.createConfigs[0] as RequestAgentCreateConfigWithHeaders;
      const headerRecord: UserAgentHeaderObject = requireHeaderObject(configRecord.headers);
      assertExactUserAgentHeader(headerRecord);
    });

    it('rejectsBlankOrControlCharacterUserAgentBeforeRequestAgentCreate', 0, async () => {
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedDirectory(`${FILES_DIR}/tmp`);
      const blankModulePort = new FakeRequestAgentModule();
      const blankTransport = buildRequestAgentTransport(fileDriver, blankModulePort, new FakeRequestAgentTimer(), ['blank-task']);

      let blankDetail: string = '';
      try {
        await blankTransport.fetch({
          url: 'https://profiles.example.com/subscription.yaml',
          timeoutMs: 30000,
          maxResponseBytes: EXACT_LIMIT_BYTES,
          userAgent: ' '
        });
      } catch (error) {
        blankDetail = `${(error as Error).message}`;
      }
      expect(blankDetail.length > 0).assertTrue();
      expect(blankDetail.includes(' ')).assertFalse();
      expect(blankModulePort.createConfigs.length).assertEqual(0);

      const controlModulePort = new FakeRequestAgentModule();
      const controlTransport = buildRequestAgentTransport(fileDriver, controlModulePort, new FakeRequestAgentTimer(), ['control-task']);

      let controlDetail: string = '';
      try {
        await controlTransport.fetch({
          url: 'https://profiles.example.com/subscription.yaml',
          timeoutMs: 30000,
          maxResponseBytes: EXACT_LIMIT_BYTES,
          userAgent: 'Bad\nAgent'
        });
      } catch (error) {
        controlDetail = `${(error as Error).message}`;
      }
      expect(controlDetail.length > 0).assertTrue();
      expect(controlDetail.includes('Bad\\nAgent')).assertFalse();
      expect(controlDetail.includes('Bad\nAgent')).assertFalse();
      expect(controlModulePort.createConfigs.length).assertEqual(0);
    });
  });
}
