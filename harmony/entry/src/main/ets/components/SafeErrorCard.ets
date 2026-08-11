import { pasteboard as Pasteboard } from '@kit.BasicServicesKit';
import type { SafeErrorState } from '../presentation/PresentationModels';

class EmptySafeErrorState implements SafeErrorState {
  code: string = '';
  stage: 'IMPORT' | 'DOWNLOAD' | 'VALIDATION' | 'PERSISTENCE' | 'CORE_LOAD' | 'RUNTIME_START' | 'RUNTIME_STOP' = 'PERSISTENCE';
  userMessageResource: string = 'error.persistence';
  technicalDetail: string = '';
  retryable: boolean = false;
}

export function createEmptySafeErrorState(): SafeErrorState {
  return new EmptySafeErrorState();
}

@Component
export struct SafeErrorCard {
  @Prop error: SafeErrorState = createEmptySafeErrorState();

  build() {
    Column({ space: $r('app.float.space_sm') }) {
      if (this.error.code.trim().length > 0 || this.error.technicalDetail.trim().length > 0) {
        Text(resolveErrorMessageResource(this.error.userMessageResource))
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))

        Text(this.error.code)
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_status_danger'))

        Text(this.error.technicalDetail)
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))

        if (this.error.technicalDetail.trim().length > 0) {
          Button($r('app.string.detail_copy_detail'))
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.copyTechnicalDetail(this.error.technicalDetail);
            })
        }
      }
    }
    .width('100%')
    .padding(this.error.code.trim().length === 0 && this.error.technicalDetail.trim().length === 0 ? 0 : $r('app.float.space_lg'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor(this.error.code.trim().length === 0 && this.error.technicalDetail.trim().length === 0
      ? Color.Transparent
      : $r('app.color.color_surface_card'))
    .border({
      width: this.error.code.trim().length === 0 && this.error.technicalDetail.trim().length === 0 ? 0 : 1,
      color: $r('app.color.color_border_subtle')
    })
  }

  private copyTechnicalDetail(technicalDetail: string): void {
    if (technicalDetail.trim().length === 0) {
      return;
    }
    const systemPasteboard = Pasteboard.getSystemPasteboard();
    const pasteData = Pasteboard.createData(Pasteboard.MIMETYPE_TEXT_PLAIN, technicalDetail);
    systemPasteboard.setData(pasteData);
  }
}

function resolveErrorMessageResource(resourceName: string) {
  switch (resourceName) {
    case 'error.import':
      return $r('app.string.error_import');
    case 'error.download':
      return $r('app.string.error_download');
    case 'error.validation':
      return $r('app.string.error_validation');
    case 'error.core.load':
      return $r('app.string.error_core_load');
    case 'error.runtime.start':
      return $r('app.string.error_runtime_start');
    case 'error.runtime.stop':
      return $r('app.string.error_runtime_stop');
    case 'error.persistence':
    default:
      return $r('app.string.error_persistence');
  }
}
