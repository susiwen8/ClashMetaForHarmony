import { describe, expect, it } from '@ohos/hypium';
import { huks } from '@kit.UniversalKeystoreKit';
import type { VpnRpcCryptoPort } from '@cmfa/shared';
import {
  HarmonyHuksOperations,
  createOwnedHuksReturnResultContract,
  createOwnedHuksSessionHandleContract
} from '../main/ets/secrets/HarmonyHuksDriver';
import {
  type HuksOperations,
  type HuksOptionsContract,
  type HuksParamContract,
  type HuksSessionHandleContract,
  type HuksReturnResultContract
} from '../main/ets/secrets/HuksDriver';
import {
  HarmonyVpnRpcKeyProvider,
  VPN_RPC_HMAC_MAX_INPUT_BYTES,
  VPN_RPC_ROOT_HUKS_ALIAS,
  type VpnRpcDerivedHmacOperations
} from '../main/ets/vpn/HarmonyVpnRpcKeyProvider';
import {
  DeterministicVpnRpcDerivedHmacOperations,
  assertNoLeak,
  buildBytes,
  utf8Bytes
} from './fakes/PlatformFakes';

const HUKS_ITEM_NOT_EXIST_CODE: number = huks.HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST;
const HUKS_ITEM_ALREADY_EXISTS_CODE: number = 12000017;
const EXPECTED_HUKS_MAC_PROPERTIES: number[] = [
  huks.HuksTag.HUKS_TAG_ALGORITHM,
  huks.HuksTag.HUKS_TAG_KEY_SIZE,
  huks.HuksTag.HUKS_TAG_PURPOSE,
  huks.HuksTag.HUKS_TAG_DIGEST
];
const EXPECTED_HUKS_MAC_VALUES: number[] = [
  huks.HuksKeyAlg.HUKS_ALG_HMAC,
  256,
  huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_MAC,
  huks.HuksKeyDigest.HUKS_DIGEST_SHA256
];
const EXPECTED_SESSION_PROPERTIES: number[] = [
  huks.HuksTag.HUKS_TAG_ALGORITHM,
  huks.HuksTag.HUKS_TAG_PURPOSE,
  huks.HuksTag.HUKS_TAG_DIGEST
];
const EXPECTED_SESSION_VALUES: number[] = [
  huks.HuksKeyAlg.HUKS_ALG_HMAC,
  huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_MAC,
  huks.HuksKeyDigest.HUKS_DIGEST_SHA256
];
const ROOT_FAILURE_MESSAGE: string = 'VPN RPC root HMAC failed.';
const DERIVED_FAILURE_MESSAGE: string = 'VPN RPC derived HMAC failed.';
const PREPARE_FAILURE_MESSAGE: string = 'VPN RPC key preparation failed.';
const INVALID_INPUT_MESSAGE: string = 'VPN RPC HMAC input is invalid.';
const INVALID_KEY_MESSAGE: string = 'VPN RPC derived HMAC key is invalid.';

class DeferredBox<T> {
  readonly promise: Promise<T>;
  private readonly resolveRef: (value: T) => void;
  private readonly rejectRef: (error: Error) => void;

  constructor() {
    let resolveLocal: ((value: T) => void) | undefined = undefined;
    let rejectLocal: ((error: Error) => void) | undefined = undefined;
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (error: Error) => void): void => {
      resolveLocal = resolve;
      rejectLocal = reject;
    });
    this.resolveRef = (value: T): void => {
      resolveLocal?.(value);
    };
    this.rejectRef = (error: Error): void => {
      rejectLocal?.(error);
    };
  }

  resolve(value: T): void {
    this.resolveRef(value);
  }

  reject(error: Error): void {
    this.rejectRef(error);
  }
}

class FakeBusinessError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class HuksSessionHandleRecord {
  readonly handle: number;

  constructor(handle: number) {
    this.handle = handle;
  }
}

class HuksReturnResultRecord implements HuksReturnResultContract {
  readonly outData?: Uint8Array;
  readonly properties?: Array<HuksParamContract>;

