import { describe, expect, it } from '@ohos/hypium';
import type { Want } from '@kit.AbilityKit';
import type { VpnControllerStartResult } from '@cmfa/shared';
import { HarmonyVpnController, type VpnExtensionAbilityApi } from '../main/ets/vpn/HarmonyVpnController';
import { VpnSessionRegistry } from '../main/ets/vpn/VpnSessionRegistry';

class FakeBusinessError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

class FakeVpnExtensionAbilityApi implements VpnExtensionAbilityApi {
  startWant?: Want;
  startCalls: number = 0;
  stopCalls: number = 0;
  startError?: Error;
  startBusinessError?: FakeBusinessError;
  rejectStartWithUndefined: boolean = false;
  rejectStartWithNull: boolean = false;
  stopError?: Error;
  deferStop: boolean = false;
  private resolveStopRef?: () => void;
  private rejectStopRef?: (error: Error) => void;
  private readonly deferredStopPromise: Promise<void>;

  setStartBusinessError(code: number, message: string): void {
    this.startBusinessError = new FakeBusinessError(code, message);
  }

  constructor() {
    this.deferredStopPromise = new Promise<void>((resolve, reject) => {
      this.resolveStopRef = resolve;
      this.rejectStopRef = reject;
    });
  }

  setStopError(error: Error): void {
    this.stopError = error;
  }

  resolveDeferredStop(): void {
    this.resolveStopRef?.();
  }

  rejectDeferredStop(error: Error): void {
    this.rejectStopRef?.(error);
  }

  async startVpnExtensionAbility(want: Want): Promise<void> {
    this.startCalls += 1;
    this.startWant = want;
    if (this.rejectStartWithUndefined) {
      return await Promise.reject();
    }
    if (this.rejectStartWithNull) {
      return await Promise.reject(null);
    }
    if (this.startBusinessError !== undefined) {
      throw this.startBusinessError;
    }
    if (this.startError !== undefined) {
      throw this.startError;
    }
  }

  async stopVpnExtensionAbility(): Promise<void> {
    this.stopCalls += 1;
    if (this.deferStop) {
      return await this.deferredStopPromise;
    }
    if (this.stopError !== undefined) {
      throw this.stopError;
    }
  }
}

function requireStartWant(api: FakeVpnExtensionAbilityApi): Want {
  const want: Want | undefined = api.startWant;
  if (want === undefined) {
    expect().assertFail();
  }
  return want as Want;
}

function hasParameter(parameters: Record<string, Object>, key: string): boolean {
  return Object.keys(parameters).includes(key);
}

function expectRejected(result: VpnControllerStartResult, code: string): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind !== 'REJECTED') {
    expect().assertFail();
    return;
  }
  expect(result.failure.code).assertEqual(code);
}

async function settleMicrotasks(turns: number = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) {
    await Promise.resolve();
  }
}

