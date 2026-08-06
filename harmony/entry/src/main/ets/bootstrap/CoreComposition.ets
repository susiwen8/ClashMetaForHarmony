import { CORE_BRIDGE_VERSION, createCoreService } from '@cmfa/core';
import type { CoreService } from '@cmfa/shared';

export interface Phase1LaunchContext {
  selfTest: boolean;
  runId: string;
  runnerStartedAt: string;
  filesDir: string;
  probeOriginRunId: string;
  probeOriginUrl: string;
  probeCaPem: string;
  probeExpectedBodySha256: string;
  probeFixturePath: string;
  probeFixtureSha256: string;
}

export type Phase1LaunchListener = (context: Phase1LaunchContext) => void;

export interface Phase2SelfTestProbeRequest {
  probeRunId: string;
  protocol: string;
  listenerAddress: string;
  originUrl: string;
  caPem: string;
  expectedBodySha256: string;
}

export interface Phase2SelfTestProbeTrackerRecord {
  connectionId: string;
  sourceAddress: string;
  destinationAddress: string;
  inboundType: string;
  openedAt: string;
}

export interface Phase2SelfTestProbeError {
  code: string;
  stage: string;
  detail: string;
}

export interface Phase2SelfTestProbeResult {
  ok: boolean;
  protocol: string;
  httpStatus: number;
  bodyBytes: number;
  probeRunId: string;
  requestIdEcho: string;
  originId: string;
  responseSha256: string;
  tlsPeerSha256: string;
  startedAt: string;
  completedAt: string;
  clientLocalAddress: string;
  clientRemoteAddress: string;
  tracker: Phase2SelfTestProbeTrackerRecord;
  error: Phase2SelfTestProbeError;
}

export interface Phase2SelfTestCoreService extends CoreService {
  probeHttpsForSelfTest(request: Phase2SelfTestProbeRequest): Promise<Phase2SelfTestProbeResult>;
}

interface AppStorageBridge {
  setOrCreate<T>(key: string, value: T): void;
  get<T>(key: string): T | undefined;
}

const PHASE1_LAUNCH_CONTEXT_KEY: string = '__cmfa_phase1_launch_context__';
declare const AppStorage: AppStorageBridge;
const phase1DefaultContext: Phase1LaunchContext = {
  selfTest: false,
  runId: '',
  runnerStartedAt: '',
  filesDir: '',
  probeOriginRunId: '',
  probeOriginUrl: '',
  probeCaPem: '',
  probeExpectedBodySha256: '',
  probeFixturePath: '',
  probeFixtureSha256: ''
};
const sharedCoreService: CoreService = createCoreService();
let phase1LaunchListener: Phase1LaunchListener | undefined = undefined;
let phase1LaunchListenerId: number = 0;

export function getCoreService(): CoreService {
  return sharedCoreService;
}

export function getSelfTestCoreService(): Phase2SelfTestCoreService {
  return sharedCoreService as Phase2SelfTestCoreService;
}

export function getBridgeVersion(): string {
  return CORE_BRIDGE_VERSION;
}

export function setPhase1LaunchContext(context: Phase1LaunchContext): void {
  AppStorage.setOrCreate<Phase1LaunchContext>(PHASE1_LAUNCH_CONTEXT_KEY, context);
  phase1LaunchListener?.(context);
}

export function subscribePhase1LaunchContext(listener: Phase1LaunchListener): number {
  phase1LaunchListenerId += 1;
  phase1LaunchListener = listener;
  return phase1LaunchListenerId;
}

export function unsubscribePhase1LaunchContext(subscriptionId: number): void {
  if (subscriptionId === phase1LaunchListenerId) {
    phase1LaunchListener = undefined;
  }
}

export function getPhase1LaunchContext(): Phase1LaunchContext {
  const raw: Phase1LaunchContext | undefined = AppStorage.get<Phase1LaunchContext>(PHASE1_LAUNCH_CONTEXT_KEY);
  if (raw === undefined) {
    return phase1DefaultContext;
  }
  return {
    selfTest: raw.selfTest === true,
    runId: raw.runId,
    runnerStartedAt: raw.runnerStartedAt,
    filesDir: raw.filesDir,
    probeOriginRunId: raw.probeOriginRunId ?? '',
    probeOriginUrl: raw.probeOriginUrl ?? '',
    probeCaPem: raw.probeCaPem ?? '',
    probeExpectedBodySha256: raw.probeExpectedBodySha256 ?? '',
    probeFixturePath: raw.probeFixturePath ?? '',
    probeFixtureSha256: raw.probeFixtureSha256 ?? ''
  };
}