  constructor(outData?: Uint8Array) {
    this.outData = outData;
    this.properties = undefined;
  }
}

class RecordedHuksCall {
  readonly keyAlias: string;
  readonly properties: Array<HuksParamContract>;

  constructor(keyAlias: string, properties: Array<HuksParamContract>) {
    this.keyAlias = keyAlias;
    this.properties = properties;
  }
}

class RecordedFinishCall {
  readonly handle: number;
  readonly properties: Array<HuksParamContract>;
  readonly inDataRef: Uint8Array;
  readonly inDataSnapshot: Uint8Array;

  constructor(handle: number, properties: Array<HuksParamContract>, inDataRef: Uint8Array) {
    this.handle = handle;
    this.properties = properties;
    this.inDataRef = inDataRef;
    this.inDataSnapshot = cloneBytes(inDataRef);
  }
}

class RecordingHuksOperations implements HuksOperations {
  readonly existCalls: HuksOptionsContract[] = [];
  readonly generateCalls: RecordedHuksCall[] = [];
  readonly initCalls: RecordedHuksCall[] = [];
  readonly finishCalls: RecordedFinishCall[] = [];
  readonly abortHandles: number[] = [];
  readonly updateHandles: number[] = [];
  existenceSequence: boolean[] = [true];
  initHandles: number[] = [41];
  finishOutput: Uint8Array = buildSequentialOutput(32, 11);
  generateError?: FakeBusinessError;
  lookupError?: FakeBusinessError;
  initError?: FakeBusinessError;
  finishError?: FakeBusinessError;
  abortError?: FakeBusinessError;
  generateDeferred?: DeferredBox<void>;
  finishDeferredByHandle: Map<number, DeferredBox<void>> = new Map<number, DeferredBox<void>>();

  async isKeyItemExist(_: string, options: HuksOptionsContract): Promise<boolean> {
    this.existCalls.push(cloneOptions(options));
    if (this.lookupError !== undefined) {
      throw this.lookupError;
    }
    if (this.existenceSequence.length === 0) {
      return true;
    }
    return this.existenceSequence.shift() ?? true;
  }

  async generateKeyItem(keyAlias: string, options: HuksOptionsContract): Promise<void> {
    this.generateCalls.push(new RecordedHuksCall(keyAlias, cloneProperties(options.properties)));
    if (this.generateError !== undefined) {
      throw this.generateError;
    }
    if (this.generateDeferred !== undefined) {
      await this.generateDeferred.promise;
    }
  }

  async initSession(keyAlias: string, options: HuksOptionsContract): Promise<HuksSessionHandleRecord> {
    this.initCalls.push(new RecordedHuksCall(keyAlias, cloneProperties(options.properties)));
    if (this.initError !== undefined) {
      throw this.initError;
    }
    const handle: number = this.initHandles.length > 0 ? (this.initHandles.shift() ?? 41) : 41;
    return new HuksSessionHandleRecord(handle);
  }

  async updateSession(handle: number, _: HuksOptionsContract, __?: Uint8Array): Promise<HuksReturnResultRecord> {
    this.updateHandles.push(handle);
    return new HuksReturnResultRecord(new Uint8Array(0));
  }

  async finishSession(handle: number, options: HuksOptionsContract, _: Uint8Array | undefined = undefined): Promise<HuksReturnResultRecord> {
    const inDataRef: Uint8Array = requireBytes(options.inData, 'Expected HUKS finish inData.');
    this.finishCalls.push(new RecordedFinishCall(handle, cloneProperties(options.properties), inDataRef));
    inDataRef[0] = inDataRef[0] ^ 0x7f;
    const deferred: DeferredBox<void> | undefined = this.finishDeferredByHandle.get(handle);
    if (deferred !== undefined) {
      await deferred.promise;
    }
    if (this.finishError !== undefined) {
      throw this.finishError;
    }
    return new HuksReturnResultRecord(this.finishOutput);
  }

  async abortSession(handle: number, _: HuksOptionsContract): Promise<void> {
    this.abortHandles.push(handle);
    if (this.abortError !== undefined) {
      throw this.abortError;
    }
  }
}

