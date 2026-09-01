import {
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcClientAuthBody,
  createVpnRpcGuards,
  createVpnRpcServerAuthBody,
  createVpnRpcServerHelloBody,
  type VpnRpcBody,
  type VpnRpcClientAuthBody,
  type VpnRpcServerAuthBody,
  type VpnRpcServerHelloBody
} from '../../main/ets/vpn/rpc/VpnRpcModels';
import {
  createVpnRpcEmptyPayload,
  createVpnRpcPingSuccessPayload
} from '../../main/ets/vpn/rpc/VpnRpcPayloads';
import type {
  VpnRpcCancelableTaskPort,
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSchedulerPort
} from '../../main/ets/vpn/rpc/VpnRpcPorts';
import {
  decodeVpnRpcLowercaseHex,
  encodeVpnRpcU32BE,
  encodeVpnRpcUtf8
} from '../../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import { encodeVpnRpcBody } from '../../main/ets/vpn/rpc/VpnRpcBodyCodec';

export const VPN_RPC_AUTH_FAILED_CODE: string = 'AUTH_FAILED';
export const VPN_RPC_FRAME_INVALID_CODE: string = 'FRAME_INVALID';
export const VPN_RPC_PROTOCOL_MISMATCH_CODE: string = 'PROTOCOL_MISMATCH';
export const VPN_RPC_RPC_UNAVAILABLE_CODE: string = 'RPC_UNAVAILABLE';
export const VPN_RPC_AUTH_FAILED_RETRYABLE: boolean = false;
export const VPN_RPC_FRAME_INVALID_RETRYABLE: boolean = false;
export const VPN_RPC_PROTOCOL_MISMATCH_RETRYABLE: boolean = false;
export const VPN_RPC_RPC_UNAVAILABLE_RETRYABLE: boolean = true;
export const VPN_RPC_AUTH_FAILED_MESSAGE: string = 'VPN RPC authentication failed.';
export const VPN_RPC_FRAME_INVALID_MESSAGE: string = 'VPN RPC authenticated frame invalid.';
export const VPN_RPC_PROTOCOL_MISMATCH_MESSAGE: string = 'VPN RPC protocol mismatch.';
export const VPN_RPC_TIMEOUT_MESSAGE: string = 'VPN RPC authentication timed out.';
export const VPN_RPC_RPC_UNAVAILABLE_MESSAGE: string = 'VPN RPC unavailable.';
export const VPN_RPC_AUTH_TIMEOUT_MS: number = 3000;

export const GOLDEN_ROOT_KEY_HEX: string = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
export const GOLDEN_SERVER_NONCE_HEX: string = '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
export const GOLDEN_CLIENT_NONCE_HEX: string = '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f';
export const GOLDEN_SERVER_INSTANCE_HEX: string = '606162636465666768696a6b6c6d6e6f';
export const GOLDEN_CLIENT_EPOCH: number = 7;
export const GOLDEN_CLIENT_PROOF_HEX: string = '971120fc74215711b7de184881eb809ef8cb8bff91b23cf5452f1b3c797918d6';
export const GOLDEN_SERVER_PROOF_HEX: string = '3cb796ee27a9e40d0ee39dd41321673242dd4c25b33a3efb06fa181fabdec5cf';
export const GOLDEN_C2S_KEY_HEX: string = '17490f3b8bcfcabf9fea8acbfb448aa912d0c4c000ea6404603201571ca79f34';
export const GOLDEN_S2C_KEY_HEX: string = '547dcc95ad1dea16c6b87b305be8f228fe56e73492f5649a485dfa35223d83aa';
export const GOLDEN_SOCKET_ADDRESS: string = 'cmfa_vpn_rpc_v1_f3c721d1d7466775b7f4687f04762580';
export const GOLDEN_SOCKET_ADDRESS_HMAC_HEX: string = 'f3c721d1d7466775b7f4687f0476258068d98f7117108ba0e6d5e21eec84724b';
export const GOLDEN_FRAME_MAC_HEX: string = '483e45b6d88e7ba872ec135d4049e334acc7230c36bd60c23f39bf7fd4f28f32';
export const GOLDEN_SERVER_RESPONSE_MAC_HEX: string = '909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf';
export const GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX: string = '3132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f50';
export const GOLDEN_PROTOCOL_MISMATCH_MAC_HEX: string = '5152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70';
export const GOLDEN_WRONG_EPOCH_MAC_HEX: string = '7172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f90';
export const GOLDEN_PING_BODY_LENGTH: number = 282;
export const GOLDEN_PING_BODY_TEXT: string =
  '{"protocolVersion":1,"kind":"REQUEST","sequence":1,"clientEpoch":7,"requestOrdinal":1,"requestId":"00000000-0000-4000-8000-000000000001","method":"PING","sessionGeneration":0,"guards":{"profileHash":null,"revisionHash":null,"catalogDigest":null},"ok":null,"error":null,"payload":{}}';
