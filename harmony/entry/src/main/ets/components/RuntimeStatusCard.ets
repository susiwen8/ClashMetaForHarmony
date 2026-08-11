import type { HomeViewState } from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from './SafeErrorCard';

@Component
export struct RuntimeStatusCard {
  @Prop state: HomeViewState;
  onPrimaryAction: () => void = () => {
  };

  build() {
    Column({ space: $r('app.float.space_lg') }) {
      Row() {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.home_runtime_title'))
            .fontSize($r('app.float.type_title'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_text_primary'))

          Text(runtimeLabel(this.state.runtime))
            .fontSize($r('app.float.type_body'))
            .fontColor(runtimeColor(this.state.runtime))
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Button(primaryActionLabel(this.state.primaryAction, this.state.runtime))
          .id('home.runtime.primary')
          .enabled(this.state.primaryAction === 'START' || this.state.primaryAction === 'STOP')
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor(primaryActionBackground(this.state.primaryAction))
          .fontColor($r('app.color.color_text_inverse'))
          .onClick(() => {
            this.onPrimaryAction();
          })
      }
      .width('100%')

      Text($r('app.string.home_runtime_local_proxy'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))

      if (this.state.httpAddress !== undefined || this.state.socksAddress !== undefined) {
        Column({ space: $r('app.float.space_sm') }) {
          if (this.state.httpAddress !== undefined) {
            buildRuntimeAddress($r('app.string.home_runtime_http_label'), this.state.httpAddress);
          }
          if (this.state.socksAddress !== undefined) {
            buildRuntimeAddress($r('app.string.home_runtime_socks_label'), this.state.socksAddress);
          }
        }
      } else if (this.state.primaryAction === 'DISABLED') {
        Text($r('app.string.home_runtime_missing_profile'))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
      }

      SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
    }
    .width('100%')
    .padding($r('app.float.space_lg'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({
      width: 1,
      color: $r('app.color.color_border_subtle')
    })
  }
}

@Builder
function buildRuntimeAddress(label: Resource, value: string): void {
  Row() {
    Text(label)
      .fontSize($r('app.float.type_caption'))
      .fontColor($r('app.color.color_text_secondary'))

    Blank()

    Text(value)
      .fontSize($r('app.float.type_caption'))
      .fontColor($r('app.color.color_text_primary'))
  }
  .width('100%')
}

function runtimeLabel(runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR') {
  switch (runtime) {
    case 'STARTING':
      return $r('app.string.home_runtime_status_starting');
    case 'RUNNING':
      return $r('app.string.home_runtime_status_running');
    case 'STOPPING':
      return $r('app.string.home_runtime_status_stopping');
    case 'ERROR':
      return $r('app.string.home_runtime_status_error');
    case 'STOPPED':
    default:
      return $r('app.string.home_runtime_status_stopped');
  }
}

function runtimeColor(runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR') {
  switch (runtime) {
    case 'RUNNING':
      return $r('app.color.color_status_success');
    case 'STARTING':
    case 'STOPPING':
      return $r('app.color.color_status_warning');
    case 'ERROR':
      return $r('app.color.color_status_danger');
    case 'STOPPED':
    default:
      return $r('app.color.color_text_secondary');
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
  if (action === 'DISABLED') {
    return $r('app.color.color_action_primary_disabled');
  }
  if (action === 'STOP') {
    return $r('app.color.color_status_danger');
  }
  return $r('app.color.color_action_primary');
}
