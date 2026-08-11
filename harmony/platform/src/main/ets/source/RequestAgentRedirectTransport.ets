import common from '@ohos.app.ability.common';
import { request } from '@kit.BasicServicesKit';
import type { FileDriver, FileToken } from '../files/FileDriver';
import { FILE_OPEN_MODE_READ_ONLY } from '../files/FileDriver';
import type { IdGenerator } from '@cmfa/shared';
import {
  createHttpTransportFailure,
  type HttpTransport,
  type HttpTransportFailureKind,
  type HttpTransportRequest,
  type HttpTransportResponse
} from './HttpTransport';

const COPY_BUFFER_BYTES: number = 64 * 1024;

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

export interface RequestAgentRedirectTransportDependencies {
  context: common.BaseContext;
  fileDriver: FileDriver;
  filesDir: string;
  idGenerator: IdGenerator;
}

export class RequestAgentRedirectTransport implements HttpTransport {
  private readonly context: common.BaseContext;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly idGenerator: IdGenerator;

  constructor(dependencies: RequestAgentRedirectTransportDependencies) {
    this.context = dependencies.context;
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxRoot(dependencies.filesDir);
    this.idGenerator = dependencies.idGenerator;
  }

  async fetch(requestSpec: HttpTransportRequest): Promise<HttpTransportResponse> {
    const tempPath: string = await this.prepareOutputPath();
    let task: request.agent.Task | undefined = undefined;
    try {
      task = await request.agent.create(this.context, {
        action: request.agent.Action.DOWNLOAD,
        url: requestSpec.url,
        mode: request.agent.Mode.FOREGROUND,
        method: 'GET',
        saveas: tempPath,
        redirect: false
      });
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
    task: request.agent.Task,
    tempPath: string,
    requestSpec: HttpTransportRequest
  ): Promise<HttpTransportResponse> {
    let settled: boolean = false;
    let timeoutHandle: number = 0;
    let responseStatusCode: number = 0;
    let responseHeaders = new Map<string, Array<string>>();

    return await new Promise<HttpTransportResponse>((resolve, reject) => {
      const completeWithFailure = (kind: HttpTransportFailureKind, detail: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutHandle !== 0) {
          clearTimeout(timeoutHandle);
        }
        reject(createHttpTransportFailure(kind, detail));
      };

      const completeWithSuccess = async (): Promise<void> => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutHandle !== 0) {
          clearTimeout(timeoutHandle);
        }
        try {
          const body: ArrayBuffer = await readFileFully(this.fileDriver, tempPath, requestSpec.maxResponseBytes);
          resolve(new HttpTransportResponseRecord(responseStatusCode, responseHeaders, body));
        } catch (_) {
          reject(createHttpTransportFailure('NETWORK', `Request agent output read failed for ${requestSpec.url}.`));
        }
      };

      timeoutHandle = setTimeout(() => {
        void safeStopTask(task);
        completeWithFailure('TIMEOUT', `Request agent timed out for ${requestSpec.url}.`);
      }, requestSpec.timeoutMs) as number;

      task.on('response', (response: request.agent.HttpResponse) => {
        responseStatusCode = response.statusCode;
        responseHeaders = cloneHeaderMap(response.headers);
      });
      task.on('progress', (progress: request.agent.Progress) => {
        if (progress.processed > requestSpec.maxResponseBytes) {
          void safeStopTask(task);
          completeWithFailure('OVERSIZE', `Request agent exceeded ${requestSpec.maxResponseBytes} bytes for ${requestSpec.url}.`);
        }
      });
      task.on('faultOccur', (fault: request.agent.Faults) => {
        void safeStopTask(task);
        completeWithFailure(mapFaultKind(fault), `Request agent fault occurred for ${requestSpec.url}.`);
      });
      task.on('failed', (_progress: request.agent.Progress) => {
        void safeStopTask(task);
        completeWithFailure('NETWORK', `Request agent failed for ${requestSpec.url}.`);
      });
      task.on('completed', (_progress: request.agent.Progress) => {
        void completeWithSuccess();
      });

      task.start().catch((_error: Error) => {
        completeWithFailure('NETWORK', `Request agent start failed for ${requestSpec.url}.`);
      });
    });
  }

  private async safeRemoveTask(task?: request.agent.Task): Promise<void> {
    if (task === undefined) {
      return;
    }
    try {
      await request.agent.remove(task.tid);
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
        throw new Error('Response exceeded limit.');
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

async function safeStopTask(task: request.agent.Task): Promise<void> {
  try {
    await task.stop();
  } catch (_) {
  }
}