export const GOLDEN_PING_BODY_HEX: string =
  '7b2270726f746f636f6c56657273696f6e223a312c226b696e64223a2252455155455354222c2273657175656e6365223a312c22636c69656e7445706f6368223a372c22726571756573744f7264696e616c223a312c22726571756573744964223a2230303030303030302d303030302d343030302d383030302d303030303030303030303031222c226d6574686f64223a2250494e47222c2273657373696f6e47656e65726174696f6e223a302c22677561726473223a7b2270726f66696c6548617368223a6e756c6c2c227265766973696f6e48617368223a6e756c6c2c22636174616c6f67446967657374223a6e756c6c7d2c226f6b223a6e756c6c2c226572726f72223a6e756c6c2c227061796c6f6164223a7b7d7d';

export const CLIENT_AUTH_INPUT_HEX: string =
  '434d46412d56504e2d5250432f434c49454e542d415554482f763100202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f';
export const SERVER_AUTH_INPUT_HEX: string =
  '434d46412d56504e2d5250432f5345525645522d415554482f763100404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f606162636465666768696a6b6c6d6e6f';
export const C2S_KEY_INPUT_HEX: string =
  '434d46412d56504e2d5250432f4332532d4b45592f763100202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f0000000000000007';
export const S2C_KEY_INPUT_HEX: string =
  '434d46412d56504e2d5250432f5332432d4b45592f763100202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f0000000000000007';
export const SOCKET_ADDRESS_INPUT_HEX: string = '636d66612d76706e2d7270632f736f636b65742d616464726573732f7631';
export const FRAME_MAC_INPUT_HEX: string =
  '434d46412d56504e2d5250432f4652414d452f7631000000011a7b2270726f746f636f6c56657273696f6e223a312c226b696e64223a2252455155455354222c2273657175656e6365223a312c22636c69656e7445706f6368223a372c22726571756573744f7264696e616c223a312c22726571756573744964223a2230303030303030302d303030302d343030302d383030302d303030303030303030303031222c226d6574686f64223a2250494e47222c2273657373696f6e47656e65726174696f6e223a302c22677561726473223a7b2270726f66696c6548617368223a6e756c6c2c227265766973696f6e48617368223a6e756c6c2c22636174616c6f67446967657374223a6e756c6c7d2c226f6b223a6e756c6c2c226572726f72223a6e756c6c2c227061796c6f6164223a7b7d7d';

function cloneBytes(bytes: Uint8Array): Uint8Array {
  return bytes.slice();
}

function decodeFixtureLowercaseHex(rawHex: string): Uint8Array {
  const result: Uint8Array = new Uint8Array(rawHex.length / 2);
  for (let index: number = 0; index < rawHex.length; index += 2) {
    const high: number = decodeFixtureHexDigit(rawHex.charCodeAt(index));
    const low: number = decodeFixtureHexDigit(rawHex.charCodeAt(index + 1));
    result[index / 2] = (high << 4) | low;
  }
  return result;
}

function decodeFixtureHexDigit(codeUnit: number): number {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  return codeUnit - 0x61 + 10;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    totalLength += parts[index].length;
  }
  const joined: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    joined.set(parts[index], offset);
    offset += parts[index].length;
  }
  return joined;
}

export function hexBytes(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += alphabet[(bytes[index] >>> 4) & 0x0f];
    result += alphabet[bytes[index] & 0x0f];
  }
  return result;
}

function requireRecord<T>(value: T | undefined, message: string): T {
  if (value === undefined) {
    throw new Error(message);
  }
  return value;
}

class FixtureCryptoMapping {
  readonly scope: 'root' | 'derived';
  readonly keyHex: string | null;
  readonly inputHex: string;
  readonly outputHex: string;

