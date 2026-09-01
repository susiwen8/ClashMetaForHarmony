import { socket } from '@kit.NetworkKit';
import {
  createVpnRpcSocketFailure,
  type VpnRpcSocketClientFactoryPort,
  type VpnRpcSocketConnectionPort
} from '@cmfa/shared';

const CONNECT_REFUSED_ERROR_CODE: number = 2301111;
const SDK_BOUNDARY_FAILURE_CODE: number = 0;
const SDK_BOUNDARY_FAILURE_MESSAGE: string = 'VPN RPC local socket SDK call failed.';
const MAX_LOCAL_SOCKET_ADDRESS_LENGTH: number = 107;

export interface HarmonyVpnLocalSocketMessageInfoPort {
  readonly message: ArrayBuffer;
  readonly size: number;
  readonly address?: string;
}

export interface HarmonyVpnLocalSocketSendOptionsPort {
  readonly data: ArrayBuffer;
}

export interface HarmonyVpnLocalSocketConnectOptionsPort {
  readonly address: string;
  readonly timeoutMs: number;
}

export interface HarmonyVpnLocalSocketConnectionDriver {
  send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void>;
  close(): Promise<void>;
  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void;
  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void;
  onClose(callback: () => void): void;
  offClose(callback?: () => void): void;
  onError(callback: () => void): void;
  offError(callback?: () => void): void;
}

export interface HarmonyVpnLocalSocketClientDriver extends HarmonyVpnLocalSocketConnectionDriver {
  connect(options: HarmonyVpnLocalSocketConnectOptionsPort): Promise<void>;
  onConnect(callback: () => void): void;
  offConnect(callback?: () => void): void;
}

export interface HarmonyVpnLocalSocketClientDriverFactory {
  create(): HarmonyVpnLocalSocketClientDriver;
}

export class HarmonyVpnLocalSocketConnectionAdapter implements VpnRpcSocketConnectionPort {
  private readonly raw: HarmonyVpnLocalSocketConnectionDriver;
  private readonly dataListeners: Map<number, (bytes: Uint8Array) => void> = new Map<number, (bytes: Uint8Array) => void>();
  private readonly closeListeners: Map<number, () => void> = new Map<number, () => void>();
  private readonly errorListeners: Map<number, () => void> = new Map<number, () => void>();
  private readonly rawMessageListener: (info: HarmonyVpnLocalSocketMessageInfoPort) => void;
  private readonly rawCloseListener: () => void;
  private readonly rawErrorListener: () => void;
  private nextListenerId: number = 1;
  private sendTail: Promise<void> = Promise.resolve();
  private closePromise?: Promise<void>;
  private closed: boolean = false;
  private rawListenersRemoved: boolean = false;

  constructor(raw: HarmonyVpnLocalSocketConnectionDriver) {
    this.raw = raw;
    this.rawMessageListener = (info: HarmonyVpnLocalSocketMessageInfoPort): void => {
      this.handleMessage(info);
    };
    this.rawCloseListener = (): void => {
      this.finishTerminal(false, false);
    };
    this.rawErrorListener = (): void => {
      this.finishTerminal(true, true);
    };
    this.registerRawListeners();
  }

  async send(bytes: Uint8Array): Promise<void> {
    if (this.closed) {
      throw createVpnRpcSocketFailure('CLOSED');
    }
    const payload: Uint8Array = copyBytes(bytes);
    const payloadBuffer: ArrayBuffer = new ArrayBuffer(payload.length);
    new Uint8Array(payloadBuffer).set(payload);
    const sendPromise: Promise<void> = this.sendTail
      .catch((): void => {
      })
      .then(async (): Promise<void> => {
        if (this.closed) {
          throw createVpnRpcSocketFailure('CLOSED');
        }
        try {
          await this.raw.send(new HarmonyVpnLocalSocketSendOptionsRecord(payloadBuffer));
        } catch (_) {
          throw createVpnRpcSocketFailure('SEND_FAILED');
        } finally {
          zeroBytes(payload);
          zeroArrayBuffer(payloadBuffer);
        }
      });
    this.sendTail = sendPromise.then(
      (): void => {
      },
      (): void => {
      }
    );
    return await sendPromise;
  }

  subscribeData(listener: (bytes: Uint8Array) => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    if (!this.closed) {
      this.dataListeners.set(id, listener);
    }
    return id;
  }

