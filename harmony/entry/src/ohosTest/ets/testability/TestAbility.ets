import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, hash } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import type { StagedSource } from '@cmfa/shared';
import common from '@ohos.app.ability.common';

const DOMAIN: number = 0x0000;
const TAG: string = 'Task14TestAbility';
const TEST_ABILITY_PAGE: string = 'testability/pages/Index';
const EVIDENCE_FILE_NAME: string = 'phase3-simulator-app-evidence.json';
const URL_PATTERN: RegExp = /https?:\/\/[^\s"']+/gu;
const FILE_URL_PATTERN: RegExp = /file:\/\/[^\s"']+/gu;
const TOKEN_PATTERN: RegExp = /token=[^&\s"']+/gu;

export const TASK14_PRODUCTION_BUNDLE_NAME: string = 'com.github.kr328.clash.harmony';
export const TASK14_PRODUCTION_MODULE_NAME: string = 'entry';
export const TASK14_PRODUCTION_ABILITY_NAME: string = 'EntryAbility';
export const TASK14_TEST_MODULE_NAME: string = 'entry_test';
export const TASK14_TEST_ABILITY_NAME: string = 'TestAbility';
export const TASK14_RUN_ID_PARAMETER_KEY: string = 'cmfa.phase3.runId';
export const TASK14_PRODUCTION_HAP_SHA256_PARAMETER_KEY: string = 'cmfa.phase3.productionHapSha256';
export const TASK14_ENTRY_TEST_HAP_SHA256_PARAMETER_KEY: string = 'cmfa.phase3.entryTestHapSha256';
export const TASK14_FIXTURE_SHA256_PARAMETER_KEY: string = 'cmfa.phase3.fixtureSha256';
export const TASK14_PLATFORM_ADAPTERS_PASS_CHECK: string = 'Phase3PlatformAdapters: pass';
export const TASK14_RUNTIME_FLOW_PASS_CHECK: string =
  'Phase3RuntimeFlow: validate > retain/save > enable.validate > enable.load > start.revalidate > start.load > startLocal(7890) > RUNNING 127.0.0.1:7890 127.0.0.1:7891 > stop > STOPPED';
export const TASK14_UI_FLOW_PASS_CHECK: string = 'Phase3UiFlow: pass';

export type Task14CleanupStatus = 'pass' | 'fail' | 'incomplete';

export interface Task14EvidenceFailure {
  suite: string;
  detail: string;
}

class Task14EvidenceFailureRecord implements Task14EvidenceFailure {
  suite: string;
  detail: string;

  constructor(suite: string, detail: string) {
    this.suite = suite;
    this.detail = detail;
  }
}

export interface Task14Evidence {
  schemaVersion: '1.0.0';
  phase: 3;
  task: 14;
  status: 'RUNNING' | 'PASS' | 'FAIL' | 'INCOMPLETE';
  updatedAt: string;
  runId: string;
  productionHapSha256: string;
  entryTestHapSha256: string;
  fixtureSha256: string;
  suites: string[];
  trace: string[];
  checks: string[];
  failures: Task14EvidenceFailure[];
  cleanup: Task14CleanupStatus;
  homeSnapshotAddress: string;
  homeRuntimeAddress: string;
}

let sharedContext: common.UIAbilityContext | undefined = undefined;
let contextWaiters: Array<(context: common.UIAbilityContext) => void> = [];
let task14CompletionResolved: boolean = false;
let task14CompletionWaiters: Array<() => void> = [];
let evidence: Task14Evidence = createInitialEvidence();

export default class TestAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    sharedContext = this.context;
    resolveContextWaiters(this.context);
    appendEvidenceTrace('TestAbility.onCreate');
    void flushEvidence();
    hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    appendEvidenceTrace('TestAbility.onWindowStageCreate');
    void flushEvidence();
    windowStage.loadContent(TEST_ABILITY_PAGE, () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'TestAbility page loaded');
    });
  }

  onForeground(): void {
    appendEvidenceTrace('TestAbility.onForeground');
  }

  onBackground(): void {
    appendEvidenceTrace('TestAbility.onBackground');
  }
}

export async function waitForTestAbilityContext(): Promise<common.UIAbilityContext> {
  if (sharedContext !== undefined) {
    return sharedContext;
  }
  return await new Promise<common.UIAbilityContext>((resolve) => {
    contextWaiters.push(resolve);
  });
}

export function getTestAbilityContext(): common.UIAbilityContext {
  if (sharedContext === undefined) {
    throw new Error('Task 14 test ability context is not ready.');
  }
  return sharedContext;
}

export function getEvidence(): Task14Evidence {
  return cloneEvidence(evidence);
}

export async function waitForTask14Completion(): Promise<void> {
  if (task14CompletionResolved) {
    return;
  }
  return await new Promise<void>((resolve) => {
    task14CompletionWaiters.push(resolve);
  });
}

export function signalTask14Completion(): void {
  if (task14CompletionResolved) {
    return;
  }
  task14CompletionResolved = true;
  const waiters: Array<() => void> = task14CompletionWaiters;
  task14CompletionWaiters = [];
  for (let index: number = 0; index < waiters.length; index += 1) {
    waiters[index]();
  }
}