class RecordingDerivedHmacOperations extends DeterministicVpnRpcDerivedHmacOperations implements VpnRpcDerivedHmacOperations {
}

async function flushAsyncTurns(turns: number = 4): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

async function expectFixedFailure(
  run: () => Promise<void | Uint8Array>,
  expectedMessage: string,
  forbiddenFragments: string[]
): Promise<void> {
  try {
    await run();
    expect(false).assertTrue();
  } catch (error) {
    const detail: string = extractErrorDetail(error as Object);
    expect(detail).assertEqual(expectedMessage);
    assertNoLeak(detail, forbiddenFragments);
  }
}

export default function harmonyVpnRpcKeyProviderTestsuite() {
  describe('HarmonyVpnRpcKeyProviderTest', () => {
    it('implementsVpnRpcCryptoPortAndSkipsGenerationWhenTheRootKeyAlreadyExists', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [true];
      const provider: VpnRpcCryptoPort = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      await provider.prepare();

      expect(operations.existCalls.length).assertEqual(1);
      expect(operations.generateCalls.length).assertEqual(0);
    });

    it('createsCallerOwnedHuksContractsForChallengeOutDataAndPropertyBytes', 0, () => {
      const sourceChallenge = utf8Bytes('owned-challenge');
      const sourceOutData = utf8Bytes('owned-out-data-value-32-bytes!!!');
      const sourcePropertyBytes = utf8Bytes('owned-property-bytes');
      const sourceProperties: Array<HuksParamContract> = [
        new HuksParamRecord(huks.HuksTag.HUKS_TAG_AE_TAG, sourcePropertyBytes),
        new HuksParamRecord(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_SHA256)
      ];

      const ownedHandle: HuksSessionHandleContract = createOwnedHuksSessionHandleContract(77, sourceChallenge);
      const ownedReturn: HuksReturnResultContract = createOwnedHuksReturnResultContract(sourceOutData, sourceProperties);
      const ownedChallenge = requireBytes(ownedHandle.challenge, 'Owned challenge missing.');
      const ownedOutData = requireBytes(ownedReturn.outData, 'Owned outData missing.');
      const ownedPropertyBytes = requireBytes(readBytesPropertyValue(ownedReturn.properties, huks.HuksTag.HUKS_TAG_AE_TAG), 'Owned property bytes missing.');

      sourceChallenge[0] = 0x31;
      sourceOutData[0] = 0x32;
      sourcePropertyBytes[0] = 0x33;
      expect(ownedChallenge[0]).assertEqual(utf8Bytes('owned-challenge')[0]);
      expect(ownedOutData[0]).assertEqual(utf8Bytes('owned-out-data-value-32-bytes!!!')[0]);
      expect(ownedPropertyBytes[0]).assertEqual(utf8Bytes('owned-property-bytes')[0]);

      ownedChallenge[1] = 0x41;
      ownedOutData[1] = 0x42;
      ownedPropertyBytes[1] = 0x43;
      expect(sourceChallenge[1]).assertEqual(utf8Bytes('owned-challenge')[1]);
      expect(sourceOutData[1]).assertEqual(utf8Bytes('owned-out-data-value-32-bytes!!!')[1]);
      expect(sourcePropertyBytes[1]).assertEqual(utf8Bytes('owned-property-bytes')[1]);
      expect(readNumberPropertyValue(ownedReturn.properties, huks.HuksTag.HUKS_TAG_DIGEST)).assertEqual(huks.HuksKeyDigest.HUKS_DIGEST_SHA256);
    });

    it('generatesTheFixedNonExportableRootKeyAndCollapsesConcurrentPrepareCallsIntoSingleFlight', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [false];
      operations.generateDeferred = new DeferredBox<void>();
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      const firstPrepare = provider.prepare();
      const secondPrepare = provider.prepare();
      await flushAsyncTurns();
      expect(operations.generateCalls.length).assertEqual(1);
      operations.generateDeferred.resolve(undefined);
      await firstPrepare;
      await secondPrepare;

      expect(operations.existCalls.length).assertEqual(1);
      expect(operations.generateCalls[0].keyAlias).assertEqual(VPN_RPC_ROOT_HUKS_ALIAS);
      expectExactProperties(operations.generateCalls[0].properties, EXPECTED_HUKS_MAC_PROPERTIES, EXPECTED_HUKS_MAC_VALUES);
      expect(containsTag(operations.generateCalls[0].properties, huks.HuksTag.HUKS_TAG_PADDING)).assertFalse();
      expect(containsTag(operations.generateCalls[0].properties, huks.HuksTag.HUKS_TAG_BLOCK_MODE)).assertFalse();
      expect(containsTag(operations.generateCalls[0].properties, huks.HuksTag.HUKS_TAG_NONCE)).assertFalse();
    });

    it('acceptsAlreadyExistsRaceButFailsAndRetriesCleanlyForOtherPrepareErrors', 0, async () => {
      const raceOperations = new RecordingHuksOperations();
      raceOperations.existenceSequence = [false, true];
      raceOperations.generateError = new FakeBusinessError(HUKS_ITEM_ALREADY_EXISTS_CODE, `${VPN_RPC_ROOT_HUKS_ALIAS}:race`);
      const raceProvider = new HarmonyVpnRpcKeyProvider(raceOperations, new RecordingDerivedHmacOperations());

      await raceProvider.prepare();
      expect(raceOperations.existCalls.length).assertEqual(2);

      const failOperations = new RecordingHuksOperations();
      failOperations.existenceSequence = [false];
      failOperations.lookupError = new FakeBusinessError(12000005, `lookup:${VPN_RPC_ROOT_HUKS_ALIAS}`);
      const failProvider = new HarmonyVpnRpcKeyProvider(failOperations, new RecordingDerivedHmacOperations());
      await expectFixedFailure(
        (): Promise<void> => failProvider.prepare(),
        PREPARE_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, '12000005', 'lookup:']
      );
      failOperations.lookupError = undefined;
      failOperations.existenceSequence = [true];
      await failProvider.prepare();
    });

    it('failsClosedForNonAlreadyExistsGenerateErrorsEvenWhenTheKeyAppearsAfterward', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [false, true];
      operations.generateError = new FakeBusinessError(12000005, `${VPN_RPC_ROOT_HUKS_ALIAS}:unexpected-generate`);
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      await expectFixedFailure(
        (): Promise<void> => provider.prepare(),
        PREPARE_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, '12000005', 'unexpected-generate']
      );

      expect(operations.existCalls.length).assertEqual(1);
      expect(operations.generateCalls.length).assertEqual(1);
    });

    it('failsPrepareWhenGenerationRaceRecheckStillShowsNoKey', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [false, false];
      operations.generateError = new FakeBusinessError(HUKS_ITEM_ALREADY_EXISTS_CODE, `${VPN_RPC_ROOT_HUKS_ALIAS}:still-missing`);
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      await expectFixedFailure(
        (): Promise<void> => provider.prepare(),
        PREPARE_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, 'still-missing', '12000017']
      );

      expect(operations.existCalls.length).assertEqual(2);
      expect(operations.generateCalls.length).assertEqual(1);
    });

    it('usesExactRootHmacSessionAliasAndPropertiesAndCopiesThenZeroesTemporaryBuffers', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [true];
      operations.finishOutput = buildSequentialOutput(32, 31);
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());
      const input = utf8Bytes('root-mac-input');
      const inputBefore = cloneBytes(input);

      const output = await provider.rootHmac(input);

      expect(operations.initCalls.length).assertEqual(1);
      expect(operations.initCalls[0].keyAlias).assertEqual(VPN_RPC_ROOT_HUKS_ALIAS);
      expectExactProperties(operations.initCalls[0].properties, EXPECTED_SESSION_PROPERTIES, EXPECTED_SESSION_VALUES);
      expect(operations.finishCalls.length).assertEqual(1);
      expect(operations.finishCalls[0].handle).assertEqual(41);
      expectExactProperties(operations.finishCalls[0].properties, EXPECTED_SESSION_PROPERTIES, EXPECTED_SESSION_VALUES);
      expectBytesEqual(input, inputBefore);
      expectBytesEqual(output, buildSequentialOutput(32, 31));
      expectAllZero(operations.finishCalls[0].inDataRef);
      expectAllZero(operations.finishOutput);
      operations.finishOutput[0] = 0x5a;
      expect(output[0]).assertEqual(buildSequentialOutput(32, 31)[0]);
      expect(operations.updateHandles.length).assertEqual(0);
    });

    it('capturesRootHmacCallerInputBeforeAwaitAndUsesTheOriginalSnapshot', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.existenceSequence = [false];
      operations.generateDeferred = new DeferredBox<void>();
      operations.finishOutput = buildSequentialOutput(32, 61);
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());
      const input = utf8Bytes('snapshot-before-await');
      const inputAtCallTime = cloneBytes(input);

      const pending = provider.rootHmac(input);
      input[0] = 0x7a;
      input[1] = 0x7b;
      await flushAsyncTurns();
      operations.generateDeferred.resolve(undefined);
      const output = await pending;

      expect(operations.finishCalls.length).assertEqual(1);
      expectBytesEqual(operations.finishCalls[0].inDataSnapshot, inputAtCallTime);
      expectBytesEqual(output, buildSequentialOutput(32, 61));
      expect(input[0]).assertEqual(0x7a);
      expect(input[1]).assertEqual(0x7b);
    });

    it('rejectsEmptyAndOversizedRootHmacInputs', 0, async () => {
      const operations = new RecordingHuksOperations();
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.rootHmac(new Uint8Array(0)),
        INVALID_INPUT_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS]
      );
      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.rootHmac(buildBytes(VPN_RPC_HMAC_MAX_INPUT_BYTES + 1)),
        INVALID_INPUT_MESSAGE,
        [`${VPN_RPC_HMAC_MAX_INPUT_BYTES + 1}`]
      );
    });

    it('abortsExactlyOnceAfterFinishFailuresButNotAfterInitFailuresAndKeepsConcurrentHandlesSeparate', 0, async () => {
      const initFailOperations = new RecordingHuksOperations();
      initFailOperations.initError = new FakeBusinessError(12000006, `init:${VPN_RPC_ROOT_HUKS_ALIAS}`);
      const initFailProvider = new HarmonyVpnRpcKeyProvider(initFailOperations, new RecordingDerivedHmacOperations());
      await expectFixedFailure(
        (): Promise<Uint8Array> => initFailProvider.rootHmac(utf8Bytes('root-init')),
        ROOT_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, 'init:']
      );
      expect(initFailOperations.abortHandles.length).assertEqual(0);

      const finishFailOperations = new RecordingHuksOperations();
      finishFailOperations.finishError = new FakeBusinessError(12000006, `finish:${VPN_RPC_ROOT_HUKS_ALIAS}`);
      finishFailOperations.abortError = new FakeBusinessError(12000005, 'abort-detail');
      const finishFailProvider = new HarmonyVpnRpcKeyProvider(finishFailOperations, new RecordingDerivedHmacOperations());
      await expectFixedFailure(
        (): Promise<Uint8Array> => finishFailProvider.rootHmac(utf8Bytes('root-finish')),
        ROOT_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, 'finish:', 'abort-detail', '12000006', '12000005']
      );
      expect(finishFailOperations.abortHandles.length).assertEqual(1);
      expect(finishFailOperations.abortHandles[0]).assertEqual(41);

      const concurrentOperations = new RecordingHuksOperations();
      concurrentOperations.initHandles = [91, 92];
      concurrentOperations.finishDeferredByHandle.set(91, new DeferredBox<void>());
      concurrentOperations.finishDeferredByHandle.set(92, new DeferredBox<void>());
      const concurrentProvider = new HarmonyVpnRpcKeyProvider(concurrentOperations, new RecordingDerivedHmacOperations());
      const firstRoot = concurrentProvider.rootHmac(utf8Bytes('root-a'));
      const secondRoot = concurrentProvider.rootHmac(utf8Bytes('root-b'));
      await flushAsyncTurns();
      expect(concurrentOperations.finishCalls.length).assertEqual(2);
      expect(concurrentOperations.finishCalls[0].handle).assertEqual(91);
      expect(concurrentOperations.finishCalls[1].handle).assertEqual(92);
      requireRecord(concurrentOperations.finishDeferredByHandle.get(91), 'Missing deferred 91.').resolve(undefined);
      requireRecord(concurrentOperations.finishDeferredByHandle.get(92), 'Missing deferred 92.').resolve(undefined);
      await firstRoot;
      await secondRoot;
    });

    it('failsRootHmacOnWrongDigestLengthWithoutLeakingRawDetail', 0, async () => {
      const operations = new RecordingHuksOperations();
      operations.finishOutput = buildSequentialOutput(31, 3);
      const provider = new HarmonyVpnRpcKeyProvider(operations, new RecordingDerivedHmacOperations());

      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.rootHmac(utf8Bytes('root-short')),
        ROOT_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, '31']
      );

      expect(operations.abortHandles.length).assertEqual(1);
    });

    it('usesDerivedAdapterWithCopiedInputsAndZeroesTemporaryKeyInputAndOutputBuffers', 0, async () => {
      const derived = new RecordingDerivedHmacOperations();
      derived.output = buildSequentialOutput(32, 121);
      const provider = new HarmonyVpnRpcKeyProvider(new RecordingHuksOperations(), derived);
      const key = buildSequentialOutput(32, 41);
      const input = utf8Bytes('frame-mac-input');
      const keyBefore = cloneBytes(key);
      const inputBefore = cloneBytes(input);

      const output = await provider.derivedHmac(key, input);

      expect(derived.calls.length).assertEqual(1);
      expect(derived.calls[0]).assertEqual(`${encodeHex(keyBefore)}:${encodeHex(inputBefore)}`);
      expectBytesEqual(key, keyBefore);
      expectBytesEqual(input, inputBefore);
      expectBytesEqual(output, buildSequentialOutput(32, 121));
      expectAllZero(derived.keyRefs[0]);
      expectAllZero(derived.inputRefs[0]);
      expectAllZero(derived.output);
      derived.output[0] = 0x77;
      expect(output[0]).assertEqual(buildSequentialOutput(32, 121)[0]);
    });

    it('rejectsInvalidDerivedInputsAndNormalizesAdapterFailures', 0, async () => {
      const derived = new RecordingDerivedHmacOperations();
      const provider = new HarmonyVpnRpcKeyProvider(new RecordingHuksOperations(), derived);

      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.derivedHmac(buildSequentialOutput(31, 7), utf8Bytes('abc')),
        INVALID_KEY_MESSAGE,
        ['31']
      );
      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.derivedHmac(buildSequentialOutput(32, 7), new Uint8Array(0)),
        INVALID_INPUT_MESSAGE,
        []
      );
      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.derivedHmac(
          buildSequentialOutput(32, 7),
          buildBytes(VPN_RPC_HMAC_MAX_INPUT_BYTES + 1)
        ),
        INVALID_INPUT_MESSAGE,
        [`${VPN_RPC_HMAC_MAX_INPUT_BYTES + 1}`]
      );

      derived.error = new Error(`derived:${VPN_RPC_ROOT_HUKS_ALIAS}`);
      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.derivedHmac(buildSequentialOutput(32, 7), utf8Bytes('abc')),
        DERIVED_FAILURE_MESSAGE,
        [VPN_RPC_ROOT_HUKS_ALIAS, 'derived:']
      );

      derived.error = undefined;
      derived.output = buildSequentialOutput(31, 5);
      await expectFixedFailure(
        (): Promise<Uint8Array> => provider.derivedHmac(buildSequentialOutput(32, 7), utf8Bytes('abc')),
        DERIVED_FAILURE_MESSAGE,
        ['31']
      );
    });

    it('reusesTheSharedHarmonyHuksOperationsWithoutExposingAnExportApiSurface', 0, () => {
      const operations = new HarmonyHuksOperations();
      expect(typeof operations.isKeyItemExist).assertEqual('function');
      expect(typeof operations.generateKeyItem).assertEqual('function');
      expect(typeof operations.initSession).assertEqual('function');
      expect(typeof operations.finishSession).assertEqual('function');
      expect(typeof operations.abortSession).assertEqual('function');
    });
  });
}

function cloneBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function cloneProperties(properties: Array<HuksParamContract> | undefined): Array<HuksParamContract> {
  if (properties === undefined) {
    return [];
  }
  const copy: Array<HuksParamContract> = [];
  for (let index = 0; index < properties.length; index += 1) {
    const property = properties[index];
    if (property.value instanceof Uint8Array) {
      copy.push(new HuksParamRecord(property.tag, cloneBytes(property.value)));
      continue;
    }
    copy.push(new HuksParamRecord(property.tag, property.value));
  }
  return copy;
}

function cloneOptions(options: HuksOptionsContract): HuksOptionsContract {
  return new HuksOptionsRecord(
    cloneProperties(options.properties),
    options.inData === undefined ? undefined : cloneBytes(options.inData)
  );
}

function requireBytes(bytes: Uint8Array | undefined, message: string): Uint8Array {
  if (bytes === undefined) {
    throw new Error(message);
  }
  return bytes;
}

function requireRecord<T>(value: T | undefined, message: string): T {
  if (value === undefined) {
    throw new Error(message);
  }
  return value;
}

function readBytesPropertyValue(
  properties: Array<HuksParamContract> | undefined,
  tag: number
): Uint8Array | undefined {
  if (properties === undefined) {
    return undefined;
  }
  for (let index = 0; index < properties.length; index += 1) {
    const property = properties[index];
    if (property.tag === tag && property.value instanceof Uint8Array) {
      return property.value;
    }
  }
  return undefined;
}

