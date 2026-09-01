import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY,
  type FileDriver,
  type FileStat,
  type FileToken
} from '../files/FileDriver';
import {
  createSubscriptionSecretError,
  isSubscriptionSecretError,
  type IdGenerator,
  type SubscriptionSecretError,
  type SubscriptionSecretStore
} from '@cmfa/shared';
import {
  HUKS_SECRET_KEY_ALIAS_VERSION,
  HUKS_SECRET_NONCE_LENGTH,
  HUKS_SECRET_TAG_LENGTH,
  type HuksDriver,
  type HuksEncryptedPayload
} from './HuksDriver';
import { hilog } from '@kit.PerformanceAnalysisKit';

const ENVELOPE_VERSION: number = 1;
const SECRET_DIRECTORY: string = 'profile-secrets';
const SECRET_SUFFIX: string = '.json';
const TEMP_SUFFIX: string = '.tmp';
const MAX_ENVELOPE_BYTES: number = 64 * 1024;
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const SECRET_DIAGNOSTIC_DOMAIN: number = 0x0000;
const SECRET_DIAGNOSTIC_TAG: string = 'CMFASecret';

type SecretFailureKind = 'MISSING' | 'DECRYPT' | 'UNSUPPORTED' | 'WRITE';

interface BusinessErrorShape {
  code?: number;
}

export interface SecretStoreDiagnosticSink {
  report(stage: string, code: number): void;
}

class SecretEnvelopeShape {
  readonly version: number;
  readonly nonce: string;
  readonly ciphertext: string;
  readonly tag: string;
  readonly keyAliasVersion: number;

  constructor(version: number, nonce: string, ciphertext: string, tag: string, keyAliasVersion: number) {
    this.version = version;
    this.nonce = nonce;
    this.ciphertext = ciphertext;
    this.tag = tag;
    this.keyAliasVersion = keyAliasVersion;
  }
}

class SecretStoreFailure extends Error {
  readonly name: string = 'SecretStoreFailure';
  readonly kind: SecretFailureKind;

  constructor(kind: SecretFailureKind) {
    super(kind);
    this.kind = kind;
  }
}

export class HuksSubscriptionSecretStore implements SubscriptionSecretStore {
  private readonly huksDriver: HuksDriver;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly idGenerator: IdGenerator;
  private readonly diagnostics: SecretStoreDiagnosticSink;

  constructor(
    huksDriver: HuksDriver,
    fileDriver: FileDriver,
    filesDir: string,
    idGenerator: IdGenerator,
    diagnostics?: SecretStoreDiagnosticSink
  ) {
    this.huksDriver = huksDriver;
    this.fileDriver = fileDriver;
    this.filesDir = normalizeAbsoluteSandboxPath(filesDir, 'Sandbox root path');
    this.idGenerator = idGenerator;
    this.diagnostics = diagnostics ?? new HilogSecretStoreDiagnosticSink();
  }

  async encrypt(plaintext: string): Promise<string> {
    let temporaryPath: string = '';
    let operationStage: string = 'store.encrypt.id.opaque';
    try {
      const opaqueId: string = normalizeOpaqueId(this.idGenerator.nextId(), false);
      operationStage = 'store.encrypt.id.temporary';
      const temporaryId: string = normalizeOpaqueId(this.idGenerator.nextId(), false);
      const targetPath: string = secretEnvelopePath(this.filesDir, opaqueId);
      temporaryPath = secretTemporaryPath(this.filesDir, opaqueId, temporaryId);
      operationStage = 'store.encrypt.huks';
      const payload: HuksEncryptedPayload = await this.huksDriver.encrypt(encodeUtf8(plaintext));
      operationStage = 'store.encrypt.payload';
      validatePayloadForSerialization(payload);
      operationStage = 'store.encrypt.serialize';
      const serializedEnvelope: Uint8Array = encodeUtf8(serializeEnvelope(payload));
      operationStage = 'store.encrypt.mkdir';
      await this.ensureSecretDirectory();
      operationStage = 'store.encrypt.write';
      await this.writeTemporaryEnvelope(temporaryPath, serializedEnvelope);
      operationStage = 'store.encrypt.rename';
      await this.fileDriver.renameNoOverwrite(temporaryPath, targetPath);
      return opaqueId;
    } catch (error) {
      this.reportFailure(operationStage, error as Object);
      if (temporaryPath.length > 0) {
        await this.cleanupTemporaryEnvelope(temporaryPath);
      }
      throw this.mapFailure(error, 'WRITE');
    }
  }

