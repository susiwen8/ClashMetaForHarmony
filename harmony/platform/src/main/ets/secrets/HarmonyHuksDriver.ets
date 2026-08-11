import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import {
  HUKS_SECRET_KEY_ALIAS_VERSION,
  HUKS_SECRET_NONCE_LENGTH,
  HUKS_SECRET_TAG_LENGTH,
  type HuksOperations,
  type HuksOptionsContract,
  type HuksParamContract,
  type HuksRandomSource,
  type HuksReturnResultContract,
  type HuksDriver,
  type HuksEncryptedPayload
} from './HuksDriver';

const APPLICATION_KEY_ALIAS: string = 'cmfa.subscription.secret.master.v1';

export class HarmonyHuksDriver implements HuksDriver {
  private ensureKeyPromise?: Promise<void>;

  private readonly operations: HuksOperations;
  private readonly randomSource: HuksRandomSource;

  constructor(operations?: HuksOperations, randomSource?: HuksRandomSource) {
    this.operations = operations ?? new DefaultHuksOperations();
    this.randomSource = randomSource ?? new DefaultHuksRandomSource();
  }

  async encrypt(plaintext: Uint8Array): Promise<HuksEncryptedPayload> {
    await this.ensureKeyMaterial();
    const nonce: Uint8Array = this.randomSource.nextNonce(HUKS_SECRET_NONCE_LENGTH);
    const sessionHandle: number = await this.initSession(nonce, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT);
    let sessionCompleted: boolean = false;
    try {
      const updateResult = await this.operations.updateSession(sessionHandle, createUpdateOptions(plaintext));
      const finishResult = await this.operations.finishSession(sessionHandle, {});
      sessionCompleted = true;
      const separated = separateEncryptResult(updateResult, finishResult);
      return {
        keyAliasVersion: HUKS_SECRET_KEY_ALIAS_VERSION,
        nonce,
        ciphertext: separated.ciphertext,
        tag: separated.tag
      };
    } catch (_) {
      if (!sessionCompleted) {
        await this.abortSessionSafely(sessionHandle);
      }
      throw new Error('Subscription secret encryption failed.');
    }
  }

  async decrypt(payload: HuksEncryptedPayload): Promise<Uint8Array> {
    validatePayloadShape(payload);
    await this.ensureKeyMaterial();
    const sessionHandle: number = await this.initSession(payload.nonce, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, payload.tag);
    let sessionCompleted: boolean = false;
    try {
      const updateResult: Uint8Array = copyOptionalBytes((await this.operations.updateSession(
        sessionHandle,
        createUpdateOptions(payload.ciphertext)
      )).outData);
      const finishResult: Uint8Array = copyOptionalBytes((await this.operations.finishSession(
        sessionHandle,
        createFinishDecryptOptions()
      )).outData);
      sessionCompleted = true;
      return concatenateBytes(updateResult, finishResult);
    } catch (_) {
      if (!sessionCompleted) {
        await this.abortSessionSafely(sessionHandle);
      }
      throw new Error('Subscription secret decryption failed.');
    }
  }

  private async ensureKeyMaterial(): Promise<void> {
    if (this.ensureKeyPromise !== undefined) {
      await this.ensureKeyPromise;
      return;
    }
    const inFlight: Promise<void> = this.ensureKeyMaterialInternal();
    this.ensureKeyPromise = inFlight;
    try {
      await inFlight;
    } catch (_) {
      if (this.ensureKeyPromise === inFlight) {
        this.ensureKeyPromise = undefined;
      }
      throw new Error('Subscription secret key preparation failed.');
    }
  }

  private async ensureKeyMaterialInternal(): Promise<void> {
    const alreadyExists: boolean = await this.safeIsKeyItemExist();
    if (alreadyExists) {
      return;
    }
    try {
      await this.operations.generateKeyItem(APPLICATION_KEY_ALIAS, createKeyGenerationOptions());
      return;
    } catch (_) {
      const existsAfterRace: boolean = await this.safeIsKeyItemExist();
      if (!existsAfterRace) {
        throw new Error('Subscription secret key generation failed.');
      }
    }
  }

