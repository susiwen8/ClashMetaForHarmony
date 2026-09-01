import { pasteboard as Pasteboard } from '@kit.BasicServicesKit';
import type { RuntimeLogEntry, RuntimeLogFilterLevel } from '@cmfa/shared';
import type { LogsViewState } from '../presentation/LogsViewModel';

@Component
export struct LogsPage {
  @Prop state: LogsViewState;
  onBack: () => void = (): void => {
  };
  onRefresh: () => void = (): void => {
  };
  onClear: () => void = (): void => {
  };
  onExport: () => void = (): void => {
  };
  onLevelChange: (level: RuntimeLogFilterLevel) => void = (_level: RuntimeLogFilterLevel): void => {
  };
  onSearchChange: (text: string) => void = (_text: string): void => {
  };

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Button($r('app.string.common_back'))
          .id('logs.back')
          .backgroundColor($r('app.color.color_surface_subtle'))
          .fontColor($r('app.color.color_text_primary'))
          .onClick(() => {
            this.onBack();
          })

        Text($r('app.string.logs_title'))
          .fontSize($r('app.float.type_headline'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))
          .layoutWeight(1)
      }
      .width('100%')

      TextInput({ text: this.state.searchText, placeholder: $r('app.string.logs_search_placeholder') })
        .id('logs.search')
        .width('100%')
        .onChange((value: string): void => {
          this.onSearchChange(value);
        })

      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        this.buildFilter('ALL', $r('app.string.logs_filter_all'))
        this.buildFilter('DEBUG', $r('app.string.logs_filter_debug'))
        this.buildFilter('INFO', $r('app.string.logs_filter_info'))
        this.buildFilter('WARN', $r('app.string.logs_filter_warn'))
        this.buildFilter('ERROR', $r('app.string.logs_filter_error'))
      }
      .width('100%')

      Row({ space: $r('app.float.space_sm') }) {
        Button($r('app.string.logs_refresh'))
          .enabled(!this.state.refreshing && !this.state.operationPending)
          .onClick(() => {
            this.onRefresh();
          })
        Button($r('app.string.logs_export'))
          .enabled(!this.state.operationPending)
          .onClick(() => {
            this.onExport();
          })
        Button($r('app.string.logs_clear'))
          .enabled(!this.state.operationPending)
          .backgroundColor($r('app.color.color_surface_subtle'))
          .fontColor($r('app.color.color_status_danger'))
          .onClick(() => {
            this.onClear();
          })
      }
      .width('100%')

      Text(resolveStatusText(this.state))
        .fontSize($r('app.float.type_caption'))
        .fontColor(this.state.failed ? $r('app.color.color_status_danger') : $r('app.color.color_text_secondary'))
        .width('100%')

      if (this.state.entries.length === 0) {
        Column() {
          Text($r('app.string.logs_empty'))
            .fontSize($r('app.float.type_body'))
            .fontColor($r('app.color.color_text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.state.entries, (entry: RuntimeLogEntry, index: number) => {
            ListItem() {
              this.buildLogEntry(entry)
            }
          }, (entry: RuntimeLogEntry, index: number) => entry.timestamp + ':' + entry.level + ':' + index)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.page_padding_compact'))
    .backgroundColor($r('app.color.color_surface_background'))
  }

  @Builder
  private buildFilter(level: RuntimeLogFilterLevel, label: Resource): void {
    Button(label)
      .margin({ right: $r('app.float.space_sm'), bottom: $r('app.float.space_sm') })
      .backgroundColor(this.state.level === level
        ? $r('app.color.color_action_primary')
        : $r('app.color.color_surface_subtle'))
      .fontColor(this.state.level === level
        ? $r('app.color.color_text_inverse')
        : $r('app.color.color_text_primary'))
      .onClick(() => {
        this.onLevelChange(level);
      })
  }

  @Builder
  private buildLogEntry(entry: RuntimeLogEntry): void {
    Column({ space: $r('app.float.space_xs') }) {
      Row() {
        Text(entry.level)
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(logLevelColor(entry.level))
        Blank()
        Text(entry.timestamp)
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
      }
      .width('100%')

      Text(entry.message)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_primary'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({ width: 1, color: $r('app.color.color_border_subtle') })
    .onClick(() => {
      copyLogEntry(entry);
    })
  }
}

function copyLogEntry(entry: RuntimeLogEntry): void {
  try {
    const systemPasteboard = Pasteboard.getSystemPasteboard();
    const data = Pasteboard.createData(
      Pasteboard.MIMETYPE_TEXT_PLAIN,
      entry.timestamp + ' [' + entry.level + '] ' + entry.message
    );
    void systemPasteboard.setData(data).catch((_error: Error): void => {
    });
  } catch (_) {
  }
}

function logLevelColor(level: string): Resource {
  if (level === 'ERROR') {
    return $r('app.color.color_status_danger');
  }
  if (level === 'WARN') {
    return $r('app.color.color_status_warning');
  }
  if (level === 'DEBUG') {
    return $r('app.color.color_text_secondary');
  }
  return $r('app.color.color_status_info');
}

function resolveStatusText(state: LogsViewState): Resource | string {
  if (state.failed) {
    return $r('app.string.logs_failed');
  }
  if (state.operationPending) {
    return $r('app.string.logs_processing');
  }
  if (state.operationResult === 'EXPORTED') {
    return $r('app.string.logs_exported');
  }
  if (state.operationResult === 'CANCELLED') {
    return $r('app.string.logs_export_cancelled');
  }
  if (state.operationResult === 'CLEARED') {
    return $r('app.string.logs_cleared');
  }
  return state.entries.length + ' / ' + state.totalCount;
}
