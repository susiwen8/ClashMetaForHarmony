import type { HomeViewState } from '../presentation/PresentationModels';

@Component
export struct RuntimeStatusCard {
  @Prop state: HomeViewState;

  build() {
    Column({ space: $r('app.float.space_lg') }) {
      Row({ space: $r('app.float.space_md') }) {
        Text($r('app.string.home_runtime_indicator'))
          .fontSize($r('app.float.type_title'))
          .fontColor(runtimeColor(this.state.runtime))

        Column({ space: $r('app.float.space_xs') }) {
          Text(runtimeLabel(this.state.runtime))
            .fontSize($r('app.float.type_title'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_text_primary'))

          Text(runtimeDetail(this.state.runtime))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider()
        .color($r('app.color.color_border_subtle'))

      Column({ space: $r('app.float.space_md') }) {
        buildRuntimeAddress($r('app.string.home_runtime_http_label'), this.state.httpAddress)
        buildRuntimeAddress($r('app.string.home_runtime_socks_label'), this.state.socksAddress)
      }

      Divider()
        .color($r('app.color.color_border_subtle'))

      Text($r('app.string.home_runtime_boundary_note'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .maxLines(2)
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
function buildRuntimeAddress(label: Resource, value: string | undefined): void {
  Row() {
    Text(label)
      .fontSize($r('app.float.type_caption'))
      .fontColor($r('app.color.color_text_secondary'))

    Blank()

    if (value !== undefined && value.trim().length > 0) {
      Text(value)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_primary'))
    } else {
      Text($r('app.string.home_runtime_listener_placeholder'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
    }
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

function runtimeDetail(runtime: 'STOPPED' | 'STARTING' | 'RUNNING' | 'STOPPING' | 'ERROR') {
  switch (runtime) {
    case 'STARTING':
      return $r('app.string.home_runtime_detail_starting');
    case 'RUNNING':
      return $r('app.string.home_runtime_detail_running');
    case 'STOPPING':
      return $r('app.string.home_runtime_detail_stopping');
    case 'ERROR':
      return $r('app.string.home_runtime_detail_error');
    case 'STOPPED':
    default:
      return $r('app.string.home_runtime_detail_stopped');
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
