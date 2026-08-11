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
    Scroll() {
      Column({ space: $r('app.float.space_lg') }) {
        Text($r('app.string.home_title'))
          .fontSize($r('app.float.type_headline'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)

        Column({ space: $r('app.float.space_sm') }) {
          Text($r('app.string.home_profile_title'))
            .fontSize($r('app.float.type_title'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.color_text_primary'))

          if (this.state.activeProfile !== undefined) {
            Text(this.state.activeProfile.name)
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_primary'))

            Text(this.state.activeProfile.sourceDisplay)
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
          } else {
            Text($r('app.string.home_profile_empty'))
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_secondary'))
          }

          Button($r('app.string.home_profile_manage'))
            .id('home.profile.manage')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
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
          state: this.state,
          onPrimaryAction: this.onPrimaryAction
        })

        SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
      }
      .width('100%')
      .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
