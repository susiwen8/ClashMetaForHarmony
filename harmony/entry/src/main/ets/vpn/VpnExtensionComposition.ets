import type { Want } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { CoreTunRuntime, type CoreTunRuntimeConfig } from '@cmfa/core';
import { PlatformFactory, type PlatformGraph } from '@cmfa/platform';
import {
  VpnRuntimeCoordinator,
  createTunRuntimeSnapshot,
  createVpnCaptureConfig,
  createVpnCounters,
  createVpnFailure,
  type BoundedDelaySchedulerPort,
  type CancelableDelayTask,
  type ClockPort,
  type CommittedProfileResolverPort,
  type ContinuousNotificationPort,
  type NetworkRecoveryPort,
  type Profile,
  type TunHandle,
  type TunRuntimeEvent,
  type TunRuntimePort,
  type TunRuntimeSnapshot,
  type TunStartOptions,
  type VpnCaptureConfig,
  type VpnControllerFailedResult,
  type VpnControllerPort,
  type VpnControllerRejectedResult,
  type VpnControllerStartResult,
  type VpnControllerStopResult,
  type VpnFailure,
  type VpnPlatformSessionPort,
  type VpnRuntimeCoordinatorDependencies,
  type VpnRuntimeEvent,
  type VpnStartRequest
} from '@cmfa/shared';
import { defaultSdkApiVersionResolver, HarmonyVpnConnectionApi } from './VpnConnectionApi';
import { HarmonyVpnConnectionDriver } from './HarmonyVpnConnectionDriver';
import { VpnSessionRegistry } from './VpnSessionRegistry';

const EXACT_CAPTURE_CONFIG: VpnCaptureConfig = createVpnCaptureConfig({
  addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
  routes: ['0.0.0.0/0', '::/0'],
  dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
  mtu: 1500,
  ipv4: true,
  ipv6: true,
  isBlocking: false,
  blockedApplications: ['com.github.kr328.clash.harmony'],
  trustedApplications: []
});

interface PlatformFactoryLike {
  create(): Promise<PlatformGraph>;
  createNetworkRecoveryPort(): Promise<NetworkRecoveryPort>;
  createContinuousNotificationPort(): ContinuousNotificationPort;
}

export interface VpnExtensionCompositionRunner {
  start(want: Want): Promise<void>;
  stopForDestroy(): Promise<void>;
  recordUnexpectedFailure(failure: VpnFailure): Promise<void>;
}

export interface VpnExtensionCompositionDependencies {
  registry?: VpnSessionRegistry;
  createPlatformFactory?: (context: common.VpnExtensionContext | undefined) => PlatformFactoryLike;
  createPlatformPort?: (sessionId: string) => VpnPlatformSessionPort;
  createTunRuntime?: (configPath: string) => TunRuntimePort;
  createCoordinator?: (dependencies: VpnRuntimeCoordinatorDependencies) => VpnControllerPort;
  createClock?: () => ClockPort;
  createScheduler?: () => BoundedDelaySchedulerPort;
}

class CompositionClock implements ClockPort {
  nowMs(): number {
    return Date.now();
  }
}

class TimeoutDelayTask implements CancelableDelayTask {
  private readonly timerId: number;

  constructor(timerId: number) {
    this.timerId = timerId;
  }

  cancel(): void {
    clearTimeout(this.timerId);
  }
}

class TimeoutDelayScheduler implements BoundedDelaySchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): CancelableDelayTask {
    const timerId: number = setTimeout(() => {
      void runner();
    }, delayMs);
    return new TimeoutDelayTask(timerId);
  }
}

class CompositionResolveError extends Error {
  readonly code: 'VPN_PROFILE_UNAVAILABLE' | 'VPN_CREATE_FAILED';

  constructor(code: 'VPN_PROFILE_UNAVAILABLE' | 'VPN_CREATE_FAILED', detail: string) {
    super(detail);
    this.code = code;
  }
}

class ResolvedConfigPath {
  private value?: string;

  set(path: string): void {
    this.value = path;
  }

  require(): string {
    if (this.value === undefined || this.value.trim().length === 0) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile config path was unavailable.');
    }
    return this.value;
  }
}

class CommittedProfileResolverRecord implements CommittedProfileResolverPort {
  private readonly graph: PlatformGraph;
  private readonly configPath: ResolvedConfigPath;

  constructor(graph: PlatformGraph, configPath: ResolvedConfigPath) {
    this.graph = graph;
    this.configPath = configPath;
  }