  constructor(scope: 'root' | 'derived', keyHex: string | null, inputHex: string, outputHex: string) {
    this.scope = scope;
    this.keyHex = keyHex;
    this.inputHex = inputHex;
    this.outputHex = outputHex;
  }
}

class FakeCancelableTask implements VpnRpcCancelableTaskPort {
  cancelCount: number = 0;

  cancel(): void {
    this.cancelCount += 1;
  }
}

class FakeScheduledTask {
  readonly delayMs: number;
  readonly runner: () => Promise<void>;
  readonly cancelable: FakeCancelableTask;
  runCount: number = 0;

  constructor(delayMs: number, runner: () => Promise<void>, cancelable: FakeCancelableTask) {
    this.delayMs = delayMs;
    this.runner = runner;
    this.cancelable = cancelable;
  }

  async run(): Promise<void> {
    this.runCount += 1;
    await this.runner();
  }
}

export class FixtureDeferredDerivedCall {
  readonly keyHex: string;
  readonly inputHex: string;
  private readonly resultBytes: Uint8Array;
  private resolveValue: ((value: Uint8Array) => void) | null = null;
  private rejectValue: ((error: Error) => void) | null = null;

  constructor(keyHex: string, inputHex: string, resultBytes: Uint8Array) {
    this.keyHex = keyHex;
    this.inputHex = inputHex;
    this.resultBytes = cloneBytes(resultBytes);
  }

  wait(): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve: (value: Uint8Array) => void, reject: (error: Error) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(): void {
    if (this.resolveValue !== null) {
      this.resolveValue(cloneBytes(this.resultBytes));
    }
  }

  reject(error: Error): void {
    if (this.rejectValue !== null) {
      this.rejectValue(error);
    }
  }
}

export class FixtureDeferredPrepareCall {
  private resolveValue: (() => void) | null = null;
  private rejectValue: ((error: Error) => void) | null = null;

  wait(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(): void {
    if (this.resolveValue !== null) {
      this.resolveValue();
    }
  }

  reject(error: Error): void {
    if (this.rejectValue !== null) {
      this.rejectValue(error);
    }
  }
}

export class FixtureDeferredRootCall {
  readonly inputHex: string;
  private readonly resultBytes: Uint8Array;
  private resolveValue: ((value: Uint8Array) => void) | null = null;
  private rejectValue: ((error: Error) => void) | null = null;

  constructor(inputHex: string, resultBytes: Uint8Array) {
    this.inputHex = inputHex;
    this.resultBytes = cloneBytes(resultBytes);
  }

  wait(): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve: (value: Uint8Array) => void, reject: (error: Error) => void): void => {
      this.resolveValue = resolve;
      this.rejectValue = reject;
    });
  }

  resolve(): void {
    if (this.resolveValue !== null) {
      this.resolveValue(cloneBytes(this.resultBytes));
    }
  }

  reject(error: Error): void {
    if (this.rejectValue !== null) {
      this.rejectValue(error);
    }
  }
}

export class FixtureVpnRpcCryptoPort implements VpnRpcCryptoPort {
  readonly prepareCalls: string[] = [];
  readonly rootInputsHex: string[] = [];
  readonly derivedCalls: string[] = [];
  readonly derivedKeyRefs: Uint8Array[] = [];
  readonly rootOutputs: Uint8Array[] = [];
  readonly derivedOutputs: Uint8Array[] = [];
  readonly deferredPrepareCalls: FixtureDeferredPrepareCall[] = [];
  readonly deferredRootCalls: FixtureDeferredRootCall[] = [];
  readonly deferredDerivedCalls: FixtureDeferredDerivedCall[] = [];
  readonly rootMappings: FixtureCryptoMapping[] = [];
  readonly derivedMappings: FixtureCryptoMapping[] = [];
  prepareError?: Error;
  rootHmacError?: Error;
  derivedHmacError?: Error;
  rootOutputLengthOverride?: number;
  derivedOutputLengthOverride?: number;
  deferredPrepareCallBudget: number = 0;
  deferredRootCallBudget: number = 0;
  deferredDerivedCallBudget: number = 0;

  constructor(rootMappings: FixtureCryptoMapping[], derivedMappings: FixtureCryptoMapping[]) {
    this.rootMappings = rootMappings.slice();
    this.derivedMappings = derivedMappings.slice();
  }

