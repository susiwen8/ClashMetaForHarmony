import type { ProfileRowState, ProfilesRefreshSummaryState, ProfilesViewState } from '../presentation/PresentationModels';
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
  onRefreshAll: () => void = () => {
  };

  build() {
    const remoteCount: number = this.state.remoteProfileCount;
    const refreshSummary: ProfilesRefreshSummaryState | undefined = this.state.refreshAllSummary;
    const showRefreshPanel: boolean = remoteCount > 0 ||
      this.state.refreshAllPending ||
      refreshSummary !== undefined ||
      this.state.refreshAllError !== undefined;

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

        if (showRefreshPanel) {
          Column({ space: $r('app.float.space_sm') }) {
            Button(this.state.refreshAllPending
              ? $r('app.string.profiles_refresh_pending')
              : $r('app.string.profiles_refresh_all'))
              .id('profiles.refresh-all')
              .constraintSize({ minHeight: $r('app.float.touch_target_min') })
              .enabled(remoteCount > 0 && !this.state.refreshAllPending)
              .backgroundColor($r('app.color.color_surface_card'))
              .fontColor($r('app.color.color_text_primary'))
              .onClick(() => {
                this.onRefreshAll();
              })

            if (this.state.refreshAllPending) {
              Row({ space: $r('app.float.space_xs') }) {
                Text($r('app.string.profiles_refresh_progress'))
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_secondary'))

                Text(`${this.state.completedRefreshCount} / ${this.state.totalRefreshCount}`)
                  .id('profiles.refresh-progress')
                  .fontSize($r('app.float.type_caption'))
                  .fontColor($r('app.color.color_text_primary'))
              }
            }

            if (refreshSummary !== undefined) {
              Flex({
                wrap: FlexWrap.Wrap,
                justifyContent: FlexAlign.Start,
                alignItems: ItemAlign.Center
              }) {
                ForEach(createRefreshSummaryItems(refreshSummary), (item: RefreshSummaryItem) => {
                  Row({ space: $r('app.float.space_xs') }) {
                    Text(`${item.count}`)
                      .fontSize($r('app.float.type_caption'))
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.color_text_primary'))

                    Text(item.label)
                      .fontSize($r('app.float.type_caption'))
                      .fontColor($r('app.color.color_text_secondary'))
                  }
                  .margin({ right: $r('app.float.space_md'), bottom: $r('app.float.space_xs') })
                }, (item: RefreshSummaryItem) => item.key)

                if (this.state.refreshAllInterrupted) {
                  Row({ space: $r('app.float.space_xs') }) {
                    Text($r('app.string.profiles_refresh_remaining'))
                      .fontSize($r('app.float.type_caption'))
                      .fontColor($r('app.color.color_status_warning'))

                    Text(`${this.state.remainingRefreshCount}`)
                      .fontSize($r('app.float.type_caption'))
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.color_status_warning'))
                  }
                  .margin({ right: $r('app.float.space_md'), bottom: $r('app.float.space_xs') })

                  Text($r('app.string.profiles_refresh_interrupted'))
                    .fontSize($r('app.float.type_caption'))
                    .fontColor($r('app.color.color_status_warning'))
                    .margin({ bottom: $r('app.float.space_xs') })
                }
              }
              .id('profiles.refresh-summary')
              .width('100%')
            }

            if (this.state.refreshAllError !== undefined) {
              SafeErrorCard({ error: this.state.refreshAllError ?? createEmptySafeErrorState() })
            }
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

interface RefreshSummaryItem {
  key: string;
  label: Resource;
  count: number;
}

function createRefreshSummaryItems(summary: ProfilesRefreshSummaryState): RefreshSummaryItem[] {
  return [
    {
      key: 'success',
      label: $r('app.string.profiles_refresh_success'),
      count: summary.success
    },
    {
      key: 'failedUsingCurrent',
      label: $r('app.string.profiles_refresh_failed_using_current'),
      count: summary.failedUsingCurrent
    },
    {
      key: 'failed',
      label: $r('app.string.profiles_refresh_failed'),
      count: summary.failed
    },
    {
      key: 'skippedHttp',
      label: $r('app.string.profiles_refresh_skipped_http'),
      count: summary.skippedHttp
    },
    {
      key: 'skippedNotDue',
      label: $r('app.string.profiles_refresh_skipped_not_due'),
      count: summary.skippedNotDue
    },
    {
      key: 'busy',
      label: $r('app.string.profiles_refresh_busy'),
      count: summary.busy
    }
  ];
}