export function setEvidenceStatus(status: 'RUNNING' | 'PASS' | 'FAIL' | 'INCOMPLETE'): void {
  evidence.status = status;
  evidence.updatedAt = new Date().toISOString();
}

export function configureEvidenceFromRunnerParameters(parameters: Record<string, Object>): void {
  evidence.runId = requireRunnerParameter(parameters, TASK14_RUN_ID_PARAMETER_KEY);
  evidence.productionHapSha256 = requireRunnerParameter(parameters, TASK14_PRODUCTION_HAP_SHA256_PARAMETER_KEY);
  evidence.entryTestHapSha256 = requireRunnerParameter(parameters, TASK14_ENTRY_TEST_HAP_SHA256_PARAMETER_KEY);
  evidence.fixtureSha256 = requireRunnerParameter(parameters, TASK14_FIXTURE_SHA256_PARAMETER_KEY);
  evidence.updatedAt = new Date().toISOString();
}

export function appendEvidenceTrace(step: string): void {
  evidence.trace.push(sanitizeEvidenceText(step));
  evidence.updatedAt = new Date().toISOString();
}

export function appendEvidenceCheck(check: string): void {
  evidence.checks.push(sanitizeEvidenceText(check));
  evidence.updatedAt = new Date().toISOString();
}

export function appendEvidenceFailure(suite: string, detail: string): void {
  evidence.failures.push(new Task14EvidenceFailureRecord(suite, sanitizeEvidenceText(detail)));
  evidence.updatedAt = new Date().toISOString();
}

export function setEvidenceCleanupStatus(status: Task14CleanupStatus): void {
  if (evidence.cleanup === 'fail') {
    evidence.updatedAt = new Date().toISOString();
    return;
  }
  evidence.cleanup = status;
  evidence.updatedAt = new Date().toISOString();
}

export function setEvidenceHomeAddresses(homeSnapshotAddress: string, homeRuntimeAddress: string): void {
  evidence.homeSnapshotAddress = sanitizeEvidenceText(homeSnapshotAddress);
  evidence.homeRuntimeAddress = sanitizeEvidenceText(homeRuntimeAddress);
  evidence.updatedAt = new Date().toISOString();
}

export async function flushEvidence(): Promise<void> {
  if (sharedContext === undefined) {
    return;
  }
  const filePath: string = evidenceFilePath(sharedContext);
  const tempPath: string = `${filePath}.${createScopedId('evidence')}.tmp`;
  const encoder = util.TextEncoder.create('utf-8');
  const payload: Uint8Array = encoder.encodeInto(`${JSON.stringify(evidence)}\n`);
  let file: fileIo.File | undefined = undefined;
  try {
    file = await fileIo.open(
      tempPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
    );
    let written: number = 0;
    while (written < payload.length) {
      const chunk: Uint8Array = payload.slice(written);
      const wroteNow: number = await fileIo.write(file.fd, chunk.buffer, { length: chunk.length });
      if (wroteNow <= 0 || wroteNow > chunk.length) {
        throw new Error('Task 14 evidence write failed.');
      }
      written += wroteNow;
    }
    await fileIo.fsync(file.fd);
    await fileIo.close(file.fd);
    file = undefined;
    await fileIo.rename(tempPath, filePath);
  } catch (_) {
    if (file !== undefined) {
      try {
        await fileIo.close(file.fd);
      } catch (_) {
      }
    }
    try {
      await fileIo.unlink(tempPath);
    } catch (_) {
    }
    throw new Error('Task 14 evidence publish failed.');
  }
}

export function evidencePath(): string {
  return evidenceFilePath(getTestAbilityContext());
}

export async function stageRawfileToSandbox(fileName: string): Promise<StagedFixture> {
  const context: common.UIAbilityContext = await waitForTestAbilityContext();
  const rawBytes: Uint8Array = context.resourceManager.getRawFileContentSync(fileName);
  const stagingId: string = createScopedId('stage');
  const stageDirectory: string = `${context.filesDir}/tmp`;
  const validationPath: string = `${stageDirectory}/${stagingId}.yaml`;
  await ensureDirectory(stageDirectory);
  await writeBytesFile(validationPath, rawBytes);
  return new StagedFixture(
    stagingId,
    validationPath,
    await hashStage(validationPath),
    rawBytes.length,
    new Date().toISOString()
  );
}

export async function writeUtf8File(filePath: string, contents: string): Promise<void> {
  const encoder = util.TextEncoder.create('utf-8');
  await writeBytesFile(filePath, encoder.encodeInto(contents));
}

export async function writeBytesFile(filePath: string, bytes: Uint8Array): Promise<void> {
  const file = await fileIo.open(
    filePath,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC
  );
  try {
    let written: number = 0;
    while (written < bytes.length) {
      const chunk: Uint8Array = bytes.slice(written);
      const wroteNow: number = await fileIo.write(file.fd, chunk.buffer, { length: chunk.length });
      written += wroteNow;
    }
  } finally {
    await fileIo.close(file.fd);
  }
}