  addDerivedMapping(keyHex: string, inputHex: string, outputHex: string): void {
    this.derivedMappings.push(new FixtureCryptoMapping('derived', keyHex, inputHex, outputHex));
  }

  addFrameMacMapping(keyHex: string, body: VpnRpcBody, outputHex: string): void {
    this.addDerivedMapping(keyHex, hexBytes(createFrameMacInputForBody(body)), outputHex);
  }

  blockNextPrepareCalls(count: number): void {
    this.deferredPrepareCallBudget += count;
  }

  blockNextRootCalls(count: number): void {
    this.deferredRootCallBudget += count;
  }

  blockNextDerivedCalls(count: number): void {
    this.deferredDerivedCallBudget += count;
  }

  async prepare(): Promise<void> {
    this.prepareCalls.push('prepare');
    if (this.prepareError !== undefined) {
      throw this.prepareError;
    }
    if (this.deferredPrepareCallBudget > 0) {
      this.deferredPrepareCallBudget -= 1;
      const deferredCall: FixtureDeferredPrepareCall = new FixtureDeferredPrepareCall();
      this.deferredPrepareCalls.push(deferredCall);
      await deferredCall.wait();
    }
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    const inputHex: string = hexBytes(input);
    this.rootInputsHex.push(inputHex);
    if (this.rootHmacError !== undefined) {
      throw this.rootHmacError;
    }
    const mapping: FixtureCryptoMapping = requireRecord(
      this.findRootMapping(inputHex),
      'Missing root HMAC fixture mapping.'
    );
    const fullResult: Uint8Array = decodeVpnRpcLowercaseHex(mapping.outputHex);
    const returned: Uint8Array = this.rootOutputLengthOverride === undefined
      ? fullResult
      : fullResult.slice(0, this.rootOutputLengthOverride);
    this.rootOutputs.push(returned);
    if (this.deferredRootCallBudget > 0) {
      this.deferredRootCallBudget -= 1;
      const deferredCall: FixtureDeferredRootCall = new FixtureDeferredRootCall(inputHex, returned);
      this.deferredRootCalls.push(deferredCall);
      return deferredCall.wait();
    }
    return returned;
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    const keyHex: string = hexBytes(key);
    const inputHex: string = hexBytes(input);
    this.derivedCalls.push(`${keyHex}:${inputHex}`);
    this.derivedKeyRefs.push(key);
    if (this.derivedHmacError !== undefined) {
      throw this.derivedHmacError;
    }
    const mapping: FixtureCryptoMapping = requireRecord(
      this.findDerivedMapping(keyHex, inputHex),
      'Missing derived HMAC fixture mapping.'
    );
    const fullResult: Uint8Array = decodeVpnRpcLowercaseHex(mapping.outputHex);
    const returned: Uint8Array = this.derivedOutputLengthOverride === undefined
      ? fullResult
      : fullResult.slice(0, this.derivedOutputLengthOverride);
    this.derivedOutputs.push(returned);
    if (this.deferredDerivedCallBudget > 0) {
      this.deferredDerivedCallBudget -= 1;
      const deferredCall: FixtureDeferredDerivedCall = new FixtureDeferredDerivedCall(keyHex, inputHex, returned);
      this.deferredDerivedCalls.push(deferredCall);
      return deferredCall.wait();
    }
    return returned;
  }

  private findRootMapping(inputHex: string): FixtureCryptoMapping | undefined {
    for (let index: number = 0; index < this.rootMappings.length; index += 1) {
      const mapping: FixtureCryptoMapping = this.rootMappings[index];
      if (mapping.inputHex === inputHex) {
        return mapping;
      }
    }
    return undefined;
  }

  private findDerivedMapping(keyHex: string, inputHex: string): FixtureCryptoMapping | undefined {
    for (let index: number = 0; index < this.derivedMappings.length; index += 1) {
      const mapping: FixtureCryptoMapping = this.derivedMappings[index];
      if (mapping.keyHex === keyHex && mapping.inputHex === inputHex) {
        return mapping;
      }
    }
    return undefined;
  }
}

export class FixtureVpnRpcRandomPort implements VpnRpcRandomPort {
  readonly requests: number[] = [];
  readonly returnedRefs: Uint8Array[] = [];
  private readonly scripted: Uint8Array[];
  throwOnRequest: boolean = false;

