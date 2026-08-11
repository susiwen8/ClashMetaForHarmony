export const HUKS_SECRET_KEY_ALIAS_VERSION: number = 1;
export const HUKS_SECRET_NONCE_LENGTH: number = 12;
export const HUKS_SECRET_TAG_LENGTH: number = 16;

export interface HuksEncryptedPayload {
  keyAliasVersion: number;
  nonce: Uint8Array;
  ciphertext: Uint8Array;
  tag: Uint8Array;
}

export interface HuksParamContract {
  tag: number;
  value: boolean | number | bigint | Uint8Array;
}

export interface HuksOptionsContract {
  properties?: Array<HuksParamContract>;
  inData?: Uint8Array;
}

export interface HuksSessionHandleContract {
  handle: number;
  challenge?: Uint8Array;
}

export interface HuksReturnResultContract {
  outData?: Uint8Array;
  properties?: Array<HuksParamContract>;
}

export interface HuksOperations {
  isKeyItemExist(keyAlias: string, options: HuksOptionsContract): Promise<boolean>;
  generateKeyItem(keyAlias: string, options: HuksOptionsContract): Promise<void>;
  initSession(keyAlias: string, options: HuksOptionsContract): Promise<HuksSessionHandleContract>;
  updateSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract>;
  finishSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<HuksReturnResultContract>;
  abortSession(handle: number, options: HuksOptionsContract): Promise<void>;
}

export interface HuksRandomSource {
  nextNonce(length: number): Uint8Array;
}

export interface HuksDriver {
  encrypt(plaintext: Uint8Array): Promise<HuksEncryptedPayload>;
  decrypt(payload: HuksEncryptedPayload): Promise<Uint8Array>;
}
