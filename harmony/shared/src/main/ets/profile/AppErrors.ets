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
  const timestamp: string = options?.timestamp !== undefined && options.timestamp.trim().length > 0
    ? options.timestamp.trim()
    : new Date().toISOString();
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
