import {
  APP_ERROR_STAGES,
  PROFILE_AVAILABILITIES,
  createAppError,
  createProfile,
  createProfileRevision,
  redactSensitiveText,
  type AppError,
  type AppErrorStage,
  type Profile,
  type ProfileAvailability,
  type ProfileRevision,
  type ProfileSourceKind
} from '@cmfa/shared';
import type { DurableProfileRow } from './RdbDriver';

export type { DurableProfileRow } from './RdbDriver';

class EncodedRemoteDisplay {
  readonly scheme: string;
  readonly authority: string;

  constructor(scheme: string, authority: string) {
    this.scheme = scheme;
    this.authority = authority;
  }
}

class ParsedRevisionShape {
  readonly relativePath: string;
  readonly sha256Digest: string;
  readonly byteLength: number;
  readonly validatedAt: string;

  constructor(relativePath: string, sha256Digest: string, byteLength: number, validatedAt: string) {
    this.relativePath = relativePath;
    this.sha256Digest = sha256Digest;
    this.byteLength = byteLength;
    this.validatedAt = validatedAt;
  }
}

class ParsedErrorShape {
  readonly stage: AppErrorStage;
  readonly code: string;
  readonly userMessageResource: string;
  readonly technicalDetail: string;
  readonly timestamp: string;
  readonly retryable: boolean;

  constructor(
    stage: AppErrorStage,
    code: string,
    userMessageResource: string,
    technicalDetail: string,
    timestamp: string,
    retryable: boolean
  ) {
    this.stage = stage;
    this.code = code;
    this.userMessageResource = userMessageResource;
    this.technicalDetail = technicalDetail;
    this.timestamp = timestamp;
    this.retryable = retryable;
  }
}

const SCHEMA_VERSION = 2;
const UTF16_HEX_ENCODING = 'utf16hex';
const LEGACY_SCHEMA_VERSION = 1;

function textToUtf16Hex(rawText: string): string {
  let encoded = '';
  for (let index = 0; index < rawText.length; index += 1) {
    const codeUnit: string = rawText.charCodeAt(index).toString(16).padStart(4, '0');
    encoded += codeUnit;
  }
  return encoded;
}

function utf16HexToText(encodedText: string, label: string): string {
  if (encodedText.length % 4 !== 0) {
    throw new Error(`${label} must use 4-digit UTF-16 hex groups.`);
  }
  let decoded = '';
  for (let index = 0; index < encodedText.length; index += 4) {
    const group: string = encodedText.substring(index, index + 4);
    const codeUnit: number = Number.parseInt(group, 16);
    if (codeUnit !== codeUnit) {
      throw new Error(`${label} contains invalid UTF-16 hex.`);
    }
    decoded += String.fromCharCode(codeUnit);
  }
  return decoded;
}

function encodeRevision(revision: ProfileRevision | null): string | null {
  if (revision === null) {
    return null;
  }
  return JSON.stringify({
    relativePath: revision.relativePath,
    sha256Digest: revision.sha256Digest,
    byteLength: revision.byteLength,
    validatedAt: revision.validatedAt
  });
}

function encodeError(error: AppError | null): string | null {
  if (error === null) {
    return null;
  }
  return JSON.stringify({
    stage: error.stage,
    code: error.code,
    userMessageResource: error.userMessageResource,
    technicalDetailEncoding: UTF16_HEX_ENCODING,
    technicalDetail: textToUtf16Hex(error.technicalDetail),
    timestamp: error.timestamp,
    retryable: error.retryable
  });
}

function encodeRemoteDisplay(sourceDisplay: string): string {
  const separatorIndex: number = sourceDisplay.indexOf('://');
  if (separatorIndex <= 0) {
    throw new Error('Remote profile source display must include a scheme and authority.');
  }
  const scheme: string = sourceDisplay.substring(0, separatorIndex);
  const authority: string = sourceDisplay.substring(separatorIndex + 3);
  return JSON.stringify(new EncodedRemoteDisplay(scheme, authority));
}

function encodeSecretRef(sourceSecretRef: string | undefined): string | undefined {
  if (sourceSecretRef === undefined) {
    return undefined;
  }
  return `${UTF16_HEX_ENCODING}:${textToUtf16Hex(sourceSecretRef)}`;
}

