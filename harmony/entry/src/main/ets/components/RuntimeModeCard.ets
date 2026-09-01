import type { CoreRuntimeMode } from '@cmfa/shared';
import type { RuntimeModeState } from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from './SafeErrorCard';

@Component
export struct RuntimeModeCard {
  @Prop state: RuntimeModeState;
  onSelect: (mode: CoreRuntimeMode) => void = (_mode: CoreRuntimeMode): void => {
  };

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Text($r('app.string.home_mode_title'))
        .fontSize($r('app.float.type_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(resolveModeDescription(this.state))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Row({ space: $r('app.float.space_sm') }) {
        this.buildModeButton('RULE', $r('app.string.home_mode_rule'))
        this.buildModeButton('GLOBAL', $r('app.string.home_mode_global'))
        this.buildModeButton('DIRECT', $r('app.string.home_mode_direct'))
      }
      .width('100%')

      Text($r('app.string.home_mode_rule_note'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .width('100%')

      if (this.state.error !== undefined) {
        SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
      }
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({
      width: 1,
      color: $r('app.color.color_border_subtle')
    })
  }

  @Builder
  private buildModeButton(mode: CoreRuntimeMode, label: Resource): void {
    Button(label)
      .layoutWeight(1)
      .enabled(this.state.available && !this.state.pending)
      .constraintSize({ minHeight: $r('app.float.touch_target_min') })
      .backgroundColor(this.state.mode === mode
        ? $r('app.color.color_action_primary')
        : $r('app.color.color_surface_subtle'))
      .fontColor(this.state.mode === mode
        ? $r('app.color.color_text_inverse')
        : $r('app.color.color_text_primary'))
      .onClick(() => {
        this.onSelect(mode);
      })
  }
}
function resolveModeDescription(state: RuntimeModeState): Resource {
  if (state.pending) {
    return $r('app.string.home_mode_switching');
  }
  if (!state.available) {
    return $r('app.string.home_mode_unavailable');
  }
  switch (state.mode) {
    case 'GLOBAL':
      return $r('app.string.home_mode_global_description');
    case 'DIRECT':
      return $r('app.string.home_mode_direct_description');
    case 'RULE':
      return $r('app.string.home_mode_rule_description');
    default:
      return $r('app.string.home_mode_loading');
  }
}
