import { ProfileDetailViewModel } from '../presentation/ProfileDetailViewModel';
import type { ProfileDetailViewState } from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

@Component
export struct ProfileDetailPage {
  @Prop state: ProfileDetailViewState;
  @Prop compactLayout: boolean;
  viewModel?: ProfileDetailViewModel;
  onBack: () => void = () => {
  };
  onRequestReplaceSubscriptionUrl: () => void = () => {
  };

  build() {
    Scroll() {
      Column({ space: $r('app.float.space_lg') }) {
        Row() {
          Button($r('app.string.common_back'))
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.onBack();
            })

          Blank()
        }
        .width('100%')

        Text($r('app.string.detail_title'))
          .fontSize($r('app.float.type_headline'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)

        if (this.state.profile !== undefined) {
          Column({ space: $r('app.float.space_sm') }) {
            Text(this.state.profile.name)
              .fontSize($r('app.float.type_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text_primary'))

            Text(sourceKindLabel(this.state.profile.sourceKind))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))

            Text(this.state.profile.sourceDisplay)
              .fontSize($r('app.float.type_body'))
              .fontColor($r('app.color.color_text_primary'))

            Text($r('app.string.detail_updated_at'))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))

            Text(this.state.profile.updatedAt)
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_primary'))
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

        if (this.state.sourceRepairRequired) {
          Text($r('app.string.detail_source_repair_required'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_warning'))
        }

        if (this.state.error?.technicalDetail !== undefined || this.state.error !== undefined) {
          SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
        }

        if (this.state.canEnable) {
          Button($r('app.string.detail_enable'))
            .id('detail.enable')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_action_primary'))
            .fontColor($r('app.color.color_text_inverse'))
            .onClick(() => {
              void this.viewModel?.requestEnable();
            })
        }

        if (this.state.canRefresh) {
          Button(refreshLabel(this.state))
            .id('detail.refresh')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              void this.viewModel?.requestRefresh();
            })
        }

        if (this.state.canReplaceSubscriptionUrl) {
          Text($r('app.string.import_url_label'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))

          TextInput({
            text: this.viewModel?.currentReplacementUrlDraft() ?? '',
            placeholder: $r('app.string.import_url_placeholder')
          })
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .onChange((value: string) => {
              this.viewModel?.updateReplacementUrlDraft(value);
            })

          Button($r('app.string.detail_replace'))
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.onRequestReplaceSubscriptionUrl();
            })
        }

        if (this.state.canDelete) {
          Button($r('app.string.detail_delete'))
            .id('detail.delete')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_status_danger'))
            .fontColor($r('app.color.color_text_inverse'))
            .onClick(() => {
              this.viewModel?.requestDelete();
            })
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

function sourceKindLabel(sourceKind: 'LOCAL_FILE' | 'REMOTE_URL') {
  return sourceKind === 'LOCAL_FILE'
    ? $r('app.string.detail_source_kind_file')
    : $r('app.string.detail_source_kind_url');
}

function refreshLabel(state: ProfileDetailViewState) {
  if (state.profile?.sourceKind === 'LOCAL_FILE') {
    return $r('app.string.detail_replace');
  }
  return $r('app.string.detail_refresh');
}
