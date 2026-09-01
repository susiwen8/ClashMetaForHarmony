import type {
  BoundedDelaySchedulerPort,
  CancelableDelayTask,
  OneClickVpnConfirmationHandle,
  OneClickVpnConfirmationPort,
  OneClickVpnConfirmationResult,
  OneClickVpnConfirmationResultKind,
  VpnControllerPort
} from '../vpn/VpnPorts';
import type { VpnRuntimeEvent, VpnRuntimeSnapshot } from '../vpn/VpnModels';

class OneClickVpnConfirmationResultValue implements OneClickVpnConfirmationResult {
  kind: OneClickVpnConfirmationResultKind = 'CANCELLED';
}

function createConfirmationResult(kind: OneClickVpnConfirmationResultKind): OneClickVpnConfirmationResult {
  const result: OneClickVpnConfirmationResultValue = new OneClickVpnConfirmationResultValue();
  result.kind = kind;
  return result;
}

function normalizeExpectedSessionId(expectedSessionId: string): string {
  const normalized: string = expectedSessionId.trim();
  if (normalized.length === 0) {
    throw new Error('One-click VPN confirmation requires a non-empty expected session id.');
  }
  return normalized;
}

function normalizeTimeoutMs(timeoutMs: number): number {
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > Number.MAX_SAFE_INTEGER) {
    throw new Error('One-click VPN confirmation requires a safe positive timeout.');
  }
  return timeoutMs;
}

function resolveObservedSessionId(snapshot: VpnRuntimeSnapshot): string | undefined {
  const activeRequestSessionId: string | null | undefined = snapshot.activeRequest?.sessionId;
  if (activeRequestSessionId !== undefined && activeRequestSessionId !== null && activeRequestSessionId.trim().length > 0) {
    return activeRequestSessionId;
  }
  const activeHandleSessionId: string | null | undefined = snapshot.activeHandle?.sessionId;
  if (activeHandleSessionId !== undefined && activeHandleSessionId !== null && activeHandleSessionId.trim().length > 0) {
    return activeHandleSessionId;
  }
  const tunSessionId: string | null | undefined = snapshot.tunSnapshot?.sessionId;
  if (tunSessionId !== undefined && tunSessionId !== null && tunSessionId.trim().length > 0) {
    return tunSessionId;
  }
  return undefined;
}

class ArmedOneClickVpnConfirmationHandle implements OneClickVpnConfirmationHandle {
  private readonly controller: VpnControllerPort;
  private readonly expectedSessionId: string;
  private readonly subscriptionId: number;
  private readonly waitPromise: Promise<OneClickVpnConfirmationResult>;
  private settled: boolean = false;
  private startAccepted: boolean = false;
  private unsubscribed: boolean = false;
  private timeoutTaskCancelled: boolean = false;
  private timeoutTask?: CancelableDelayTask;
  private resolveWaitRef?: (result: OneClickVpnConfirmationResult) => void;

  constructor(
    controller: VpnControllerPort,
    expectedSessionId: string,
    subscriptionId: number
  ) {
    this.controller = controller;
    this.expectedSessionId = expectedSessionId;
    this.subscriptionId = subscriptionId;
    this.waitPromise = new Promise<OneClickVpnConfirmationResult>((resolve) => {
      this.resolveWaitRef = resolve;
    });
  }

  wait(): Promise<OneClickVpnConfirmationResult> {
    return this.waitPromise;
  }

  markStartAccepted(): void {
    if (this.settled) {
      return;
    }
    this.startAccepted = true;
    this.observeSnapshot(this.controller.snapshot(), true);
  }

  cancel(): void {
    this.complete('CANCELLED');
  }

  attachTimeoutTask(timeoutTask: CancelableDelayTask): void {
    this.timeoutTask = timeoutTask;
    if (this.settled) {
      this.cancelTimeoutTaskOnce();
    }
  }

  onRuntimeEvent(event: VpnRuntimeEvent): void {
    this.observeSnapshot(event.snapshot, this.startAccepted);
  }

  onTimeout(): void {
    this.complete('TIMEOUT');
  }

  private observeSnapshot(snapshot: VpnRuntimeSnapshot, stoppedAllowed: boolean): void {
    if (this.settled) {
      return;
    }
    const observedSessionId: string | undefined = resolveObservedSessionId(snapshot);
    if (observedSessionId !== undefined && observedSessionId !== this.expectedSessionId) {
      this.complete('SESSION_CHANGED');
      return;
    }
    if (snapshot.state === 'RUNNING' && observedSessionId === this.expectedSessionId) {
      this.complete('RUNNING');
      return;
    }
    if (snapshot.state === 'ERROR') {
      this.complete('ERROR');
      return;
    }
    if (snapshot.state === 'STOPPED' && stoppedAllowed) {
      this.complete('STOPPED');
    }
  }

  private complete(kind: OneClickVpnConfirmationResultKind): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.cancelTimeoutTaskOnce();
    this.unsubscribeOnce();
    this.resolveWaitRef?.(createConfirmationResult(kind));
  }

  private cancelTimeoutTaskOnce(): void {
    if (this.timeoutTaskCancelled) {
      return;
    }
    const timeoutTask: CancelableDelayTask | undefined = this.timeoutTask;
    if (timeoutTask === undefined) {
      return;
    }
    this.timeoutTaskCancelled = true;
    timeoutTask.cancel();
  }

  private unsubscribeOnce(): void {
    if (this.unsubscribed) {
      return;
    }
    this.unsubscribed = true;
    this.controller.unsubscribe(this.subscriptionId);
  }
}

export class SubscriptionOneClickVpnConfirmation implements OneClickVpnConfirmationPort {
  private readonly controller: VpnControllerPort;
  private readonly scheduler: BoundedDelaySchedulerPort;

  constructor(controller: VpnControllerPort, scheduler: BoundedDelaySchedulerPort) {
    this.controller = controller;
    this.scheduler = scheduler;
  }

  arm(expectedSessionId: string, timeoutMs: number): OneClickVpnConfirmationHandle {
    const normalizedExpectedSessionId: string = normalizeExpectedSessionId(expectedSessionId);
    const normalizedTimeoutMs: number = normalizeTimeoutMs(timeoutMs);
    const subscriptionId: number = this.controller.subscribe((event: VpnRuntimeEvent) => {
      handle.onRuntimeEvent(event);
    });
    const handle: ArmedOneClickVpnConfirmationHandle = new ArmedOneClickVpnConfirmationHandle(
      this.controller,
      normalizedExpectedSessionId,
      subscriptionId
    );
    try {
      const timeoutTask: CancelableDelayTask = this.scheduler.schedule(normalizedTimeoutMs, async () => {
        handle.onTimeout();
      });
      handle.attachTimeoutTask(timeoutTask);
    } catch (error) {
      handle.cancel();
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('One-click VPN confirmation scheduler failed.');
    }
    return handle;
  }
}
