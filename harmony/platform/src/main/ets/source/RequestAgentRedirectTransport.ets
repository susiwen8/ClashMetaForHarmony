import common from '@ohos.app.ability.common';
import { request } from '@kit.BasicServicesKit';
import type { FileDriver, FileToken } from '../files/FileDriver';
import { FILE_OPEN_MODE_READ_ONLY } from '../files/FileDriver';
import type { IdGenerator } from '@cmfa/shared';
import {
  createHttpTransportFailure,
  isHttpTransportFailure,
  validateHttpTransportRequestUserAgent,
  type HttpTransport,
  type HttpTransportFailureKind,
  type HttpTransportRequest,
  type HttpTransportResponse
} from './HttpTransport';

const COPY_BUFFER_BYTES: number = 64 * 1024;
const REDIRECT_STATUS_CODES: number[] = [301, 302, 303, 307, 308];

class HttpTransportResponseRecord implements HttpTransportResponse {
  readonly statusCode: number;
  readonly headers: Map<string, Array<string>>;
  readonly body: ArrayBuffer;

  constructor(statusCode: number, headers: Map<string, Array<string>>, body: ArrayBuffer) {
    this.statusCode = statusCode;
    this.headers = headers;
    this.body = body;
  }
}

class RequestAgentCreateConfigRecord implements RequestAgentCreateConfig {
  action: request.agent.Action;
  url: string;
  mode: request.agent.Mode;
  method: string;
  saveas: string;
  redirect: boolean;
  headers: RequestAgentHeaderRecord;

  constructor(url: string, saveas: string, userAgent: string) {
    this.action = request.agent.Action.DOWNLOAD;
    this.url = url;
    this.mode = request.agent.Mode.FOREGROUND;
    this.method = 'GET';
    this.saveas = saveas;
    this.redirect = false;
    this.headers = buildRequestAgentHeaderRecord(userAgent);
  }
}

export interface RequestAgentRedirectTransportDependencies {
  context?: common.BaseContext;
  fileDriver: FileDriver;
  filesDir: string;
  idGenerator: IdGenerator;
  requestAgent?: RequestAgentModulePort;
  timer?: RequestAgentTimerPort;
}

export interface RequestAgentTaskPort {
  readonly tid: string;
  on(event: 'progress', callback: (progress: RequestAgentProgressPort) => void): void;
  on(event: 'response', callback: (response: RequestAgentResponsePort) => void): void;
  on(event: 'faultOccur', callback: (fault: RequestAgentFaultPort) => void): void;
  on(event: 'failed', callback: (progress: RequestAgentProgressPort) => void): void;
  on(event: 'completed', callback: (progress: RequestAgentProgressPort) => void): void;
  start(): Promise<void>;
  stop(): Promise<void>;
}

export interface RequestAgentProgressPort {
  readonly processed: number;
}

export interface RequestAgentResponsePort {
  readonly statusCode: number;
  readonly headers: Map<string, Array<string>>;
}

export type RequestAgentFaultPort = number;

export interface RequestAgentCreateConfig extends request.agent.Config {}

interface RequestAgentHeaderRecord {
  'User-Agent': string;
}

export interface RequestAgentModulePort {
  create(context: common.BaseContext | undefined, config: RequestAgentCreateConfig): Promise<RequestAgentTaskPort>;
  remove(tid: string): Promise<void>;
}

export interface RequestAgentTimerPort {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(timerId: number): void;
}

export class RequestAgentRedirectTransport implements HttpTransport {
  private readonly context?: common.BaseContext;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly idGenerator: IdGenerator;
  private readonly requestAgent: RequestAgentModulePort;
  private readonly timer: RequestAgentTimerPort;

  constructor(dependencies: RequestAgentRedirectTransportDependencies) {
    this.context = dependencies.context;
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxRoot(dependencies.filesDir);
    this.idGenerator = dependencies.idGenerator;
    this.requestAgent = dependencies.requestAgent ?? createSystemRequestAgentModule();
    this.timer = dependencies.timer ?? createSystemRequestAgentTimer();
  }