  private async safeIsKeyItemExist(): Promise<boolean> {
    try {
      return await this.operations.isKeyItemExist(APPLICATION_KEY_ALIAS, {});
    } catch (_) {
      throw new Error('Subscription secret key lookup failed.');
    }
  }

  private async initSession(nonce: Uint8Array, purpose: number, tag?: Uint8Array): Promise<number> {
    try {
      const handle = await this.operations.initSession(
        APPLICATION_KEY_ALIAS,
        createInitOptions(nonce, purpose, tag)
      );
      return handle.handle;
    } catch (_) {
      throw new Error('Subscription secret session initialization failed.');
    }
  }

  private async abortSessionSafely(handle: number): Promise<void> {
    try {
      await this.operations.abortSession(handle, {});
    } catch (_) {
    }
  }
}

class DefaultHuksOperations implements HuksOperations {
  async isKeyItemExist(keyAlias: string, options: HuksOptionsContract): Promise<boolean> {
    return await huks.isKeyItemExist(keyAlias, options as huks.HuksOptions);
  }

  async generateKeyItem(keyAlias: string, options: HuksOptionsContract): Promise<void> {
    await huks.generateKeyItem(keyAlias, options as huks.HuksOptions);
  }

  async initSession(keyAlias: string, options: HuksOptionsContract): Promise<SessionHandleContractRecord> {
    const result = await huks.initSession(keyAlias, options as huks.HuksOptions);
    return new SessionHandleContractRecord(result.handle, result.challenge);
  }

  async updateSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract> {
    const result = await huks.updateSession(handle, options as huks.HuksOptions, token);
    return new ReturnResultContractRecord(result.outData, result.properties as Array<HuksParamContract> | undefined);
  }

  async finishSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract> {
    const result = await huks.finishSession(handle, options as huks.HuksOptions, token);
    return new ReturnResultContractRecord(result.outData, result.properties as Array<HuksParamContract> | undefined);
  }

  async abortSession(handle: number, options: HuksOptionsContract): Promise<void> {
    await huks.abortSession(handle, options as huks.HuksOptions);
  }
}

class DefaultHuksRandomSource implements HuksRandomSource {
  nextNonce(length: number): Uint8Array {
    try {
      const random = cryptoFramework.createRandom();
      return cloneBytes(random.generateRandomSync(length).data);
    } catch (_) {
      throw new Error('Subscription secret nonce generation failed.');
    }
  }
}

class SessionHandleContractRecord {
  readonly handle: number;
  readonly challenge?: Uint8Array;

  constructor(handle: number, challenge?: Uint8Array) {
    this.handle = handle;
    this.challenge = challenge;
  }
}

class ReturnResultContractRecord implements HuksReturnResultContract {
  readonly outData?: Uint8Array;
  readonly properties?: Array<HuksParamContract>;

  constructor(outData?: Uint8Array, properties?: Array<HuksParamContract>) {
    this.outData = outData;
    this.properties = properties;
  }
}

