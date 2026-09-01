import { probeSocket as nativeProbeSocket } from 'libprobeentry.so';

export type NativeSocketProbeKind = 'tcpEcho' | 'tcpHttp' | 'tcpSend' | 'tcpExchange' | 'udpEcho' | 'dnsUdpEcho';
export type NativeSocketProbeFailureCode =
  'INVALID_ARGUMENT' |
  'CONNECT_FAILED' |
  'SEND_FAILED' |
  'RECV_FAILED' |
  'TIMEOUT' |
  'PAYLOAD_MISMATCH';
export type LocalNativeSocketProbeFailureCode = 'INVALID_RESULT' | 'BRIDGE_FAILURE';
export type NativeSocketProbeKnownFailureCode = NativeSocketProbeFailureCode | LocalNativeSocketProbeFailureCode;

export class NativeSocketProbeResult {
  outcome: 'pass' | 'fail' | 'timeout' = 'fail';
  bytesSent: number = 0;
  bytesReceived: number = 0;
  durationMs: number = 0;
  failureCode?: NativeSocketProbeKnownFailureCode;
}

export interface NativeSocketProbePort {
  probe(
    kind: NativeSocketProbeKind,
    hostIpv4: string,
    port: number,
    payload: ArrayBuffer,
    timeoutMs: number
  ): Promise<NativeSocketProbeResult>;
}

interface NativeSocketProbeRequest {
  kind: NativeSocketProbeKind;
  hostIpv4: string;
  port: number;
  payload: ArrayBuffer;
  timeoutMs: number;
}

interface NativeSocketProbeBridgeResult {
  outcome: string;
  bytesSent: number;
  bytesReceived: number;
  durationMs: number;
  failureCode?: string;
}

type NativeSocketBridgeResolved = Object | string | number | boolean | null | undefined;
type NativeSocketBridge = (request: NativeSocketProbeRequest) => Promise<NativeSocketBridgeResolved>;

const PASS_RESULT_KEYS: string[] = ['outcome', 'bytesSent', 'bytesReceived', 'durationMs'];
const FAILURE_RESULT_KEYS: string[] = ['outcome', 'bytesSent', 'bytesReceived', 'durationMs', 'failureCode'];

class NativeSocketProbeRequestRecord implements NativeSocketProbeRequest {
  kind: NativeSocketProbeKind = 'tcpEcho';
  hostIpv4: string = '';
  port: number = 0;
  payload: ArrayBuffer = new ArrayBuffer(0);
  timeoutMs: number = 0;
}

class DefaultNativeSocketProbePort implements NativeSocketProbePort {
  private readonly bridge: NativeSocketBridge;

  constructor(bridge: NativeSocketBridge) {
    this.bridge = bridge;
  }

  async probe(
    kind: NativeSocketProbeKind,
    hostIpv4: string,
    port: number,
    payload: ArrayBuffer,
    timeoutMs: number
  ): Promise<NativeSocketProbeResult> {
    try {
      const clonedPayload: ArrayBuffer = payload.slice(0);
      const expectedPayloadBytes: number = new Uint8Array(clonedPayload).byteLength;
      const request: NativeSocketProbeRequestRecord = new NativeSocketProbeRequestRecord();
      request.kind = kind;
      request.hostIpv4 = hostIpv4;
      request.port = port;
      request.payload = clonedPayload;
      request.timeoutMs = timeoutMs;
      const rawResult: NativeSocketBridgeResolved = await this.bridge(request);
      return normalizeNativeSocketProbeResult(rawResult, expectedPayloadBytes, kind);
    } catch (_) {
      return createFailureResult('BRIDGE_FAILURE');
    }
  }
}

export function createDefaultNativeSocketProbePort(bridge?: NativeSocketBridge): NativeSocketProbePort {
  return new DefaultNativeSocketProbePort(bridge ?? nativeProbeSocket);
}