function readNumberPropertyValue(
  properties: Array<HuksParamContract> | undefined,
  tag: number
): number {
  if (properties === undefined) {
    return -1;
  }
  for (let index = 0; index < properties.length; index += 1) {
    const property = properties[index];
    if (property.tag === tag && typeof property.value === 'number') {
      return property.value;
    }
  }
  return -1;
}

function expectBytesEqual(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function expectAllZero(bytes: Uint8Array): void {
  for (let index = 0; index < bytes.length; index += 1) {
    expect(bytes[index]).assertEqual(0);
  }
}

function expectExactProperties(
  properties: Array<HuksParamContract>,
  expectedTags: number[],
  expectedValues: number[]
): void {
  expect(properties.length).assertEqual(expectedTags.length);
  for (let index = 0; index < expectedTags.length; index += 1) {
    expect(properties[index].tag).assertEqual(expectedTags[index]);
    expect(properties[index].value).assertEqual(expectedValues[index]);
  }
}

function containsTag(properties: Array<HuksParamContract>, tag: number): boolean {
  for (let index = 0; index < properties.length; index += 1) {
    if (properties[index].tag === tag) {
      return true;
    }
  }
  return false;
}

function buildSequentialOutput(length: number, start: number): Uint8Array {
  const output = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    output[index] = (start + index) & 0xff;
  }
  return output;
}

function encodeHex(bytes: Uint8Array): string {
  let text = '';
  for (let index = 0; index < bytes.length; index += 1) {
    text += bytes[index].toString(16).padStart(2, '0');
  }
  return text;
}

class HuksParamRecord implements HuksParamContract {
  readonly tag: number;
  readonly value: boolean | number | bigint | Uint8Array;

  constructor(tag: number, value: boolean | number | bigint | Uint8Array) {
    this.tag = tag;
    this.value = value;
  }
}

class HuksOptionsRecord implements HuksOptionsContract {
  readonly properties?: Array<HuksParamContract>;
  readonly inData?: Uint8Array;

  constructor(properties?: Array<HuksParamContract>, inData?: Uint8Array) {
    this.properties = properties;
    this.inData = inData;
  }
}

function extractErrorDetail(error: Object | undefined): string {
  if (error === undefined) {
    return 'undefined';
  }
  if (error instanceof Error) {
    return error.message;
  }
  return `${error}`;
}