function createKeyGenerationOptions(): HuksOptionsContract {
  return {
    properties: [
      uintParam(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
      uintParam(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
      uintParam(
        huks.HuksTag.HUKS_TAG_PURPOSE,
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
      ),
      uintParam(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
      uintParam(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM)
    ]
  };
}

function createInitOptions(nonce: Uint8Array, purpose: number, tag?: Uint8Array): HuksOptionsContract {
  const properties: Array<HuksParamContract> = [
    uintParam(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
    uintParam(huks.HuksTag.HUKS_TAG_KEY_SIZE, huks.HuksKeySize.HUKS_AES_KEY_SIZE_256),
    uintParam(huks.HuksTag.HUKS_TAG_PURPOSE, purpose),
    uintParam(huks.HuksTag.HUKS_TAG_PADDING, huks.HuksKeyPadding.HUKS_PADDING_NONE),
    uintParam(huks.HuksTag.HUKS_TAG_BLOCK_MODE, huks.HuksCipherMode.HUKS_MODE_GCM),
    bytesParam(huks.HuksTag.HUKS_TAG_NONCE, nonce)
  ];
  if (tag !== undefined) {
    properties.push(bytesParam(huks.HuksTag.HUKS_TAG_AE_TAG, tag));
  }
  return {
    properties
  };
}

function createUpdateOptions(inData: Uint8Array): HuksOptionsContract {
  return {
    inData: cloneBytes(inData)
  };
}

function createFinishDecryptOptions(): HuksOptionsContract {
  return {};
}

function uintParam(tag: huks.HuksTag, value: number): HuksParamContract {
  return { tag, value };
}

function bytesParam(tag: huks.HuksTag, value: Uint8Array): HuksParamContract {
  return { tag, value: cloneBytes(value) };
}

function validatePayloadShape(payload: HuksEncryptedPayload): void {
  if (payload.keyAliasVersion !== HUKS_SECRET_KEY_ALIAS_VERSION) {
    throw new Error('Subscription secret key version is unsupported.');
  }
  if (payload.nonce.length !== HUKS_SECRET_NONCE_LENGTH || payload.tag.length !== HUKS_SECRET_TAG_LENGTH) {
    throw new Error('Subscription secret payload is malformed.');
  }
}

function copyOptionalBytes(value: Uint8Array | undefined): Uint8Array {
  if (value === undefined) {
    return new Uint8Array(0);
  }
  return cloneBytes(value);
}

class SeparatedEncryptResult {
  readonly ciphertext: Uint8Array;
  readonly tag: Uint8Array;

  constructor(ciphertext: Uint8Array, tag: Uint8Array) {
    this.ciphertext = ciphertext;
    this.tag = tag;
  }
}

function separateEncryptResult(
  updateResult: HuksReturnResultContract,
  finishResult: HuksReturnResultContract
): SeparatedEncryptResult {
  const updateBytes: Uint8Array = copyOptionalBytes(updateResult.outData);
  const finishBytes: Uint8Array = copyOptionalBytes(finishResult.outData);
  const merged: Uint8Array = concatenateBytes(updateBytes, finishBytes);
  const propertyTag: Uint8Array | undefined = extractTagFromProperties(finishResult.properties);
  if (propertyTag !== undefined) {
    if (propertyTag.length !== HUKS_SECRET_TAG_LENGTH) {
      throw new Error('HUKS encryption tag was malformed.');
    }
    if (merged.length >= propertyTag.length && endsWithBytes(merged, propertyTag)) {
      return new SeparatedEncryptResult(
        sliceBytes(merged, 0, merged.length - propertyTag.length),
        propertyTag
      );
    }
    return new SeparatedEncryptResult(merged, propertyTag);
  }
  if (merged.length < HUKS_SECRET_TAG_LENGTH) {
    throw new Error('HUKS encryption output was incomplete.');
  }
  return new SeparatedEncryptResult(
    sliceBytes(merged, 0, merged.length - HUKS_SECRET_TAG_LENGTH),
    sliceBytes(merged, merged.length - HUKS_SECRET_TAG_LENGTH, HUKS_SECRET_TAG_LENGTH)
  );
}

function extractTagFromProperties(properties: Array<HuksParamContract> | undefined): Uint8Array | undefined {
  if (properties === undefined) {
    return undefined;
  }
  for (let index = 0; index < properties.length; index += 1) {
    const property: huks.HuksParam = properties[index];
    if (property.tag === huks.HuksTag.HUKS_TAG_AE_TAG && property.value instanceof Uint8Array) {
      return cloneBytes(property.value);
    }
  }
  return undefined;
}

function cloneBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}

function concatenateBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const merged = new Uint8Array(first.length + second.length);
  for (let index = 0; index < first.length; index += 1) {
    merged[index] = first[index];
  }
  for (let index = 0; index < second.length; index += 1) {
    merged[first.length + index] = second[index];
  }
  return merged;
}

function endsWithBytes(bytes: Uint8Array, suffix: Uint8Array): boolean {
  if (suffix.length > bytes.length) {
    return false;
  }
  const start: number = bytes.length - suffix.length;
  for (let index = 0; index < suffix.length; index += 1) {
    if (bytes[start + index] !== suffix[index]) {
      return false;
    }
  }
  return true;
}

function sliceBytes(bytes: Uint8Array, start: number, length: number): Uint8Array {
  const copy = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    copy[index] = bytes[start + index];
  }
  return copy;
}
