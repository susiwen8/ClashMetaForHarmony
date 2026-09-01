import { describe, expect, it } from '@ohos/hypium';
import {
  VpnRpcFramer,
  type VpnRpcDecodedFrame
} from '../main/ets/vpn/rpc/VpnRpcFramer';
import { decodeVpnRpcLowercaseHex, encodeVpnRpcU32BE } from '../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import { expectThrowsMessage } from './fakes/ProfileFakes';

const MAX_FRAME_BODY_BYTES: number = 262144;
const INVALID_FRAME_MESSAGE: string = 'Invalid VPN RPC frame.';

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    totalLength += parts[index].length;
  }
  const result: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    result.set(parts[index], offset);
    offset += parts[index].length;
  }
  return result;
}

function createFilledBytes(length: number, start: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  for (let index: number = 0; index < length; index += 1) {
    bytes[index] = (start + index) & 0xff;
  }
  return bytes;
}

function createFrame(bodyBytes: Uint8Array, macBytes: Uint8Array | null): Uint8Array {
  const header: Uint8Array = encodeVpnRpcU32BE(bodyBytes.length);
  if (macBytes === null) {
    return concatBytes([header, bodyBytes]);
  }
  return concatBytes([header, bodyBytes, macBytes]);
}

function expectFrame(frame: VpnRpcDecodedFrame, bodyHex: string, macHex: string | null): void {
  expect(encodeBytes(frame.bodyBytes)).assertEqual(bodyHex);
  if (macHex === null) {
    expect(frame.macBytes === null).assertTrue();
    return;
  }
  if (frame.macBytes === null) {
    throw new Error('Expected MAC bytes.');
  }
  expect(encodeBytes(frame.macBytes)).assertEqual(macHex);
}

function encodeBytes(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += alphabet[(bytes[index] >>> 4) & 0x0f];
    result += alphabet[bytes[index] & 0x0f];
  }
  return result;
}

function expectByteSequence(bytes: Uint8Array, start: number): void {
  for (let index: number = 0; index < bytes.length; index += 1) {
    const expected: number = (start + index) & 0xff;
    if (bytes[index] !== expected) {
      throw new Error(`Expected byte mismatch at ${index}.`);
    }
  }
}

