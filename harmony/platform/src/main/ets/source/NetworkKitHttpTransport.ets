import { http } from '@kit.NetworkKit';
import {
  createHttpTransportFailure,
  type HttpTransport,
  type HttpTransportRequest,
  type HttpTransportResponse
} from './HttpTransport';

interface BusinessErrorShape {
  code?: number;
  message?: string;
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
  async fetch(request: HttpTransportRequest): Promise<HttpTransportResponse> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(request.url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: 30 * 1000,
        readTimeout: 30 * 1000,
        maxLimit: 16 * 1024 * 1024,
        maxRedirects: 0
      });
      return new HttpTransportResponseRecord(
        response.responseCode as number,
        normalizeHeaderMap(response.header),
        normalizeResponseBody(response.result)
      );
    } catch (error) {
      throw mapNetworkKitFailure(error as Object | undefined, request.url);
    } finally {
      try {
        client.destroy();
      } catch (_) {
      }
    }
  }
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

function mapNetworkKitFailure(error: Object | undefined, requestUrl: string) {
  const record: BusinessErrorShape = error as BusinessErrorShape;
  const code: number = typeof record.code === 'number' ? record.code : -1;
  const message: string = typeof record.message === 'string' ? record.message.toLowerCase() : '';
  if (message.includes('ssl') || message.includes('tls') || message.includes('certificate')) {
    return createHttpTransportFailure('TLS', `NetworkKit TLS request failed for ${requestUrl}.`);
  }
  if (code === 2300008 || code === 2300052 || message.includes('timeout')) {
    return createHttpTransportFailure('TIMEOUT', `NetworkKit request timed out for ${requestUrl}.`);
  }
  return createHttpTransportFailure('NETWORK', `NetworkKit request failed for ${requestUrl}.`);
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
