import { ImportProfileViewModel } from '../presentation/ImportProfileViewModel';
import type { ImportProfileViewState } from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

@Component
export struct ImportProfileSheet {
  @Prop state: ImportProfileViewState;
  @Prop compactLayout: boolean;
  viewModel?: ImportProfileViewModel;
  onClose: () => void = () => {
  };

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.import_title'))
            .fontSize($r('app.float.type_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text_primary'))

          Text($r('app.string.import_url_action'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.import_cancel'))
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_surface_subtle'))
          .fontColor($r('app.color.color_text_primary'))
          .borderRadius($r('app.float.radius_action'))
          .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: $r('app.float.space_md') }) {
          SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })

          Column({ space: $r('app.float.space_xs') }) {
            Text($r('app.string.import_name_label'))
              .fontSize($r('app.float.type_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)

            TextInput({
              text: this.viewModel?.currentNameDraft() ?? '',
              placeholder: $r('app.string.import_name_placeholder')
            })
              .width('100%')
              .constraintSize({ minHeight: $r('app.float.touch_target_min') })
              .backgroundColor($r('app.color.color_surface_subtle'))
              .borderRadius($r('app.float.radius_action'))
              .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
              .onChange((value: string) => {
                this.viewModel?.updateNameDraft(value);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: $r('app.float.space_xs') }) {
            Text($r('app.string.import_url_label'))
              .fontSize($r('app.float.type_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)

            TextInput({
              text: this.viewModel?.currentUrlDraft() ?? '',
              placeholder: $r('app.string.import_url_placeholder')
            })
              .id('import.url')
              .width('100%')
              .constraintSize({ minHeight: $r('app.float.touch_target_min') })
              .backgroundColor($r('app.color.color_surface_subtle'))
              .borderRadius($r('app.float.radius_action'))
              .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
              .onChange((value: string) => {
                this.viewModel?.updateUrlDraft(value);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Button($r('app.string.import_submit'))
            .id('import.submit')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_action_primary'))
            .fontColor($r('app.color.color_text_inverse'))
            .fontWeight(FontWeight.Medium)
            .borderRadius($r('app.float.radius_action'))
            .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
            .onClick(() => {
              void this.viewModel?.requestImportUrl();
            })

          Row({ space: $r('app.float.space_sm') }) {
            Button($r('app.string.import_file_action'))
              .id('import.file')
              .layoutWeight(1)
              .constraintSize({ minHeight: $r('app.float.touch_target_min') })
              .backgroundColor($r('app.color.color_surface_subtle'))
              .fontColor($r('app.color.color_text_primary'))
              .borderRadius($r('app.float.radius_action'))
              .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
              .onClick(() => {
                void this.viewModel?.requestImportLocal();
              })

            Button(this.state.status === 'SCANNING'
              ? $r('app.string.import_qr_scanning')
              : $r('app.string.import_qr_action'))
              .id('import.qr')
              .layoutWeight(1)
              .constraintSize({ minHeight: $r('app.float.touch_target_min') })
              .backgroundColor($r('app.color.color_surface_subtle'))
              .fontColor($r('app.color.color_text_primary'))
              .borderRadius($r('app.float.radius_action'))
              .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
              .onClick(() => {
                void this.viewModel?.requestScanQr();
              })
          }
          .width('100%')

          if (this.state.status === 'SUBMITTING') {
            Column({ space: $r('app.float.space_sm') }) {
              Progress({ value: 50, total: 100, type: ProgressType.Linear })
                .width('100%')

              Row({ space: $r('app.float.space_sm') }) {
                Text($r('app.string.import_progress_import'))
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_secondary'))
                Text($r('app.string.import_progress_download'))
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_secondary'))
                Text($r('app.string.import_progress_validation'))
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_secondary'))
                Text($r('app.string.import_progress_persistence'))
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_secondary'))
              }
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_3xl') })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
    .backgroundColor($r('app.color.color_surface_card'))
  }
}
