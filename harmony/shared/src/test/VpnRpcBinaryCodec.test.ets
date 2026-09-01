import { describe, expect, it } from '@ohos/hypium';
import {
  constantTimeEqualVpnRpcBytes,
  decodeVpnRpcLengthPrefixedBytes,
  decodeVpnRpcLowercaseHex,
  decodeVpnRpcU16BE,
  decodeVpnRpcU32BE,
  decodeVpnRpcU64BE,
  decodeVpnRpcUtf8,
  encodeVpnRpcLengthPrefixedBytes,
  encodeVpnRpcLowercaseHex,
  encodeVpnRpcU16BE,
  encodeVpnRpcU32BE,
  encodeVpnRpcU64BE,
  encodeVpnRpcUtf8
} from '../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import { expectThrowsMessage } from './fakes/ProfileFakes';

const MAX_FRAME_BODY_BYTES: number = 262144;
const INVALID_BINARY_MESSAGE: string = 'Invalid VPN RPC binary.';

function bytesToHex(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += alphabet[(bytes[index] >>> 4) & 0x0f];
    result += alphabet[bytes[index] & 0x0f];
  }
  return result;
}

function asciiBytes(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let index: number = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index);
  }
  return bytes;
}

function expectBytesEqual(actual: Uint8Array, expectedHex: string): void {
  expect(bytesToHex(actual)).assertEqual(expectedHex);
}