  async resolve(profileId: string, versionId: string): Promise<VpnCaptureConfig> {
    const profile: Profile | undefined = await this.graph.repository.get(profileId);
    if (profile === undefined || profile.currentRevision === null) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile was unavailable.');
    }
    if ((profile.availability !== 'VALID' && profile.availability !== 'UPDATE_FAILED_USING_VALID') ||
      profile.currentRevision.validatedAt !== versionId) {
      throw new CompositionResolveError('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile version was unavailable.');
    }
    this.configPath.set(this.graph.contentStore.resolveCorePath(profile.currentRevision));
    return createVpnCaptureConfig({
      addresses: EXACT_CAPTURE_CONFIG.addresses,
      routes: EXACT_CAPTURE_CONFIG.routes,
      dnsServers: EXACT_CAPTURE_CONFIG.dnsServers,
      mtu: EXACT_CAPTURE_CONFIG.mtu,
      ipv4: EXACT_CAPTURE_CONFIG.ipv4,
      ipv6: EXACT_CAPTURE_CONFIG.ipv6,
      isBlocking: EXACT_CAPTURE_CONFIG.isBlocking,
      blockedApplications: EXACT_CAPTURE_CONFIG.blockedApplications,
      trustedApplications: EXACT_CAPTURE_CONFIG.trustedApplications
    });
  }
}

class DeferredTunRuntime implements TunRuntimePort {
  private readonly createRuntime: () => TunRuntimePort;
  private readonly listeners: Map<number, (event: TunRuntimeEvent) => void> = new Map();
  private nextListenerId: number = 1;
  private runtime?: TunRuntimePort;
  private bridgeSubscriptionId?: number;

  constructor(createRuntime: () => TunRuntimePort) {
    this.createRuntime = createRuntime;
  }

  async start(handle: TunHandle, options: TunStartOptions): Promise<TunRuntimeSnapshot> {
    return await this.resolveRuntime().start(handle, options);
  }

  async stop(): Promise<void> {
    if (this.runtime === undefined) {
      return;
    }
    await this.runtime.stop();
  }

  async closeStaleOutboundConnections(sessionId: string): Promise<void> {
    return await this.resolveRuntime().closeStaleOutboundConnections(sessionId);
  }

  async recover(sessionId: string): Promise<TunRuntimeSnapshot> {
    return await this.resolveRuntime().recover(sessionId);
  }

  snapshot(): TunRuntimeSnapshot {
    if (this.runtime === undefined) {
      return createTunRuntimeSnapshot({
        sessionId: 'tun-runtime',
        state: 'STOPPED',
        counters: createVpnCounters(0, 0, 0, 0),
        ingressTraces: [],
        failure: null
      });
    }
    return this.runtime.snapshot();
  }

  subscribe(listener: (event: TunRuntimeEvent) => void): number {
    const subscriptionId: number = this.nextListenerId;
    this.nextListenerId += 1;
    this.listeners.set(subscriptionId, listener);
    return subscriptionId;
  }

  unsubscribe(subscriptionId: number): void {
    this.listeners.delete(subscriptionId);
  }

  private resolveRuntime(): TunRuntimePort {
    if (this.runtime !== undefined) {
      return this.runtime;
    }
    const runtime: TunRuntimePort = this.createRuntime();
    this.runtime = runtime;
    this.bridgeSubscriptionId = runtime.subscribe((event: TunRuntimeEvent) => {
      this.publish(event);
    });
    return runtime;
  }

  private publish(event: TunRuntimeEvent): void {
    const listeners: Array<(event: TunRuntimeEvent) => void> = [];
    this.listeners.forEach((listener: (event: TunRuntimeEvent) => void) => {
      listeners.push(listener);
    });
    const clonedEvent: TunRuntimeEvent = {
      sessionId: event.sessionId,
      snapshot: createTunRuntimeSnapshot({
        sessionId: event.snapshot.sessionId,
        state: event.snapshot.state,
        counters: event.snapshot.counters,
        ingressTraces: event.snapshot.ingressTraces,
        failure: event.snapshot.failure
      })
    };
    for (let index: number = 0; index < listeners.length; index += 1) {
      listeners[index](clonedEvent);
    }
  }
}

function createMalformedWantFailure(): VpnFailure {
  return createVpnFailure('VPN_CONFIG_INVALID', 'VPN extension launch parameters were invalid.');
}

function createProfileUnavailableFailure(): VpnFailure {
  return createVpnFailure('VPN_PROFILE_UNAVAILABLE', 'Committed VPN profile version was unavailable.');
}