export function encodeProfileRow(profile: Profile): DurableProfileRow {
  return {
    schemaVersion: SCHEMA_VERSION,
    id: profile.id,
    name: profile.name,
    sourceKind: profile.sourceKind,
    sourceDisplay: profile.sourceKind === 'REMOTE_URL'
      ? encodeRemoteDisplay(profile.sourceDisplay)
      : profile.sourceDisplay,
    sourceSecretRef: encodeSecretRef(profile.sourceSecretRef),
    currentRevisionJson: encodeRevision(profile.currentRevision),
    failedCandidateJson: encodeRevision(profile.failedCandidate),
    availability: profile.availability,
    lastErrorJson: encodeError(profile.lastError),
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    lastSuccessfulUpdateAt: profile.lastSuccessfulUpdateAt,
    autoUpdateIntervalMs: profile.autoUpdateIntervalMs
  };
}

function requireString(value: Object | null | undefined, label: string): string {
  if (typeof value !== 'string') {
    throw new Error(`${label} must be a string.`);
  }
  return value;
}

function requireNullableString(value: Object | null | undefined, label: string): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return requireString(value, label);
}

function requireNumber(value: Object | null | undefined, label: string): number {
  if (typeof value !== 'number' || value !== value) {
    throw new Error(`${label} must be a number.`);
  }
  return value;
}

function requireBoolean(value: Object | null | undefined, label: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(`${label} must be a boolean.`);
  }
  return value;
}

function isKnownAvailability(value: string): boolean {
  for (let index = 0; index < PROFILE_AVAILABILITIES.length; index += 1) {
    if (PROFILE_AVAILABILITIES[index] === value) {
      return true;
    }
  }
  return false;
}

function isKnownStage(value: string): boolean {
  for (let index = 0; index < APP_ERROR_STAGES.length; index += 1) {
    if (APP_ERROR_STAGES[index] === value) {
      return true;
    }
  }
  return false;
}

function parseJsonRecord(rawJson: string, label: string): Record<string, Object> {
  try {
    const parsed: Object = JSON.parse(rawJson) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error(`${label} must decode to an object.`);
    }
    return parsed as Record<string, Object>;
  } catch (error) {
    if (error instanceof Error) {
      throw new Error(`${label} JSON is invalid: ${error.message}`);
    }
    throw new Error(`${label} JSON is invalid.`);
  }
}

function decodeRevision(rawJson: string | null, label: string): ProfileRevision | null {
  if (rawJson === null) {
    return null;
  }
  const record: Record<string, Object> = parseJsonRecord(rawJson, label);
  return createProfileRevision(
    requireString(record.relativePath, `${label}.relativePath`),
    requireString(record.sha256Digest, `${label}.sha256Digest`),
    requireNumber(record.byteLength, `${label}.byteLength`),
    requireString(record.validatedAt, `${label}.validatedAt`)
  );
}

function decodeError(rawJson: string | null): AppError | null {
  if (rawJson === null) {
    return null;
  }
  const record: Record<string, Object> = parseJsonRecord(rawJson, 'lastErrorJson');
  const stageValue: string = requireString(record.stage, 'lastErrorJson.stage');
  if (!isKnownStage(stageValue)) {
    throw new Error('lastErrorJson.stage must be a known AppError stage.');
  }
  let technicalDetail: string = requireString(record.technicalDetail, 'lastErrorJson.technicalDetail');
  const encoding: string | null = requireNullableString(record.technicalDetailEncoding, 'lastErrorJson.technicalDetailEncoding');
  if (encoding !== null) {
    if (encoding !== UTF16_HEX_ENCODING) {
      throw new Error('lastErrorJson.technicalDetailEncoding is unsupported.');
    }
    technicalDetail = utf16HexToText(technicalDetail, 'lastErrorJson.technicalDetail');
  }
  if (technicalDetail !== redactSensitiveText(technicalDetail)) {
    throw new Error(`lastErrorJson contains unredacted detail: ${redactSensitiveText(technicalDetail)}`);
  }
  const parsed = new ParsedErrorShape(
    stageValue as AppErrorStage,
    requireString(record.code, 'lastErrorJson.code'),
    requireString(record.userMessageResource, 'lastErrorJson.userMessageResource'),
    technicalDetail,
    requireString(record.timestamp, 'lastErrorJson.timestamp'),
    requireBoolean(record.retryable, 'lastErrorJson.retryable')
  );
  return createAppError(parsed.stage, parsed.technicalDetail, {
    code: parsed.code,
    userMessageResource: parsed.userMessageResource,
    timestamp: parsed.timestamp,
    retryable: parsed.retryable
  });
}

