import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import type { ProxyIdentityHasher } from '@cmfa/shared';

const INVALID_INPUT_DETAIL: string = 'Proxy identity input was invalid.';
const HASH_FAILURE_DETAIL: string = 'Proxy identity hashing failed.';
const MAX_INPUT_CODE_UNITS: number = 4096;
const SHA256_DIGEST_LENGTH_BYTES: number = 32;
const LOWERCASE_HEX_DIGITS: string = '0123456789abcdef';

type DigestBytesOperation = (bytes: Uint8Array) => Promise<Uint8Array>;

export class HarmonyProxyIdentityHasher implements ProxyIdentityHasher {
  private readonly digestBytesOperation: DigestBytesOperation;

  constructor(digestBytesOperation?: DigestBytesOperation) {
    this.digestBytesOperation = digestBytesOperation ?? digestSha256Bytes;
  }

  async sha256(value: string): Promise<string> {
    const utf8Encoded: Uint8Array = encodeValidatedUtf8(value);
    try {
      const digestBytes: Uint8Array = cloneBytes(await this.digestBytesOperation(cloneBytes(utf8Encoded)));
      if (digestBytes.length !== SHA256_DIGEST_LENGTH_BYTES) {
        throw new Error('Digest byte length was invalid.');
      }
      return bytesToLowercaseHex(digestBytes);
    } catch (_error) {
      throw new Error(HASH_FAILURE_DETAIL);
    }
  }
}

async function digestSha256Bytes(bytes: Uint8Array): Promise<Uint8Array> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const utf8Bytes: Uint8Array = cloneBytes(bytes);
  await md.update({ data: utf8Bytes });
  const result: cryptoFramework.DataBlob = await md.digest();
  return cloneBytes(result.data);
}

function encodeValidatedUtf8(value: string): Uint8Array {
  if (value.length === 0 || value.length > MAX_INPUT_CODE_UNITS) {
    throw new Error(INVALID_INPUT_DETAIL);
  }
  const encoded: number[] = [];
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (isControlCodeUnit(codeUnit)) {
      throw new Error(INVALID_INPUT_DETAIL);
    }
    if (isHighSurrogate(codeUnit)) {
      if (index + 1 >= value.length) {
        throw new Error(INVALID_INPUT_DETAIL);
      }
      const trailingCodeUnit: number = value.charCodeAt(index + 1);
      if (!isLowSurrogate(trailingCodeUnit)) {
        throw new Error(INVALID_INPUT_DETAIL);
      }
      const codePoint: number = 0x10000 + ((codeUnit - 0xD800) << 10) + (trailingCodeUnit - 0xDC00);
      encoded.push(
        0xF0 | (codePoint >> 18),
        0x80 | ((codePoint >> 12) & 0x3F),
        0x80 | ((codePoint >> 6) & 0x3F),
        0x80 | (codePoint & 0x3F)
      );
      index += 2;
      continue;
    }
    if (isLowSurrogate(codeUnit)) {
      throw new Error(INVALID_INPUT_DETAIL);
    }
    if (codeUnit <= 0x7F) {
      encoded.push(codeUnit);
      index += 1;
      continue;
    }
    if (codeUnit <= 0x7FF) {
      encoded.push(
        0xC0 | (codeUnit >> 6),
        0x80 | (codeUnit & 0x3F)
      );
      index += 1;
      continue;
    }
    encoded.push(
      0xE0 | (codeUnit >> 12),
      0x80 | ((codeUnit >> 6) & 0x3F),
      0x80 | (codeUnit & 0x3F)
    );
    index += 1;
  }
  return Uint8Array.from(encoded);
}

function isControlCodeUnit(codeUnit: number): boolean {
  return codeUnit <= 0x1F || (codeUnit >= 0x7F && codeUnit <= 0x9F);
}

function isHighSurrogate(codeUnit: number): boolean {
  return codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
}

function isLowSurrogate(codeUnit: number): boolean {
  return codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}

function cloneBytes(bytes: Uint8Array): Uint8Array {
  const copy: Uint8Array = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy;
}

function bytesToLowercaseHex(bytes: Uint8Array): string {
  let text: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    const value: number = bytes[index];
    text += LOWERCASE_HEX_DIGITS[(value >> 4) & 0x0F];
    text += LOWERCASE_HEX_DIGITS[value & 0x0F];
  }
  return text;
}