  private async ensureSecretDirectory(): Promise<void> {
    const directoryPath: string = secretDirectoryPath(this.filesDir);
    const existing: FileStat | undefined = await this.fileDriver.statIfPresent(directoryPath);
    if (existing !== undefined) {
      if (!existing.isDirectory) {
        throw new SecretStoreFailure('WRITE');
      }
      return;
    }
    try {
      await this.fileDriver.mkdir(directoryPath, true);
    } catch (_) {
      const createdByRace: FileStat | undefined = await this.fileDriver.statIfPresent(directoryPath);
      if (createdByRace === undefined || !createdByRace.isDirectory) {
        throw new SecretStoreFailure('WRITE');
      }
    }
  }

  private reportFailure(stage: string, error: Object): void {
    const businessError: BusinessErrorShape = error as BusinessErrorShape;
    const code: number = typeof businessError.code === 'number' ? businessError.code : -1;
    this.diagnostics.report(stage, code);
  }

  async decrypt(secretRef: string): Promise<string> {
    try {
      const opaqueId: string = normalizeOpaqueId(secretRef, true);
      const payload: HuksEncryptedPayload = await this.readEnvelopePayload(opaqueId);
      const plaintextBytes: Uint8Array = await this.huksDriver.decrypt(payload);
      return decodeUtf8(plaintextBytes);
    } catch (error) {
      if (isSubscriptionSecretError(error as Object)) {
        throw error as SubscriptionSecretError;
      }
      if (isSecretStoreFailure(error) && (error as SecretStoreFailure).kind === 'WRITE') {
        throw this.mapFailure(error as SecretStoreFailure, 'DECRYPT');
      }
      throw this.mapFailure(error, 'DECRYPT');
    }
  }

  async remove(secretRef: string): Promise<void> {
    try {
      const opaqueId: string = normalizeOpaqueId(secretRef, false);
      const targetPath: string = secretEnvelopePath(this.filesDir, opaqueId);
      const stat: FileStat | undefined = await this.fileDriver.statIfPresent(targetPath);
      if (stat === undefined) {
        return;
      }
      if (!stat.isFile) {
        throw new SecretStoreFailure('WRITE');
      }
      await this.fileDriver.unlink(targetPath);
    } catch (error) {
      throw this.mapFailure(error, 'WRITE');
    }
  }

  async reconcile(referencedSecretIds: string[]): Promise<void> {
    try {
      const referenced: Set<string> = new Set<string>();
      for (let index = 0; index < referencedSecretIds.length; index += 1) {
        referenced.add(normalizeOpaqueId(referencedSecretIds[index], false));
      }
      const directoryPath: string = secretDirectoryPath(this.filesDir);
      const stat: FileStat | undefined = await this.fileDriver.statIfPresent(directoryPath);
      if (stat === undefined) {
        return;
      }
      if (!stat.isDirectory) {
        throw new SecretStoreFailure('WRITE');
      }
      const names: string[] = await this.fileDriver.list(directoryPath);
      for (let index = 0; index < names.length; index += 1) {
        const entryName: string = names[index];
        if (isManagedTemporaryName(entryName)) {
          await this.fileDriver.unlink(joinAbsoluteSandboxPath(directoryPath, entryName));
          continue;
        }
        const referencedId: string | undefined = managedEnvelopeId(entryName);
        if (referencedId === undefined) {
          continue;
        }
        if (!referenced.has(referencedId)) {
          await this.fileDriver.unlink(joinAbsoluteSandboxPath(directoryPath, entryName));
        }
      }
    } catch (error) {
      throw this.mapFailure(error, 'WRITE');
    }
  }