export default function vpnRpcBinaryCodecTestsuite() {
  describe('VpnRpcBinaryCodecTest', () => {
    it('pinsExactBigEndianVectorsAcrossU16U32AndU64Helpers', 0, () => {
      expectBytesEqual(encodeVpnRpcU16BE(0), '0000');
      expectBytesEqual(encodeVpnRpcU16BE(4660), '1234');
      expect(decodeVpnRpcU16BE(decodeVpnRpcLowercaseHex('ffff'))).assertEqual(65535);

      expectBytesEqual(encodeVpnRpcU32BE(0), '00000000');
      expectBytesEqual(encodeVpnRpcU32BE(0x12345678), '12345678');
      expect(decodeVpnRpcU32BE(decodeVpnRpcLowercaseHex('ffffffff'))).assertEqual(4294967295);

      expectBytesEqual(encodeVpnRpcU64BE(0), '0000000000000000');
      expectBytesEqual(encodeVpnRpcU64BE(9007199254740991), '001fffffffffffff');
      expect(decodeVpnRpcU64BE(decodeVpnRpcLowercaseHex('001fffffffffffff'))).assertEqual(9007199254740991);
    });

    it('rejectsOutOfRangeInputsAndMalformedLengthsForBinaryIntegerHelpers', 0, () => {
      expectThrowsMessage(() => {
        encodeVpnRpcU16BE(-1);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        encodeVpnRpcU16BE(65536);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcU16BE(decodeVpnRpcLowercaseHex('000000'));
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        encodeVpnRpcU32BE(4294967296);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcU32BE(decodeVpnRpcLowercaseHex('00'));
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        encodeVpnRpcU64BE(9007199254740992);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcU64BE(decodeVpnRpcLowercaseHex('0020000000000000'));
      }, INVALID_BINARY_MESSAGE);
    });

    it('acceptsOnlyEvenLengthLowercaseHexAndRoundTripsBytesExactly', 0, () => {
      const source: Uint8Array = decodeVpnRpcLowercaseHex('00017f80feff');
      expect(encodeVpnRpcLowercaseHex(source)).assertEqual('00017f80feff');
      expectBytesEqual(source, '00017f80feff');

      expectThrowsMessage(() => {
        decodeVpnRpcLowercaseHex('ABCDEF');
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcLowercaseHex('abcde');
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcLowercaseHex('00gg');
      }, INVALID_BINARY_MESSAGE);
    });

    it('encodesAndDecodesLengthPrefixedBytesWithBoundsAndCopyIsolation', 0, () => {
      const body: Uint8Array = decodeVpnRpcLowercaseHex('0102030405');
      const encoded: Uint8Array = encodeVpnRpcLengthPrefixedBytes(body, 8);
      expectBytesEqual(encoded, '000000050102030405');
      body[0] = 0xff;
      expectBytesEqual(encoded, '000000050102030405');

      const decoded: Uint8Array = decodeVpnRpcLengthPrefixedBytes(encoded, 8);
      expectBytesEqual(decoded, '0102030405');
      decoded[0] = 0xaa;
      expectBytesEqual(encoded, '000000050102030405');

      expectThrowsMessage(() => {
        encodeVpnRpcLengthPrefixedBytes(body, 4);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcLengthPrefixedBytes(decodeVpnRpcLowercaseHex('000000060102030405'), 8);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcLengthPrefixedBytes(decodeVpnRpcLowercaseHex('00000009010203040506070809'), 8);
      }, INVALID_BINARY_MESSAGE);
    });

    it('encodesAndDecodesUtf8WithinBoundsAndRejectsBomInvalidNulAndOverlongData', 0, () => {
      const encoded: Uint8Array = encodeVpnRpcUtf8('vpn-中文', 16);
      expectBytesEqual(encoded, '76706e2de4b8ade69687');
      expect(decodeVpnRpcUtf8(encoded, 16)).assertEqual('vpn-中文');
      const encodedInteriorBom: Uint8Array = encodeVpnRpcUtf8('vpn\uFEFFrpc', 16);
      expectBytesEqual(encodedInteriorBom, '76706eefbbbf727063');
      expect(decodeVpnRpcUtf8(encodedInteriorBom, 16)).assertEqual('vpn\uFEFFrpc');

      expectThrowsMessage(() => {
        encodeVpnRpcUtf8('\uFEFFvpn', 16);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        encodeVpnRpcUtf8(`vpn${String.fromCharCode(0)}rpc`, 16);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        encodeVpnRpcUtf8('vpn-中文', 3);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcUtf8(new Uint8Array([0xef, 0xbb, 0xbf, 0x61]), 16);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcUtf8(new Uint8Array([0xc3, 0x28]), 16);
      }, INVALID_BINARY_MESSAGE);
      expect(decodeVpnRpcUtf8(new Uint8Array([0x61, 0xef, 0xbb, 0xbf, 0x62]), 16)).assertEqual(`a\uFEFFb`);
      expectThrowsMessage(() => {
        decodeVpnRpcUtf8(new Uint8Array([0x61, 0x00, 0x62]), 16);
      }, INVALID_BINARY_MESSAGE);
      expectThrowsMessage(() => {
        decodeVpnRpcUtf8(asciiBytes('0123456789'), 5);
      }, INVALID_BINARY_MESSAGE);
    });

    it('comparesByteArraysWithoutLeakingPrefixAndLengthShortcutsThroughApiResults', 0, () => {
      const baseline: Uint8Array = decodeVpnRpcLowercaseHex('00112233445566778899aabbccddeeff');
      const same: Uint8Array = decodeVpnRpcLowercaseHex('00112233445566778899aabbccddeeff');
      const mismatchAtFront: Uint8Array = decodeVpnRpcLowercaseHex('ff112233445566778899aabbccddeeff');
      const mismatchAtTail: Uint8Array = decodeVpnRpcLowercaseHex('00112233445566778899aabbccddee00');
      const shorter: Uint8Array = decodeVpnRpcLowercaseHex('00112233445566778899aabbccddee');

      expect(constantTimeEqualVpnRpcBytes(baseline, same)).assertTrue();
      expect(constantTimeEqualVpnRpcBytes(baseline, mismatchAtFront)).assertFalse();
      expect(constantTimeEqualVpnRpcBytes(baseline, mismatchAtTail)).assertFalse();
      expect(constantTimeEqualVpnRpcBytes(baseline, shorter)).assertFalse();
      expect(constantTimeEqualVpnRpcBytes(shorter, baseline)).assertFalse();
    });

    it('supportsLengthPrefixedUtf8AtTheFramePayloadLimit', 0, () => {
      const source: Uint8Array = new Uint8Array(MAX_FRAME_BODY_BYTES);
      for (let index: number = 0; index < source.length; index += 1) {
        source[index] = 0x61;
      }

      const encoded: Uint8Array = encodeVpnRpcLengthPrefixedBytes(source, MAX_FRAME_BODY_BYTES);
      expect(encoded.length).assertEqual(MAX_FRAME_BODY_BYTES + 4);
      expect(decodeVpnRpcU32BE(encoded.slice(0, 4))).assertEqual(MAX_FRAME_BODY_BYTES);
      const decoded: Uint8Array = decodeVpnRpcLengthPrefixedBytes(encoded, MAX_FRAME_BODY_BYTES);
      expect(decoded.length).assertEqual(MAX_FRAME_BODY_BYTES);
      expect(decoded[0]).assertEqual(0x61);
      expect(decoded[MAX_FRAME_BODY_BYTES - 1]).assertEqual(0x61);
    });
  });
}
