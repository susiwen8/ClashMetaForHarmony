import type { CoreError } from '../core/CoreErrors';
import { createAppError, defaultErrorCodeForStage, type AppError, type AppErrorStage } from './AppErrors';
import { redactSensitiveText } from './SecretRedactor';

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

export function mapCoreError(requestedOperation: string, error: CoreError): AppError {
  const operation: string = resolveAllowedOperation(requestedOperation, error.context?.operation);
  const stage: AppErrorStage = resolveStageFromOperation(operation);
  const code: string = error.code.trim().length > 0 ? error.code.trim() : defaultErrorCodeForStage(stage);
  const technicalDetail: string = redactSensitiveText(error.detail);
  return createAppError(stage, technicalDetail, {
    code,
    retryable: error.retryable
  });
}
