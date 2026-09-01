export type RuntimeState = 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR';
export type LogLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';
export type RuntimeMode = 'RULE' | 'GLOBAL' | 'DIRECT';

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

export interface ProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;
}

export type CoreEvent =
  | { type: 'runtime'; state: RuntimeState; message: string; code: string; sessionId: string; traceId: string; ingress: string; protocol: string }
  | { type: 'log'; level: LogLevel; message: string };

export interface TunStartCaptureConfig {
  addresses: string[];
  routes: string[];
  dnsServers: string[];
  mtu: number;
  ipv4: boolean;
  ipv6: boolean;
  isBlocking: boolean;
  blockedApplications: string[];
  trustedApplications: string[];
}

export interface TunStartOptions {
  fd: number;
  vpnId: string;
  sessionId: string;
  configPath: string;
  mixedPort: number;
  platformApiLevel: number;
  processProtected: boolean;
  captureConfig: TunStartCaptureConfig;
  dnsServers: string[];
}

export interface TunCounters {
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

export interface TunFailure {
  code: string;
  detail: string;
}

export interface TunSnapshot {
  sessionId: string;
  state: 'IDLE' | 'STARTING' | 'READY' | 'STOPPED' | 'ERROR';
  counters: TunCounters;
  failure: TunFailure | null;
}

export interface TunTrace {
  sequence: number;
  sessionId: string;
  traceId: string;
  ingress: string;
  protocol: string;
  sourceAddress: string;
  destinationAddress: string;
  hashedTuple: string;
  correlationHash: string;
  destinationHash: string;
  outboundTerminalHash: string;
  outboundChainHash: string;
  outboundChainLength: number;
}

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
export declare function queryRuntimeMode(): RuntimeMode;
export declare function setRuntimeMode(mode: RuntimeMode): RuntimeMode;
export declare function queryProxyGroups(context: ProxyQueryContext, selectableOnly: boolean): Promise<string>;
export declare function queryProxyGroup(context: ProxyQueryContext, groupName: string): Promise<string>;
export declare function selectProxy(context: ProxyQueryContext, groupName: string, memberName: string): Promise<string>;
export declare function startProxyDelayTest(context: ProxyQueryContext, groupName: string): Promise<string>;
export declare function readProxyDelayTest(jobId: string): Promise<string>;
export declare function cancelProxyDelayTest(jobId: string): Promise<string>;
export declare function startTun(options: TunStartOptions): Promise<TunSnapshot>;
export declare function stopTun(): Promise<TunSnapshot>;
export declare function closeStaleOutboundConnections(sessionId: string): Promise<void>;
export declare function tunSnapshot(): Promise<TunSnapshot>;
export declare function readTunTraces(afterSequence: number): Promise<TunTrace[]>;
export declare function subscribe(callback: (event: CoreEvent) => void): number;
export declare function unsubscribe(subscriptionId: number): void;