export default function harmonyVpnControllerTestsuite() {
  describe('HarmonyVpnControllerTest', () => {
    it('startsWithTheExactVpnExtensionWantAndPublishesAwaitingConsent', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      const controller = new HarmonyVpnController(registry, api);

      const result = await controller.start('profile-1', 'version-1', 'session-1');

      expect(api.startCalls).assertEqual(1);
      expect(result.kind).assertEqual('STARTED');
      expect(registry.snapshot().state).assertEqual('AWAITING_CONSENT');

      const want = requireStartWant(api);
      expect(want.bundleName ?? '').assertEqual('com.github.kr328.clash.harmony');
      expect(want.abilityName ?? '').assertEqual('CmfaVpnExtensionAbility');

      const parameters: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
      expect(Object.keys(parameters).sort().join(',')).assertEqual('profileId,sessionId,versionId');
      expect(parameters.profileId as string).assertEqual('profile-1');
      expect(parameters.versionId as string).assertEqual('version-1');
      expect(parameters.sessionId as string).assertEqual('session-1');
      expect(hasParameter(parameters, 'url')).assertFalse();
      expect(hasParameter(parameters, 'node')).assertFalse();
      expect(hasParameter(parameters, 'credential')).assertFalse();
      expect(hasParameter(parameters, 'vpnId')).assertFalse();
      expect(hasParameter(parameters, 'fd')).assertFalse();
    });

    it('rejectsBlankIdsAndDuplicatePendingOrActiveStarts', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      const controller = new HarmonyVpnController(registry, api);

      const blank = await controller.start('profile-1', ' ', 'session-1');
      expectRejected(blank, 'VPN_CONFIG_INVALID');
      expect(api.startCalls).assertEqual(0);

      const first = await controller.start('profile-1', 'version-1', 'session-1');
      expect(first.kind).assertEqual('STARTED');

      const duplicatePending = await controller.start('profile-2', 'version-2', 'session-2');
      expectRejected(duplicatePending, 'VPN_ALREADY_ACTIVE');
      expect(api.startCalls).assertEqual(1);

      registry.activatePending('session-1', 'RUNNING');
      const duplicateActive = await controller.start('profile-2', 'version-2', 'session-2');
      expectRejected(duplicateActive, 'VPN_ALREADY_ACTIVE');
      expect(api.startCalls).assertEqual(1);
    });

    it('mapsConsentDenialAndBusinessErrorsWithoutLeakingSystemMessages', 0, async () => {
      const deniedRegistry = new VpnSessionRegistry();
      const deniedApi = new FakeVpnExtensionAbilityApi();
      deniedApi.setStartBusinessError(2203001, 'raw consent secret 42');
      const deniedController = new HarmonyVpnController(deniedRegistry, deniedApi);

      const denied = await deniedController.start('profile-1', 'version-1', 'session-1');
      expectRejected(denied, 'VPN_PERMISSION_DENIED');
      expect(deniedRegistry.snapshot().state).assertEqual('STOPPED');
      expect(deniedRegistry.snapshot().lastFailure?.detail.includes('raw consent secret 42') ?? false).assertFalse();

      const failedRegistry = new VpnSessionRegistry();
      const failedApi = new FakeVpnExtensionAbilityApi();
      failedApi.setStartBusinessError(2203999, 'raw platform secret 99');
      const failedController = new HarmonyVpnController(failedRegistry, failedApi);

      const failed = await failedController.start('profile-1', 'version-1', 'session-1');
      expectRejected(failed, 'VPN_CREATE_FAILED');
      expect(failedRegistry.snapshot().state).assertEqual('STOPPED');
      expect(failedRegistry.snapshot().lastFailure?.detail.includes('raw platform secret 99') ?? false).assertFalse();
    });

    it('keepsStopPendingUntilDestructionAndSharesOneCompletionPromiseAcrossDuplicateStops', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      api.deferStop = true;
      const controller = new HarmonyVpnController(registry, api);

      await controller.start('profile-1', 'version-1', 'session-1');
      registry.activatePending('session-1', 'RUNNING');

      let firstSettled: boolean = false;
      let secondSettled: boolean = false;
      const firstStopPromise = controller.stop('session-1').then((result) => {
        firstSettled = true;
        return result;
      });
      const secondStopPromise = controller.stop('session-1').then((result) => {
        secondSettled = true;
        return result;
      });

      await settleMicrotasks();
      expect(firstSettled).assertFalse();
      expect(secondSettled).assertFalse();
      expect(api.stopCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('STOPPING');
      expect(registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');

      controller.handleExtensionDestroyed();
      await settleMicrotasks();

      const firstStop = await firstStopPromise;
      const secondStop = await secondStopPromise;
      expect(firstStop.kind).assertEqual('STOPPED');
      expect(secondStop.kind).assertEqual('STOPPED');
      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(controller.isUserStopRequested('session-1')).assertFalse();
    });

    it('retriesThePlatformStopForTheSameSessionAfterAFailedAttempt', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      const controller = new HarmonyVpnController(registry, api);

      await controller.start('profile-1', 'version-1', 'session-1');
      registry.activatePending('session-1', 'RUNNING');
      api.deferStop = true;

      const firstStopPromise = controller.stop('session-1');
      api.rejectDeferredStop(new Error('raw stop secret 77'));
      const firstStop = await firstStopPromise;

      expect(firstStop.kind).assertEqual('FAILED');
      expect(api.stopCalls).assertEqual(1);
      expect(registry.snapshot().state).assertEqual('ERROR');
      expect(registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw stop secret 77') ?? false).assertFalse();

      api.deferStop = false;
      api.stopError = undefined;
      let secondSettled: boolean = false;
      const secondStopPromise = controller.stop('session-1').then((result) => {
        secondSettled = true;
        return result;
      });
      await settleMicrotasks();

      expect(secondSettled).assertFalse();
      expect(api.stopCalls).assertEqual(2);
      expect(registry.snapshot().state).assertEqual('STOPPING');
      expect(registry.snapshot().activeRequest?.sessionId ?? '').assertEqual('session-1');
      controller.handleExtensionDestroyed();
      const secondStop = await secondStopPromise;
      expect(secondStop.kind).assertEqual('STOPPED');
    });

    it('preservesStopFailureAfterUserRequestedDestructionCompletesTheSession', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      const controller = new HarmonyVpnController(registry, api);

      await controller.start('profile-1', 'version-1', 'session-1');
      registry.activatePending('session-1', 'RUNNING');
      api.setStopError(new Error('raw stop secret 77'));

      const firstStop = await controller.stop('session-1');

      expect(firstStop.kind).assertEqual('FAILED');
      expect(registry.snapshot().state).assertEqual('ERROR');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw stop secret 77') ?? false).assertFalse();

      controller.handleExtensionDestroyed();

      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_STOP_FAILED');
      expect(registry.snapshot().lastFailure?.detail.includes('raw stop secret 77') ?? false).assertFalse();
    });

    it('handlesUndefinedAndNullStartRejectionsWithoutLeavingPendingStateBehind', 0, async () => {
      const undefinedRegistry = new VpnSessionRegistry();
      const undefinedApi = new FakeVpnExtensionAbilityApi();
      undefinedApi.rejectStartWithUndefined = true;
      const undefinedController = new HarmonyVpnController(undefinedRegistry, undefinedApi);

      const undefinedResult = await undefinedController.start('profile-1', 'version-1', 'session-1');

      expectRejected(undefinedResult, 'VPN_CREATE_FAILED');
      expect(undefinedRegistry.snapshot().state).assertEqual('STOPPED');
      expect(undefinedRegistry.snapshot().activeRequest).assertNull();

      const nullRegistry = new VpnSessionRegistry();
      const nullApi = new FakeVpnExtensionAbilityApi();
      nullApi.rejectStartWithNull = true;
      const nullController = new HarmonyVpnController(nullRegistry, nullApi);

      const nullResult = await nullController.start('profile-1', 'version-1', 'session-1');

      expectRejected(nullResult, 'VPN_CREATE_FAILED');
      expect(nullRegistry.snapshot().state).assertEqual('STOPPED');
      expect(nullRegistry.snapshot().activeRequest).assertNull();
    });

    it('classifiesUnrequestedExtensionDestructionAsSystemRevocation', 0, async () => {
      const registry = new VpnSessionRegistry();
      const api = new FakeVpnExtensionAbilityApi();
      const controller = new HarmonyVpnController(registry, api);

      await controller.start('profile-1', 'version-1', 'session-1');
      registry.activatePending('session-1', 'RUNNING');

      controller.handleExtensionDestroyed();

      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure?.code ?? '').assertEqual('VPN_SYSTEM_REVOKED');

      await controller.start('profile-2', 'version-2', 'session-2');
      registry.activatePending('session-2', 'RUNNING');
      const requestedStop = controller.stop('session-2');
      controller.handleExtensionDestroyed();
      await requestedStop;

      expect(registry.snapshot().state).assertEqual('STOPPED');
      expect(registry.snapshot().lastFailure).assertNull();
    });
  });
}