export async function readBytesFile(filePath: string): Promise<Uint8Array> {
  const stat = await fileIo.stat(filePath);
    const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
  try {
    const buffer = new ArrayBuffer(Number(stat.size));
    let readNow: number = 0;
    while (readNow < Number(stat.size)) {
      const bytesRead: number = await fileIo.read(file.fd, buffer, {
        offset: readNow,
        length: Number(stat.size) - readNow
      });
      if (bytesRead <= 0) {
        break;
      }
      readNow += bytesRead;
    }
    return new Uint8Array(buffer);
  } finally {
    await fileIo.close(file.fd);
  }
}

export async function readUtf8File(filePath: string): Promise<string> {
  return decodeUtf8(await readBytesFile(filePath));
}

export async function ensureDirectory(directoryPath: string): Promise<void> {
  await fileIo.mkdir(directoryPath, true);
}

export function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeWithStream(bytes);
}

export async function removeIfPresent(filePath: string): Promise<void> {
  try {
    const exists: boolean = await fileIo.access(filePath);
    if (exists) {
      await fileIo.unlink(filePath);
    }
  } catch (_) {
  }
}

export async function listDirectoryIfPresent(directoryPath: string): Promise<string[]> {
  const exists: boolean = await fileIo.access(directoryPath);
  if (!exists) {
    return [];
  }
  return await fileIo.listFile(directoryPath);
}

export function sanitizeEvidenceText(rawValue: string): string {
  let sanitized: string = rawValue;
  const context: common.UIAbilityContext | undefined = sharedContext;
  if (context !== undefined) {
    for (const root of [context.filesDir, context.cacheDir, context.tempDir, context.databaseDir]) {
      sanitized = sanitized.split(root).join('<sandbox>');
    }
  }
  sanitized = sanitized.replace(FILE_URL_PATTERN, 'file://<redacted>');
  sanitized = sanitized.replace(URL_PATTERN, '<url>');
  sanitized = sanitized.replace(TOKEN_PATTERN, 'token=<redacted>');
  return sanitized;
}

export class StagedFixture implements StagedSource {
  stagingId: string;
  validationPath: string;
  sha256Digest: string;
  byteLength: number;
  validatedAt: string;

  constructor(stagingId: string, validationPath: string, sha256Digest: string, byteLength: number, validatedAt: string) {
    this.stagingId = stagingId;
    this.validationPath = validationPath;
    this.sha256Digest = sha256Digest;
    this.byteLength = byteLength;
    this.validatedAt = validatedAt;
  }
}

function createInitialEvidence(): Task14Evidence {
  return {
    schemaVersion: '1.0.0',
    phase: 3,
    task: 14,
    status: 'RUNNING',
    updatedAt: new Date().toISOString(),
    runId: '',
    productionHapSha256: '',
    entryTestHapSha256: '',
    fixtureSha256: '',
    suites: ['Phase3PlatformAdapters', 'Phase3RuntimeFlow', 'Phase3UiFlow'],
    trace: [],
    checks: [],
    failures: [],
    cleanup: 'incomplete',
    homeSnapshotAddress: '',
    homeRuntimeAddress: ''
  };
}

function cloneEvidence(source: Task14Evidence): Task14Evidence {
  const failures: Task14EvidenceFailure[] = [];
  for (let index: number = 0; index < source.failures.length; index += 1) {
    const failure: Task14EvidenceFailure = source.failures[index];
    failures.push(new Task14EvidenceFailureRecord(failure.suite, failure.detail));
  }
  return {
    schemaVersion: source.schemaVersion,
    phase: source.phase,
    task: source.task,
    status: source.status,
    updatedAt: source.updatedAt,
    runId: source.runId,
    productionHapSha256: source.productionHapSha256,
    entryTestHapSha256: source.entryTestHapSha256,
    fixtureSha256: source.fixtureSha256,
    suites: source.suites.slice(),
    trace: source.trace.slice(),
    checks: source.checks.slice(),
    failures,
    cleanup: source.cleanup,
    homeSnapshotAddress: source.homeSnapshotAddress,
    homeRuntimeAddress: source.homeRuntimeAddress
  };
}

function resolveContextWaiters(context: common.UIAbilityContext): void {
  const waiters = contextWaiters;
  contextWaiters = [];
  for (let index: number = 0; index < waiters.length; index += 1) {
    waiters[index](context);
  }
}

function evidenceFilePath(context: common.UIAbilityContext): string {
  return `${context.filesDir}/${EVIDENCE_FILE_NAME}`;
}

async function hashStage(filePath: string): Promise<string> {
  return await hash.hash(filePath, 'sha256');
}

function createScopedId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
}

function requireRunnerParameter(parameters: Record<string, Object>, key: string): string {
  const value: string = `${parameters[key] ?? ''}`;
  if (value.length === 0) {
    throw new Error(`Missing required Task 14 runner parameter: ${key}`);
  }
  return sanitizeEvidenceText(value);
}