  unsubscribeData(id: number): void {
    this.dataListeners.delete(id);
  }

  subscribeClose(listener: () => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    if (!this.closed) {
      this.closeListeners.set(id, listener);
    }
    return id;
  }

  unsubscribeClose(id: number): void {
    this.closeListeners.delete(id);
  }

  subscribeError(listener: () => void): number {
    const id: number = this.nextListenerId;
    this.nextListenerId += 1;
    if (!this.closed) {
      this.errorListeners.set(id, listener);
    }
    return id;
  }

  unsubscribeError(id: number): void {
    this.errorListeners.delete(id);
  }

  async close(): Promise<void> {
    this.finishTerminal(false, true);
    await this.ensureRawClosed();
  }

  private registerRawListeners(): void {
    let messageRegistered: boolean = false;
    let closeRegistered: boolean = false;
    try {
      this.raw.onMessage(this.rawMessageListener);
      messageRegistered = true;
      this.raw.onClose(this.rawCloseListener);
      closeRegistered = true;
      this.raw.onError(this.rawErrorListener);
    } catch (_) {
      if (messageRegistered) {
        this.safeOffMessage();
      }
      if (closeRegistered) {
        this.safeOffClose();
      }
      this.safeOffError();
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
  }

  private handleMessage(info: HarmonyVpnLocalSocketMessageInfoPort): void {
    if (this.closed) {
      return;
    }
    const copied: Uint8Array | null = readOwnedMessage(info);
    if (copied === null) {
      this.finishTerminal(true, true);
      return;
    }
    const listeners: Array<(bytes: Uint8Array) => void> = Array.from(this.dataListeners.values());
    for (let index: number = 0; index < listeners.length; index += 1) {
      try {
        listeners[index](copyBytes(copied));
      } catch (_) {
      }
    }
    zeroBytes(copied);
  }

  private finishTerminal(notifyError: boolean, closeRaw: boolean): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.removeRawListenersOnce();
    if (closeRaw) {
      void this.ensureRawClosed();
    }
    if (notifyError) {
      this.dispatchTerminalListeners(this.errorListeners);
    }
    this.dispatchTerminalListeners(this.closeListeners);
    this.dataListeners.clear();
    this.closeListeners.clear();
    this.errorListeners.clear();
  }

  private dispatchTerminalListeners(listeners: Map<number, () => void>): void {
    const callbacks: Array<() => void> = Array.from(listeners.values());
    for (let index: number = 0; index < callbacks.length; index += 1) {
      try {
        callbacks[index]();
      } catch (_) {
      }
    }
  }

  private removeRawListenersOnce(): void {
    if (this.rawListenersRemoved) {
      return;
    }
    this.rawListenersRemoved = true;
    this.safeOffMessage();
    this.safeOffClose();
    this.safeOffError();
  }

  private safeOffMessage(): void {
    try {
      this.raw.offMessage(this.rawMessageListener);
    } catch (_) {
    }
  }

  private safeOffClose(): void {
    try {
      this.raw.offClose(this.rawCloseListener);
    } catch (_) {
    }
  }

  private safeOffError(): void {
    try {
      this.raw.offError(this.rawErrorListener);
    } catch (_) {
    }
  }

  private ensureRawClosed(): Promise<void> {
    if (this.closePromise !== undefined) {
      return this.closePromise;
    }
    this.closePromise = this.closeRawSafely();
    return this.closePromise;
  }

  private async closeRawSafely(): Promise<void> {
    try {
      await this.raw.close();
    } catch (_) {
    }
  }
}

export class HarmonyVpnLocalSocketClient implements VpnRpcSocketClientFactoryPort {
  private readonly driverFactory: HarmonyVpnLocalSocketClientDriverFactory;
  private readonly socketRootDir: string;

  constructor(driverFactory?: HarmonyVpnLocalSocketClientDriverFactory, socketRootDir: string = '') {
    this.driverFactory = driverFactory ?? new HarmonyVpnSdkLocalSocketClientDriverFactory();
    this.socketRootDir = socketRootDir;
  }

