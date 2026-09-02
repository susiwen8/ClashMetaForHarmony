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
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_surface_card'))
          .fontColor($r('app.color.color_text_primary'))
          .borderRadius($r('app.float.radius_action'))
          .onClick(() => {
            this.onBack();
          })

        Text($r('app.string.logs_title'))
          .fontSize($r('app.float.type_headline'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.color_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.state.searchText, placeholder: $r('app.string.logs_search_placeholder') })
        .id('logs.search')
        .width('100%')
        .height($r('app.float.touch_target_min'))
        .backgroundColor($r('app.color.color_surface_card'))
        .borderRadius($r('app.float.radius_action'))
        .onChange((value: string): void => {
          this.onSearchChange(value);
        })

      Scroll() {
        Row({ space: $r('app.float.space_sm') }) {
          this.buildFilter('ALL', $r('app.string.logs_filter_all'))
          this.buildFilter('DEBUG', $r('app.string.logs_filter_debug'))
          this.buildFilter('INFO', $r('app.string.logs_filter_info'))
          this.buildFilter('WARN', $r('app.string.logs_filter_warn'))
          this.buildFilter('ERROR', $r('app.string.logs_filter_error'))
        }
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      Row({ space: $r('app.float.space_sm') }) {
        Button($r('app.string.logs_refresh'))
          .enabled(!this.state.refreshing && !this.state.operationPending)
          .layoutWeight(1)
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_action_primary'))
          .fontColor($r('app.color.color_text_inverse'))
          .fontWeight(FontWeight.Medium)
          .borderRadius($r('app.float.radius_action'))
          .onClick(() => {
            this.onRefresh();
          })
        Button($r('app.string.logs_export'))
          .enabled(!this.state.operationPending)
          .layoutWeight(1)
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_surface_card'))
          .fontColor($r('app.color.color_text_primary'))
          .fontWeight(FontWeight.Medium)
          .borderRadius($r('app.float.radius_action'))
          .onClick(() => {
            this.onExport();
          })
        Button($r('app.string.logs_clear'))
          .enabled(!this.state.operationPending)
          .layoutWeight(1)
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .backgroundColor($r('app.color.color_surface_danger'))
          .fontColor($r('app.color.color_status_danger'))
          .fontWeight(FontWeight.Medium)
          .borderRadius($r('app.float.radius_action'))
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
        List({ space: 0 }) {
          ForEach(this.state.entries, (entry: RuntimeLogEntry, index: number) => {
            ListItem() {
              this.buildLogEntry(entry)
            }
          }, (entry: RuntimeLogEntry, index: number) => entry.timestamp + ':' + entry.level + ':' + index)
        }
        .id('logs.list')
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .borderRadius($r('app.float.radius_card'))
        .backgroundColor($r('app.color.color_surface_card'))
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
      .constraintSize({ minHeight: $r('app.float.touch_target_min') })
      .padding({ left: $r('app.float.space_lg'), right: $r('app.float.space_lg') })
      .backgroundColor(this.state.level === level
        ? $r('app.color.color_surface_hero')
        : $r('app.color.color_surface_card'))
      .fontColor(this.state.level === level
        ? $r('app.color.color_text_on_hero')
        : $r('app.color.color_text_primary'))
      .fontWeight(FontWeight.Medium)
      .borderRadius($r('app.float.radius_action'))
      .onClick(() => {
        this.onLevelChange(level);
      })
  }

  @Builder
  private buildLogEntry(entry: RuntimeLogEntry): void {
    Column({ space: $r('app.float.space_sm') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Text(entry.level)
          .fontSize($r('app.float.type_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor(logLevelColor(entry.level))

        Text(formatLogTimestamp(entry.timestamp))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
      }
      .width('100%')

      Text(entry.message)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_primary'))
        .width('100%')
        .maxLines(5)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .copyOption(CopyOptions.LocalDevice)

      Divider()
        .color($r('app.color.color_border_subtle'))
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_md'),
      right: $r('app.float.space_md'),
      top: $r('app.float.space_md')
    })
    .backgroundColor($r('app.color.color_surface_card'))
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

function formatLogTimestamp(timestamp: string): string {
  const normalized: string = timestamp.trim().replace('T', ' ');
  if (normalized.length <= 19) {
    return normalized;
  }
  return normalized.substring(0, 19);
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
