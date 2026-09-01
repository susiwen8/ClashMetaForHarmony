import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import type { VpnRpcCryptoPort } from '@cmfa/shared';
import { HarmonyHuksOperations } from '../secrets/HarmonyHuksDriver';
import {
  HUKS_KEY_ITEM_ALREADY_EXISTS_ERROR_CODE,
  HUKS_STANDARD_KEY_SIZE_256,
  type HuksErrorCodeCarrier,
  type HuksOperations,
  type HuksOptionsContract,
  type HuksParamContract,
  type HuksReturnResultContract
} from '../secrets/HuksDriver';

export const VPN_RPC_ROOT_HUKS_ALIAS: string = 'cmfa.vpn.rpc.root.hmac.v1';
export const VPN_RPC_HMAC_MAX_INPUT_BYTES: number = 512 * 1024;

const VPN_RPC_KEY_ALGORITHM: string = 'HMAC|SHA256';
const VPN_RPC_MAC_ALGORITHM: string = 'SHA256';
const VPN_RPC_HMAC_OUTPUT_BYTES: number = 32;
const VPN_RPC_DERIVED_KEY_BYTES: number = 32;
const PREPARE_FAILURE_MESSAGE: string = 'VPN RPC key preparation failed.';
const ROOT_FAILURE_MESSAGE: string = 'VPN RPC root HMAC failed.';
const DERIVED_FAILURE_MESSAGE: string = 'VPN RPC derived HMAC failed.';
const INVALID_INPUT_MESSAGE: string = 'VPN RPC HMAC input is invalid.';
const INVALID_KEY_MESSAGE: string = 'VPN RPC derived HMAC key is invalid.';

export interface VpnRpcDerivedHmacOperations {
  hmacSha256(key: Uint8Array, input: Uint8Array): Promise<Uint8Array>;
}

export class HarmonyVpnRpcKeyProvider implements VpnRpcCryptoPort {
  private ensureKeyPromise?: Promise<void>;

  private readonly operations: HuksOperations;
  private readonly derivedHmacOperations: VpnRpcDerivedHmacOperations;

  constructor(
    operations?: HuksOperations,
    derivedHmacOperations?: VpnRpcDerivedHmacOperations
  ) {
    this.operations = operations ?? new HarmonyHuksOperations();
    this.derivedHmacOperations = derivedHmacOperations ?? new CryptoFrameworkDerivedHmacOperations();
  }

  async prepare(): Promise<void> {
    await this.ensureRootKeyMaterial();
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    validateHmacInput(input);
    const inputSnapshot: Uint8Array = copyBytes(input);
    let sessionHandle: number = 0;
    let initSucceeded: boolean = false;
    try {
      await this.ensureRootKeyMaterial();
      const initResult = await this.operations.initSession(
        VPN_RPC_ROOT_HUKS_ALIAS,
        createHmacSessionOptions()
      );
      sessionHandle = initResult.handle;
      initSucceeded = true;
      const finishInput: Uint8Array = copyBytes(inputSnapshot);
      let rawOutput: Uint8Array | undefined = undefined;
      try {
        const finishResult: HuksReturnResultContract = await this.operations.finishSession(
          sessionHandle,
          createHmacFinishOptions(finishInput)
        );
        rawOutput = finishResult.outData;
        return copyFixedLengthOutput(rawOutput, ROOT_FAILURE_MESSAGE);
      } finally {
        zeroBytes(finishInput);
        zeroBytes(rawOutput);
      }
    } catch (_) {
      if (initSucceeded) {
        await abortSessionSafely(this.operations, sessionHandle);
      }
      throw new Error(ROOT_FAILURE_MESSAGE);
    } finally {
      zeroBytes(inputSnapshot);
    }
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    validateDerivedKey(key);
    validateHmacInput(input);
    const keyCopy: Uint8Array = copyBytes(key);
    const inputCopy: Uint8Array = copyBytes(input);
    let rawOutput: Uint8Array | undefined = undefined;
    try {
      rawOutput = await this.derivedHmacOperations.hmacSha256(keyCopy, inputCopy);
      return copyFixedLengthOutput(rawOutput, DERIVED_FAILURE_MESSAGE);
    } catch (_) {
      throw new Error(DERIVED_FAILURE_MESSAGE);
    } finally {
      zeroBytes(keyCopy);
      zeroBytes(inputCopy);
      zeroBytes(rawOutput);
    }
  }

  private async ensureRootKeyMaterial(): Promise<void> {
    if (this.ensureKeyPromise !== undefined) {
      await this.ensureKeyPromise;
      return;
    }
    const inFlight: Promise<void> = this.ensureRootKeyMaterialInternal();
    this.ensureKeyPromise = inFlight;
    try {
      await inFlight;
    } catch (_) {
      if (this.ensureKeyPromise === inFlight) {
        this.ensureKeyPromise = undefined;
      }
      throw new Error(PREPARE_FAILURE_MESSAGE);
    }
  }

