import { redactSensitiveText } from '../profile/SecretRedactor';
import type { LogLevel } from '../core/CoreModels';

const MAX_RUNTIME_LOG_MESSAGE_LENGTH: number = 4096;
const MAX_RUNTIME_LOG_TIMESTAMP_LENGTH: number = 64;
const SANITIZED_URL_PATTERN: RegExp = /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s"'<>]+/gu;

export interface RuntimeLogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
}

export type RuntimeLogFilterLevel = 'ALL' | LogLevel;
export type RuntimeLogExportResult = 'EXPORTED' | 'CANCELLED' | 'FAILED';

export interface RuntimeLogStorePort {
  append(entry: RuntimeLogEntry): Promise<void>;
  read(limit?: number): Promise<RuntimeLogEntry[]>;
  clear(): Promise<void>;
  exportText(): Promise<string>;
  drain(): Promise<void>;
}

export interface RuntimeLogExportPort {
  export(text: string): Promise<RuntimeLogExportResult>;
}

class RuntimeLogEntryValue implements RuntimeLogEntry {
  timestamp: string = '';
  level: LogLevel = 'INFO';
  message: string = '';
}

export function createRuntimeLogEntry(timestamp: string, level: string, message: string): RuntimeLogEntry {
  const normalizedTimestamp: string = timestamp.trim();
  if (normalizedTimestamp.length === 0 || normalizedTimestamp.length > MAX_RUNTIME_LOG_TIMESTAMP_LENGTH) {
    throw new Error('Runtime log timestamp is invalid.');
  }
  const entry: RuntimeLogEntryValue = new RuntimeLogEntryValue();
  entry.timestamp = normalizedTimestamp;
  entry.level = requireRuntimeLogLevel(level);
  entry.message = boundMessage(redactRuntimeLogMessage(message));
  return entry;
}

export function cloneRuntimeLogEntry(entry: RuntimeLogEntry): RuntimeLogEntry {
  if (!(entry instanceof RuntimeLogEntryValue)) {
    throw new Error('RuntimeLogEntry values must come from createRuntimeLogEntry.');
  }
  return createRuntimeLogEntry(entry.timestamp, entry.level, entry.message);
}

export function cloneRuntimeLogEntries(entries: RuntimeLogEntry[]): RuntimeLogEntry[] {
  const cloned: RuntimeLogEntry[] = [];
  for (let index: number = 0; index < entries.length; index += 1) {
    cloned.push(cloneRuntimeLogEntry(entries[index]));
  }
  return cloned;
}

export function formatRuntimeLogsAsText(entries: RuntimeLogEntry[]): string {
  const lines: string[] = [];
  for (let index: number = 0; index < entries.length; index += 1) {
    const entry: RuntimeLogEntry = cloneRuntimeLogEntry(entries[index]);
    lines.push(`${entry.timestamp} [${entry.level}] ${entry.message}`);
  }
  return lines.join('\n');
}

function requireRuntimeLogLevel(rawLevel: string): LogLevel {
  switch (rawLevel) {
    case 'DEBUG':
    case 'INFO':
    case 'WARN':
    case 'ERROR':
      return rawLevel;
    default:
      throw new Error('Runtime log level must stay inside the closed level contract.');
  }
}

function boundMessage(message: string): string {
  if (message.length <= MAX_RUNTIME_LOG_MESSAGE_LENGTH) {
    return message;
  }
  return message.substring(0, MAX_RUNTIME_LOG_MESSAGE_LENGTH);
}

function redactRuntimeLogMessage(message: string): string {
  return redactSensitiveText(message).replace(SANITIZED_URL_PATTERN, '<redacted-url>');
}
