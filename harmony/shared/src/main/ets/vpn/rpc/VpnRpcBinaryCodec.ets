const MAX_U16_VALUE: number = 0xffff;
const MAX_U32_VALUE: number = 0xffffffff;
const MAX_SAFE_U64_VALUE: number = Number.MAX_SAFE_INTEGER;
const MAX_FRAME_BODY_BYTES: number = 262144;

function failBinary(): never {
  throw new Error('Invalid VPN RPC binary.');
}

function requireIntegerInRange(value: number, min: number, max: number): number {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    failBinary();
  }
  return value;
}

function requireExactByteLength(bytes: Uint8Array, expectedLength: number): Uint8Array {
  if (bytes.length !== expectedLength) {
    failBinary();
  }
  return bytes;
}

function requireMaxByteLength(maxByteLength: number): number {
  if (!Number.isSafeInteger(maxByteLength) || maxByteLength < 0) {
    failBinary();
  }
  return maxByteLength;
}

function isLowercaseHexCode(codeUnit: number): boolean {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) || (codeUnit >= 0x61 && codeUnit <= 0x66);
}

function decodeHexDigit(codeUnit: number): number {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) {
    return codeUnit - 0x30;
  }
  if (codeUnit >= 0x61 && codeUnit <= 0x66) {
    return codeUnit - 0x61 + 10;
  }
  failBinary();
}

function appendUtf8Bytes(codePoint: number, bytes: number[]): void {
  if (codePoint <= 0x7f) {
    bytes.push(codePoint);
    return;
  }
  if (codePoint <= 0x7ff) {
    bytes.push(0xc0 | (codePoint >>> 6));
    bytes.push(0x80 | (codePoint & 0x3f));
    return;
  }
  if (codePoint <= 0xffff) {
    bytes.push(0xe0 | (codePoint >>> 12));
    bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
    bytes.push(0x80 | (codePoint & 0x3f));
    return;
  }
  bytes.push(0xf0 | (codePoint >>> 18));
  bytes.push(0x80 | ((codePoint >>> 12) & 0x3f));
  bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
  bytes.push(0x80 | (codePoint & 0x3f));
}

function appendScalarText(codePoint: number, pieces: string[]): void {
  if (codePoint <= 0xffff) {
    pieces.push(String.fromCharCode(codePoint));
    return;
  }
  const normalized: number = codePoint - 0x10000;
  const high: number = 0xd800 + (normalized >>> 10);
  const low: number = 0xdc00 + (normalized & 0x3ff);
  pieces.push(String.fromCharCode(high));
  pieces.push(String.fromCharCode(low));
}

function encodeUtf8Unchecked(text: string): Uint8Array {
  const byteValues: number[] = [];
  for (let index: number = 0; index < text.length; index += 1) {
    const firstUnit: number = text.charCodeAt(index);
    if (firstUnit === 0 || (index === 0 && firstUnit === 0xfeff)) {
      failBinary();
    }
    if (firstUnit >= 0xd800 && firstUnit <= 0xdbff) {
      if (index + 1 >= text.length) {
        failBinary();
      }
      const secondUnit: number = text.charCodeAt(index + 1);
      if (secondUnit < 0xdc00 || secondUnit > 0xdfff) {
        failBinary();
      }
      const codePoint: number = (((firstUnit - 0xd800) << 10) | (secondUnit - 0xdc00)) + 0x10000;
      appendUtf8Bytes(codePoint, byteValues);
      index += 1;
      continue;
    }
    if (firstUnit >= 0xdc00 && firstUnit <= 0xdfff) {
      failBinary();
    }
    appendUtf8Bytes(firstUnit, byteValues);
  }
  const result: Uint8Array = new Uint8Array(byteValues.length);
  for (let index: number = 0; index < byteValues.length; index += 1) {
    result[index] = byteValues[index];
  }
  return result;
}

