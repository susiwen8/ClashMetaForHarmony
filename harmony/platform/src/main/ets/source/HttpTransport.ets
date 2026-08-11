export interface HttpTransportRequest {
  url: string;
  timeoutMs: number;
  maxResponseBytes: number;
}

export interface HttpTransportResponse {
  statusCode: number;
  headers: Map<string, Array<string>>;
  body: ArrayBuffer;
}

export type HttpTransportFailureKind =
  | 'NETWORK'
  | 'TIMEOUT'
  | 'TLS'
  | 'REDIRECT'
  | 'OVERSIZE';

export interface HttpTransportFailure extends Error {
  name: 'HttpTransportFailure';
  kind: HttpTransportFailureKind;
  detail: string;
}

class HttpTransportFailureError extends Error implements HttpTransportFailure {
  name: 'HttpTransportFailure' = 'HttpTransportFailure';
  kind: HttpTransportFailureKind;
  detail: string;

  constructor(kind: HttpTransportFailureKind, detail: string) {
    const normalized: string = detail.trim().length > 0 ? detail.trim() : 'HTTP transport failed.';
    super(normalized);
    this.kind = kind;
    this.detail = normalized;
  }
}

export function createHttpTransportFailure(
  kind: HttpTransportFailureKind,
  detail: string
): HttpTransportFailure {
  return new HttpTransportFailureError(kind, detail);
}

export function isHttpTransportFailure(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return record.name === 'HttpTransportFailure' &&
    typeof record.kind === 'string' &&
    typeof record.detail === 'string';
}

export interface HttpTransport {
  fetch(request: HttpTransportRequest): Promise<HttpTransportResponse>;
}
