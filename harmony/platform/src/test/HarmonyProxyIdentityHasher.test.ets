import { describe, expect, it } from '@ohos/hypium';
import { HarmonyProxyIdentityHasher } from '../main/ets/proxy/HarmonyProxyIdentityHasher';
import { assertNoLeak, decodeHexBytes, utf8Bytes } from './fakes/PlatformFakes';

const INVALID_DETAIL = 'Proxy identity input was invalid.';
const HASH_FAILURE_DETAIL = 'Proxy identity hashing failed.';
const MAX_VALUE_SENTINEL: string = 'safe-value-sentinel';

class HashVector {
  readonly value: string;
  readonly digest: string;

  constructor(value: string, digest: string) {
    this.value = value;
    this.digest = digest;
  }
}

class DeferredBytes {
  readonly promise: Promise<Uint8Array>;
  private readonly resolveFn: (value: Uint8Array) => void;

  constructor() {
    let resolveRef: ((value: Uint8Array) => void) | undefined = undefined;
    this.promise = new Promise<Uint8Array>((resolve) => {
      resolveRef = resolve;
    });
    this.resolveFn = (value: Uint8Array) => {
      if (resolveRef !== undefined) {
        resolveRef(value);
      }
    };
  }

  resolve(value: Uint8Array): void {
    this.resolveFn(value);
  }
}

async function expectRejectedWithoutLeak(operation: () => Promise<string>, expectedDetail: string, forbidden: string): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    const message = (error as Error).message;
    expect(message).assertEqual(expectedDetail);
    assertNoLeak(message, [forbidden]);
  }
}

export default function harmonyProxyIdentityHasherTestsuite() {
  describe('HarmonyProxyIdentityHasherTest', () => {
    it('encodesAsciiAndUnicodeInputsExactlyBeforeHexEncodingTheDigest', 0, async () => {
      const expectedVectors: HashVector[] = [
        new HashVector('abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'),
        new HashVector(' proxy id ', '2d06fdb16fdf3ad3102f25daf26e9f088fffb285230a8dff1addd5a8b006df17'),
        new HashVector('Aé中😀', '6eaf1f20c5385f231e0daabb38aeddb70dddf431fa0a9fd60ff93311b0abf5b9'),
        new HashVector('代理😀', '162f1e840e89020c8052e9f366c26e79f82276e4d070c784fc88ae56f1b86d9e')
      ];
      const seenBytes: string[] = [];
      const hasher = new HarmonyProxyIdentityHasher(async (bytes: Uint8Array): Promise<Uint8Array> => {
        let matchedValue: string | undefined = undefined;
        let matchedDigest: string | undefined = undefined;
        for (let index: number = 0; index < expectedVectors.length; index += 1) {
          const vector: HashVector = expectedVectors[index];
          if (sameBytes(bytes, utf8Bytes(vector.value))) {
            matchedValue = vector.value;
            matchedDigest = vector.digest;
            break;
          }
        }
        expect(matchedValue !== undefined).assertTrue();
        if (matchedValue === undefined || matchedDigest === undefined) {
          return new Uint8Array(32);
        }
        seenBytes.push(bytesToHex(bytes));
        return decodeHexBytes(matchedDigest);
      });

      for (let index: number = 0; index < expectedVectors.length; index += 1) {
        const vector: HashVector = expectedVectors[index];
        const digest: string = await hasher.sha256(vector.value);
        expect(digest).assertEqual(vector.digest);
      }

      expect(seenBytes[0]).assertEqual(bytesToHex(utf8Bytes('abc')));
      expect(seenBytes[1]).assertEqual(bytesToHex(utf8Bytes(' proxy id ')));
      expect(seenBytes[2]).assertEqual(bytesToHex(utf8Bytes('Aé中😀')));
      expect(seenBytes[3]).assertEqual(bytesToHex(utf8Bytes('代理😀')));
    });

    it('rejectsEmptyControlSurrogateAndOversizedInputsWithoutEchoingThem', 0, async () => {
      const hasher = new HarmonyProxyIdentityHasher(async (_bytes: Uint8Array): Promise<Uint8Array> => {
        return new Uint8Array(32);
      });
      const oversized = MAX_VALUE_SENTINEL.repeat(300);

      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(''), INVALID_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(`prefix\u0000${MAX_VALUE_SENTINEL}`), INVALID_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(`prefix\u007f${MAX_VALUE_SENTINEL}`), INVALID_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(`prefix\uD800${MAX_VALUE_SENTINEL}`), INVALID_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(`prefix\uDC00${MAX_VALUE_SENTINEL}`), INVALID_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => hasher.sha256(oversized), INVALID_DETAIL, MAX_VALUE_SENTINEL);
    });

    it('sanitizesDigestFailuresAndRejectsUnexpectedDigestLengths', 0, async () => {
      const unsafeInput = `unsafe-${MAX_VALUE_SENTINEL}`;
      const throwingHasher = new HarmonyProxyIdentityHasher(async (_bytes: Uint8Array): Promise<Uint8Array> => {
        throw new Error(`digest failed for ${unsafeInput}`);
      });
      const shortHasher = new HarmonyProxyIdentityHasher(async (_bytes: Uint8Array): Promise<Uint8Array> => {
        return new Uint8Array(31);
      });

      await expectRejectedWithoutLeak((): Promise<string> => throwingHasher.sha256(unsafeInput), HASH_FAILURE_DETAIL, MAX_VALUE_SENTINEL);
      await expectRejectedWithoutLeak((): Promise<string> => shortHasher.sha256('abc'), HASH_FAILURE_DETAIL, 'abc');
    });

    it('keepsConcurrentCallsIndependentWhenTheDigestSeamBlocksAndReusesItsOwnBuffers', 0, async () => {
      const firstDeferred = new DeferredBytes();
      const secondDeferred = new DeferredBytes();
      const firstExpectedBytes = utf8Bytes('abc');
      const secondExpectedBytes = utf8Bytes('代理😀');
      const observedInputs: Uint8Array[] = [];
      let callCount = 0;
      const hasher = new HarmonyProxyIdentityHasher(async (bytes: Uint8Array): Promise<Uint8Array> => {
        observedInputs.push(bytes);
        callCount += 1;
        if (callCount === 1) {
          return await firstDeferred.promise;
        }
        return await secondDeferred.promise;
      });

      const firstPromise = hasher.sha256('abc');
      await Promise.resolve();
      const secondPromise = hasher.sha256('代理😀');
      await Promise.resolve();

      expect(observedInputs.length).assertEqual(2);
      expect(sameBytes(observedInputs[0], firstExpectedBytes)).assertTrue();
      expect(sameBytes(observedInputs[1], secondExpectedBytes)).assertTrue();

      firstDeferred.resolve(decodeHexBytes('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
      secondDeferred.resolve(decodeHexBytes('162f1e840e89020c8052e9f366c26e79f82276e4d070c784fc88ae56f1b86d9e'));

      expect(await firstPromise).assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(await secondPromise).assertEqual('162f1e840e89020c8052e9f366c26e79f82276e4d070c784fc88ae56f1b86d9e');
    });
  });
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index: number = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function bytesToHex(bytes: Uint8Array): string {
  let text = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    text += bytes[index].toString(16).padStart(2, '0');
  }
  return text;
}