  private async readEnvelopePayload(opaqueId: string): Promise<HuksEncryptedPayload> {
    const targetPath: string = secretEnvelopePath(this.filesDir, opaqueId);
    const stat: FileStat | undefined = await this.statForRead(targetPath);
    if (stat === undefined) {
      throw createSubscriptionSecretError('SOURCE_SECRET_MISSING', 'Subscription secret source is missing.');
    }
    if (!stat.isFile || stat.size <= 0 || stat.size > MAX_ENVELOPE_BYTES) {
      throw createSubscriptionSecretError('SOURCE_DECRYPT_FAILED', 'Subscription secret source could not be decrypted.');
    }
    try {
      const fileContents: string = await this.readEnvelopeText(targetPath, stat.size);
      const parsed: SecretEnvelopeShape = parseEnvelope(fileContents);
      if (parsed.version !== ENVELOPE_VERSION || parsed.keyAliasVersion !== HUKS_SECRET_KEY_ALIAS_VERSION) {
        throw createSubscriptionSecretError(
          'SOURCE_SECRET_VERSION_UNSUPPORTED',
          'Subscription secret source version is unsupported.'
        );
      }
      return {
        keyAliasVersion: parsed.keyAliasVersion,
        nonce: decodeBase64(parsed.nonce, HUKS_SECRET_NONCE_LENGTH),
        ciphertext: decodeBase64(parsed.ciphertext),
        tag: decodeBase64(parsed.tag, HUKS_SECRET_TAG_LENGTH)
      };
    } catch (error) {
      if (isSubscriptionSecretError(error as Object)) {
        throw error as SubscriptionSecretError;
      }
      throw createSubscriptionSecretError('SOURCE_DECRYPT_FAILED', 'Subscription secret source could not be decrypted.');
    }
  }

  private async statForRead(path: string): Promise<FileStat | undefined> {
    try {
      return await this.fileDriver.statIfPresent(path);
    } catch (_) {
      throw new SecretStoreFailure('DECRYPT');
    }
  }

  private async readEnvelopeText(path: string, size: number): Promise<string> {
    let fileToken: FileToken | undefined = undefined;
    let pendingFailure: SecretStoreFailure | undefined = undefined;
    let decodedText: string | undefined = undefined;
    try {
      fileToken = await this.fileDriver.open(path, 0);
      const buffer = new Uint8Array(size);
      let bytesRead: number = 0;
      while (bytesRead < size) {
        const remaining: number = size - bytesRead;
        const chunkBuffer = new ArrayBuffer(remaining);
        const readNow: number = await this.fileDriver.read(fileToken.fd, chunkBuffer, { length: remaining });
        if (readNow <= 0 || readNow > remaining) {
          pendingFailure = new SecretStoreFailure('DECRYPT');
          break;
        }
        const chunkBytes = new Uint8Array(chunkBuffer);
        for (let index = 0; index < readNow; index += 1) {
          buffer[bytesRead + index] = chunkBytes[index];
        }
        bytesRead += readNow;
      }
      if (pendingFailure !== undefined) {
        throw pendingFailure;
      }
      decodedText = decodeUtf8(buffer);
    } catch (error) {
      if (isSecretStoreFailure(error)) {
        pendingFailure = error as SecretStoreFailure;
      } else {
        pendingFailure = new SecretStoreFailure('DECRYPT');
      }
    }
    if (fileToken !== undefined) {
      try {
        await this.fileDriver.close(fileToken);
      } catch (_) {
        if (pendingFailure === undefined) {
          pendingFailure = new SecretStoreFailure('DECRYPT');
        }
      }
    }
    if (pendingFailure !== undefined) {
      throw pendingFailure;
    }
    if (decodedText !== undefined) {
      return decodedText;
    }
    throw new SecretStoreFailure('DECRYPT');
  }

  private async writeTemporaryEnvelope(path: string, contents: Uint8Array): Promise<void> {
    let fileToken: FileToken | undefined = undefined;
    let pendingFailure: SecretStoreFailure | undefined = undefined;
    try {
      fileToken = await this.fileDriver.open(path, FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_TRUNC);
      let bytesWritten: number = 0;
      while (bytesWritten < contents.length) {
        const chunk = sliceBytes(contents, bytesWritten, contents.length - bytesWritten);
        const wroteNow: number = await this.fileDriver.write(fileToken.fd, chunk.buffer, { length: chunk.length });
        if (wroteNow <= 0 || wroteNow > chunk.length) {
          pendingFailure = new SecretStoreFailure('WRITE');
          break;
        }
        bytesWritten += wroteNow;
      }
      if (pendingFailure !== undefined) {
        throw pendingFailure;
      }
    } catch (error) {
      if (isSecretStoreFailure(error)) {
        pendingFailure = error as SecretStoreFailure;
      } else {
        pendingFailure = new SecretStoreFailure('WRITE');
      }
    }
    if (fileToken !== undefined) {
      try {
        await this.fileDriver.close(fileToken);
      } catch (_) {
        if (pendingFailure === undefined) {
          pendingFailure = new SecretStoreFailure('WRITE');
        }
      }
    }
    if (pendingFailure !== undefined) {
      throw pendingFailure;
    }
  }