  constructor(scripted: Uint8Array[]) {
    this.scripted = scripted.map((bytes: Uint8Array) => cloneBytes(bytes));
  }

  bytes(length: number): Uint8Array {
    this.requests.push(length);
    if (this.throwOnRequest) {
      throw new Error('fixture-random');
    }
    const next: Uint8Array = requireRecord(this.scripted.shift(), 'Missing scripted random bytes.');
    this.returnedRefs.push(next);
    return next;
  }
}

export class FixtureVpnRpcSchedulerPort implements VpnRpcSchedulerPort {
  readonly delays: number[] = [];
  readonly tasks: FakeScheduledTask[] = [];
  throwOnSchedule: boolean = false;

  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort {
    this.delays.push(delayMs);
    if (this.throwOnSchedule) {
      throw new Error('fixture-scheduler');
    }
    const cancelable: FakeCancelableTask = new FakeCancelableTask();
    const task: FakeScheduledTask = new FakeScheduledTask(delayMs, runner, cancelable);
    this.tasks.push(task);
    return cancelable;
  }

  latest(): FakeScheduledTask {
    return requireRecord(this.tasks[this.tasks.length - 1], 'Missing scheduled task.');
  }
}

export function createGoldenCryptoPort(): FixtureVpnRpcCryptoPort {
  return new FixtureVpnRpcCryptoPort(
    [
      new FixtureCryptoMapping('root', null, CLIENT_AUTH_INPUT_HEX, GOLDEN_CLIENT_PROOF_HEX),
      new FixtureCryptoMapping('root', null, SERVER_AUTH_INPUT_HEX, GOLDEN_SERVER_PROOF_HEX),
      new FixtureCryptoMapping('root', null, C2S_KEY_INPUT_HEX, GOLDEN_C2S_KEY_HEX),
      new FixtureCryptoMapping('root', null, S2C_KEY_INPUT_HEX, GOLDEN_S2C_KEY_HEX),
      new FixtureCryptoMapping('root', null, SOCKET_ADDRESS_INPUT_HEX, GOLDEN_SOCKET_ADDRESS_HMAC_HEX)
    ],
    [
      new FixtureCryptoMapping('derived', GOLDEN_C2S_KEY_HEX, FRAME_MAC_INPUT_HEX, GOLDEN_FRAME_MAC_HEX)
    ]
  );
}

export function createGoldenClientRandomPort(): FixtureVpnRpcRandomPort {
  return new FixtureVpnRpcRandomPort([decodeVpnRpcLowercaseHex(GOLDEN_CLIENT_NONCE_HEX)]);
}

export function createGoldenServerRandomPort(): FixtureVpnRpcRandomPort {
  return new FixtureVpnRpcRandomPort([
    decodeVpnRpcLowercaseHex(GOLDEN_SERVER_NONCE_HEX),
    decodeVpnRpcLowercaseHex(GOLDEN_SERVER_INSTANCE_HEX)
  ]);
}

export function createGoldenNullGuards() {
  return createVpnRpcGuards(null, null, null);
}

export function createPingRequestBody(
  sequence: number,
  requestOrdinal: number = sequence,
  requestId: string = createRequestId(sequence),
  clientEpoch: number = GOLDEN_CLIENT_EPOCH
): VpnRpcBody {
  return createVpnRpcBodyRequest(
    sequence,
    clientEpoch,
    requestOrdinal,
    requestId,
    'PING',
    0,
    createGoldenNullGuards(),
    createVpnRpcEmptyPayload()
  );
}

export type FixtureOutgoingBodyBuilder = (sequence: number, clientEpoch: number) => VpnRpcBody;

export function createAppendixABodyBuilder(): FixtureOutgoingBodyBuilder {
  return (sequence: number, clientEpoch: number): VpnRpcBody =>
    createPingRequestBody(sequence, 1, '00000000-0000-4000-8000-000000000001', clientEpoch);
}

export function createPingRequestBuilder(
  requestOrdinal: number,
  requestId: string
): FixtureOutgoingBodyBuilder {
  return (sequence: number, clientEpoch: number): VpnRpcBody =>
    createPingRequestBody(sequence, requestOrdinal, requestId, clientEpoch);
}

export function createPingResponseBuilder(
  requestOrdinal: number,
  requestId: string
): FixtureOutgoingBodyBuilder {
  return (sequence: number, clientEpoch: number): VpnRpcBody =>
    createPingResponseBody(sequence, requestOrdinal, requestId, clientEpoch);
}