export default function vpnRpcFramerTestsuite() {
  describe('VpnRpcFramerTest', () => {
    it('acceptsPreAuthFramesAcrossEveryChunkBoundaryAndReturnsIsolatedCopies', 0, () => {
      const frameBytes: Uint8Array = createFrame(decodeVpnRpcLowercaseHex('7b7d'), null);
      for (let splitPoint: number = 0; splitPoint <= frameBytes.length; splitPoint += 1) {
        const framer: VpnRpcFramer = new VpnRpcFramer();
        const left: Uint8Array = frameBytes.slice(0, splitPoint);
        const right: Uint8Array = frameBytes.slice(splitPoint);
        const first: VpnRpcDecodedFrame[] = framer.push(left, false);
        const second: VpnRpcDecodedFrame[] = framer.push(right, false);
        expect(first.length + second.length).assertEqual(1);
        const emitted: VpnRpcDecodedFrame = first.length === 1 ? first[0] : second[0];
        expectFrame(emitted, '7b7d', null);

        if (right.length > 0) {
          right[right.length - 1] = 0x00;
        } else if (left.length > 0) {
          left[left.length - 1] = 0x00;
        }
        expectFrame(emitted, '7b7d', null);
        emitted.bodyBytes[0] = 0x00;
        expectFrame(emitted, '007d', null);

        const nextFrame: VpnRpcDecodedFrame[] = framer.push(frameBytes.slice(), false);
        expect(nextFrame.length).assertEqual(1);
        expectFrame(nextFrame[0], '7b7d', null);
      }
    });

    it('acceptsAuthenticatedFramesAcrossHeaderBodyAndMacFragmentBoundaries', 0, () => {
      const bodyBytes: Uint8Array = decodeVpnRpcLowercaseHex('7b226f6b223a747275657d');
      const macBytes: Uint8Array = createFilledBytes(32, 0x80);
      const frameBytes: Uint8Array = createFrame(bodyBytes, macBytes);

      for (let splitPoint: number = 0; splitPoint <= frameBytes.length; splitPoint += 1) {
        const framer: VpnRpcFramer = new VpnRpcFramer();
        const first: VpnRpcDecodedFrame[] = framer.push(frameBytes.slice(0, splitPoint), true);
        const second: VpnRpcDecodedFrame[] = framer.push(frameBytes.slice(splitPoint), true);
        expect(first.length + second.length).assertEqual(1);
        const emitted: VpnRpcDecodedFrame = first.length === 1 ? first[0] : second[0];
        expectFrame(emitted, encodeBytes(bodyBytes), encodeBytes(macBytes));
      }
    });

    it('drainsMultipleCoalescedFramesAndPreservesFrameModeSpecificMacRules', 0, () => {
      const firstPreAuth: Uint8Array = createFrame(decodeVpnRpcLowercaseHex('7b7d'), null);
      const secondPreAuth: Uint8Array = createFrame(decodeVpnRpcLowercaseHex('5b5d'), null);
      const preAuthFramer: VpnRpcFramer = new VpnRpcFramer();
      const preAuthFrames: VpnRpcDecodedFrame[] = preAuthFramer.push(concatBytes([firstPreAuth, secondPreAuth]), false);
      expect(preAuthFrames.length).assertEqual(2);
      expectFrame(preAuthFrames[0], '7b7d', null);
      expectFrame(preAuthFrames[1], '5b5d', null);

      const macA: Uint8Array = createFilledBytes(32, 0x10);
      const macB: Uint8Array = createFilledBytes(32, 0x40);
      const authFramer: VpnRpcFramer = new VpnRpcFramer();
      const authFrames: VpnRpcDecodedFrame[] = authFramer.push(
        concatBytes([
          createFrame(decodeVpnRpcLowercaseHex('0102'), macA),
          createFrame(decodeVpnRpcLowercaseHex('030405'), macB)
        ]),
        true
      );
      expect(authFrames.length).assertEqual(2);
      expectFrame(authFrames[0], '0102', encodeBytes(macA));
      expectFrame(authFrames[1], '030405', encodeBytes(macB));
    });

    it('rejectsZeroOversizedAndTruncatedFramesAndResetsAfterFailure', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();

      expectThrowsMessage(() => {
        framer.push(decodeVpnRpcLowercaseHex('00000000'), false);
      }, INVALID_FRAME_MESSAGE);
      expectThrowsMessage(() => {
        framer.push(encodeVpnRpcU32BE(MAX_FRAME_BODY_BYTES + 1), false);
      }, INVALID_FRAME_MESSAGE);

      const truncatedPreAuth: VpnRpcFramer = new VpnRpcFramer();
      truncatedPreAuth.push(concatBytes([encodeVpnRpcU32BE(2), decodeVpnRpcLowercaseHex('7b')]), false);
      expectThrowsMessage(() => {
        truncatedPreAuth.finish();
      }, INVALID_FRAME_MESSAGE);
      const recoveredPreAuth: VpnRpcDecodedFrame[] = truncatedPreAuth.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), false);
      expect(recoveredPreAuth.length).assertEqual(1);

      const truncatedAuth: VpnRpcFramer = new VpnRpcFramer();
      truncatedAuth.push(concatBytes([encodeVpnRpcU32BE(2), decodeVpnRpcLowercaseHex('7b7d'), createFilledBytes(31, 0x20)]), true);
      expectThrowsMessage(() => {
        truncatedAuth.finish();
      }, INVALID_FRAME_MESSAGE);
      const recoveredAuth: VpnRpcDecodedFrame[] =
        truncatedAuth.push(createFrame(decodeVpnRpcLowercaseHex('0102'), createFilledBytes(32, 0x21)), true);
      expect(recoveredAuth.length).assertEqual(1);
    });

    it('rejectsModeSwitchesWithBufferedStateAndRejectsBusinessTrailerBeforeAuthentication', 0, () => {
      const switchFramer: VpnRpcFramer = new VpnRpcFramer();
      switchFramer.push(encodeVpnRpcU32BE(2), false);
      expectThrowsMessage(() => {
        switchFramer.push(decodeVpnRpcLowercaseHex('7b7d'), true);
      }, INVALID_FRAME_MESSAGE);
      const recoveredSwitch: VpnRpcDecodedFrame[] = switchFramer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), false);
      expect(recoveredSwitch.length).assertEqual(1);

      const preAuthFramer: VpnRpcFramer = new VpnRpcFramer();
      expectThrowsMessage(() => {
        preAuthFramer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), new Uint8Array(32)), false);
      }, INVALID_FRAME_MESSAGE);

      const authenticatedFramer: VpnRpcFramer = new VpnRpcFramer();
      const pending: VpnRpcDecodedFrame[] = authenticatedFramer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), true);
      expect(pending.length).assertEqual(0);
      expectThrowsMessage(() => {
        authenticatedFramer.finish();
      }, INVALID_FRAME_MESSAGE);
    });

    it('capsBufferedBytesAndDoesNotAllowUnboundedIncompleteAccumulation', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      framer.push(encodeVpnRpcU32BE(MAX_FRAME_BODY_BYTES), false);
      const almostAllBody: Uint8Array = createFilledBytes(MAX_FRAME_BODY_BYTES - 1, 0x61);
      const pending: VpnRpcDecodedFrame[] = framer.push(almostAllBody, false);
      expect(pending.length).assertEqual(0);

      const completed: VpnRpcDecodedFrame[] = framer.push(createFilledBytes(1, 0x61), false);
      expect(completed.length).assertEqual(1);
      expect(completed[0].bodyBytes.length).assertEqual(MAX_FRAME_BODY_BYTES);

      expectThrowsMessage(() => {
        framer.push(concatBytes([encodeVpnRpcU32BE(MAX_FRAME_BODY_BYTES + 1), createFilledBytes(1, 0x61)]), false);
      }, INVALID_FRAME_MESSAGE);
    });

    it('rejectsOversizedRawChunksBeforePreAuthFrameAssemblyAndRecoversAfterReset', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      const oversizedChunk: Uint8Array = createFilledBytes(MAX_FRAME_BODY_BYTES + 5, 0x51);

      expectThrowsMessage(() => {
        framer.push(oversizedChunk, false);
      }, INVALID_FRAME_MESSAGE);

      const recovered: VpnRpcDecodedFrame[] = framer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), false);
      expect(recovered.length).assertEqual(1);
      expectFrame(recovered[0], '7b7d', null);
    });

    it('rejectsOversizedRawChunksBeforeAuthenticatedFrameAssemblyAndRecoversAfterReset', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      const oversizedChunk: Uint8Array = createFilledBytes(MAX_FRAME_BODY_BYTES + 37, 0x61);

      expectThrowsMessage(() => {
        framer.push(oversizedChunk, true);
      }, INVALID_FRAME_MESSAGE);

      const recovered: VpnRpcDecodedFrame[] =
        framer.push(createFrame(decodeVpnRpcLowercaseHex('0102'), createFilledBytes(32, 0x31)), true);
      expect(recovered.length).assertEqual(1);
      expectFrame(recovered[0], '0102', encodeBytes(createFilledBytes(32, 0x31)));
    });

    it('reassemblesLargeHighlyFragmentedFramesAndSupportsResetReuse', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      const bodyBytes: Uint8Array = createFilledBytes(16384, 0x20);
      const frameBytes: Uint8Array = createFrame(bodyBytes, null);

      let frames: VpnRpcDecodedFrame[] = [];
      for (let index: number = 0; index < frameBytes.length; index += 1) {
        const emitted: VpnRpcDecodedFrame[] = framer.push(frameBytes.slice(index, index + 1), false);
        if (emitted.length > 0) {
          frames = emitted;
        }
      }

      expect(frames.length).assertEqual(1);
      expect(frames[0].bodyBytes.length).assertEqual(16384);
      expectByteSequence(frames[0].bodyBytes, 0x20);
      framer.reset();

      const reused: VpnRpcDecodedFrame[] = framer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), false);
      expect(reused.length).assertEqual(1);
      expectFrame(reused[0], '7b7d', null);
    });

    it('compactsUnreadBytesOnlyWhenTailCapacityIsExhaustedAndThenFinishesNextFrame', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      const firstBody: Uint8Array = createFilledBytes(196608, 0x10);
      const secondBody: Uint8Array = createFilledBytes(60000, 0x30);
      const secondFrame: Uint8Array = createFrame(secondBody, null);
      const initialChunk: Uint8Array = concatBytes([
        createFrame(firstBody, null),
        secondFrame.slice(0, 20000)
      ]);

      const firstFrames: VpnRpcDecodedFrame[] = framer.push(initialChunk, false);
      expect(firstFrames.length).assertEqual(1);
      expect(firstFrames[0].bodyBytes.length).assertEqual(196608);
      expectByteSequence(firstFrames[0].bodyBytes, 0x10);

      const completed: VpnRpcDecodedFrame[] = framer.push(secondFrame.slice(20000), false);
      expect(completed.length).assertEqual(1);
      expect(completed[0].bodyBytes.length).assertEqual(60000);
      expectByteSequence(completed[0].bodyBytes, 0x30);

      const reused: VpnRpcDecodedFrame[] = framer.push(createFrame(decodeVpnRpcLowercaseHex('5b5d'), null), false);
      expect(reused.length).assertEqual(1);
      expectFrame(reused[0], '5b5d', null);
    });

    it('resetIsIdempotentAndClearsPartialHeaderBodyAndMacState', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      framer.push(decodeVpnRpcLowercaseHex('0000'), false);
      framer.reset();
      framer.reset();
      const preAuthFrames: VpnRpcDecodedFrame[] = framer.push(createFrame(decodeVpnRpcLowercaseHex('7b7d'), null), false);
      expect(preAuthFrames.length).assertEqual(1);
      expectFrame(preAuthFrames[0], '7b7d', null);

      framer.push(concatBytes([encodeVpnRpcU32BE(2), decodeVpnRpcLowercaseHex('0102'), createFilledBytes(16, 0x90)]), true);
      framer.reset();
      const authenticatedFrames: VpnRpcDecodedFrame[] =
        framer.push(createFrame(decodeVpnRpcLowercaseHex('0102'), createFilledBytes(32, 0x91)), true);
      expect(authenticatedFrames.length).assertEqual(1);
      expectFrame(authenticatedFrames[0], '0102', encodeBytes(createFilledBytes(32, 0x91)));
    });
  });
}
