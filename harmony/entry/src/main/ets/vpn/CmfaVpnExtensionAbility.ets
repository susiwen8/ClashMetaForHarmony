import type { Want } from '@kit.AbilityKit';
import { VpnExtensionAbility } from '@kit.NetworkKit';
import { createVpnFailure, type VpnFailure } from '@cmfa/shared';
import {
  isVpnExtensionCompositionDraining,
  markVpnExtensionCompositionDraining,
  releaseVpnExtensionComposition,
  resolveVpnExtensionComposition,
  type VpnExtensionCompositionRunner
} from './VpnExtensionComposition';

function createAbilityStartFailure(): VpnFailure {
  return createVpnFailure('VPN_CREATE_FAILED', 'HarmonyOS VPN extension start failed.');
}

export default class CmfaVpnExtensionAbility extends VpnExtensionAbility {
  private composition?: VpnExtensionCompositionRunner;
  private startPromise?: Promise<void>;
  private destroyPromise?: Promise<void>;

  onCreate(want: Want): void {
    if (this.startPromise !== undefined) {
      return;
    }
    const composition: VpnExtensionCompositionRunner = this.composition ?? resolveVpnExtensionComposition(this.context);
    if (isVpnExtensionCompositionDraining(composition)) {
      return;
    }
    this.composition = composition;
    const startPromise: Promise<void> = composition.start(want)
      .catch(() => {
        return composition.recordUnexpectedFailure(createAbilityStartFailure());
      })
      .finally(() => {
        if (this.startPromise === startPromise) {
          this.startPromise = undefined;
        }
      });
    this.startPromise = startPromise;
  }

  onDestroy(): void {
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
