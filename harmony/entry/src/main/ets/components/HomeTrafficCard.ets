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
      Text($r('app.string.home_traffic_title'))
        .fontSize($r('app.float.type_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(resolveTrafficStatus(this.state))
        .id('home.traffic.status')
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      Divider()
        .color($r('app.color.color_border_subtle'))

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
    }
    .id('home.traffic.card')
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({
      width: 1,
      color: $r('app.color.color_border_subtle')
    })
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
      .fontSize($r('app.float.type_headline'))
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
