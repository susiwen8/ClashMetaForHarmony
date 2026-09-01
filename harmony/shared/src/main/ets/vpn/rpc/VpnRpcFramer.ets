import { decodeVpnRpcU32BE } from './VpnRpcBinaryCodec';

const FRAME_HEADER_BYTES: number = 4;
const FRAME_MAC_BYTES: number = 32;
const MAX_FRAME_BODY_BYTES: number = 262144;
const MAX_PREAUTH_BUFFERED_BYTES: number = FRAME_HEADER_BYTES + MAX_FRAME_BODY_BYTES;
const MAX_AUTHENTICATED_BUFFERED_BYTES: number = FRAME_HEADER_BYTES + MAX_FRAME_BODY_BYTES + FRAME_MAC_BYTES;
const MAX_SCRATCH_BYTES: number = MAX_AUTHENTICATED_BUFFERED_BYTES;

function failFrame(): never {
  throw new Error('Invalid VPN RPC frame.');
}

function safeBufferedLimit(authenticated: boolean): number {
  return authenticated ? MAX_AUTHENTICATED_BUFFERED_BYTES : MAX_PREAUTH_BUFFERED_BYTES;
}

function copyBytes(bytes: Uint8Array, start: number, end: number): Uint8Array {
  return bytes.slice(start, end);
}

function wipeBytes(bytes: Uint8Array, start: number, end: number): void {
  for (let index: number = start; index < end; index += 1) {
    bytes[index] = 0;
  }
}

function readU32BEAt(bytes: Uint8Array, offset: number): number {
  return (
    ((bytes[offset] * 0x1000000) >>> 0) +
    ((bytes[offset + 1] << 16) >>> 0) +
    ((bytes[offset + 2] << 8) >>> 0) +
    bytes[offset + 3]
  ) >>> 0;
}

class VpnRpcDecodedFrameValue implements VpnRpcDecodedFrame {
  bodyBytes: Uint8Array;
  macBytes: Uint8Array | null;

  constructor(bodyBytes: Uint8Array, macBytes: Uint8Array | null) {
    this.bodyBytes = bodyBytes;
    this.macBytes = macBytes;
  }
}

export interface VpnRpcDecodedFrame {
  bodyBytes: Uint8Array;
  macBytes: Uint8Array | null;
}

export class VpnRpcFramer {
  private scratchBytes: Uint8Array = new Uint8Array(MAX_SCRATCH_BYTES);
  private readOffset: number = 0;
  private writeOffset: number = 0;
  private bufferedAuthenticated: boolean | null = null;

  push(chunk: Uint8Array, authenticated: boolean): VpnRpcDecodedFrame[] {
    try {
      if (this.bufferedLength() > 0 && this.bufferedAuthenticated !== authenticated) {
        this.reset();
        failFrame();
      }
      if (this.bufferedLength() === 0) {
        this.bufferedAuthenticated = authenticated;
      }
      this.requireBufferedCapacityBeforeAppend(chunk.length, authenticated);
      this.appendChunk(chunk);
      this.enforceBufferedLimit(authenticated);

      const frames: VpnRpcDecodedFrame[] = [];
      while (true) {
        if (this.bufferedLength() < FRAME_HEADER_BYTES) {
          return frames;
        }
        const bodyLength: number = readU32BEAt(this.scratchBytes, this.readOffset);
        if (bodyLength <= 0 || bodyLength > MAX_FRAME_BODY_BYTES) {
          this.reset();
          failFrame();
        }
        const trailerLength: number = authenticated ? FRAME_MAC_BYTES : 0;
        const frameLength: number = FRAME_HEADER_BYTES + bodyLength + trailerLength;
        if (frameLength > this.maxBufferedBytes(authenticated)) {
          this.reset();
          failFrame();
        }
        if (this.bufferedLength() < frameLength) {
          return frames;
        }

        const frameStart: number = this.readOffset;
        const bodyStart: number = frameStart + FRAME_HEADER_BYTES;
        const bodyEnd: number = bodyStart + bodyLength;
        const frameEnd: number = bodyEnd + trailerLength;
        const bodyBytes: Uint8Array = copyBytes(this.scratchBytes, bodyStart, bodyEnd);
        const macBytes: Uint8Array | null = authenticated
          ? copyBytes(this.scratchBytes, bodyEnd, frameEnd)
          : null;
        frames.push(new VpnRpcDecodedFrameValue(bodyBytes, macBytes));
        wipeBytes(this.scratchBytes, frameStart, frameEnd);
        this.readOffset = frameEnd;
        if (this.readOffset === this.writeOffset) {
          this.readOffset = 0;
          this.writeOffset = 0;
          this.bufferedAuthenticated = null;
          return frames;
        }
      }
    } catch (error) {
      this.reset();
      if (error instanceof Error) {
        throw error;
      }
      failFrame();
    }
  }

  finish(): void {
    if (this.bufferedLength() === 0) {
      this.reset();
      return;
    }
    this.reset();
    failFrame();
  }

  reset(): void {
    wipeBytes(this.scratchBytes, 0, this.writeOffset);
    this.readOffset = 0;
    this.writeOffset = 0;
    this.bufferedAuthenticated = null;
  }

  private enforceBufferedLimit(authenticated: boolean): void {
    if (this.bufferedLength() > this.maxBufferedBytes(authenticated)) {
      this.reset();
      failFrame();
    }
  }

  private requireBufferedCapacityBeforeAppend(chunkLength: number, authenticated: boolean): void {
    const limit: number = this.maxBufferedBytes(authenticated);
    const bufferedLength: number = this.bufferedLength();
    if (!Number.isSafeInteger(chunkLength) || chunkLength < 0) {
      this.reset();
      failFrame();
    }
    if (bufferedLength > limit || chunkLength > limit) {
      this.reset();
      failFrame();
    }
    if (bufferedLength > Number.MAX_SAFE_INTEGER - chunkLength) {
      this.reset();
      failFrame();
    }
    const nextLength: number = bufferedLength + chunkLength;
    if (nextLength > limit) {
      this.reset();
      failFrame();
    }
  }

  private appendChunk(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    if (this.scratchBytes.length - this.writeOffset < chunk.length && this.readOffset > 0) {
      this.compactUnreadBytes();
    }
    if (this.scratchBytes.length - this.writeOffset < chunk.length) {
      this.reset();
      failFrame();
    }
    this.scratchBytes.set(chunk, this.writeOffset);
    this.writeOffset += chunk.length;
  }

  private compactUnreadBytes(): void {
    const unreadLength: number = this.bufferedLength();
    for (let index: number = 0; index < unreadLength; index += 1) {
      this.scratchBytes[index] = this.scratchBytes[this.readOffset + index];
    }
    wipeBytes(this.scratchBytes, unreadLength, this.writeOffset);
    this.readOffset = 0;
    this.writeOffset = unreadLength;
  }

  private bufferedLength(): number {
    return this.writeOffset - this.readOffset;
  }

  private maxBufferedBytes(authenticated: boolean): number {
    return safeBufferedLimit(authenticated);
  }
}