function decodeUtf8Unchecked(bytes: Uint8Array): string {
  const pieces: string[] = [];
  let index: number = 0;
  while (index < bytes.length) {
    const first: number = bytes[index];
    let codePoint: number = 0;
    if ((first & 0x80) === 0) {
      codePoint = first;
      index += 1;
    } else if ((first & 0xe0) === 0xc0) {
      if (index + 1 >= bytes.length) {
        failBinary();
      }
      const second: number = bytes[index + 1];
      if ((second & 0xc0) !== 0x80) {
        failBinary();
      }
      codePoint = ((first & 0x1f) << 6) | (second & 0x3f);
      if (codePoint < 0x80) {
        failBinary();
      }
      index += 2;
    } else if ((first & 0xf0) === 0xe0) {
      if (index + 2 >= bytes.length) {
        failBinary();
      }
      const second: number = bytes[index + 1];
      const third: number = bytes[index + 2];
      if ((second & 0xc0) !== 0x80 || (third & 0xc0) !== 0x80) {
        failBinary();
      }
      codePoint = ((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f);
      if (codePoint < 0x800 || (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
        failBinary();
      }
      index += 3;
    } else if ((first & 0xf8) === 0xf0) {
      if (index + 3 >= bytes.length) {
        failBinary();
      }
      const second: number = bytes[index + 1];
      const third: number = bytes[index + 2];
      const fourth: number = bytes[index + 3];
      if ((second & 0xc0) !== 0x80 || (third & 0xc0) !== 0x80 || (fourth & 0xc0) !== 0x80) {
        failBinary();
      }
      codePoint =
        ((first & 0x07) << 18) |
        ((second & 0x3f) << 12) |
        ((third & 0x3f) << 6) |
        (fourth & 0x3f);
      if (codePoint < 0x10000 || codePoint > 0x10ffff) {
        failBinary();
      }
      index += 4;
    } else {
      failBinary();
    }

    if (codePoint === 0 || (pieces.length === 0 && codePoint === 0xfeff)) {
      failBinary();
    }
    appendScalarText(codePoint, pieces);
  }
  return pieces.join('');
}

function sliceCopy(bytes: Uint8Array, start: number, end: number): Uint8Array {
  return bytes.slice(start, end);
}

export function encodeVpnRpcU16BE(value: number): Uint8Array {
  const safeValue: number = requireIntegerInRange(value, 0, MAX_U16_VALUE);
  return new Uint8Array([
    (safeValue >>> 8) & 0xff,
    safeValue & 0xff
  ]);
}

export function decodeVpnRpcU16BE(bytes: Uint8Array): number {
  const safeBytes: Uint8Array = requireExactByteLength(bytes, 2);
  return ((safeBytes[0] << 8) | safeBytes[1]) >>> 0;
}

export function encodeVpnRpcU32BE(value: number): Uint8Array {
  const safeValue: number = requireIntegerInRange(value, 0, MAX_U32_VALUE);
  return new Uint8Array([
    (safeValue >>> 24) & 0xff,
    (safeValue >>> 16) & 0xff,
    (safeValue >>> 8) & 0xff,
    safeValue & 0xff
  ]);
}

export function decodeVpnRpcU32BE(bytes: Uint8Array): number {
  const safeBytes: Uint8Array = requireExactByteLength(bytes, 4);
  return (
    ((safeBytes[0] * 0x1000000) >>> 0) +
    ((safeBytes[1] << 16) >>> 0) +
    ((safeBytes[2] << 8) >>> 0) +
    safeBytes[3]
  ) >>> 0;
}

export function encodeVpnRpcU64BE(value: number): Uint8Array {
  const safeValue: number = requireIntegerInRange(value, 0, MAX_SAFE_U64_VALUE);
  const high: number = Math.floor(safeValue / 0x100000000);
  const low: number = safeValue - high * 0x100000000;
  return new Uint8Array([
    (high >>> 24) & 0xff,
    (high >>> 16) & 0xff,
    (high >>> 8) & 0xff,
    high & 0xff,
    (low >>> 24) & 0xff,
    (low >>> 16) & 0xff,
    (low >>> 8) & 0xff,
    low & 0xff
  ]);
}

export function decodeVpnRpcU64BE(bytes: Uint8Array): number {
  const safeBytes: Uint8Array = requireExactByteLength(bytes, 8);
  const high: number = decodeVpnRpcU32BE(sliceCopy(safeBytes, 0, 4));
  const low: number = decodeVpnRpcU32BE(sliceCopy(safeBytes, 4, 8));
  const value: number = high * 0x100000000 + low;
  if (!Number.isSafeInteger(value)) {
    failBinary();
  }
  return value;
}

export function encodeVpnRpcLowercaseHex(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += alphabet[(bytes[index] >>> 4) & 0x0f];
    result += alphabet[bytes[index] & 0x0f];
  }
  return result;
}

export function decodeVpnRpcLowercaseHex(text: string): Uint8Array {
  if ((text.length & 1) !== 0) {
    failBinary();
  }
  const result: Uint8Array = new Uint8Array(text.length / 2);
  for (let index: number = 0; index < text.length; index += 2) {
    const highCode: number = text.charCodeAt(index);
    const lowCode: number = text.charCodeAt(index + 1);
    if (!isLowercaseHexCode(highCode) || !isLowercaseHexCode(lowCode)) {
      failBinary();
    }
    result[index / 2] = (decodeHexDigit(highCode) << 4) | decodeHexDigit(lowCode);
  }
  return result;
}

export function encodeVpnRpcLengthPrefixedBytes(bytes: Uint8Array, maxByteLength: number = MAX_FRAME_BODY_BYTES): Uint8Array {
  const safeMaxByteLength: number = requireMaxByteLength(maxByteLength);
  if (bytes.length > safeMaxByteLength) {
    failBinary();
  }
  const result: Uint8Array = new Uint8Array(bytes.length + 4);
  result.set(encodeVpnRpcU32BE(bytes.length), 0);
  result.set(bytes, 4);
  return result;
}

export function decodeVpnRpcLengthPrefixedBytes(bytes: Uint8Array, maxByteLength: number = MAX_FRAME_BODY_BYTES): Uint8Array {
  const safeMaxByteLength: number = requireMaxByteLength(maxByteLength);
  if (bytes.length < 4) {
    failBinary();
  }
  const byteLength: number = decodeVpnRpcU32BE(sliceCopy(bytes, 0, 4));
  if (byteLength > safeMaxByteLength || bytes.length !== byteLength + 4) {
    failBinary();
  }
  return sliceCopy(bytes, 4, bytes.length);
}

export function encodeVpnRpcUtf8(text: string, maxByteLength: number = MAX_FRAME_BODY_BYTES): Uint8Array {
  const safeMaxByteLength: number = requireMaxByteLength(maxByteLength);
  const bytes: Uint8Array = encodeUtf8Unchecked(text);
  if (bytes.length > safeMaxByteLength) {
    failBinary();
  }
  return bytes;
}

export function decodeVpnRpcUtf8(bytes: Uint8Array, maxByteLength: number = MAX_FRAME_BODY_BYTES): string {
  const safeMaxByteLength: number = requireMaxByteLength(maxByteLength);
  if (bytes.length > safeMaxByteLength) {
    failBinary();
  }
  return decodeUtf8Unchecked(bytes);
}

export function constantTimeEqualVpnRpcBytes(left: Uint8Array, right: Uint8Array): boolean {
  const maxLength: number = Math.max(left.length, right.length);
  let diff: number = left.length ^ right.length;
  for (let index: number = 0; index < maxLength; index += 1) {
    const leftByte: number = index < left.length ? left[index] : 0;
    const rightByte: number = index < right.length ? right[index] : 0;
    diff |= leftByte ^ rightByte;
  }
  return diff === 0;
}