function createCreateFailure(): VpnFailure {
  return createVpnFailure('VPN_CREATE_FAILED', 'VPN extension startup failed before runtime handoff.');
}

function createSystemRevokedFailure(): VpnFailure {
  return createVpnFailure('VPN_SYSTEM_REVOKED', 'HarmonyOS VPN session was revoked by the system.');
}

function sanitizeFailure(failure: VpnFailure | null): VpnFailure | null {
  if (failure === null) {
    return null;
  }
  switch (failure.code) {
    case 'VPN_BACKGROUND_TASK_FAILED':
      return createVpnFailure(failure.code, 'VPN continuous task startup failed.');
    case 'VPN_CREATE_FAILED':
      return createVpnFailure(failure.code, 'HarmonyOS VPN extension start failed.');
    case 'VPN_TUN_START_FAILED':
      return createVpnFailure(failure.code, 'VPN tun runtime start failed.');
    case 'VPN_STOP_FAILED':
      return createVpnFailure(failure.code, 'HarmonyOS VPN extension stop failed.');
    case 'VPN_PROFILE_UNAVAILABLE':
      return createProfileUnavailableFailure();
    case 'VPN_CONFIG_INVALID':
      return createMalformedWantFailure();
    case 'VPN_SYSTEM_REVOKED':
      return createSystemRevokedFailure();
    default:
      return createVpnFailure(failure.code, failure.detail);
  }
}

function extractFailure(result: VpnControllerStartResult | VpnControllerStopResult): VpnFailure | null {
  if (result.kind === 'FAILED') {
    return (result as VpnControllerFailedResult).failure;
  }
  if (result.kind === 'REJECTED') {
    return (result as VpnControllerRejectedResult).failure;
  }
  return result.snapshot.lastFailure;
}

function cloneExactCaptureConfig(): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: EXACT_CAPTURE_CONFIG.addresses,
    routes: EXACT_CAPTURE_CONFIG.routes,
    dnsServers: EXACT_CAPTURE_CONFIG.dnsServers,
    mtu: EXACT_CAPTURE_CONFIG.mtu,
    ipv4: EXACT_CAPTURE_CONFIG.ipv4,
    ipv6: EXACT_CAPTURE_CONFIG.ipv6,
    isBlocking: EXACT_CAPTURE_CONFIG.isBlocking,
    blockedApplications: EXACT_CAPTURE_CONFIG.blockedApplications,
    trustedApplications: EXACT_CAPTURE_CONFIG.trustedApplications
  });
}

function parseStartWant(want: Want): VpnStartRequest | undefined {
  const parameters: Record<string, Object> | null | undefined =
    want.parameters as Record<string, Object> | null | undefined;
  if (parameters === undefined || parameters === null) {
    return undefined;
  }
  const keys: string[] = Object.keys(parameters);
  if (keys.length !== 3) {
    return undefined;
  }
  if (!keys.includes('profileId') || !keys.includes('versionId') || !keys.includes('sessionId')) {
    return undefined;
  }
  const rawProfileId: Object | undefined = parameters.profileId;
  const rawVersionId: Object | undefined = parameters.versionId;
  const rawSessionId: Object | undefined = parameters.sessionId;
  if (typeof rawProfileId !== 'string' || typeof rawVersionId !== 'string' || typeof rawSessionId !== 'string') {
    return undefined;
  }
  return {
    profileId: rawProfileId,
    versionId: rawVersionId,
    sessionId: rawSessionId
  };
}

let installedFactory: ((context: common.VpnExtensionContext | undefined) => VpnExtensionCompositionRunner) | undefined = undefined;
let sharedComposition: VpnExtensionCompositionRunner | undefined = undefined;
let drainingComposition: VpnExtensionCompositionRunner | undefined = undefined;

export function installVpnExtensionCompositionFactoryForTesting(
  factory?: (context: common.VpnExtensionContext | undefined) => VpnExtensionCompositionRunner
): void {
  installedFactory = factory;
  sharedComposition = undefined;
}

export function resetVpnExtensionCompositionForTesting(): void {
  installedFactory = undefined;
  sharedComposition = undefined;
  drainingComposition = undefined;
}

export function markVpnExtensionCompositionDraining(runner: VpnExtensionCompositionRunner): void {
  if (sharedComposition === runner) {
    drainingComposition = runner;
  }
}

export function isVpnExtensionCompositionDraining(runner: VpnExtensionCompositionRunner): boolean {
  return drainingComposition === runner;
}

