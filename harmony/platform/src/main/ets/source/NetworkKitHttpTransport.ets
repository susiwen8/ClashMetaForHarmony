import { http } from '@kit.NetworkKit';
import {
  createHttpTransportFailure,
  validateHttpTransportRequestUserAgent,
  type HttpTransport,
  type HttpTransportRequest,
  type HttpTransportResponse
} from './HttpTransport';

interface BusinessErrorShape {
  code?: number;
  message?: string;
}

export interface NetworkKitResponsePort {
  responseCode: number;
  header: Object;
  result: string | Object | ArrayBuffer;
}

export interface NetworkKitRequestOptions {
  method: http.RequestMethod;
  expectDataType: http.HttpDataType;
  usingCache: boolean;
  connectTimeout: number;
  readTimeout: number;
  maxLimit: number;
  maxRedirects: number;
  header: NetworkKitHeaderRecord;
}

export interface NetworkKitClientPort {
  request(url: string, options: NetworkKitRequestOptions): Promise<NetworkKitResponsePort>;
  destroy(): void;
}

export type NetworkKitClientFactory = () => NetworkKitClientPort;

export interface NetworkKitHeaderRecord {
  'User-Agent': string;
}

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

export class NetworkKitHttpTransport implements HttpTransport {
  private readonly clientFactory: NetworkKitClientFactory;

  constructor(clientFactory?: NetworkKitClientFactory) {
    this.clientFactory = clientFactory ?? createSystemNetworkKitClient;
  }

  async fetch(request: HttpTransportRequest): Promise<HttpTransportResponse> {
    validateHttpTransportRequestUserAgent(request.userAgent);
    const client: NetworkKitClientPort = this.clientFactory();
    try {
      const response: NetworkKitResponsePort = await client.request(request.url, buildNetworkKitRequestOptions(request));
      return new HttpTransportResponseRecord(
        response.responseCode as number,
        normalizeHeaderMap(response.header),
        normalizeResponseBody(response.result)
      );
    } catch (error) {
      throw mapNetworkKitFailure(error as Object | undefined);
    } finally {
      try {
        client.destroy();
      } catch (_) {
      }
    }
  }
}

export function buildNetworkKitRequestOptions(request: HttpTransportRequest): NetworkKitRequestOptions {
  return {
    method: http.RequestMethod.GET,
    expectDataType: http.HttpDataType.ARRAY_BUFFER,
    usingCache: false,
    connectTimeout: 30 * 1000,
    readTimeout: 30 * 1000,
    maxLimit: 16 * 1024 * 1024,
    maxRedirects: 0,
    header: buildNetworkKitHeaderRecord(request.userAgent)
  };
}

function normalizeHeaderMap(rawHeaders: Object): Map<string, Array<string>> {
  const normalized = new Map<string, Array<string>>();
  const record: Record<string, Object> = rawHeaders as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let index = 0; index < keys.length; index += 1) {
    const key: string = keys[index];
    const rawValue: Object = record[key];
    if (typeof rawValue === 'string') {
      normalized.set(key, [rawValue]);
      continue;
    }
    if (Array.isArray(rawValue)) {
      const values: Array<string> = [];
      for (let valueIndex = 0; valueIndex < rawValue.length; valueIndex += 1) {
        const next: Object = rawValue[valueIndex];
        if (typeof next === 'string') {
          values.push(next);
        }
      }
      normalized.set(key, values);
    }
  }
  return normalized;
}

function normalizeResponseBody(result: string | Object | ArrayBuffer): ArrayBuffer {
  if (result instanceof ArrayBuffer) {
    return result;
  }
  if (typeof result === 'string') {
    return encodeUtf8(result);
  }
  throw createHttpTransportFailure('NETWORK', 'NetworkKit HTTP response body type was unsupported.');
}

function mapNetworkKitFailure(error: Object | undefined) {
  const record: BusinessErrorShape = error as BusinessErrorShape;
  const code: number = typeof record.code === 'number' ? record.code : -1;
  const message: string = typeof record.message === 'string' ? record.message.toLowerCase() : '';
  if (code === 2300063 || isExplicitMaxLimitFailureMessage(message)) {
    return createHttpTransportFailure('OVERSIZE', 'NetworkKit response exceeded the configured size limit.');
  }
  if (message.includes('ssl') || message.includes('tls') || message.includes('certificate')) {
    return createHttpTransportFailure('TLS', 'NetworkKit TLS request failed.');
  }
  if (code === 2300008 || code === 2300052 || message.includes('timeout')) {
    return createHttpTransportFailure('TIMEOUT', 'NetworkKit request timed out.');
  }
  return createHttpTransportFailure('NETWORK', 'NetworkKit request failed.');
}

function isExplicitMaxLimitFailureMessage(message: string): boolean {
  return message.includes('maximum file size exceeded') ||
    message.includes('max limit');
}

function encodeUtf8(value: string): ArrayBuffer {
  const bytes: number[] = [];
  for (let index = 0; index < value.length; index += 1) {
    const codePoint: number = value.charCodeAt(index);
    if (codePoint <= 0x7f) {
      bytes.push(codePoint);
      continue;
    }
    if (codePoint <= 0x7ff) {
      bytes.push(0xc0 | (codePoint >> 6));
      bytes.push(0x80 | (codePoint & 0x3f));
      continue;
    }
    bytes.push(0xe0 | (codePoint >> 12));
    bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
    bytes.push(0x80 | (codePoint & 0x3f));
  }
  const target = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    target[index] = bytes[index];
  }
  return target.buffer;
}

function createSystemNetworkKitClient(): NetworkKitClientPort {
  return http.createHttp() as http.HttpRequest as NetworkKitClientPort;
}

function buildNetworkKitHeaderRecord(userAgent: string): NetworkKitHeaderRecord {
  return {
    'User-Agent': userAgent
  };
}
