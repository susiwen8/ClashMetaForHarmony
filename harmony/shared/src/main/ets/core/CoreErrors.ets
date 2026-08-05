export interface CoreErrorContext {
  operation: string;
  status: number;
}

export interface CoreError {
  name: 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError';
  message: string;
  detail: string;
  retryable: boolean;
  action: string;
  context?: CoreErrorContext;
}

export class CoreErrorException extends Error implements CoreError {
  name: 'CoreError' = 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError';
  detail: string;
  retryable: boolean;
  action: string;
  context?: CoreErrorContext;

  constructor(operation: string, value: Error | Record<string, Object> | undefined) {
    const record: Record<string, Object> = value !== undefined && typeof value === 'object'
      ? (value as Record<string, Object>)
      : {};
    const message: string = typeof record.message === 'string' && record.message.length > 0
      ? record.message
      : 'Native bridge operation failed.';
    super(message);
    this.code = typeof record.code === 'string' && record.code.length > 0
      ? record.code
      : 'CMFA_NATIVE_ERROR';
    this.category = record.category === 'StateError' ? 'StateError' : 'CoreError';
    this.detail = typeof record.detail === 'string' && record.detail.length > 0
      ? record.detail
      : `Native bridge operation ${operation} failed.`;
    this.retryable = record.retryable === true;
    this.action = typeof record.action === 'string' && record.action.length > 0
      ? record.action
      : 'Check the supplied value.';
    if (record.context !== undefined && typeof record.context === 'object') {
      const contextRecord: Record<string, Object> = record.context as Record<string, Object>;
      this.context = {
        operation: typeof contextRecord.operation === 'string' && contextRecord.operation.length > 0
          ? contextRecord.operation
          : operation,
        status: typeof contextRecord.status === 'number'
          ? Number.parseInt(`${contextRecord.status}`, 10)
          : -1
      };
    } else {
      this.context = {
        operation,
        status: -1
      };
    }
  }
}

export function isCoreError(value: Object | undefined): boolean {
  if (value === undefined || typeof value !== 'object') {
    return false;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return record.name === 'CoreError' &&
    typeof record.code === 'string' &&
    typeof record.message === 'string' &&
    typeof record.detail === 'string' &&
    typeof record.action === 'string';
}

export function normalizeCoreError(operation: string, value: Error | Object | undefined): CoreErrorException {
  return new CoreErrorException(operation, value as Error | Record<string, Object> | undefined);
}