  async connect(address: string, timeoutMs: number): Promise<VpnRpcSocketConnectionPort> {
    if (!isValidSocketAddress(address) || !isValidTimeout(timeoutMs)) {
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
    const resolvedAddress: string = resolveLocalSocketAddress(this.socketRootDir, address);
    let raw: HarmonyVpnLocalSocketClientDriver | null = null;
    let connection: HarmonyVpnLocalSocketConnectionAdapter | null = null;
    try {
      raw = this.driverFactory.create();
      connection = new HarmonyVpnLocalSocketConnectionAdapter(new HarmonyVpnLocalSocketClientConnectionDriverView(raw));
      await raw.connect(new HarmonyVpnLocalSocketConnectOptionsRecord(
        resolvedAddress,
        timeoutMs
      ));
      return connection;
    } catch (error) {
      if (connection !== null) {
        await connection.close();
      } else if (raw !== null) {
        await safeCloseClient(raw);
      }
      throw mapConnectFailure(error instanceof Error ? error : new Error(SDK_BOUNDARY_FAILURE_MESSAGE));
    }
  }
}

export class HarmonyVpnSdkLocalSocketConnectionDriver implements HarmonyVpnLocalSocketConnectionDriver {
  private readonly raw: socket.LocalSocket | socket.LocalSocketConnection;
  private readonly messageBindings: Map<(info: HarmonyVpnLocalSocketMessageInfoPort) => void, (info: socket.LocalSocketMessageInfo) => void> =
    new Map<(info: HarmonyVpnLocalSocketMessageInfoPort) => void, (info: socket.LocalSocketMessageInfo) => void>();
  private readonly closeBindings: Map<() => void, () => void> = new Map<() => void, () => void>();
  private readonly errorBindings: Map<() => void, (error: Error) => void> = new Map<() => void, (error: Error) => void>();

  constructor(raw: socket.LocalSocket | socket.LocalSocketConnection) {
    this.raw = raw;
  }

  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    try {
      await this.raw.send(new HarmonyVpnSdkLocalSocketSendOptionsRecord(options.data));
    } catch (error) {
      throw createSdkBoundaryFailure(readBusinessErrorCarrier(error));
    }
  }

  async close(): Promise<void> {
    try {
      await this.raw.close();
    } catch (error) {
      throw createSdkBoundaryFailure(readBusinessErrorCarrier(error));
    }
  }

  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    const sdkCallback = (info: socket.LocalSocketMessageInfo): void => {
      callback(new HarmonyVpnSdkLocalSocketMessageInfoRecord(info.message, info.size, info.address));
    };
    this.messageBindings.set(callback, sdkCallback);
    this.raw.on('message', sdkCallback);
  }

  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    if (callback === undefined) {
      this.messageBindings.clear();
      this.raw.off('message');
      return;
    }
    const binding = this.messageBindings.get(callback);
    this.messageBindings.delete(callback);
    this.raw.off('message', binding);
  }

  onClose(callback: () => void): void {
    const sdkCallback = (): void => {
      callback();
    };
    this.closeBindings.set(callback, sdkCallback);
    this.raw.on('close', sdkCallback);
  }

  offClose(callback?: () => void): void {
    if (callback === undefined) {
      this.closeBindings.clear();
      this.raw.off('close');
      return;
    }
    const binding = this.closeBindings.get(callback);
    this.closeBindings.delete(callback);
    this.raw.off('close', binding);
  }

  onError(callback: () => void): void {
    const sdkCallback = (_: Error): void => {
      callback();
    };
    this.errorBindings.set(callback, sdkCallback);
    this.raw.on('error', sdkCallback);
  }

  offError(callback?: () => void): void {
    if (callback === undefined) {
      this.errorBindings.clear();
      this.raw.off('error');
      return;
    }
    const binding = this.errorBindings.get(callback);
    this.errorBindings.delete(callback);
    this.raw.off('error', binding);
  }
}

class HarmonyVpnSdkLocalSocketClientDriverFactory implements HarmonyVpnLocalSocketClientDriverFactory {
  create(): HarmonyVpnLocalSocketClientDriver {
    return new HarmonyVpnSdkLocalSocketClientDriver(socket.constructLocalSocketInstance());
  }
}

class HarmonyVpnSdkLocalSocketClientDriver extends HarmonyVpnSdkLocalSocketConnectionDriver implements HarmonyVpnLocalSocketClientDriver {
  private readonly rawClient: socket.LocalSocket;
  private readonly connectBindings: Map<() => void, () => void> = new Map<() => void, () => void>();

