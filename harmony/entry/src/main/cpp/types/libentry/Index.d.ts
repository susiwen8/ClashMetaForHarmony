export type RuntimeState = 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
export type LogLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

export interface LocalOptions {
  configPath: string;
  mixedPort: number;
}

export interface RuntimeSnapshot {
  state: RuntimeState;
  activeConfigPath: string;
  httpAddress: string;
  socksAddress: string;
  lastError: string;
  mixedPort: number;
}

export type CoreEvent =
  | { type: 'runtime'; state: RuntimeState; message: string }
  | { type: 'log'; level: LogLevel; message: string };

export interface CoreErrorContext {
  operation: string;
  status: number;
}

export interface CoreError extends Error {
  name: 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError';
  detail: string;
  retryable: boolean;
  action: string;
  context?: CoreErrorContext;
}

export declare function hello(): string;
export declare function coreVersion(): Promise<string>;
export declare function validateConfiguration(path: string): Promise<void>;
export declare function loadConfiguration(path: string): Promise<void>;
export declare function startLocal(options: LocalOptions): Promise<RuntimeSnapshot>;
export declare function stopRuntime(): Promise<RuntimeSnapshot>;
export declare function runtimeSnapshot(): RuntimeSnapshot;
export declare function subscribe(callback: (event: CoreEvent) => void): number;
export declare function unsubscribe(subscriptionId: number): void;