export function createPingResponseBody(
  sequence: number,
  requestOrdinal: number = sequence,
  requestId: string = createRequestId(requestOrdinal),
  clientEpoch: number = GOLDEN_CLIENT_EPOCH
): VpnRpcBody {
  return createVpnRpcBodySuccessResponse(
    sequence,
    clientEpoch,
    requestOrdinal,
    requestId,
    'PING',
    0,
    createGoldenNullGuards(),
    createVpnRpcPingSuccessPayload(GOLDEN_SERVER_INSTANCE_HEX)
  );
}

function createRequestId(ordinal: number): string {
  const suffix: string = `${ordinal}`.padStart(12, '0');
  return `00000000-0000-4000-8000-${suffix}`;
}

export function createAppendixARequestBody(): VpnRpcBody {
  return createPingRequestBody(1, 1, '00000000-0000-4000-8000-000000000001', GOLDEN_CLIENT_EPOCH);
}

export function createGoldenServerHello(): VpnRpcServerHelloBody {
  return createVpnRpcServerHelloBody(1, GOLDEN_SERVER_NONCE_HEX, GOLDEN_SERVER_INSTANCE_HEX);
}

export function createGoldenClientAuth(): VpnRpcClientAuthBody {
  return createVpnRpcClientAuthBody(1, GOLDEN_CLIENT_NONCE_HEX, GOLDEN_CLIENT_PROOF_HEX);
}

export function createGoldenServerAuth(epoch: number = GOLDEN_CLIENT_EPOCH): VpnRpcServerAuthBody {
  return createVpnRpcServerAuthBody(1, epoch, GOLDEN_SERVER_PROOF_HEX);
}

export function createMutatedMacBytesFirstByte(): Uint8Array {
  const mutated: Uint8Array = decodeVpnRpcLowercaseHex(GOLDEN_FRAME_MAC_HEX);
  mutated[0] ^= 0xff;
  return mutated;
}

export function createMutatedMacBytesLastByte(): Uint8Array {
  const mutated: Uint8Array = decodeVpnRpcLowercaseHex(GOLDEN_FRAME_MAC_HEX);
  mutated[mutated.length - 1] ^= 0xff;
  return mutated;
}

export function createMutatedProofFirstByte(rawHex: string): string {
  const bytes: Uint8Array = decodeVpnRpcLowercaseHex(rawHex);
  bytes[0] ^= 0xff;
  return hexBytes(bytes);
}

export function createMutatedProofLastByte(rawHex: string): string {
  const bytes: Uint8Array = decodeVpnRpcLowercaseHex(rawHex);
  bytes[bytes.length - 1] ^= 0xff;
  return hexBytes(bytes);
}

export function createFrameMacInputForBody(body: VpnRpcBody): Uint8Array {
  const bodyBytes: Uint8Array = encodeVpnRpcBody(body);
  return createFrameMacInputForBytes(bodyBytes);
}

export function createFrameMacInputForBytes(bodyBytes: Uint8Array): Uint8Array {
  return concatBytes([
    encodeVpnRpcUtf8('CMFA-VPN-RPC/FRAME/v1'),
    new Uint8Array([0x00]),
    encodeVpnRpcU32BE(bodyBytes.length),
    bodyBytes
  ]);
}

export function createAppendixABodyBytes(): Uint8Array {
  return decodeFixtureLowercaseHex(GOLDEN_PING_BODY_HEX);
}

export function createProtocolMismatchBodyBytes(): Uint8Array {
  return encodeVpnRpcUtf8(GOLDEN_PING_BODY_TEXT.replace('"protocolVersion":1', '"protocolVersion":2'));
}

export function createInvalidJsonBodyBytes(): Uint8Array {
  return encodeVpnRpcUtf8('{"protocolVersion":1');
}

export function createGoldenContractSummary(): string {
  return [
    GOLDEN_SOCKET_ADDRESS,
    GOLDEN_CLIENT_PROOF_HEX,
    GOLDEN_SERVER_PROOF_HEX,
    GOLDEN_C2S_KEY_HEX,
    GOLDEN_S2C_KEY_HEX,
    GOLDEN_FRAME_MAC_HEX,
    GOLDEN_PING_BODY_TEXT
  ].join('|');
}