  async fetch(requestSpec: HttpTransportRequest): Promise<HttpTransportResponse> {
    validateHttpTransportRequestUserAgent(requestSpec.userAgent);
    const tempPath: string = await this.prepareOutputPath();
    let task: RequestAgentTaskPort | undefined = undefined;
    try {
      task = await this.requestAgent.create(
        this.context,
        new RequestAgentCreateConfigRecord(requestSpec.url, tempPath, requestSpec.userAgent)
      );
      return await this.awaitTask(task, tempPath, requestSpec);
    } finally {
      await this.safeRemoveTask(task);
      await this.safeUnlink(tempPath);
    }
  }

  private async prepareOutputPath(): Promise<string> {
    const tempDirectory: string = `${this.filesDir}/tmp`;
    await this.fileDriver.mkdir(tempDirectory, true);
    return `${tempDirectory}/${this.idGenerator.nextId()}.download`;
  }

  private async awaitTask(
    task: RequestAgentTaskPort,
    tempPath: string,
    requestSpec: HttpTransportRequest
  ): Promise<HttpTransportResponse> {
    let settled: boolean = false;
    let timeoutHandle: number = 0;
    let responseStatusCode: number = 0;
    let responseHeaders = new Map<string, Array<string>>();
    let stopPromise: Promise<void> | undefined = undefined;

    return await new Promise<HttpTransportResponse>((resolve, reject) => {
      const ensureStop = (): Promise<void> => {
        if (stopPromise !== undefined) {
          return stopPromise;
        }
        stopPromise = safeStopTask(task);
        return stopPromise;
      };

      const completeWithFailure = (kind: HttpTransportFailureKind, detail: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutHandle !== 0) {
          this.timer.clearTimeout(timeoutHandle);
        }
        void ensureStop().finally(() => {
          reject(createHttpTransportFailure(kind, detail));
        });
      };

      const completeWithSuccess = async (): Promise<void> => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutHandle !== 0) {
          this.timer.clearTimeout(timeoutHandle);
        }
        if (isRedirectStatus(responseStatusCode)) {
          resolve(new HttpTransportResponseRecord(responseStatusCode, responseHeaders, new ArrayBuffer(0)));
          return;
        }
        try {
          const body: ArrayBuffer = await readFileFully(this.fileDriver, tempPath, requestSpec.maxResponseBytes);
          resolve(new HttpTransportResponseRecord(responseStatusCode, responseHeaders, body));
        } catch (error) {
          if (isHttpTransportFailure(error as Object | undefined)) {
            reject(error as Error);
            return;
          }
          reject(createHttpTransportFailure('NETWORK', 'Request agent output read failed.'));
        }
      };

      timeoutHandle = this.timer.setTimeout(() => {
        completeWithFailure('TIMEOUT', 'Request agent timed out.');
      }, requestSpec.timeoutMs);

      task.on('response', (response: RequestAgentResponsePort) => {
        responseStatusCode = response.statusCode;
        responseHeaders = cloneHeaderMap(response.headers);
      });
      task.on('progress', (progress: RequestAgentProgressPort) => {
        if (progress.processed > requestSpec.maxResponseBytes) {
          completeWithFailure('OVERSIZE', 'Request agent exceeded the configured size limit.');
        }
      });
      task.on('faultOccur', (fault: RequestAgentFaultPort) => {
        completeWithFailure(mapFaultKind(fault), 'Request agent fault occurred.');
      });
      task.on('failed', (_progress: RequestAgentProgressPort) => {
        completeWithFailure('NETWORK', 'Request agent failed.');
      });
      task.on('completed', (_progress: RequestAgentProgressPort) => {
        void completeWithSuccess();
      });

      task.start().catch((_error: Error) => {
        completeWithFailure('NETWORK', 'Request agent start failed.');
      });
    });
  }

  private async safeRemoveTask(task?: RequestAgentTaskPort): Promise<void> {
    if (task === undefined) {
      return;
    }
    try {
      await this.requestAgent.remove(task.tid);
    } catch (_) {
    }
  }

  private async safeUnlink(path: string): Promise<void> {
    try {
      await this.fileDriver.unlink(path);
    } catch (_) {
    }
  }
}