  constructor(rawClient: socket.LocalSocket) {
    super(rawClient);
    this.rawClient = rawClient;
  }

  async connect(options: HarmonyVpnLocalSocketConnectOptionsPort): Promise<void> {
    try {
      await this.rawClient.connect(new HarmonyVpnSdkLocalSocketConnectOptionsRecord(options.address, options.timeoutMs));
    } catch (error) {
      throw createSdkBoundaryFailure(readBusinessErrorCarrier(error));
    }
  }

  onConnect(callback: () => void): void {
    const sdkCallback = (): void => {
      callback();
    };
    this.connectBindings.set(callback, sdkCallback);
    this.rawClient.on('connect', sdkCallback);
  }

  offConnect(callback?: () => void): void {
    if (callback === undefined) {
      this.connectBindings.clear();
      this.rawClient.off('connect');
      return;
    }
    const binding = this.connectBindings.get(callback);
    this.connectBindings.delete(callback);
    this.rawClient.off('connect', binding);
  }
}

class HarmonyVpnLocalSocketSendOptionsRecord implements HarmonyVpnLocalSocketSendOptionsPort {
  readonly data: ArrayBuffer;

  constructor(data: ArrayBuffer) {
    this.data = data;
  }
}

class HarmonyVpnLocalSocketConnectOptionsRecord implements HarmonyVpnLocalSocketConnectOptionsPort {
  readonly address: string;
  readonly timeoutMs: number;

  constructor(address: string, timeoutMs: number) {
    this.address = address;
    this.timeoutMs = timeoutMs;
  }
}

class HarmonyVpnLocalSocketClientConnectionDriverView implements HarmonyVpnLocalSocketConnectionDriver {
  private readonly raw: HarmonyVpnLocalSocketClientDriver;

  constructor(raw: HarmonyVpnLocalSocketClientDriver) {
    this.raw = raw;
  }

  async send(options: HarmonyVpnLocalSocketSendOptionsPort): Promise<void> {
    await this.raw.send(options);
  }

  async close(): Promise<void> {
    await this.raw.close();
  }

  onMessage(callback: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.raw.onMessage(callback);
  }

  offMessage(callback?: (info: HarmonyVpnLocalSocketMessageInfoPort) => void): void {
    this.raw.offMessage(callback);
  }

  onClose(callback: () => void): void {
    this.raw.onClose(callback);
  }

  offClose(callback?: () => void): void {
    this.raw.offClose(callback);
  }

  onError(callback: () => void): void {
    this.raw.onError(callback);
  }

  offError(callback?: () => void): void {
    this.raw.offError(callback);
  }
}

class HarmonyVpnSdkLocalSocketMessageInfoRecord implements HarmonyVpnLocalSocketMessageInfoPort {
  readonly message: ArrayBuffer;
  readonly size: number;
  readonly address?: string;

  constructor(message: ArrayBuffer, size: number, address?: string) {
    this.message = message;
    this.size = size;
    this.address = address;
  }
}

class HarmonyVpnSdkLocalAddressRecord implements socket.LocalAddress {
  readonly address: string;

  constructor(address: string) {
    this.address = address;
  }
}

class HarmonyVpnSdkLocalSocketConnectOptionsRecord implements socket.LocalConnectOptions {
  readonly address: socket.LocalAddress;
  readonly timeout?: number;

  constructor(address: string, timeoutMs: number) {
    this.address = new HarmonyVpnSdkLocalAddressRecord(address);
    this.timeout = timeoutMs;
  }
}

class HarmonyVpnSdkLocalSocketSendOptionsRecord implements socket.LocalSendOptions {
  readonly data: ArrayBuffer;
  readonly encoding?: string;

  constructor(data: ArrayBuffer) {
    this.data = data;
    this.encoding = undefined;
  }
}

export function resolveLocalSocketAddress(rootDir: string, address: string): string {
  if (!isValidSocketAddress(address)) {
    throw createVpnRpcSocketFailure('PLATFORM_FAILED');
  }
  const normalizedRootDir: string = normalizeSocketRootDir(rootDir);
  if (normalizedRootDir.length === 0) {
    if (rootDir.length > 0) {
      throw createVpnRpcSocketFailure('PLATFORM_FAILED');
    }
    return address;
  }
  const resolvedAddress: string = `${normalizedRootDir}/${address}`;
  if (resolvedAddress.length > MAX_LOCAL_SOCKET_ADDRESS_LENGTH) {
    throw createVpnRpcSocketFailure('PLATFORM_FAILED');
  }
  return resolvedAddress;
}

