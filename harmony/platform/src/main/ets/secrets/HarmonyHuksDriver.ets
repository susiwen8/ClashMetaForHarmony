import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  HUKS_STANDARD_KEY_SIZE_256,
  HUKS_SECRET_KEY_ALIAS_VERSION,
  HUKS_SECRET_NONCE_LENGTH,
  HUKS_SECRET_TAG_LENGTH,
  type HuksErrorCodeCarrier,
  type HuksOperations,
  type HuksOptionsContract,
  type HuksParamContract,
  type HuksRandomSource,
  type HuksReturnResultContract,
  type HuksSessionHandleContract,
  type HuksDriver,
  type HuksEncryptedPayload
} from './HuksDriver';

const APPLICATION_KEY_ALIAS: string = 'cmfa.subscription.secret.master.v1';
const HUKS_DIAGNOSTIC_DOMAIN: number = 0x0000;
const HUKS_DIAGNOSTIC_TAG: string = 'CMFAHuks';

interface BusinessErrorShape {
  code?: number;
}

export interface HuksDiagnosticSink {
  report(stage: string, code: number): void;
}

export class HarmonyHuksDriver implements HuksDriver {
  private ensureKeyPromise?: Promise<void>;

  private readonly operations: HuksOperations;
  private readonly randomSource: HuksRandomSource;
  private readonly diagnostics: HuksDiagnosticSink;

  constructor(
    operations?: HuksOperations,
    randomSource?: HuksRandomSource,
    diagnostics?: HuksDiagnosticSink
  ) {
    this.operations = operations ?? new HarmonyHuksOperations();
    this.randomSource = randomSource ?? new DefaultHuksRandomSource();
    this.diagnostics = diagnostics ?? new HilogHuksDiagnosticSink();
  }

  async prepare(): Promise<void> {
    await this.ensureKeyMaterial();
  }

  async encrypt(plaintext: Uint8Array): Promise<HuksEncryptedPayload> {
    await this.ensureKeyMaterial();
    const nonce: Uint8Array = this.randomSource.nextNonce(HUKS_SECRET_NONCE_LENGTH);
    const sessionHandle: number = await this.initSession(
      nonce,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT,
      'encrypt.init'
    );
    let sessionCompleted: boolean = false;
    let operationStage: string = 'encrypt.finish';
    try {
      const finishResult = await this.operations.finishSession(
        sessionHandle,
        createFinishOptions(nonce, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, plaintext)
      );
      sessionCompleted = true;
      operationStage = 'encrypt.result';
      const separated = separateEncryptResult(finishResult);
      return {
        keyAliasVersion: HUKS_SECRET_KEY_ALIAS_VERSION,
        nonce,
        ciphertext: separated.ciphertext,
        tag: separated.tag
      };
    } catch (error) {
      this.reportFailure(operationStage, error as Object);
      if (!sessionCompleted) {
        await this.abortSessionSafely(sessionHandle);
      }
      throw new Error('Subscription secret encryption failed.');
    }
  }

  async decrypt(payload: HuksEncryptedPayload): Promise<Uint8Array> {
    validatePayloadShape(payload);
    await this.ensureKeyMaterial();
    const sessionHandle: number = await this.initSession(
      payload.nonce,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      'decrypt.init',
      payload.tag
    );
    let sessionCompleted: boolean = false;
    let operationStage: string = 'decrypt.finish';
    try {
      const finishResult: Uint8Array = copyOptionalBytes((await this.operations.finishSession(
        sessionHandle,
        createFinishOptions(
          payload.nonce,
          huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
          payload.ciphertext,
          payload.tag
        )
      )).outData);
      sessionCompleted = true;
      return finishResult;
    } catch (error) {
      this.reportFailure(operationStage, error as Object);
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
    } catch (error) {
      if (isKeyItemMissingError(error as Object)) {
        return false;
      }
      throw new Error('Subscription secret key lookup failed.');
    }
  }

  private async initSession(
    nonce: Uint8Array,
    purpose: number,
    diagnosticStage: string,
    tag?: Uint8Array
  ): Promise<number> {
    try {
      const handle = await this.operations.initSession(
        APPLICATION_KEY_ALIAS,
        createInitOptions(nonce, purpose, tag)
      );
      return handle.handle;
    } catch (error) {
      this.reportFailure(diagnosticStage, error as Object);
      throw new Error('Subscription secret session initialization failed.');
    }
  }

  private reportFailure(stage: string, error: Object): void {
    const businessError: BusinessErrorShape = error as BusinessErrorShape;
    const code: number = typeof businessError.code === 'number' ? businessError.code : -1;
    this.diagnostics.report(stage, code);
  }

  private async abortSessionSafely(handle: number): Promise<void> {
    try {
      await this.operations.abortSession(handle, {});
    } catch (_) {
    }
  }
}

class HilogHuksDiagnosticSink implements HuksDiagnosticSink {
  report(stage: string, code: number): void {
    hilog.error(
      HUKS_DIAGNOSTIC_DOMAIN,
      HUKS_DIAGNOSTIC_TAG,
      '%{public}s:%{public}d',
      stage,
      code
    );
  }
}

export class HarmonyHuksOperations implements HuksOperations {
  async isKeyItemExist(keyAlias: string, options: HuksOptionsContract): Promise<boolean> {
    return await huks.isKeyItemExist(keyAlias, options as huks.HuksOptions);
  }

  async generateKeyItem(keyAlias: string, options: HuksOptionsContract): Promise<void> {
    await huks.generateKeyItem(keyAlias, options as huks.HuksOptions);
  }