function normalizeNativeSocketProbeResult(
  rawResult: NativeSocketBridgeResolved,
  expectedPayloadBytes: number,
  kind: NativeSocketProbeKind
): NativeSocketProbeResult {
  try {
    const record: Record<string, Object> = requireBridgeResultRecord(rawResult);
    const actualKeys: string[] = Object.keys(record);
    const outcomeValue: Object | undefined = record['outcome'];
    const outcome: 'pass' | 'fail' | 'timeout' = requireOutcome(outcomeValue);
    const expectedKeys: string[] = outcome === 'pass' ? PASS_RESULT_KEYS : FAILURE_RESULT_KEYS;
    if (!hasExactKeys(actualKeys, expectedKeys)) {
      return createFailureResult('INVALID_RESULT');
    }
    const bytesSentValue: Object | undefined = record['bytesSent'];
    const bytesReceivedValue: Object | undefined = record['bytesReceived'];
    const durationMsValue: Object | undefined = record['durationMs'];
    const failureCodeValue: Object | undefined = outcome === 'pass' ? undefined : record['failureCode'];
    const bytesSent: number = requireUint32(bytesSentValue);
    const bytesReceived: number = requireUint32(bytesReceivedValue);
    const durationMs: number = requireUint32(durationMsValue);
    if (!isValidUint32(expectedPayloadBytes)) {
      return createFailureResult('INVALID_RESULT');
    }
    const normalized: NativeSocketProbeResult = new NativeSocketProbeResult();
    normalized.outcome = outcome;
    normalized.bytesSent = bytesSent;
    normalized.bytesReceived = bytesReceived;
    normalized.durationMs = durationMs;
    if (outcome === 'pass') {
      const receiveCountsValid: boolean = kind === 'tcpSend'
        ? bytesReceived === 0
        : kind === 'tcpHttp' || kind === 'tcpExchange'
          ? bytesReceived > 0 && bytesReceived <= 4096
          : bytesReceived === expectedPayloadBytes;
      if (bytesSent !== expectedPayloadBytes || !receiveCountsValid) {
        return createFailureResult('INVALID_RESULT');
      }
      return normalized;
    }
    const failureCode: NativeSocketProbeFailureCode | undefined =
      outcome === 'timeout'
        ? normalizeTimeoutFailureCode(failureCodeValue)
        : normalizeFailFailureCode(failureCodeValue);
    if (failureCode === undefined) {
      return createFailureResult('INVALID_RESULT');
    }
    normalized.failureCode = failureCode;
    return normalized;
  } catch (_) {
    return createFailureResult('INVALID_RESULT');
  }
}

function requireBridgeResultRecord(value: NativeSocketBridgeResolved): Record<string, Object> {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('invalid-result-record');
  }
  return value as Record<string, Object>;
}

function hasExactKeys(actualKeys: string[], expectedKeys: string[]): boolean {
  if (hasForbiddenMetaKey(actualKeys) || actualKeys.length !== expectedKeys.length) {
    return false;
  }
  for (let index: number = 0; index < actualKeys.length; index += 1) {
    if (!containsKey(expectedKeys, actualKeys[index])) {
      return false;
    }
  }
  return true;
}

function hasForbiddenMetaKey(keys: string[]): boolean {
  return containsKey(keys, '__proto__') || containsKey(keys, 'constructor') || containsKey(keys, 'prototype');
}

function containsKey(keys: string[], expected: string): boolean {
  for (let index: number = 0; index < keys.length; index += 1) {
    if (keys[index] === expected) {
      return true;
    }
  }
  return false;
}

function requireOutcome(value: Object | undefined): 'pass' | 'fail' | 'timeout' {
  if (typeof value !== 'string' || !isValidOutcome(value)) {
    throw new Error('invalid-outcome');
  }
  return normalizeOutcome(value);
}

function requireUint32(value: Object | undefined): number {
  if (typeof value !== 'number' || !isValidUint32(value)) {
    throw new Error('invalid-uint32');
  }
  return value;
}

function normalizeTimeoutFailureCode(value: Object | undefined): NativeSocketProbeFailureCode | undefined {
  if (value === 'TIMEOUT') {
    return 'TIMEOUT';
  }
  return undefined;
}

function normalizeFailFailureCode(value: Object | undefined): NativeSocketProbeFailureCode | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  if (value === 'INVALID_ARGUMENT' ||
    value === 'CONNECT_FAILED' ||
    value === 'SEND_FAILED' ||
    value === 'RECV_FAILED' ||
    value === 'PAYLOAD_MISMATCH') {
    return value;
  }
  return undefined;
}

function createFailureResult(code: LocalNativeSocketProbeFailureCode): NativeSocketProbeResult {
  const normalized: NativeSocketProbeResult = new NativeSocketProbeResult();
  normalized.outcome = 'fail';
  normalized.bytesSent = 0;
  normalized.bytesReceived = 0;
  normalized.durationMs = 0;
  normalized.failureCode = code;
  return normalized;
}

function isValidOutcome(value: string): boolean {
  return value === 'pass' || value === 'fail' || value === 'timeout';
}

function isValidUint32(value: number): boolean {
  return Number.isInteger(value) && value >= 0 && value <= 0xFFFFFFFF;
}

function normalizeOutcome(value: string): 'pass' | 'fail' | 'timeout' {
  if (value === 'pass') {
    return 'pass';
  }
  if (value === 'timeout') {
    return 'timeout';
  }
  return 'fail';
}