function normalizeSocketRootDir(rootDir: string): string {
  if (rootDir.length === 0) {
    return '';
  }
  let end: number = rootDir.length;
  while (end > 0 && rootDir.charCodeAt(end - 1) === 0x2f) {
    end -= 1;
  }
  const normalized: string = end === rootDir.length ? rootDir : rootDir.slice(0, end);
  if (normalized.length === 0 || normalized.charCodeAt(0) !== 0x2f || normalized.includes('//')) {
    return '';
  }
  const segments: string[] = normalized.split('/');
  for (let index: number = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    if (segment === '.' || segment === '..') {
      return '';
    }
    for (let characterIndex: number = 0; characterIndex < segment.length; characterIndex += 1) {
      const code: number = segment.charCodeAt(characterIndex);
      if (code <= 0x20 || code === 0x7f) {
        return '';
      }
    }
  }
  return normalized;
}

function isValidSocketAddress(address: string): boolean {
  if (address.length === 0 || address.length > 64) {
    return false;
  }
  for (let index: number = 0; index < address.length; index += 1) {
    const code: number = address.charCodeAt(index);
    const digit: boolean = code >= 0x30 && code <= 0x39;
    const upper: boolean = code >= 0x41 && code <= 0x5a;
    const underscore: boolean = code === 0x5f;
    const lower: boolean = code >= 0x61 && code <= 0x7a;
    if (!digit && !upper && !underscore && !lower) {
      return false;
    }
  }
  return true;
}

function isValidTimeout(timeoutMs: number): boolean {
  return Number.isSafeInteger(timeoutMs) && timeoutMs > 0;
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index: number = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function zeroBytes(bytes: Uint8Array): void {
  bytes.fill(0);
}

function zeroArrayBuffer(buffer: ArrayBuffer): void {
  new Uint8Array(buffer).fill(0);
}

function readOwnedMessage(info: HarmonyVpnLocalSocketMessageInfoPort): Uint8Array | null {
  if (!Number.isSafeInteger(info.size) || info.size < 0) {
    return null;
  }
  const rawBytes = new Uint8Array(info.message);
  if (info.size > rawBytes.length) {
    return null;
  }
  const copy = new Uint8Array(info.size);
  for (let index: number = 0; index < info.size; index += 1) {
    copy[index] = rawBytes[index];
  }
  return copy;
}

function mapConnectFailure(error: Error): Error {
  if (error instanceof HarmonyVpnLocalSocketSdkBoundaryFailure && error.code === CONNECT_REFUSED_ERROR_CODE) {
    return createVpnRpcSocketFailure('CONNECT_REFUSED');
  }
  const directCode: number = readBusinessErrorCode(readBusinessErrorCarrier(error));
  if (directCode === CONNECT_REFUSED_ERROR_CODE) {
    return createVpnRpcSocketFailure('CONNECT_REFUSED');
  }
  return createVpnRpcSocketFailure('PLATFORM_FAILED');
}

async function safeCloseClient(connection: HarmonyVpnLocalSocketClientDriver): Promise<void> {
  try {
    await connection.close();
  } catch (_) {
  }
}

function createSdkBoundaryFailure(error: BusinessErrorCarrier | undefined): HarmonyVpnLocalSocketSdkBoundaryFailure {
  return new HarmonyVpnLocalSocketSdkBoundaryFailure(readBusinessErrorCode(error));
}

function readBusinessErrorCarrier(error: Error | object | undefined): BusinessErrorCarrier | undefined {
  if (error === undefined || typeof error !== 'object') {
    return undefined;
  }
  return error as BusinessErrorCarrier;
}

class HarmonyVpnLocalSocketSdkBoundaryFailure extends Error {
  readonly code: number;

  constructor(code: number) {
    super(SDK_BOUNDARY_FAILURE_MESSAGE);
    this.code = code;
  }
}

interface BusinessErrorCarrier {
  code?: number;
}

function readBusinessErrorCode(error: BusinessErrorCarrier | undefined): number {
  if (error === undefined || error.code === undefined || !Number.isSafeInteger(error.code)) {
    return SDK_BOUNDARY_FAILURE_CODE;
  }
  return error.code;
}