export function releaseVpnExtensionComposition(runner: VpnExtensionCompositionRunner): void {
  if (sharedComposition === runner) {
    sharedComposition = undefined;
  }
  if (drainingComposition === runner) {
    drainingComposition = undefined;
  }
}

export function resolveVpnExtensionComposition(context: common.VpnExtensionContext): VpnExtensionCompositionRunner {
  if (sharedComposition !== undefined) {
    return sharedComposition;
  }
  sharedComposition = installedFactory !== undefined
    ? installedFactory(context)
    : new VpnExtensionComposition(context);
  return sharedComposition;
}

export class VpnExtensionComposition implements VpnExtensionCompositionRunner {
  private readonly context?: common.VpnExtensionContext;
  private readonly dependencies: VpnExtensionCompositionDependencies;
  private readonly registry: VpnSessionRegistry;
  private platformGraph?: PlatformGraph;
  private coordinator?: VpnControllerPort;
  private currentRequest?: VpnStartRequest;
  private startPromise?: Promise<void>;
  private stopPromise?: Promise<void>;

  constructor(context: common.VpnExtensionContext | undefined, dependencies?: VpnExtensionCompositionDependencies) {
    this.context = context;
    this.dependencies = dependencies ?? {};
    this.registry = this.dependencies.registry ?? new VpnSessionRegistry();
  }

  async start(want: Want): Promise<void> {
    if (this.stopPromise !== undefined) {
      return;
    }
    if (this.startPromise !== undefined) {
      return await this.startPromise;
    }
    const request: VpnStartRequest | undefined = parseStartWant(want);
    if (request === undefined) {
      this.completeMalformedPendingSession();
      return;
    }
    if (this.currentRequest !== undefined && this.currentRequest.sessionId === request.sessionId) {
      return;
    }
    const claimed: VpnStartRequest | undefined = this.registry.activatePending(request.sessionId, 'STARTING');
    if (claimed === undefined) {
      return;
    }
    this.currentRequest = claimed;
    const startPromise: Promise<void> = this.startInternal(claimed).finally(() => {
      if (this.startPromise === startPromise) {
        this.startPromise = undefined;
      }
    });
    this.startPromise = startPromise;
    await startPromise;
  }

  async stopForDestroy(): Promise<void> {
    if (this.stopPromise !== undefined) {
      await this.stopPromise;
      return;
    }
    const stopPromise: Promise<void> = this.stopInternal().finally(() => {
      if (this.stopPromise === stopPromise) {
        this.stopPromise = undefined;
      }
    });
    this.stopPromise = stopPromise;
    await stopPromise;
  }

  async recordUnexpectedFailure(failure: VpnFailure): Promise<void> {
    const sessionId: string | undefined = this.currentRequest?.sessionId ?? this.registry.currentSessionId();
    const sanitized: VpnFailure = sanitizeFailure(failure) ?? createCreateFailure();
    if (sessionId === undefined) {
      return;
    }
    await this.disposeOwnedResources();
    this.registry.completeStop(sessionId, sanitized);
    this.currentRequest = undefined;
    this.coordinator = undefined;
  }

  private async startInternal(request: VpnStartRequest): Promise<void> {
    const platformFactory: PlatformFactoryLike = this.createPlatformFactory();
    try {
      const platformGraph: PlatformGraph = await platformFactory.create();
      this.platformGraph = platformGraph;
      const networkRecovery: NetworkRecoveryPort = await platformFactory.createNetworkRecoveryPort();
      const notification: ContinuousNotificationPort = platformFactory.createContinuousNotificationPort();
      const configPath: ResolvedConfigPath = new ResolvedConfigPath();
      const resolver: CommittedProfileResolverPort = new CommittedProfileResolverRecord(platformGraph, configPath);
      const tunRuntime: TunRuntimePort = new DeferredTunRuntime(() => {
        return this.createTunRuntime(configPath.require());
      });
      const coordinator: VpnControllerPort = this.createCoordinator({
        resolver,
        platform: this.createPlatformPort(request.sessionId),
        tunRuntime,
        networkRecovery,
        notification,
        scheduler: this.dependencies.createScheduler?.() ?? new TimeoutDelayScheduler(),
        clock: this.dependencies.createClock?.() ?? new CompositionClock()
      });
      this.coordinator = coordinator;
      coordinator.subscribe((event: VpnRuntimeEvent) => {
        if (event.snapshot.activeRequest === null) {
          return;
        }
        this.registry.publish({
          sessionId: event.snapshot.activeRequest.sessionId,
          state: event.snapshot.state,
          activeHandle: event.snapshot.activeHandle,
          captureConfig: event.snapshot.captureConfig,
          tunSnapshot: event.snapshot.tunSnapshot,
          notificationActive: event.snapshot.notificationActive,
          recoveryAttempt: event.snapshot.recoveryAttempt,
          scheduledRetryDelayMs: event.snapshot.scheduledRetryDelayMs,
          lastFailure: sanitizeFailure(event.snapshot.lastFailure)
        });
      });
      const result: VpnControllerStartResult = await coordinator.start(request.profileId, request.versionId, request.sessionId);
      if (result.kind === 'STARTED') {
        return;
      }
      const failure: VpnFailure | null = sanitizeFailure(extractFailure(result));
      await this.disposeOwnedResources();
      this.registry.completeStop(request.sessionId, failure);
      this.currentRequest = undefined;
      this.coordinator = undefined;
    } catch (error) {
      const failure: VpnFailure = sanitizeFailure(this.mapCompositionFailure(error as Error | Object | undefined))!;
      await this.disposeOwnedResources();
      this.registry.completeStop(request.sessionId, failure);
      this.currentRequest = undefined;
      this.coordinator = undefined;
    }
  }

