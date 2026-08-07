export type AppErrorStage =
  'IMPORT' |
  'DOWNLOAD' |
  'VALIDATION' |
  'PERSISTENCE' |
  'CORE_LOAD' |
  'RUNTIME_START' |
  'RUNTIME_STOP';

export const APP_ERROR_STAGES: AppErrorStage[] = [
  'IMPORT',
  'DOWNLOAD',
  'VALIDATION',
  'PERSISTENCE',
  'CORE_LOAD',
  'RUNTIME_START',
  'RUNTIME_STOP'
];

export interface AppError {
  code: string;
  stage: AppErrorStage;
  userMessageResource: string;
  technicalDetail: string;
  timestamp: string;
  retryable: boolean;
}

export interface CreateAppErrorOptions {
  code?: string;
  timestamp?: string;
  retryable?: boolean;
  userMessageResource?: string;
}

const CANONICAL_UTC_ISO_PATTERN: RegExp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u;

export function normalizeCanonicalUtcIsoTimestamp(rawTimestamp: string, label: string): string {
  const normalizedTimestamp: string = rawTimestamp.trim();
  if (!CANONICAL_UTC_ISO_PATTERN.test(normalizedTimestamp)) {
    throw new Error(`${label} must be canonical ISO-8601 UTC.`);
  }

  const year: number = Number.parseInt(normalizedTimestamp.substring(0, 4), 10);
  const month: number = Number.parseInt(normalizedTimestamp.substring(5, 7), 10);
  const day: number = Number.parseInt(normalizedTimestamp.substring(8, 10), 10);
  const hour: number = Number.parseInt(normalizedTimestamp.substring(11, 13), 10);
  const minute: number = Number.parseInt(normalizedTimestamp.substring(14, 16), 10);
  const second: number = Number.parseInt(normalizedTimestamp.substring(17, 19), 10);
  const millisecond: number = Number.parseInt(normalizedTimestamp.substring(20, 23), 10);
  const parsedTimestamp: Date = new Date(Date.UTC(year, month - 1, day, hour, minute, second, millisecond));

  if (parsedTimestamp.getUTCFullYear() !== year ||
    parsedTimestamp.getUTCMonth() !== month - 1 ||
    parsedTimestamp.getUTCDate() !== day ||
    parsedTimestamp.getUTCHours() !== hour ||
    parsedTimestamp.getUTCMinutes() !== minute ||
    parsedTimestamp.getUTCSeconds() !== second ||
    parsedTimestamp.getUTCMilliseconds() !== millisecond ||
    parsedTimestamp.toISOString() !== normalizedTimestamp) {
    throw new Error(`${label} must be canonical ISO-8601 UTC.`);
  }
  return normalizedTimestamp;
}

export function defaultErrorCodeForStage(stage: AppErrorStage): string {
  switch (stage) {
    case 'IMPORT':
      return 'CMFA_IMPORT_FAILED';
    case 'DOWNLOAD':
      return 'CMFA_DOWNLOAD_FAILED';
    case 'VALIDATION':
      return 'CMFA_VALIDATION_FAILED';
    case 'PERSISTENCE':
      return 'CMFA_PERSISTENCE_FAILED';
    case 'CORE_LOAD':
      return 'CMFA_CORE_LOAD_FAILED';
    case 'RUNTIME_START':
      return 'CMFA_RUNTIME_START_FAILED';
    case 'RUNTIME_STOP':
      return 'CMFA_RUNTIME_STOP_FAILED';
    default:
      return 'CMFA_APP_ERROR';
  }
}

export function defaultUserMessageResourceForStage(stage: AppErrorStage): string {
  switch (stage) {
    case 'IMPORT':
      return 'error.import';
    case 'DOWNLOAD':
      return 'error.download';
    case 'VALIDATION':
      return 'error.validation';
    case 'PERSISTENCE':
      return 'error.persistence';
    case 'CORE_LOAD':
      return 'error.core.load';
    case 'RUNTIME_START':
      return 'error.runtime.start';
    case 'RUNTIME_STOP':
      return 'error.runtime.stop';
    default:
      return 'error.generic';
  }
}

export function createAppError(
  stage: AppErrorStage,
  technicalDetail: string,
  options?: CreateAppErrorOptions
): AppError {
  const normalizedDetail: string = technicalDetail.trim().length > 0
    ? technicalDetail.trim()
    : 'Operation failed.';
  const code: string = options?.code !== undefined && options.code.trim().length > 0
    ? options.code.trim()
    : defaultErrorCodeForStage(stage);
  const timestampInput: string = options?.timestamp !== undefined && options.timestamp.trim().length > 0
    ? options.timestamp
    : new Date().toISOString();
  const timestamp: string = normalizeCanonicalUtcIsoTimestamp(timestampInput, 'App error timestamp');
  const userMessageResource: string = options?.userMessageResource !== undefined &&
    options.userMessageResource.trim().length > 0
    ? options.userMessageResource.trim()
    : defaultUserMessageResourceForStage(stage);

  return {
    code,
    stage,
    userMessageResource,
    technicalDetail: normalizedDetail,
    timestamp,
    retryable: options?.retryable === true
  };
}
