import {
  createHomeTrafficState,
  formatTrafficBytes,
  type HomeTrafficState
} from '../presentation/PresentationModels';

@Component
export struct HomeTrafficCard {
  @Prop state: HomeTrafficState = createHomeTrafficState(false, false, 0, 0, 0, 0, false);

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Text($r('app.string.home_traffic_title'))
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))

        Blank()

        Text(resolveTrafficStatus(this.state))
          .id('home.traffic.status')
          .fontSize($r('app.float.type_caption'))
          .fontColor(this.state.available
            ? $r('app.color.color_status_success')
            : $r('app.color.color_text_secondary'))
      }
      .width('100%')

      Row({ space: $r('app.float.space_md') }) {
        buildTrafficMetric(
          $r('app.string.home_traffic_upload'),
          formatTrafficBytes(this.state.uploadBytesPerSecond),
          formatTrafficBytes(this.state.txBytes),
          'home.traffic.upload.speed',
          'home.traffic.upload.total'
        )
        buildTrafficMetric(
          $r('app.string.home_traffic_download'),
          formatTrafficBytes(this.state.downloadBytesPerSecond),
          formatTrafficBytes(this.state.rxBytes),
          'home.traffic.download.speed',
          'home.traffic.download.total'
        )
      }
      .width('100%')
      .padding($r('app.float.space_sm'))
      .borderRadius($r('app.float.radius_action'))
      .backgroundColor($r('app.color.color_surface_subtle'))
    }
    .id('home.traffic.card')
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
  }
}

@Builder
function buildTrafficMetric(
  title: Resource,
  speed: string,
  total: string,
  speedId: string,
  totalId: string
): void {
  Column({ space: $r('app.float.space_xs') }) {
    Text(title)
      .fontSize($r('app.float.type_caption'))
      .fontColor($r('app.color.color_text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)

    Text(`${speed}/s`)
      .id(speedId)
      .fontSize($r('app.float.type_metric'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.color_text_primary'))
      .width('100%')
      .textAlign(TextAlign.Start)

    Row({ space: $r('app.float.space_xs') }) {
      Text($r('app.string.home_traffic_total'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))

      Text(total)
        .id(totalId)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_primary'))
    }
    .width('100%')
  }
  .layoutWeight(1)
  .alignItems(HorizontalAlign.Start)
}

function resolveTrafficStatus(state: HomeTrafficState): Resource {
  if (state.recovering) {
    return $r('app.string.home_traffic_status_recovering');
  }
  if (!state.available) {
    return $r('app.string.home_traffic_status_unavailable');
  }
  return $r('app.string.home_traffic_status_available');
}
