import type { VpnGlobalCaptureState } from '../presentation/PresentationModels';

@Component
export struct RuntimeStatusCard {
  @Prop vpnState: VpnGlobalCaptureState = createEmptyVpnGlobalCaptureState();
  @Link selectedProxyGroupName: string;
  @Link selectedProxyNodeName: string;

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Text($r('app.string.home_vpn_title'))
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))

        Blank()

        Text(resolveStatusLabel(this.vpnState))
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(runtimeColor(this.vpnState.status))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.buildSelectedProxyRows()

      Divider()
        .color($r('app.color.color_border_subtle'))

      Row({ space: $r('app.float.space_lg') }) {
        Column({ space: $r('app.float.space_sm') }) {
          buildFactRow(
            $r('app.string.home_vpn_ipv4_label'),
            this.vpnState.ipv4Enabled ? $r('app.string.home_vpn_enabled') : $r('app.string.home_vpn_disabled')
          )
          buildFactRow(
            $r('app.string.home_vpn_dns_label'),
            this.vpnState.dnsServers.length > 0 ? this.vpnState.dnsServers.join(', ') : undefined
          )
          buildFactRow(
            $r('app.string.home_vpn_notification_label'),
            this.vpnState.notificationActive
              ? $r('app.string.home_vpn_notification_active')
              : $r('app.string.home_vpn_notification_inactive')
          )
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: $r('app.float.space_sm') }) {
          buildFactRow(
            $r('app.string.home_vpn_ipv6_label'),
            this.vpnState.ipv6Enabled ? $r('app.string.home_vpn_enabled') : $r('app.string.home_vpn_disabled')
          )
          buildFactRow(
            $r('app.string.home_vpn_mtu_label'),
            this.vpnState.mtu === undefined ? undefined : `${this.vpnState.mtu}`
          )
          buildFactRow($r('app.string.home_vpn_recovery_label'), resolveRecoveryValue(this.vpnState))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Divider()
        .color($r('app.color.color_border_subtle'))

      Text($r('app.string.home_vpn_boundary_note'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .maxLines(3)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
  }

  @Builder
  private buildSelectedProxyRows(): void {
    if (this.selectedProxyGroupName.length > 0 && this.selectedProxyNodeName.length > 0) {
      Column({ space: $r('app.float.space_xs') }) {
        Row({ space: $r('app.float.space_sm') }) {
          Text($r('app.string.home_vpn_proxy_group_label'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))

          Text(this.selectedProxyGroupName)
            .layoutWeight(1)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_primary'))
            .textAlign(TextAlign.End)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row({ space: $r('app.float.space_sm') }) {
          Text($r('app.string.home_vpn_proxy_node_label'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))

          Text(this.selectedProxyNodeName)
            .layoutWeight(1)
            .fontSize($r('app.float.type_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_text_primary'))
            .textAlign(TextAlign.End)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .width('100%')
      .padding($r('app.float.space_sm'))
      .borderRadius($r('app.float.radius_action'))
      .backgroundColor($r('app.color.color_surface_subtle'))
    }
  }
}

class VpnGlobalCaptureStateValue implements VpnGlobalCaptureState {
  status: 'STOPPED' | 'AWAITING_CONSENT' | 'STARTING' | 'RUNNING' | 'RECOVERING' | 'STOPPING' | 'ERROR' = 'STOPPED';
  action: 'DISABLED' | 'START' | 'STOP' | 'BUSY' = 'DISABLED';
  ipv4Enabled: boolean = false;
  ipv6Enabled: boolean = false;
  dnsServers: string[] = [];
  mtu?: number;
  notificationActive: boolean = false;
  recoveryAttempt: number = 0;
  scheduledRetryDelayMs?: number;
  error?: import('../presentation/PresentationModels').SafeErrorState;
}

function createEmptyVpnGlobalCaptureState(): VpnGlobalCaptureState {
  return new VpnGlobalCaptureStateValue();
}

@Builder
function buildFactRow(label: Resource, value: Resource | string | undefined): void {
  Column({ space: $r('app.float.space_xs') }) {
    Text(label)
      .fontSize($r('app.float.type_caption'))
      .fontColor($r('app.color.color_text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)

    if (value !== undefined && `${value}`.trim().length > 0) {
      if (typeof value === 'string') {
        Text(value)
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text(value)
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    } else {
      Text($r('app.string.home_runtime_listener_placeholder'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
    }
  }
  .width('100%')
  .alignItems(HorizontalAlign.Start)
}

function resolveStatusLabel(vpnState: VpnGlobalCaptureState) {
  switch (vpnState.status) {
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

function resolveRecoveryValue(state: VpnGlobalCaptureState): string | Resource {
  if (state.status === 'RECOVERING') {
    return state.scheduledRetryDelayMs === undefined
      ? $r('app.string.home_vpn_recovery_active')
      : `${state.recoveryAttempt} / ${state.scheduledRetryDelayMs} ms`;
  }
  return $r('app.string.home_vpn_recovery_idle');
}

function runtimeColor(status: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR' | 'AWAITING_CONSENT' | 'RECOVERING') {
  switch (status) {
    case 'RUNNING':
      return $r('app.color.color_status_success');
    case 'AWAITING_CONSENT':
    case 'STARTING':
    case 'STOPPING':
    case 'RECOVERING':
      return $r('app.color.color_status_warning');
    case 'ERROR':
      return $r('app.color.color_status_danger');
    case 'STOPPED':
    default:
      return $r('app.color.color_text_secondary');
  }
}
