export type RuntimeState = 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
export type LogLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

export interface LocalOptions {
  configPath: string;
  mixedPort: number;
}

export interface RuntimeSnapshot {
  state: RuntimeState;
  activeConfigPath: string;
  mixedPort: number;
}

export interface RuntimeEvent {
  type: 'runtime';
  state: RuntimeState;
  message: string;
}

export interface LogEvent {
  type: 'log';
  level: LogLevel;
  message: string;
}

export type CoreEvent = RuntimeEvent | LogEvent;

export interface Phase1Timestamps {
  startedAt: string;
  proofAt: string;
}

export type Phase1CheckId =
  | 'nativeHello'
  | 'coreVersion'
  | 'promiseResolution'
  | 'typedRejection'
  | 'eventDelivery'
  | 'unsubscribeSilence';

export type Phase1CheckState = 'pass' | 'fail' | 'not-run';

export interface Phase1Check {
  id: Phase1CheckId;
  result: Phase1CheckState;
  detail: string;
}

export interface Phase1Failure {
  code: string;
  detail: string;
  stage: string;
}

export interface Phase1CoreErrorEvidence {
  name: 'CoreError';
  code: string;
  category: 'CoreError' | 'StateError';
  message: string;
  detail: string;
  retryable: boolean;
  action: string;
  context: Phase1CoreErrorContext;
}

export interface Phase1CoreErrorContext {
  operation: string;
  status: number;
}

export interface Phase1SelfTestProof {
  schemaVersion: '1.0.0';
  phase: 1;
  result: 'pass' | 'fail' | 'incomplete';
  runId: string;
  timestamps: Phase1Timestamps;
  bridgeVersion: string;
  coreVersion: string;
  eventCount: number;
  lastError: Phase1CoreErrorEvidence | null;
  checks: Phase1Check[];
  failures: Phase1Failure[];
}