  private async cleanupTemporaryEnvelope(path: string): Promise<void> {
    try {
      const stat: FileStat | undefined = await this.fileDriver.statIfPresent(path);
      if (stat !== undefined && stat.isFile) {
        await this.fileDriver.unlink(path);
      }
    } catch (_) {
    }
  }

  private mapFailure(error: Object | undefined, defaultKind: SecretFailureKind): SubscriptionSecretError {
    let kind: SecretFailureKind = defaultKind;
    if (isSecretStoreFailure(error)) {
      kind = (error as SecretStoreFailure).kind;
    }
    switch (kind) {
      case 'MISSING':
        return createSubscriptionSecretError('SOURCE_SECRET_MISSING', 'Subscription secret source is missing.');
      case 'UNSUPPORTED':
        return createSubscriptionSecretError('SOURCE_SECRET_VERSION_UNSUPPORTED', 'Subscription secret source version is unsupported.');
      case 'DECRYPT':
        return createSubscriptionSecretError('SOURCE_DECRYPT_FAILED', 'Subscription secret source could not be decrypted.');
      case 'WRITE':
      default:
        return createSubscriptionSecretError('SOURCE_SECRET_WRITE_FAILED', 'Subscription secret source could not be stored.');
    }
  }
}

class HilogSecretStoreDiagnosticSink implements SecretStoreDiagnosticSink {
  report(stage: string, code: number): void {
    hilog.error(
      SECRET_DIAGNOSTIC_DOMAIN,
      SECRET_DIAGNOSTIC_TAG,
      '%{public}s:%{public}d',
      stage,
      code
    );
  }
}

function validatePayloadForSerialization(payload: HuksEncryptedPayload): void {
  if (payload.keyAliasVersion !== HUKS_SECRET_KEY_ALIAS_VERSION ||
    payload.nonce.length !== HUKS_SECRET_NONCE_LENGTH ||
    payload.tag.length !== HUKS_SECRET_TAG_LENGTH ||
    payload.ciphertext.length === 0) {
    throw new SecretStoreFailure('WRITE');
  }
}

function serializeEnvelope(payload: HuksEncryptedPayload): string {
  const envelope = new SecretEnvelopeShape(
    ENVELOPE_VERSION,
    encodeBase64(payload.nonce),
    encodeBase64(payload.ciphertext),
    encodeBase64(payload.tag),
    payload.keyAliasVersion
  );
  return JSON.stringify(envelope);
}

function parseEnvelope(rawText: string): SecretEnvelopeShape {
  try {
    const parsed: Object = JSON.parse(rawText) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new SecretStoreFailure('DECRYPT');
    }
    const record = parsed as Record<string, Object>;
    if (record.version === undefined ||
      record.nonce === undefined ||
      record.ciphertext === undefined ||
      record.tag === undefined ||
      record.keyAliasVersion === undefined) {
      throw new SecretStoreFailure('DECRYPT');
    }
    const envelope = new SecretEnvelopeShape(
      requireFiniteNumber(record.version),
      requireString(record.nonce),
      requireString(record.ciphertext),
      requireString(record.tag),
      requireFiniteNumber(record.keyAliasVersion)
    );
    if (JSON.stringify(parsed) !== JSON.stringify(envelope)) {
      throw new SecretStoreFailure('DECRYPT');
    }
    return envelope;
  } catch (error) {
    if (isSecretStoreFailure(error)) {
      throw error as SecretStoreFailure;
    }
    throw new SecretStoreFailure('DECRYPT');
  }
}

function requireString(value: Object | undefined): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new SecretStoreFailure('DECRYPT');
  }
  return value;
}

function requireFiniteNumber(value: Object | undefined): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new SecretStoreFailure('DECRYPT');
  }
  return value;
}

function normalizeOpaqueId(rawValue: string, missingOnInvalid: boolean): string {
  if (!/^[A-Za-z0-9_-]+$/u.test(rawValue)) {
    throw new SecretStoreFailure(missingOnInvalid ? 'MISSING' : 'WRITE');
  }
  return rawValue;
}

function secretDirectoryPath(filesDir: string): string {
  return joinAbsoluteSandboxPath(filesDir, SECRET_DIRECTORY);
}

function secretEnvelopePath(filesDir: string, opaqueId: string): string {
  return joinAbsoluteSandboxPath(secretDirectoryPath(filesDir), `${opaqueId}${SECRET_SUFFIX}`);
}

