import { ProfileDetailViewModel } from '../presentation/ProfileDetailViewModel';
import type { ProfileDetailViewState } from '../presentation/PresentationModels';
import type { ProxyViewState } from '../presentation/ProxyPresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';
import { ProxiesPage } from './ProxiesPage';

@Component
export struct ProfileDetailPage {
  @Prop state: ProfileDetailViewState;
  @Link commandPending: boolean;
  @Link commandCompleted: boolean;
  @Link canManageProxies: boolean;
  @Link proxyExpanded: boolean;
  @Prop proxyState: ProxyViewState;
  @Prop proxyRenderVersion: number;
  @Prop compactLayout: boolean;
  viewModel?: ProfileDetailViewModel;
  onBack: () => void = () => {
  };
  onToggleProxyManager: () => void = () => {
  };
  onRetryProxy: () => void = () => {
  };
  onOpenProxyGroup: (groupIndex: number) => void = (_groupIndex: number) => {
  };
  onSelectProxyNode: (nodeIndex: number) => void = (_nodeIndex: number) => {
  };
  onProxyDelayAction: () => void = () => {
  };

  build() {
    Scroll() {
      Column({ space: $r('app.float.space_lg') }) {
        Row() {
          Button($r('app.string.common_back'))
            .id('detail.back')
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

        this.buildEditSurface()

        if (this.state.sourceRepairRequired) {
          Text(this.state.sourceRetryAvailable
            ? $r('app.string.detail_source_retry_or_replace')
            : $r('app.string.detail_source_repair_required'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_warning'))
        }

        this.buildOperationFeedback()

        if (this.state.error?.technicalDetail !== undefined || this.state.error !== undefined) {
          SafeErrorCard({ error: this.state.error ?? createEmptySafeErrorState() })
        }

        if (!this.state.editing && this.state.canEnable) {
          Button($r('app.string.detail_enable'))
            .id('detail.enable')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
            .backgroundColor($r('app.color.color_action_primary'))
            .fontColor($r('app.color.color_text_inverse'))
            .onClick(() => {
              void this.viewModel?.requestEnable();
            })
        }

        if (!this.state.editing) {
          this.buildProxyManager()
        }

        if (!this.state.editing && this.state.canRefresh) {
          Button(refreshLabel(this.state))
            .id('detail.refresh')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              void this.viewModel?.requestRefresh();
            })
        }

        if (!this.state.editing && this.state.canDelete) {
          Button($r('app.string.detail_delete'))
            .id('detail.delete')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
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

  @Builder
  private buildOperationFeedback(): void {
    if (this.commandPending) {
      Text($r('app.string.detail_operation_processing'))
        .id('detail.operation.pending')
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_status_warning'))
    } else if (this.commandCompleted) {
      Text($r('app.string.detail_operation_completed'))
        .id('detail.operation.completed')
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_status_success'))
    }
  }

  @Builder
  private buildEditSurface(): void {
    Column({ space: $r('app.float.space_sm') }) {
      if (this.state.editing) {
        Text($r('app.string.detail_edit_name_label'))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)

        TextInput({
          text: this.viewModel?.currentEditNameDraft() ?? '',
          placeholder: $r('app.string.import_name_placeholder')
        })
          .id('detail.edit.name')
          .width('100%')
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .enabled(!this.commandPending)
          .onChange((value: string) => {
            this.viewModel?.updateEditNameDraft(value);
          })

        if (this.state.editNameIssue !== undefined) {
          Text(resolveDetailEditNameIssue(this.state.editNameIssue))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_danger'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        if (this.state.profile?.sourceKind === 'REMOTE_URL') {
          Text($r('app.string.detail_edit_url_label'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)

          TextInput({
            text: this.viewModel?.currentEditUrlDraft() ?? '',
            placeholder: $r('app.string.import_url_placeholder')
          })
            .id('detail.edit.url')
            .width('100%')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
            .onChange((value: string) => {
              this.viewModel?.updateEditUrlDraft(value);
            })

          Text($r('app.string.detail_edit_url_hint'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)

          if (this.state.editUrlIssue !== undefined) {
            Text(resolveDetailEditUrlIssue(this.state.editUrlIssue))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_status_danger'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }

        Row({ space: $r('app.float.space_md') }) {
          Button($r('app.string.detail_edit_cancel'))
            .id('detail.edit.cancel')
            .layoutWeight(1)
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
            .backgroundColor($r('app.color.color_surface_subtle'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.viewModel?.cancelEdit();
            })

          Button($r('app.string.detail_edit_save'))
            .id('detail.edit.save')
            .layoutWeight(1)
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .enabled(!this.commandPending)
            .backgroundColor($r('app.color.color_action_primary'))
            .fontColor($r('app.color.color_text_inverse'))
            .onClick(() => {
              void this.viewModel?.requestSaveEdits();
            })
        }
        .width('100%')
      } else {
        Button($r('app.string.detail_edit'))
          .id('detail.edit')
          .width('100%')
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .enabled(!this.commandPending)
          .backgroundColor($r('app.color.color_surface_subtle'))
          .fontColor($r('app.color.color_text_primary'))
          .onClick(() => {
            this.viewModel?.requestEdit();
          })
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
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private buildProxyManager(): void {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_md') }) {
        Text($r('app.string.detail_proxy_title'))
          .fontSize($r('app.float.type_title'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        Button(this.proxyExpanded
          ? $r('app.string.detail_proxy_collapse')
          : $r('app.string.detail_proxy_manage'))
          .id('detail.proxy.toggle')
          .constraintSize({ minHeight: $r('app.float.touch_target_min') })
          .enabled(this.proxyExpanded || this.canManageProxies)
          .backgroundColor(this.proxyExpanded || this.canManageProxies
            ? $r('app.color.color_action_primary')
            : $r('app.color.color_action_primary_disabled'))
          .fontColor(this.proxyExpanded || this.canManageProxies
            ? $r('app.color.color_text_inverse')
            : $r('app.color.color_action_disabled_text'))
          .onClick(() => {
            this.onToggleProxyManager();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (!this.proxyExpanded && !this.canManageProxies) {
        Text($r('app.string.detail_proxy_requires_active'))
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      if (this.proxyExpanded) {
        ProxiesPage({
          state: this.proxyState,
          renderVersion: this.proxyRenderVersion,
          compactLayout: this.compactLayout,
          embedded: true,
          onRetry: this.onRetryProxy,
          onOpenGroup: this.onOpenProxyGroup,
          onSelectNode: this.onSelectProxyNode,
          onDelayAction: this.onProxyDelayAction
        })
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
    .alignItems(HorizontalAlign.Start)
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

function resolveDetailEditNameIssue(issue?: 'REQUIRED' | 'TOO_LONG') {
  if (issue === 'TOO_LONG') {
    return $r('app.string.detail_edit_issue_name_too_long');
  }
  return $r('app.string.detail_edit_issue_required');
}

function resolveDetailEditUrlIssue(issue?: 'REQUIRED' | 'INVALID_URL' | 'INVALID_SCHEME') {
  if (issue === 'INVALID_SCHEME') {
    return $r('app.string.detail_edit_issue_url_invalid_scheme');
  }
  if (issue === 'INVALID_URL') {
    return $r('app.string.detail_edit_issue_url_invalid');
  }
  return $r('app.string.detail_edit_issue_required');
}