  async initSession(keyAlias: string, options: HuksOptionsContract): Promise<HuksSessionHandleContract> {
    const result = await huks.initSession(keyAlias, options as huks.HuksOptions);
    return createOwnedHuksSessionHandleContract(result.handle, result.challenge);
  }

  async updateSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract> {
    const result = await huks.updateSession(handle, options as huks.HuksOptions, token);
    return createOwnedHuksReturnResultContract(
      result.outData,
      result.properties as Array<HuksParamContract> | undefined
    );
  }

  async finishSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract> {
    const result = await huks.finishSession(handle, options as huks.HuksOptions, token);
    return createOwnedHuksReturnResultContract(
      result.outData,
      result.properties as Array<HuksParamContract> | undefined
    );
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

export class OwnedHuksSessionHandleContractRecord implements HuksSessionHandleContract {
  readonly handle: number;
  readonly challenge?: Uint8Array;

  constructor(handle: number, challenge?: Uint8Array) {
    this.handle = handle;
    this.challenge = cloneOptionalBytesMaybe(challenge);
  }
}

export class OwnedHuksReturnResultContractRecord implements HuksReturnResultContract {
  readonly outData?: Uint8Array;
  readonly properties?: Array<HuksParamContract>;

  constructor(outData?: Uint8Array, properties?: Array<HuksParamContract>) {
    this.outData = cloneOptionalBytesMaybe(outData);
    this.properties = cloneOwnedHuksParamContracts(properties);
  }
}

export class OwnedHuksParamContractRecord implements HuksParamContract {
  readonly tag: number;
  readonly value: boolean | number | bigint | Uint8Array;

  constructor(tag: number, value: boolean | number | bigint | Uint8Array) {
    this.tag = tag;
    this.value = cloneHuksParamValue(value);
  }
}

export function createOwnedHuksSessionHandleContract(
  handle: number,
  challenge?: Uint8Array
): HuksSessionHandleContract {
  return new OwnedHuksSessionHandleContractRecord(handle, challenge);
}

export function createOwnedHuksReturnResultContract(
  outData?: Uint8Array,
  properties?: Array<HuksParamContract>
): HuksReturnResultContract {
  return new OwnedHuksReturnResultContractRecord(outData, properties);
}

export function cloneOwnedHuksParamContracts(
  properties?: Array<HuksParamContract>
): Array<HuksParamContract> | undefined {
  if (properties === undefined) {
    return undefined;
  }
  const copy: Array<HuksParamContract> = [];
  for (let index = 0; index < properties.length; index += 1) {
    copy.push(new OwnedHuksParamContractRecord(properties[index].tag, properties[index].value));
  }
  return copy;
}

function createKeyGenerationOptions(): HuksOptionsContract {
  return {
    properties: [
      uintParam(huks.HuksTag.HUKS_TAG_ALGORITHM, huks.HuksKeyAlg.HUKS_ALG_AES),
      uintParam(huks.HuksTag.HUKS_TAG_KEY_SIZE, HUKS_STANDARD_KEY_SIZE_256),
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
    uintParam(huks.HuksTag.HUKS_TAG_KEY_SIZE, HUKS_STANDARD_KEY_SIZE_256),
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

function createFinishOptions(
  nonce: Uint8Array,
  purpose: number,
  inData: Uint8Array,
  tag?: Uint8Array
): HuksOptionsContract {
  const options: HuksOptionsContract = createInitOptions(nonce, purpose, tag);
  options.inData = cloneBytes(inData);
  return options;
}

function uintParam(tag: huks.HuksTag, value: number): HuksParamContract {
  return { tag, value };
}

function bytesParam(tag: huks.HuksTag, value: Uint8Array): HuksParamContract {
  return { tag, value: cloneBytes(value) };
}

function cloneOptionalBytesMaybe(value?: Uint8Array): Uint8Array | undefined {
  if (value === undefined) {
    return undefined;
  }
  return cloneBytes(value);
}

function cloneHuksParamValue(value: boolean | number | bigint | Uint8Array): boolean | number | bigint | Uint8Array {
  if (value instanceof Uint8Array) {
    return cloneBytes(value);
  }
  return value;
}

function isKeyItemMissingError(error: Object): boolean {
  const businessError: HuksErrorCodeCarrier = error as HuksErrorCodeCarrier;
  return businessError.code === huks.HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST;
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
  finishResult: HuksReturnResultContract
): SeparatedEncryptResult {
  const outData: Uint8Array = copyOptionalBytes(finishResult.outData);
  const propertyTag: Uint8Array | undefined = extractTagFromProperties(finishResult.properties);
  if (propertyTag !== undefined) {
    if (propertyTag.length !== HUKS_SECRET_TAG_LENGTH) {
      throw new Error('HUKS encryption tag was malformed.');
    }
    if (outData.length >= propertyTag.length && endsWithBytes(outData, propertyTag)) {
      return new SeparatedEncryptResult(
        sliceBytes(outData, 0, outData.length - propertyTag.length),
        propertyTag
      );
    }
    return new SeparatedEncryptResult(outData, propertyTag);
  }
  if (outData.length < HUKS_SECRET_TAG_LENGTH) {
    throw new Error('HUKS encryption output was incomplete.');
  }
  return new SeparatedEncryptResult(
    sliceBytes(outData, 0, outData.length - HUKS_SECRET_TAG_LENGTH),
    sliceBytes(outData, outData.length - HUKS_SECRET_TAG_LENGTH, HUKS_SECRET_TAG_LENGTH)
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
