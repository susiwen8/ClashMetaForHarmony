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
              .fontSize($r('app.float.type_display'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text_primary'))
              .letterSpacing(0.2)
              .width('100%')
              .textAlign(TextAlign.Start)

            Text($r('app.string.home_subtitle'))
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .margin({ bottom: $r('app.float.space_xs') })

          this.buildConnectionHero()

          if (this.state.vpnGlobalCapture.error !== undefined) {
            SafeErrorCard({ error: this.state.vpnGlobalCapture.error ?? createEmptySafeErrorState() })
          }

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
            .fontColor($r('app.color.color_text_primary'))
            .borderRadius($r('app.float.radius_action'))
            .onClick(() => {
              this.onOpenLogs();
            })

          if (this.state.error !== undefined) {
            SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
          }

          Blank()
            .height($r('app.float.space_3xl'))
        }
        .width('100%')
        .padding($r('app.float.page_padding_compact'))
        .alignItems(HorizontalAlign.Start)
      }
      .id('home.scroll')
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

  @Builder
  private buildConnectionHero(): void {
    Column({ space: $r('app.float.space_lg') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Row()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(this.resolveHeroStatusColor())

        Text(this.resolveHeroStatusLabel())
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.resolveHeroStatusColor())

        Blank()

        Text($r('app.string.home_vpn_title'))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_on_hero_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: $r('app.float.space_xs') }) {
        Text(this.resolveHeroContext())
          .fontSize($r('app.float.type_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_on_hero'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(this.resolveHeroSupportText())
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_on_hero_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Button(resolveVpnActionLabel(this.state))
        .id('home.vpn.action')
        .width('100%')
        .enabled(this.state.vpnGlobalCapture.action === 'START' || this.state.vpnGlobalCapture.action === 'STOP')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .backgroundColor(resolveActionBackground(this.state.vpnGlobalCapture.action))
        .fontColor(resolveActionForeground(this.state.vpnGlobalCapture.action))
        .fontWeight(FontWeight.Medium)
        .borderRadius($r('app.float.radius_action'))
        .accessibilityText(resolveVpnActionLabel(this.state))
        .onClick(() => {
          this.onVpnAction();
        })
    }
    .width('100%')
    .padding($r('app.float.space_lg'))
    .borderRadius($r('app.float.radius_hero'))
    .backgroundColor($r('app.color.color_surface_hero'))
  }

  private resolveHeroStatusLabel(): Resource {
    if (this.state.activeProfile === undefined) {
      return $r('app.string.home_profile_empty');
    }
    switch (this.state.vpnGlobalCapture.status) {
      case 'AWAITING_CONSENT':
        return $r('app.string.home_vpn_status_awaiting_consent');
      case 'STARTING':
        return $r('app.string.home_vpn_status_starting');
      case 'RUNNING':
        return $r('app.string.home_vpn_status_running');
      case 'RECOVERING':
        return $r('app.string.home_vpn_status_recovering');
      case 'STOPPING':
        return $r('app.string.home_vpn_status_stopping');
      case 'ERROR':
        return $r('app.string.home_vpn_status_error');
      case 'STOPPED':
      default:
        return $r('app.string.home_vpn_status_stopped');
    }
  }

  private resolveHeroStatusColor(): Resource {
    switch (this.state.vpnGlobalCapture.status) {
      case 'RUNNING':
        return $r('app.color.color_signal_active');
      case 'AWAITING_CONSENT':
      case 'STARTING':
      case 'RECOVERING':
      case 'STOPPING':
        return $r('app.color.color_status_warning');
      case 'ERROR':
        return $r('app.color.color_status_danger');
      case 'STOPPED':
      default:
        return $r('app.color.color_signal_idle');
    }
  }

  private resolveHeroContext(): Resource | string {
    if (this.state.activeProfile === undefined) {
      return $r('app.string.home_profile_empty_detail');
    }
    if (this.selectedProxyNodeName.length > 0) {
      return this.selectedProxyNodeName;
    }
    return this.state.activeProfile.name;
  }

  private resolveHeroSupportText(): Resource | string {
    if (this.state.activeProfile === undefined) {
      return $r('app.string.home_profile_manage');
    }
    if (this.selectedProxyGroupName.length > 0) {
      return this.selectedProxyGroupName;
    }
    return this.state.activeProfile.sourceDisplay;
  }
}

@Builder
function buildProfileCard(state: HomeViewState, onManageProfiles: () => void): void {
  Row({ space: $r('app.float.space_md') }) {
    Column({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.home_profile_title'))
        .fontSize($r('app.float.type_caption'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(state.activeProfile?.name ?? $r('app.string.home_profile_empty'))
        .fontSize($r('app.float.type_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      if (state.activeProfile !== undefined) {
        Text(state.activeProfile.sourceDisplay)
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      } else {
        Text($r('app.string.home_profile_empty_detail'))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)

    Column({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.home_profile_manage'))
        .fontSize($r('app.float.type_caption'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_action_primary'))

      Text($r('app.string.home_profile_manage_trailing'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
    }
    .alignItems(HorizontalAlign.End)
  }
  .id('home.profile.manage')
  .width('100%')
  .padding($r('app.float.space_md'))
  .constraintSize({ minHeight: $r('app.float.touch_target_min') })
  .borderRadius($r('app.float.radius_card'))
  .backgroundColor($r('app.color.color_surface_card'))
  .onClick(() => {
    onManageProfiles();
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
  if (action === 'START') {
    return $r('app.color.color_action_primary');
  }
  return $r('app.color.color_surface_hero_subtle');
}

function resolveActionForeground(action: 'DISABLED' | 'START' | 'STOP' | 'BUSY') {
  if (action === 'DISABLED' || action === 'BUSY') {
    return $r('app.color.color_text_on_hero_secondary');
  }
  return $r('app.color.color_text_on_hero');
}
