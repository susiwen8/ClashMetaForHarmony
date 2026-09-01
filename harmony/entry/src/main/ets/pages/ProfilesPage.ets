import type { ProfileRowState, ProfilesViewState } from '../presentation/PresentationModels';
import { ProfileListItem } from '../components/ProfileListItem';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

@Component
export struct ProfilesPage {
  @Prop state: ProfilesViewState;
  @Prop compactLayout: boolean;
  onBack: () => void = () => {
  };
  onOpenAddSheet: () => void = () => {
  };
  onOpenProfile: (profileId: string) => void = (_profileId: string) => {
  };

  build() {
    Scroll() {
      Column({ space: $r('app.float.space_lg') }) {
        Row({ space: $r('app.float.space_md') }) {
          Button($r('app.string.common_back'))
            .id('profiles.back')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_card'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.onBack();
            })

          Text($r('app.string.profiles_title'))
            .fontSize($r('app.float.type_headline'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button($r('app.string.profiles_add'))
            .id('profiles.add')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_action_primary'))
            .fontColor($r('app.color.color_text_inverse'))
            .onClick(() => {
              this.onOpenAddSheet();
            })
        }
        .width('100%')

        if (this.state.error !== undefined) {
          SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
        }

        if (this.state.profiles.length === 0) {
          Column({ space: $r('app.float.space_sm') }) {
            Text($r('app.string.profiles_empty_title'))
              .fontSize($r('app.float.type_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text_primary'))

            Text($r('app.string.profiles_empty_body'))
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_secondary'))
          }
          .width('100%')
          .padding($r('app.float.space_xl'))
          .borderRadius($r('app.float.radius_card'))
          .backgroundColor($r('app.color.color_surface_card'))
          .border({
            width: 1,
            color: $r('app.color.color_border_subtle')
          })
        } else {
          ForEach(this.state.profiles, (row: ProfileRowState) => {
            ProfileListItem({
              row,
              onOpenProfile: this.onOpenProfile
            })
          }, (row: ProfileRowState) => row.id)
        }
      }
      .width('100%')
      .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
