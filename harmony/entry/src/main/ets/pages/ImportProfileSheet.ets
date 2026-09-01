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
    Column({ space: $r('app.float.space_lg') }) {
      Row() {
        Text($r('app.string.import_title'))
          .fontSize($r('app.float.type_title'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))

        Blank()

        Button($r('app.string.import_cancel'))
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_surface_subtle'))
          .fontColor($r('app.color.color_text_primary'))
          .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })

      Text($r('app.string.import_name_label'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))

      TextInput({
        text: this.viewModel?.currentNameDraft() ?? '',
        placeholder: $r('app.string.import_name_placeholder')
      })
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .onChange((value: string) => {
          this.viewModel?.updateNameDraft(value);
        })

      Button($r('app.string.import_file_action'))
        .id('import.file')
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .backgroundColor($r('app.color.color_surface_subtle'))
        .fontColor($r('app.color.color_text_primary'))
        .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
        .onClick(() => {
          void this.viewModel?.requestImportLocal();
        })

      Button(this.state.status === 'SCANNING'
        ? $r('app.string.import_qr_scanning')
        : $r('app.string.import_qr_action'))
        .id('import.qr')
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .backgroundColor($r('app.color.color_surface_subtle'))
        .fontColor($r('app.color.color_text_primary'))
        .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
        .onClick(() => {
          void this.viewModel?.requestScanQr();
        })

      Text($r('app.string.import_url_label'))
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))

      TextInput({
        text: this.viewModel?.currentUrlDraft() ?? '',
        placeholder: $r('app.string.import_url_placeholder')
      })
        .id('import.url')
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .onChange((value: string) => {
          this.viewModel?.updateUrlDraft(value);
        })

      Button($r('app.string.import_submit'))
        .id('import.submit')
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .backgroundColor($r('app.color.color_action_primary'))
        .fontColor($r('app.color.color_text_inverse'))
        .enabled(this.state.status !== 'SUBMITTING' && this.state.status !== 'SCANNING')
        .onClick(() => {
          void this.viewModel?.requestImportUrl();
        })

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
    .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
    .backgroundColor($r('app.color.color_surface_card'))
  }
}
