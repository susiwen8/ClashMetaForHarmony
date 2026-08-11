import type { HomeViewState } from '../presentation/PresentationModels';
import { RuntimeStatusCard } from '../components/RuntimeStatusCard';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

@Component
export struct HomePage {
  @Prop state: HomeViewState;
  @Prop compactLayout: boolean;
  onManageProfiles: () => void = () => {
  };
  onPrimaryAction: () => void = () => {
  };

  build() {
    Column() {
      Scroll() {
        Column({ space: $r('app.float.space_lg') }) {
          Column({ space: $r('app.float.space_sm') }) {
            Text($r('app.string.home_title'))
              .fontSize($r('app.float.type_headline'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text_primary'))
              .width('100%')
              .textAlign(TextAlign.Start)

            Text($r('app.string.home_subtitle'))
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')

          Column({ space: $r('app.float.space_md') }) {
            Text($r('app.string.home_profile_title'))
              .fontSize($r('app.float.type_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text_secondary'))

            if (this.state.activeProfile !== undefined) {
              Text(this.state.activeProfile.name)
                .fontSize($r('app.float.type_title'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.color_text_primary'))
                .width('100%')
                .textAlign(TextAlign.Start)

              Text(this.state.activeProfile.sourceDisplay)
                .fontSize($r('app.float.type_body'))
                .fontColor($r('app.color.color_text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            } else {
              Text($r('app.string.home_profile_empty'))
                .fontSize($r('app.float.type_title'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.color_text_primary'))
                .width('100%')
                .textAlign(TextAlign.Start)

              Text($r('app.string.home_profile_empty_detail'))
                .fontSize($r('app.float.type_body'))
                .fontColor($r('app.color.color_text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }

            Divider()
              .color($r('app.color.color_border_subtle'))

            Row() {
              Text($r('app.string.home_profile_manage'))
                .fontSize($r('app.float.type_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.color_action_primary'))

              Blank()

              Text($r('app.string.home_profile_manage_trailing'))
                .fontSize($r('app.float.type_title'))
                .fontColor($r('app.color.color_action_primary'))
            }
            .id('home.profile.manage')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .onClick(() => {
              this.onManageProfiles();
            })
          }
          .width('100%')
          .padding($r('app.float.space_lg'))
          .borderRadius($r('app.float.radius_card'))
          .backgroundColor($r('app.color.color_surface_card'))
          .border({
            width: 1,
            color: $r('app.color.color_border_subtle')
          })

          RuntimeStatusCard({
            state: this.state
          })

          Button(primaryActionLabel(this.state.primaryAction, this.state.runtime))
            .id('home.runtime.primary')
            .width('100%')
            .enabled(this.state.primaryAction === 'START' || this.state.primaryAction === 'STOP')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor(primaryActionBackground(this.state.primaryAction))
            .fontColor(primaryActionForeground(this.state.primaryAction))
            .onClick(() => {
              this.onPrimaryAction();
            })

          if (this.state.error !== undefined) {
            SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
          }

          Column({ space: $r('app.float.space_sm') }) {
            Text($r('app.string.home_info_title'))
              .fontSize($r('app.float.type_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_action_primary'))

            Text($r('app.string.home_info_body'))
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_secondary'))
              .maxLines(3)
          }
          .width('100%')
          .padding($r('app.float.space_lg'))
          .borderRadius($r('app.float.radius_card'))
          .backgroundColor($r('app.color.color_surface_info_panel'))
        }
        .width('100%')
        .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.color_surface_background'))
  }
}

function primaryActionLabel(
  action: 'DISABLED' | 'START' | 'STOP' | 'BUSY',
  runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR'
) {
  if (action === 'STOP') {
    return $r('app.string.home_runtime_primary_stop');
  }
  if (action === 'BUSY' || runtime === 'STARTING' || runtime === 'STOPPING') {
    return $r('app.string.home_runtime_primary_busy');
  }
  return $r('app.string.home_runtime_primary_start');
}

function primaryActionBackground(action: 'DISABLED' | 'START' | 'STOP' | 'BUSY') {
  if (action === 'DISABLED' || action === 'BUSY') {
    return $r('app.color.color_action_primary_disabled');
  }
  if (action === 'STOP') {
    return $r('app.color.color_action_primary');
  }
  return $r('app.color.color_action_primary');
}

function primaryActionForeground(action: 'DISABLED' | 'START' | 'STOP' | 'BUSY') {
  if (action === 'DISABLED' || action === 'BUSY') {
    return $r('app.color.color_text_secondary');
  }
  return $r('app.color.color_text_inverse');
}