  private async ensureRootKeyMaterialInternal(): Promise<void> {
    if (await this.safeIsKeyItemExist()) {
      return;
    }
    try {
      await this.operations.generateKeyItem(VPN_RPC_ROOT_HUKS_ALIAS, createHmacKeyGenerationOptions());
    } catch (error) {
      if (!isKeyItemAlreadyExistsError(error as Object)) {
        throw new Error(PREPARE_FAILURE_MESSAGE);
      }
      if (!await this.safeIsKeyItemExist()) {
        throw new Error(PREPARE_FAILURE_MESSAGE);
      }
    }
  }

  private async safeIsKeyItemExist(): Promise<boolean> {
    try {
      return await this.operations.isKeyItemExist(VPN_RPC_ROOT_HUKS_ALIAS, new HuksOptionsRecord());
    } catch (error) {
      if (isKeyItemMissingError(error as Object)) {
        return false;
      }
      throw new Error(PREPARE_FAILURE_MESSAGE);
    }
  }
}

class CryptoFrameworkDerivedHmacOperations implements VpnRpcDerivedHmacOperations {
  async hmacSha256(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    const keyBytes: Uint8Array = copyBytes(key);
    const inputBytes: Uint8Array = copyBytes(input);
    let symKey: cryptoFramework.SymKey | undefined = undefined;
    let rawOutput: Uint8Array | undefined = undefined;
    try {
      const keyGenerator = cryptoFramework.createSymKeyGenerator(VPN_RPC_KEY_ALGORITHM);
      symKey = await keyGenerator.convertKey(new CryptoDataBlobRecord(keyBytes));
      const mac = cryptoFramework.createMac(VPN_RPC_MAC_ALGORITHM);
      await mac.init(symKey);
      await mac.update(new CryptoDataBlobRecord(inputBytes));
      rawOutput = (await mac.doFinal()).data;
      return copyBytes(rawOutput);
    } catch (_) {
      throw new Error(DERIVED_FAILURE_MESSAGE);
    } finally {
      zeroBytes(keyBytes);
      zeroBytes(inputBytes);
      zeroBytes(rawOutput);
      clearSymKeySafely(symKey);
    }
  }
}

class CryptoDataBlobRecord implements cryptoFramework.DataBlob {
  readonly data: Uint8Array;

  constructor(data: Uint8Array) {
    this.data = data;
  }
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

function createHmacKeyGenerationOptions(): HuksOptionsContract {
  return new HuksOptionsRecord([
    uintParam(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_HMAC),
    uintParam(huks.HuksTag.HUKS_TAG_KEY_SIZE, HUKS_STANDARD_KEY_SIZE_256),
    uintParam(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_MAC),
    uintParam(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_SHA256)
  ]);
}

function createHmacSessionOptions(): HuksOptionsContract {
  return new HuksOptionsRecord([
    uintParam(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_HMAC),
    uintParam(huks.HuksTag.HUKS_TAG_PURPOSE, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_MAC),
    uintParam(huks.HuksTag.HUKS_TAG_DIGEST, huks.HuksKeyDigest.HUKS_DIGEST_SHA256)
  ]);
}

function createHmacFinishOptions(inData: Uint8Array): HuksOptionsContract {
  return new HuksOptionsRecord(createHmacSessionOptions().properties, inData);
}

function uintParam(tag: huks.HuksTag, value: number): HuksParamContract {
  return new HuksParamRecord(tag, value);
}

function validateHmacInput(input: Uint8Array): void {
  if (input.length === 0 || input.length > VPN_RPC_HMAC_MAX_INPUT_BYTES) {
    throw new Error(INVALID_INPUT_MESSAGE);
  }
}

function validateDerivedKey(key: Uint8Array): void {
  if (key.length !== VPN_RPC_DERIVED_KEY_BYTES) {
    throw new Error(INVALID_KEY_MESSAGE);
  }
}

function copyFixedLengthOutput(output: Uint8Array | undefined, errorMessage: string): Uint8Array {
  if (output === undefined || output.length !== VPN_RPC_HMAC_OUTPUT_BYTES) {
    throw new Error(errorMessage);
  }
  return copyBytes(output);
}

function isKeyItemMissingError(error: Object): boolean {
  const carrier: HuksErrorCodeCarrier = error as HuksErrorCodeCarrier;
  return carrier.code === huks.HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST;
}

function isKeyItemAlreadyExistsError(error: Object): boolean {
  const carrier: HuksErrorCodeCarrier = error as HuksErrorCodeCarrier;
  return carrier.code === HUKS_KEY_ITEM_ALREADY_EXISTS_ERROR_CODE;
}

async function abortSessionSafely(operations: HuksOperations, handle: number): Promise<void> {
  try {
    await operations.abortSession(handle, new HuksOptionsRecord());
  } catch (_) {
  }
}

function clearSymKeySafely(symKey: cryptoFramework.SymKey | undefined): void {
  if (symKey === undefined) {
    return;
  }
  try {
    symKey.clearMem();
  } catch (_) {
  }
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function zeroBytes(bytes: Uint8Array | undefined): void {
  if (bytes === undefined) {
    return;
  }
  bytes.fill(0);
}
