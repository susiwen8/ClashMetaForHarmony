import type { HomeViewState } from '../presentation/PresentationModels';
import { RuntimeStatusCard } from '../components/RuntimeStatusCard';
import { HomeTrafficCard } from '../components/HomeTrafficCard';
import { RuntimeModeCard } from '../components/RuntimeModeCard';
import type { CoreRuntimeMode } from '@cmfa/shared';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

@Component
export struct HomePage {
  @Prop state: HomeViewState;
  @Link selectedProxyGroupName: string;
  @Link selectedProxyNodeName: string;
  @Prop compactLayout: boolean;
  onManageProfiles: () => void = () => {
  };
  onVpnAction: () => void = () => {
  };
  onRuntimeModeSelect: (mode: CoreRuntimeMode) => void = (_mode: CoreRuntimeMode): void => {
  };
  onOpenLogs: () => void = (): void => {
  };

  build() {
    Column() {
      Scroll() {
        Column({ space: $r('app.float.space_lg') }) {
          Column({ space: $r('app.float.space_xs') }) {
            Text($r('app.string.home_title'))
              .fontSize($r('app.float.type_headline'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text_primary'))
              .width('100%')
              .textAlign(TextAlign.Start)

            Text($r('app.string.home_subtitle'))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')

          buildProfileCard(this.state, this.onManageProfiles)

          RuntimeStatusCard({
            vpnState: this.state.vpnGlobalCapture,
            selectedProxyGroupName: $selectedProxyGroupName,
            selectedProxyNodeName: $selectedProxyNodeName
          })

          if (this.state.traffic.visible) {
            HomeTrafficCard({
              state: this.state.traffic
            })
          }

          RuntimeModeCard({
            state: this.state.runtimeMode,
            onSelect: this.onRuntimeModeSelect
          })

          Button($r('app.string.home_logs_open'))
            .id('home.logs.open')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_card'))
            .fontColor($r('app.color.color_action_primary'))
            .border({ width: 1, color: $r('app.color.color_border_subtle') })
            .onClick(() => {
              this.onOpenLogs();
            })

          Button(resolveVpnActionLabel(this.state))
            .id('home.vpn.action')
            .width('100%')
            .enabled(this.state.vpnGlobalCapture.action === 'START' || this.state.vpnGlobalCapture.action === 'STOP')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor(resolveActionBackground(this.state.vpnGlobalCapture.action))
            .fontColor(resolveActionForeground(this.state.vpnGlobalCapture.action))
            .onClick(() => {
              this.onVpnAction();
            })

          if (this.state.vpnGlobalCapture.error !== undefined) {
            SafeErrorCard({ error: this.state.vpnGlobalCapture.error ?? createEmptySafeErrorState() })
          }

          if (this.state.error !== undefined) {
            SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
          }
        }
        .width('100%')
        .padding($r('app.float.page_padding_compact'))
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
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

@Builder
function buildProfileCard(state: HomeViewState, onManageProfiles: () => void): void {
  Column({ space: $r('app.float.space_md') }) {
    Text($r('app.string.home_profile_title'))
      .fontSize($r('app.float.type_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.color_text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)

    if (state.activeProfile !== undefined) {
      Text(state.activeProfile.name)
        .fontSize($r('app.float.type_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(state.activeProfile.sourceDisplay)
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
        .fontSize($r('app.float.type_caption'))
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
      onManageProfiles();
    })
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

function resolveVpnActionLabel(state: HomeViewState) {
  const action: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = state.vpnGlobalCapture.action;
  if (action === 'STOP') {
    return $r('app.string.home_vpn_primary_stop');
  }
  if (action === 'BUSY') {
    return $r('app.string.home_runtime_primary_busy');
  }
  return $r('app.string.home_vpn_primary_start');
}

function resolveActionBackground(action: 'DISABLED' | 'START' | 'STOP' | 'BUSY') {
  if (action === 'DISABLED' || action === 'BUSY') {
    return $r('app.color.color_action_primary_disabled');
  }
  return $r('app.color.color_action_primary');
}

function resolveActionForeground(action: 'DISABLED' | 'START' | 'STOP' | 'BUSY') {
  if (action === 'DISABLED' || action === 'BUSY') {
    return $r('app.color.color_action_disabled_text');
  }
  return $r('app.color.color_text_inverse');
}