  private async stopInternal(): Promise<void> {
    const pendingStart: Promise<void> | undefined = this.startPromise;
    if (pendingStart !== undefined) {
      try {
        await pendingStart;
      } catch (_) {
      }
    }
    const request: VpnStartRequest | undefined = this.currentRequest;
    if (request === undefined) {
      return;
    }
    const userRequested: boolean = this.registry.isUserStopRequested(request.sessionId);
    let stopFailure: VpnFailure | null = null;
    if (this.coordinator !== undefined) {
      const stopResult: VpnControllerStopResult = await this.coordinator.stop(request.sessionId);
      stopFailure = sanitizeFailure(extractFailure(stopResult));
    }
    await this.disposeOwnedResources();
    this.registry.completeStop(
      request.sessionId,
      stopFailure ?? (userRequested ? null : sanitizeFailure(createSystemRevokedFailure()))
    );
    this.currentRequest = undefined;
    this.coordinator = undefined;
  }

  private completeMalformedPendingSession(): void {
    const sessionId: string | undefined = this.registry.currentSessionId();
    if (sessionId === undefined) {
      return;
    }
    this.registry.completeStop(sessionId, createMalformedWantFailure());
  }

  private createPlatformFactory(): PlatformFactoryLike {
    if (this.dependencies.createPlatformFactory !== undefined) {
      return this.dependencies.createPlatformFactory(this.context);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    return new PlatformFactory(this.context);
  }

  private createPlatformPort(sessionId: string): VpnPlatformSessionPort {
    if (this.dependencies.createPlatformPort !== undefined) {
      return this.dependencies.createPlatformPort(sessionId);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    return new HarmonyVpnConnectionDriver(
      new HarmonyVpnConnectionApi(this.context, defaultSdkApiVersionResolver),
      sessionId
    );
  }

  private createTunRuntime(configPath: string): TunRuntimePort {
    if (this.dependencies.createTunRuntime !== undefined) {
      return this.dependencies.createTunRuntime(configPath);
    }
    if (this.context === undefined) {
      throw new CompositionResolveError('VPN_CREATE_FAILED', 'VPN extension context was unavailable.');
    }
    const runtimeConfig: CoreTunRuntimeConfig = {
      configPath,
      mixedPort: 7890,
      platformApiLevel: defaultSdkApiVersionResolver(this.context),
      processProtected: true
    };
    return new CoreTunRuntime(runtimeConfig);
  }

  private createCoordinator(dependencies: VpnRuntimeCoordinatorDependencies): VpnControllerPort {
    if (this.dependencies.createCoordinator !== undefined) {
      return this.dependencies.createCoordinator(dependencies);
    }
    return new VpnRuntimeCoordinator(dependencies);
  }

  private mapCompositionFailure(error: Error | Object | undefined): VpnFailure {
    if (error instanceof CompositionResolveError) {
      return error.code === 'VPN_PROFILE_UNAVAILABLE'
        ? createProfileUnavailableFailure()
        : createCreateFailure();
    }
    return createCreateFailure();
  }

  private async disposeOwnedResources(): Promise<void> {
    const graph: PlatformGraph | undefined = this.platformGraph;
    this.platformGraph = undefined;
    if (graph === undefined) {
      return;
    }
    try {
      await graph.close();
    } catch (_) {
    }
  }
}
