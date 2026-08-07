import type { CoreError } from '../core/CoreErrors';
import { createAppError, defaultErrorCodeForStage, type AppError, type AppErrorStage } from './AppErrors';
import { redactSensitiveText } from './SecretRedactor';

const ALLOWED_CORE_ERROR_CODES: string[] = [
  'CMFA_INVALID_ARGUMENT',
  'CMFA_INVALID_UTF8',
  'CMFA_OUT_OF_RANGE',
  'CMFA_BUFFER_TOO_SMALL',
  'CMFA_NOT_INITIALIZED',
  'CMFA_ALREADY_INITIALIZED',
  'CMFA_INVALID_STATE',
  'CMFA_BUSY',
  'CMFA_CORE_UNAVAILABLE',
  'CMFA_BACKEND_ERROR',
  'NAPI_FAILURE'
];

function resolveStageFromOperation(operation: string): AppErrorStage {
  switch (operation) {
    case 'validate':
      return 'VALIDATION';
    case 'load':
      return 'CORE_LOAD';
    case 'startLocal':
      return 'RUNTIME_START';
    case 'stop':
      return 'RUNTIME_STOP';
    default:
      return 'CORE_LOAD';
  }
}

function resolveAllowedOperation(requestedOperation: string, coreOperation?: string): string {
  const candidates: string[] = [];
  if (coreOperation !== undefined && coreOperation.trim().length > 0) {
    candidates.push(coreOperation.trim());
  }
  if (requestedOperation.trim().length > 0) {
    candidates.push(requestedOperation.trim());
  }

  for (let index = 0; index < candidates.length; index += 1) {
    const candidate: string = candidates[index];
    if (candidate === 'validate' || candidate === 'load' || candidate === 'startLocal' || candidate === 'stop') {
      return candidate;
    }
  }
  return 'load';
}

function normalizeCoreMappedCode(rawCode: string, stage: AppErrorStage): string {
  const normalizedCode: string = rawCode.trim();
  for (let index: number = 0; index < ALLOWED_CORE_ERROR_CODES.length; index += 1) {
    if (ALLOWED_CORE_ERROR_CODES[index] === normalizedCode) {
      return normalizedCode;
    }
  }
  return defaultErrorCodeForStage(stage);
}

export function mapCoreError(requestedOperation: string, error: CoreError): AppError {
  const operation: string = resolveAllowedOperation(requestedOperation, error.context?.operation);
  const stage: AppErrorStage = resolveStageFromOperation(operation);
  const code: string = normalizeCoreMappedCode(error.code, stage);
  const technicalDetail: string = redactSensitiveText(error.detail);
  return createAppError(stage, technicalDetail, {
    code,
    retryable: error.retryable
  });
}