function mapFaultKind(fault: request.agent.Faults): HttpTransportFailureKind {
  switch (fault) {
    case request.agent.Faults.TIMEOUT:
      return 'TIMEOUT';
    case request.agent.Faults.SSL:
      return 'TLS';
    case request.agent.Faults.REDIRECT:
      return 'REDIRECT';
    default:
      return 'NETWORK';
  }
}

function cloneHeaderMap(headers: Map<string, Array<string>>): Map<string, Array<string>> {
  const normalized = new Map<string, Array<string>>();
  for (const entry of headers.entries()) {
    normalized.set(entry[0], entry[1].slice());
  }
  return normalized;
}

function normalizeAbsoluteSandboxRoot(rawPath: string): string {
  const normalized: string = rawPath.trim().replace(/\\/g, '/').replace(/\/+$/u, '');
  if (!normalized.startsWith('/')) {
    throw new Error('Sandbox root must be absolute.');
  }
  return normalized;
}

function isRedirectStatus(statusCode: number): boolean {
  for (let index = 0; index < REDIRECT_STATUS_CODES.length; index += 1) {
    if (REDIRECT_STATUS_CODES[index] === statusCode) {
      return true;
    }
  }
  return false;
}

async function readFileFully(
  fileDriver: FileDriver,
  path: string,
  maxResponseBytes: number
): Promise<ArrayBuffer> {
  let handle: FileToken | undefined = undefined;
  try {
    handle = await fileDriver.open(path, FILE_OPEN_MODE_READ_ONLY);
    const chunks: Uint8Array[] = [];
    let total: number = 0;
    while (true) {
      const buffer = new ArrayBuffer(COPY_BUFFER_BYTES);
      const bytesRead: number = await fileDriver.read(handle.fd, buffer);
      if (bytesRead <= 0) {
        break;
      }
      total += bytesRead;
      if (total > maxResponseBytes) {
        throw createHttpTransportFailure('OVERSIZE', 'Request agent exceeded the configured size limit.');
      }
      chunks.push(new Uint8Array(buffer.slice(0, bytesRead)));
    }
    return mergeChunks(chunks, total);
  } finally {
    if (handle !== undefined) {
      try {
        await fileDriver.close(handle);
      } catch (_) {
      }
    }
  }
}

function mergeChunks(chunks: Uint8Array[], total: number): ArrayBuffer {
  const output = new Uint8Array(total);
  let offset: number = 0;
  for (let index = 0; index < chunks.length; index += 1) {
    const chunk: Uint8Array = chunks[index];
    for (let chunkIndex = 0; chunkIndex < chunk.length; chunkIndex += 1) {
      output[offset + chunkIndex] = chunk[chunkIndex];
    }
    offset += chunk.length;
  }
  return output.buffer;
}

async function safeStopTask(task: RequestAgentTaskPort): Promise<void> {
  try {
    await task.stop();
  } catch (_) {
  }
}

class SystemRequestAgentModule implements RequestAgentModulePort {
  async create(
    context: common.BaseContext | undefined,
    config: RequestAgentCreateConfig
  ): Promise<RequestAgentTaskPort> {
    if (context === undefined) {
      throw new Error('Request agent context was missing.');
    }
    return await request.agent.create(context, config) as RequestAgentTaskPort;
  }

  async remove(tid: string): Promise<void> {
    await request.agent.remove(tid);
  }
}

function createSystemRequestAgentModule(): RequestAgentModulePort {
  return new SystemRequestAgentModule();
}

class SystemRequestAgentTimer implements RequestAgentTimerPort {
  setTimeout(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs) as number;
  }

  clearTimeout(timerId: number): void {
    clearTimeout(timerId);
  }
}

function createSystemRequestAgentTimer(): RequestAgentTimerPort {
  return new SystemRequestAgentTimer();
}

function buildRequestAgentHeaderRecord(userAgent: string): RequestAgentHeaderRecord {
  return {
    'User-Agent': userAgent
  };
}