function secretTemporaryPath(filesDir: string, opaqueId: string, temporaryId: string): string {
  return joinAbsoluteSandboxPath(secretDirectoryPath(filesDir), `${opaqueId}.${temporaryId}${TEMP_SUFFIX}`);
}

function isManagedTemporaryName(fileName: string): boolean {
  const parts: string[] = fileName.split('.');
  return parts.length === 3 &&
    normalizeManagedPart(parts[0]) &&
    normalizeManagedPart(parts[1]) &&
    parts[2] === 'tmp';
}

function managedEnvelopeId(fileName: string): string | undefined {
  if (!fileName.endsWith(SECRET_SUFFIX)) {
    return undefined;
  }
  const opaqueId: string = fileName.substring(0, fileName.length - SECRET_SUFFIX.length);
  return normalizeManagedPart(opaqueId) ? opaqueId : undefined;
}

function normalizeManagedPart(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value);
}

function normalizeAbsoluteSandboxPath(rawPath: string, label: string): string {
  if (rawPath.trim() !== rawPath || rawPath.length === 0 || !rawPath.startsWith('/')) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  if (rawPath.indexOf('\\') >= 0 || rawPath.indexOf('%') >= 0 || rawPath.indexOf(':') >= 0) {
    throw new Error(`${label} must be a canonical absolute sandbox path.`);
  }
  const rawSegments: string[] = rawPath.split('/');
  const normalizedSegments: string[] = [];
  for (let index = 1; index < rawSegments.length; index += 1) {
    const segment: string = rawSegments[index];
    if (!isCanonicalPathSegment(segment)) {
      throw new Error(`${label} must be a canonical absolute sandbox path.`);
    }
    normalizedSegments.push(segment);
  }
  return `/${normalizedSegments.join('/')}`;
}

function joinAbsoluteSandboxPath(base: string, child: string): string {
  if (base === '/') {
    return normalizeAbsoluteSandboxPath(`/${child}`, 'Sandbox path');
  }
  return normalizeAbsoluteSandboxPath(`${base}/${child}`, 'Sandbox path');
}

function isCanonicalPathSegment(segment: string): boolean {
  return segment.length > 0 &&
    segment !== '.' &&
    segment !== '..' &&
    !/\s/u.test(segment) &&
    segment.indexOf('/') < 0 &&
    segment.indexOf('\\') < 0 &&
    segment.indexOf('%') < 0 &&
    segment.indexOf(':') < 0;
}

function sliceBytes(bytes: Uint8Array, start: number, length: number): Uint8Array {
  const copy = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    copy[index] = bytes[start + index];
  }
  return copy;
}

function encodeUtf8(value: string): Uint8Array {
  const bytes: number[] = [];
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (codeUnit < 0x80) {
      bytes.push(codeUnit);
      index += 1;
      continue;
    }
    if (codeUnit < 0x800) {
      bytes.push(0xc0 | (codeUnit >> 6));
      bytes.push(0x80 | (codeUnit & 0x3f));
      index += 1;
      continue;
    }
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff && index + 1 < value.length) {
      const nextCodeUnit: number = value.charCodeAt(index + 1);
      if (nextCodeUnit >= 0xdc00 && nextCodeUnit <= 0xdfff) {
        const codePoint: number = 0x10000 + ((codeUnit - 0xd800) << 10) + (nextCodeUnit - 0xdc00);
        bytes.push(0xf0 | (codePoint >> 18));
        bytes.push(0x80 | ((codePoint >> 12) & 0x3f));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
        bytes.push(0x80 | (codePoint & 0x3f));
        index += 2;
        continue;
      }
    }
    bytes.push(0xe0 | (codeUnit >> 12));
    bytes.push(0x80 | ((codeUnit >> 6) & 0x3f));
    bytes.push(0x80 | (codeUnit & 0x3f));
    index += 1;
  }
  const result = new Uint8Array(bytes.length);
  for (let position = 0; position < bytes.length; position += 1) {
    result[position] = bytes[position];
  }
  return result;
}