function decodeSourceDisplay(sourceKind: ProfileSourceKind, encoded: string): string {
  if (sourceKind === 'LOCAL_FILE') {
    return encoded;
  }
  const record: Record<string, Object> = parseJsonRecord(encoded, 'sourceDisplay');
  const scheme: string = requireString(record.scheme, 'sourceDisplay.scheme');
  const authority: string = requireString(record.authority, 'sourceDisplay.authority');
  if (scheme !== 'http' && scheme !== 'https') {
    throw new Error('sourceDisplay.scheme must be http or https.');
  }
  return `${scheme}://${authority}`;
}

function decodeSecretRef(sourceKind: ProfileSourceKind, rawSourceSecretRef: string | null): string | undefined {
  if (rawSourceSecretRef === null) {
    return undefined;
  }
  if (!rawSourceSecretRef.startsWith(`${UTF16_HEX_ENCODING}:`)) {
    if (sourceKind === 'REMOTE_URL') {
      throw new Error('sourceSecretRef must use encoded remote secret storage.');
    }
    return rawSourceSecretRef;
  }
  return utf16HexToText(rawSourceSecretRef.substring(UTF16_HEX_ENCODING.length + 1), 'sourceSecretRef');
}

function decodeSourceKind(rawSourceKind: string): ProfileSourceKind {
  if (rawSourceKind === 'LOCAL_FILE' || rawSourceKind === 'REMOTE_URL') {
    return rawSourceKind;
  }
  throw new Error('source kind must be LOCAL_FILE or REMOTE_URL.');
}

function decodeAvailability(rawAvailability: string): ProfileAvailability {
  if (isKnownAvailability(rawAvailability)) {
    return rawAvailability as ProfileAvailability;
  }
  throw new Error('availability must be a known Profile availability.');
}

function decodeAutoUpdateIntervalMs(row: DurableProfileRow, schemaVersion: number): number {
  if (schemaVersion === LEGACY_SCHEMA_VERSION) {
    return 0;
  }
  const autoUpdateIntervalMs: number = requireNumber(row.autoUpdateIntervalMs as Object, 'autoUpdateIntervalMs');
  if (!Number.isSafeInteger(autoUpdateIntervalMs) || autoUpdateIntervalMs < 0) {
    throw new Error('autoUpdateIntervalMs must be a safe non-negative integer.');
  }
  return autoUpdateIntervalMs;
}

export function decodeProfileRow(row: DurableProfileRow): Profile {
  const schemaVersion: number = requireNumber(row.schemaVersion as Object, 'schemaVersion');
  if (schemaVersion !== LEGACY_SCHEMA_VERSION && schemaVersion !== SCHEMA_VERSION) {
    throw new Error(`Unsupported schema version ${schemaVersion}.`);
  }
  const sourceKind: ProfileSourceKind = decodeSourceKind(requireString(row.sourceKind as Object, 'sourceKind'));
  return createProfile({
    id: requireString(row.id as Object, 'id'),
    name: requireString(row.name as Object, 'name'),
    sourceKind,
    sourceDisplay: decodeSourceDisplay(sourceKind, requireString(row.sourceDisplay as Object, 'sourceDisplay')),
    sourceSecretRef: decodeSecretRef(sourceKind, requireNullableString(row.sourceSecretRef, 'sourceSecretRef')),
    currentRevision: decodeRevision(requireNullableString(row.currentRevisionJson, 'currentRevisionJson'), 'currentRevisionJson'),
    failedCandidate: decodeRevision(requireNullableString(row.failedCandidateJson, 'failedCandidateJson'), 'failedCandidateJson'),
    availability: decodeAvailability(requireString(row.availability as Object, 'availability')),
    lastError: decodeError(requireNullableString(row.lastErrorJson, 'lastErrorJson')),
    createdAt: requireString(row.createdAt as Object, 'createdAt'),
    updatedAt: requireString(row.updatedAt as Object, 'updatedAt'),
    lastSuccessfulUpdateAt: requireNullableString(row.lastSuccessfulUpdateAt, 'lastSuccessfulUpdateAt'),
    autoUpdateIntervalMs: decodeAutoUpdateIntervalMs(row, schemaVersion)
  });
}
