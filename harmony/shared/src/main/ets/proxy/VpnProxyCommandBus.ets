import { SerialCommandQueue } from '../profile/SerialCommandQueue';
import {
  cloneProxyGroupListQueryResult,
  cloneProxyGroupQueryResult,
  cloneProxyRuntimeIdentity,
  cloneProxySelectionResult,
  createProxyRejectedError,
  createProxyRejectedResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult
} from './ProxyModels';
import {
  cloneProxyDelayResult,
  type ProxyDelayResult
} from './ProxyDelayModels';
import {
  cloneVpnProxyCancelDelayTestCommand,
  cloneVpnProxyQueryGroupCommand,
  cloneVpnProxyQueryGroupsCommand,
  cloneVpnProxyReadDelayTestCommand,
  cloneVpnProxyStartDelayTestCommand,
  cloneVpnProxySelectCommand,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnProxyReadDelayTestCommand,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyStartDelayTestCommand,
  type VpnProxySelectCommand
} from './ProxyPorts';

interface ActiveBinding {
  epoch: number;
  identity: ProxyRuntimeIdentity;
  handler: VpnProxyCommandHandler;
  sessionGeneration?: number;
}

interface CapturedBinding {
  epoch: number;
  identity: ProxyRuntimeIdentity;
  handler: VpnProxyCommandHandler;
}

function requireSafeNonNegativeInteger(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) {
    throw new Error(`${label} must be a safe non-negative integer.`);
  }
  return value;
}

function requireSafePositiveInteger(value: number, label: string): number {
  const normalized: number = requireSafeNonNegativeInteger(value, label);
  if (normalized === 0) {
    throw new Error(`${label} must be positive.`);
  }
  return normalized;
}

function requireBoundIdentity(identity: ProxyRuntimeIdentity): ProxyRuntimeIdentity {
  const clone: ProxyRuntimeIdentity = cloneProxyRuntimeIdentity(identity);
  if (clone.sessionId === null) {
    throw new Error('Vpn proxy command bus requires a running session identity.');
  }
  return clone;
}

function sameIdentity(left: ProxyRuntimeIdentity, right: ProxyRuntimeIdentity): boolean {
  return left.profileId === right.profileId &&
    left.revisionId === right.revisionId &&
    left.revisionHash === right.revisionHash &&
    left.sessionId === right.sessionId;
}

export class VpnProxyCommandBus {
  private readonly queue: SerialCommandQueue = new SerialCommandQueue();
  private readonly now: () => string;
  private epochValue: number;
  private activeBinding?: ActiveBinding;
  private epochSealed: boolean = false;

  constructor(now: () => string = () => new Date().toISOString(), initialEpoch: number = 0) {
    this.now = now;
    this.epochValue = requireSafeNonNegativeInteger(initialEpoch, 'Vpn proxy command bus initial epoch');
  }

  bind(identity: ProxyRuntimeIdentity, handler: VpnProxyCommandHandler, sessionGeneration?: number): number {
    if (this.activeBinding !== undefined) {
      throw new Error('Vpn proxy command bus already has a live binding.');
    }
    const boundIdentity: ProxyRuntimeIdentity = requireBoundIdentity(identity);
    const boundSessionGeneration: number | undefined = sessionGeneration === undefined
      ? undefined
      : requireSafePositiveInteger(sessionGeneration, 'Vpn proxy command bus session generation');
    const epoch: number = this.advanceBindingEpoch();
    this.activeBinding = {
      epoch,
      identity: boundIdentity,
      handler,
      sessionGeneration: boundSessionGeneration
    };
    return epoch;
  }

  activeSessionGeneration(identity: ProxyRuntimeIdentity): number | undefined {
    const active: ActiveBinding | undefined = this.activeBinding;
    if (active === undefined || !sameIdentity(active.identity, identity)) {
      return undefined;
    }
    return active.sessionGeneration;
  }

  invalidate(sessionId: string): void {
    const active: ActiveBinding | undefined = this.activeBinding;
    if (active === undefined) {
      return;
    }
    if (active.identity.sessionId !== sessionId) {
      return;
    }
    this.activeBinding = undefined;
    this.advanceClosedEpoch();
  }

  async deactivate(sessionId: string): Promise<void> {
    this.invalidate(sessionId);
    await this.queue.execute(async (): Promise<void> => {
      return;
    });
  }

  submitQueryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    const validatedCommand: VpnProxyQueryGroupsCommand = cloneVpnProxyQueryGroupsCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxyGroupListQueryResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxyGroupListQueryResult = await captured.handler.queryGroups(
          cloneVpnProxyQueryGroupsCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxyGroupListQueryResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createQueryFailedResult();
      }
    });
  }

  submitQueryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    const validatedCommand: VpnProxyQueryGroupCommand = cloneVpnProxyQueryGroupCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxyGroupQueryResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxyGroupQueryResult = await captured.handler.queryGroup(
          cloneVpnProxyQueryGroupCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxyGroupQueryResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createQueryFailedResult();
      }
    });
  }

  submitSelect(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    const validatedCommand: VpnProxySelectCommand = cloneVpnProxySelectCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxySelectionResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxySelectionResult = await captured.handler.select(
          cloneVpnProxySelectCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxySelectionResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createSelectionFailedResult();
      }
    });
  }

  submitStartDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    const validatedCommand: VpnProxyStartDelayTestCommand = cloneVpnProxyStartDelayTestCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxyDelayResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxyDelayResult = await captured.handler.startDelayTest(
          cloneVpnProxyStartDelayTestCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxyDelayResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createDelayTestFailedResult();
      }
    });
  }

  submitReadDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    const validatedCommand: VpnProxyReadDelayTestCommand = cloneVpnProxyReadDelayTestCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxyDelayResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxyDelayResult = await captured.handler.readDelayTest(
          cloneVpnProxyReadDelayTestCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxyDelayResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createDelayTestFailedResult();
      }
    });
  }

  submitCancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    const validatedCommand: VpnProxyCancelDelayTestCommand = cloneVpnProxyCancelDelayTestCommand(command);
    const captured: CapturedBinding | undefined = this.captureBinding();
    return this.queue.execute(async (): Promise<ProxyDelayResult> => {
      if (captured === undefined || !this.matchesCapturedBinding(captured, validatedCommand.identity)) {
        return this.createSessionChangedResult();
      }
      try {
        const result: ProxyDelayResult = await captured.handler.cancelDelayTest(
          cloneVpnProxyCancelDelayTestCommand(validatedCommand)
        );
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return cloneProxyDelayResult(result);
      } catch (_) {
        if (!this.matchesCapturedBinding(captured, validatedCommand.identity)) {
          return this.createSessionChangedResult();
        }
        return this.createDelayTestFailedResult();
      }
    });
  }

  private captureBinding(): CapturedBinding | undefined {
    const active: ActiveBinding | undefined = this.activeBinding;
    if (active === undefined) {
      return undefined;
    }
    return {
      epoch: active.epoch,
      identity: cloneProxyRuntimeIdentity(active.identity),
      handler: active.handler
    };
  }

  private matchesCapturedBinding(
    captured: CapturedBinding,
    commandIdentity: ProxyRuntimeIdentity
  ): boolean {
    if (!sameIdentity(captured.identity, commandIdentity)) {
      return false;
    }
    const active: ActiveBinding | undefined = this.activeBinding;
    if (active === undefined) {
      return false;
    }
    if (active.epoch !== captured.epoch) {
      return false;
    }
    if (active.handler !== captured.handler) {
      return false;
    }
    return sameIdentity(active.identity, captured.identity);
  }

  private advanceBindingEpoch(): number {
    if (this.epochSealed || this.epochValue >= Number.MAX_SAFE_INTEGER) {
      this.activeBinding = undefined;
      this.epochSealed = true;
      throw new Error('Vpn proxy command bus cannot allocate another binding.');
    }
    this.epochValue += 1;
    return this.epochValue;
  }

  private advanceClosedEpoch(): void {
    if (this.epochSealed) {
      return;
    }
    if (this.epochValue >= Number.MAX_SAFE_INTEGER) {
      this.epochSealed = true;
      return;
    }
    this.epochValue += 1;
  }

  private createSessionChangedResult() {
    return createProxyRejectedResult(
      createProxyRejectedError('VPN_SESSION_CHANGED', false, this.now())
    );
  }

  private createQueryFailedResult() {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_QUERY_FAILED', true, this.now())
    );
  }

  private createSelectionFailedResult() {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_SELECTION_FAILED', false, this.now())
    );
  }

  private createDelayTestFailedResult() {
    return createProxyRejectedResult(
      createProxyRejectedError('PROXY_DELAY_TEST_FAILED', true, this.now())
    );
  }
}
