import type { Want } from '@kit.AbilityKit';
import { VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { createVpnFailure, type VpnFailure } from '@cmfa/shared';
import {
  cloneValidatedVpnReplayWant,
  isVpnExtensionCompositionDraining,
  markVpnExtensionCompositionDraining,
  parseVpnStartWant,
  releaseVpnExtensionComposition,
  resolveVpnExtensionComposition,
  waitForVpnExtensionCompositionDrainRelease,
  type VpnExtensionCompositionRunner
} from './VpnExtensionComposition';

const VPN_ABILITY_LOG_DOMAIN: number = 0x0000;
const VPN_ABILITY_LOG_TAG: string = 'CMFAVpn';

function logVpnAbilityStage(stage: string): void {
  hilog.info(VPN_ABILITY_LOG_DOMAIN, VPN_ABILITY_LOG_TAG, '%{public}s', stage);
}

function createAbilityStartFailure(): VpnFailure {
  return createVpnFailure('VPN_CREATE_FAILED', 'HarmonyOS VPN extension start failed.');
}

export default class CmfaVpnExtensionAbility extends VpnExtensionAbility {
  private composition?: VpnExtensionCompositionRunner;
  private startPromise?: Promise<void>;
  private destroyPromise?: Promise<void>;
  private queuedReplayWant?: Want;
  private queuedReplayPromise?: Promise<void>;
  private replayEpoch: number = 0;
  private destroyed: boolean = false;

  onCreate(want: Want): void {
    logVpnAbilityStage('ability.onCreate');
    this.startFromWant(want);
  }

  onRequest(want: Want, startId: number): void {
    logVpnAbilityStage('ability.onRequest');
    void startId;
    this.startFromWant(want);
  }

  private startFromWant(want: Want): void {
    const replayWant: Want | undefined = cloneValidatedVpnReplayWant(want);
    if (parseVpnStartWant(want) === undefined || replayWant === undefined) {
      logVpnAbilityStage('ability.want.invalid');
      return;
    }
    this.destroyed = false;
    logVpnAbilityStage('ability.want.valid');
    if (this.startPromise !== undefined) {
      return;
    }
    const composition: VpnExtensionCompositionRunner = this.composition ?? resolveVpnExtensionComposition(this.context);
    if (isVpnExtensionCompositionDraining(composition)) {
      this.queueReplayAfterDrain(replayWant);
      return;
    }
    this.composition = composition;
    this.queuedReplayWant = undefined;
    logVpnAbilityStage('ability.composition.start');
    const startPromise: Promise<void> = composition.start(want)
      .then(() => {
        logVpnAbilityStage('ability.composition.ok');
      })
      .catch(() => {
        logVpnAbilityStage('ability.composition.failed');
        return composition.recordUnexpectedFailure(createAbilityStartFailure());
      })
      .finally(() => {
        if (this.startPromise === startPromise) {
          this.startPromise = undefined;
        }
      });
    this.startPromise = startPromise;
  }

  private queueReplayAfterDrain(want: Want): void {
    this.queuedReplayWant = want;
    if (this.queuedReplayPromise !== undefined) {
      return;
    }
    const epoch: number = this.replayEpoch + 1;
    this.replayEpoch = epoch;
    const replayPromise: Promise<void> = waitForVpnExtensionCompositionDrainRelease()
      .then(() => {
        if (this.destroyed || this.replayEpoch !== epoch) {
          return;
        }
        const queued: Want | undefined = this.queuedReplayWant;
        this.queuedReplayWant = undefined;
        if (queued === undefined) {
          return;
        }
        this.startFromWant(queued);
      })
      .finally(() => {
        if (this.queuedReplayPromise === replayPromise) {
          this.queuedReplayPromise = undefined;
        }
      });
    this.queuedReplayPromise = replayPromise;
  }

  onDestroy(): void {
    logVpnAbilityStage('ability.onDestroy');
    this.destroyed = true;
    this.queuedReplayWant = undefined;
    this.replayEpoch += 1;
    if (this.destroyPromise !== undefined) {
      return;
    }
    const composition: VpnExtensionCompositionRunner | undefined = this.composition;
    if (composition === undefined) {
      return;
    }
    markVpnExtensionCompositionDraining(composition);
    const pendingStart: Promise<void> = this.startPromise ?? Promise.resolve();
    const destroyPromise: Promise<void> = pendingStart
      .catch(() => {
      })
      .then(() => {
        return composition.stopForDestroy();
      })
      .catch(() => {
      })
      .finally(() => {
        if (this.destroyPromise === destroyPromise) {
          this.destroyPromise = undefined;
        }
        releaseVpnExtensionComposition(composition);
        if (this.composition === composition) {
          this.composition = undefined;
        }
      });
    this.destroyPromise = destroyPromise;
  }
}