function decodeUtf8(bytes: Uint8Array): string {
  let decoded = '';
  let index = 0;
  while (index < bytes.length) {
    const first: number = bytes[index];
    if (first < 0x80) {
      decoded += String.fromCharCode(first);
      index += 1;
      continue;
    }
    if ((first & 0xe0) === 0xc0 && index + 1 < bytes.length) {
      const second: number = requireContinuation(bytes[index + 1]);
      const codePoint: number = ((first & 0x1f) << 6) | second;
      decoded += String.fromCharCode(codePoint);
      index += 2;
      continue;
    }
    if ((first & 0xf0) === 0xe0 && index + 2 < bytes.length) {
      const second: number = requireContinuation(bytes[index + 1]);
      const third: number = requireContinuation(bytes[index + 2]);
      const codePoint: number = ((first & 0x0f) << 12) | (second << 6) | third;
      decoded += String.fromCharCode(codePoint);
      index += 3;
      continue;
    }
    if ((first & 0xf8) === 0xf0 && index + 3 < bytes.length) {
      const second: number = requireContinuation(bytes[index + 1]);
      const third: number = requireContinuation(bytes[index + 2]);
      const fourth: number = requireContinuation(bytes[index + 3]);
      const codePoint: number = ((first & 0x07) << 18) | (second << 12) | (third << 6) | fourth;
      const adjusted: number = codePoint - 0x10000;
      decoded += String.fromCharCode(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff));
      index += 4;
      continue;
    }
    throw new SecretStoreFailure('DECRYPT');
  }
  return decoded;
}

function requireContinuation(byte: number): number {
  if ((byte & 0xc0) !== 0x80) {
    throw new SecretStoreFailure('DECRYPT');
  }
  return byte & 0x3f;
}

function encodeBase64(bytes: Uint8Array): string {
  let encoded = '';
  let index = 0;
  while (index < bytes.length) {
    const first: number = bytes[index];
    const second: number = index + 1 < bytes.length ? bytes[index + 1] : -1;
    const third: number = index + 2 < bytes.length ? bytes[index + 2] : -1;
    encoded += BASE64_ALPHABET[(first >> 2) & 0x3f];
    encoded += BASE64_ALPHABET[((first & 0x03) << 4) | (second >= 0 ? ((second >> 4) & 0x0f) : 0)];
    encoded += second >= 0 ? BASE64_ALPHABET[((second & 0x0f) << 2) | (third >= 0 ? ((third >> 6) & 0x03) : 0)] : '=';
    encoded += third >= 0 ? BASE64_ALPHABET[third & 0x3f] : '=';
    index += 3;
  }
  return encoded;
}

function decodeBase64(encoded: string, expectedLength?: number): Uint8Array {
  if (encoded.length === 0 || encoded.length % 4 !== 0 || /\s/u.test(encoded)) {
    throw new SecretStoreFailure('DECRYPT');
  }
  let paddingCount = 0;
  if (encoded.endsWith('==')) {
    paddingCount = 2;
  } else if (encoded.endsWith('=')) {
    paddingCount = 1;
  }
  const outputLength: number = (encoded.length / 4) * 3 - paddingCount;
  const decoded = new Uint8Array(outputLength);
  let writeIndex = 0;
  for (let index = 0; index < encoded.length; index += 4) {
    const a: number = decodeBase64Char(encoded[index]);
    const b: number = decodeBase64Char(encoded[index + 1]);
    const c: number = encoded[index + 2] === '=' ? -1 : decodeBase64Char(encoded[index + 2]);
    const d: number = encoded[index + 3] === '=' ? -1 : decodeBase64Char(encoded[index + 3]);
    decoded[writeIndex] = ((a << 2) | (b >> 4)) & 0xff;
    writeIndex += 1;
    if (c >= 0 && writeIndex <= decoded.length) {
      decoded[writeIndex] = (((b & 0x0f) << 4) | (c >> 2)) & 0xff;
      writeIndex += 1;
    }
    if (d >= 0 && writeIndex <= decoded.length) {
      decoded[writeIndex] = (((c & 0x03) << 6) | d) & 0xff;
      writeIndex += 1;
    }
  }
  if (expectedLength !== undefined && decoded.length !== expectedLength) {
    throw new SecretStoreFailure('DECRYPT');
  }
  if (decoded.length === 0) {
    throw new SecretStoreFailure('DECRYPT');
  }
  return decoded;
}

function decodeBase64Char(value: string): number {
  const index: number = BASE64_ALPHABET.indexOf(value);
  if (index < 0) {
    throw new SecretStoreFailure('DECRYPT');
  }
  return index;
}

function isSecretStoreFailure(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record = value as Record<string, Object>;
  return record.name === 'SecretStoreFailure' &&
    (record.kind === 'MISSING' ||
      record.kind === 'DECRYPT' ||
      record.kind === 'UNSUPPORTED' ||
      record.kind === 'WRITE');
}
