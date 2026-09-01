import type { OneClickVpnErrorResourceId, ProxyRejectedErrorCode } from '@cmfa/shared';
import type {
  ProxyDelayViewState,
  ProxyGroupTabState,
  ProxyNodeRowState,
  ProxyViewState
} from '../presentation/ProxyPresentationModels';

@Component
export struct ProxiesPage {
  @Prop state: ProxyViewState;
  @Prop renderVersion: number;
  @Prop compactLayout: boolean;
  @Prop embedded: boolean = false;
  onBack: () => void = () => {
  };
  onRetry: () => void = () => {
  };
  onOpenGroup: (groupIndex: number) => void = (_groupIndex: number) => {
  };
  onSelectNode: (nodeIndex: number) => void = (_nodeIndex: number) => {
  };
  onDelayAction: () => void = () => {
  };

  build() {
    if (this.embedded) {
      this.buildProxyContent()
    } else {
      Scroll() {
        this.buildProxyContent()
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .backgroundColor($r('app.color.color_surface_background'))
    }
  }

  @Builder
  private buildProxyContent(): void {
    Column({ space: resolveProxyPageSectionSpacing(this.renderVersion, this.state.delayState) }) {
      if (!this.embedded) {
        Row({ space: $r('app.float.space_md') }) {
          Button($r('app.string.proxies_back'))
            .id('proxies.back')
            .constraintSize({ minHeight: $r('app.float.touch_target_min') })
            .backgroundColor($r('app.color.color_surface_card'))
            .fontColor($r('app.color.color_text_primary'))
            .onClick(() => {
              this.onBack();
            })

          Text($r('app.string.proxies_title'))
            .fontSize($r('app.float.type_headline'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.color_text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        .width('100%')
      }

      if (this.state.warning === 'APPLIED_NOT_PERSISTED') {
          Text($r('app.string.proxies_applied_not_persisted'))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_warning'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

      if (this.state.groups.length > 0) {
          Scroll() {
            Row({ space: $r('app.float.space_sm') }) {
              ForEach(this.state.groups, (group: ProxyGroupTabState) => {
                Button() {
                  Column({ space: $r('app.float.space_xs') }) {
                    Text(group.name)
                      .fontSize($r('app.float.type_body'))
                      .fontWeight(FontWeight.Medium)
                      .fontColor(group.active ? $r('app.color.color_text_inverse') : $r('app.color.color_text_primary'))

                    Text(group.type)
                      .fontSize($r('app.float.type_caption'))
                      .fontColor(group.active ? $r('app.color.color_text_inverse') : $r('app.color.color_text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                }
                .id(group.semanticId)
                .enabled(!shouldDisableProxyInteractions(this.state))
                .constraintSize({ minHeight: $r('app.float.touch_target_min') })
                .padding({
                  left: $r('app.float.space_md'),
                  right: $r('app.float.space_md'),
                  top: $r('app.float.space_sm'),
                  bottom: $r('app.float.space_sm')
                })
                .backgroundColor(group.active ? $r('app.color.color_action_primary') : $r('app.color.color_surface_card'))
                .borderRadius($r('app.float.radius_card'))
                .border({
                  width: 1,
                  color: group.active ? $r('app.color.color_action_primary') : $r('app.color.color_border_subtle')
                })
                .onClick(() => {
                  this.onOpenGroup(group.index);
                })
              }, (group: ProxyGroupTabState) => group.semanticId)
            }
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }

      if (this.state.status === 'LOADING' || this.state.status === 'IDLE') {
          buildMessageCard($r('app.string.proxies_loading'))
        } else if (this.state.status === 'EMPTY') {
          buildMessageCard($r('app.string.proxies_empty'))
        } else if (this.state.status === 'ERROR') {
          buildErrorCard(this.state, this.onRetry)
        } else {
          if (this.state.errorCode !== undefined) {
            buildErrorCard(this.state, this.onRetry)
          }

          if (this.state.activationStage === 'FAILED' && this.state.activationErrorResourceId !== undefined) {
            buildActivationErrorCard(this.state, this.onRetry)
          }

          if (this.state.status === 'READY') {
            this.buildDelaySection();
          }

          Column({ space: $r('app.float.space_sm') }) {
            ForEach(this.state.nodes, (row: ProxyNodeRowState) => {
              buildNodeButton(row, this.state, this.onSelectNode)
            }, (row: ProxyNodeRowState) => `${this.renderVersion}:${row.semanticId}`)
          }
          .width('100%')
      }
    }
    .width('100%')
    .padding(this.embedded ? 0 : (this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular')))
    .alignItems(HorizontalAlign.Start)
    .safeAreaPadding({
      top: this.embedded ? 0 : $r('app.float.page_padding_compact'),
      bottom: this.embedded ? 0 : $r('app.float.page_padding_compact')
    })
  }

  @Builder
  private buildDelaySection(): void {
    Column({ space: resolveDelaySectionSpacing(this.state.delayState) }) {
      Button(resolveDelayActionLabel(this.state.delayState))
        .id('proxies.delay-test')
        .width('100%')
        .constraintSize({ minHeight: $r('app.float.touch_target_min') })
        .backgroundColor(isDelayActionLive(this.state.delayState) ? $r('app.color.color_status_danger') : $r('app.color.color_action_primary'))
        .fontColor($r('app.color.color_text_inverse'))
        .focusable(true)
        .accessibilityText(resolveDelayActionLabel(this.state.delayState))
        .enabled(isDelayActionEnabled(this.state))
        .onClick(() => {
          this.onDelayAction();
        })

      if (isDelayActionLive(this.state.delayState)) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.proxies_delay_progress', this.state.completedDelayCount, this.state.totalDelayCount))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)

          Progress({
            value: resolveDelayProgressValue(this.state),
            total: resolveDelayProgressTotal(this.state),
            type: ProgressType.Linear
          })
            .id('proxies.delay-progress')
            .width('100%')
        }
        .width('100%')
      } else if (isTerminalDelayState(this.state.delayState)) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.proxies_delay_summary_available', this.state.availableDelayCount, this.state.totalDelayCount))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)

          if (this.state.timeoutDelayCount > 0) {
            Text($r('app.string.proxies_delay_summary_timeout', this.state.timeoutDelayCount))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (this.state.failedDelayCount > 0) {
            Text($r('app.string.proxies_delay_summary_failed', this.state.failedDelayCount))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (this.state.cancelledDelayCount > 0) {
            Text($r('app.string.proxies_delay_summary_cancelled', this.state.cancelledDelayCount))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (this.state.unsupportedDelayCount > 0) {
            Text($r('app.string.proxies_delay_summary_unsupported', this.state.unsupportedDelayCount))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (resolveFastestRow(this.state) !== undefined && resolveFastestRow(this.state)!.delayMs !== undefined) {
            Text($r('app.string.proxies_delay_fastest_summary', resolveFastestRow(this.state)!.name, resolveFastestRow(this.state)!.delayMs!))
              .fontSize($r('app.float.type_caption'))
              .fontColor($r('app.color.color_status_success'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .id('proxies.delay-summary')
        .width('100%')
      }
    }
    .width('100%')
    .padding($r('app.float.space_md'))
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({
      width: 1,
      color: $r('app.color.color_border_subtle')
    })
  }
}

@Builder
function buildMessageCard(message: Resource): void {
  Column() {
    Text(message)
      .fontSize($r('app.float.type_body'))
      .fontColor($r('app.color.color_text_secondary'))
      .width('100%')
      .textAlign(TextAlign.Start)
  }
  .width('100%')
  .padding($r('app.float.space_xl'))
  .borderRadius($r('app.float.radius_card'))
  .backgroundColor($r('app.color.color_surface_card'))
  .border({
    width: 1,
    color: $r('app.color.color_border_subtle')
  })
}

@Builder
function buildErrorCard(state: ProxyViewState, onRetry: () => void): void {
  Column({ space: $r('app.float.space_md') }) {
    Text(resolveErrorMessage(state.errorCode))
      .fontSize($r('app.float.type_body'))
      .fontColor($r('app.color.color_status_danger'))
      .width('100%')
      .textAlign(TextAlign.Start)

    Button($r('app.string.proxies_retry'))
      .id('proxies.retry')
      .constraintSize({ minHeight: $r('app.float.touch_target_min') })
      .backgroundColor($r('app.color.color_action_primary'))
      .fontColor($r('app.color.color_text_inverse'))
      .enabled(state.errorRetryable && !shouldDisableProxyInteractions(state))
      .onClick(() => {
        onRetry();
      })
  }
  .width('100%')
  .padding($r('app.float.space_xl'))
  .borderRadius($r('app.float.radius_card'))
  .backgroundColor($r('app.color.color_surface_card'))
  .border({
    width: 1,
    color: $r('app.color.color_border_subtle')
  })
}

@Builder
function buildActivationErrorCard(state: ProxyViewState, onRetry: () => void): void {
  Column({ space: $r('app.float.space_md') }) {
    Text(resolveActivationErrorMessage(state.activationErrorResourceId))
      .fontSize($r('app.float.type_body'))
      .fontColor($r('app.color.color_status_danger'))
      .width('100%')
      .textAlign(TextAlign.Start)

    Button($r('app.string.proxies_retry'))
      .id('proxies.activation-retry')
      .constraintSize({ minHeight: $r('app.float.touch_target_min') })
      .backgroundColor($r('app.color.color_action_primary'))
      .fontColor($r('app.color.color_text_inverse'))
      .enabled(state.activationErrorRetryable && !shouldDisableProxyInteractions(state))
      .onClick(() => {
        onRetry();
      })
  }
  .width('100%')
  .padding($r('app.float.space_xl'))
  .borderRadius($r('app.float.radius_card'))
  .backgroundColor($r('app.color.color_surface_card'))
  .border({
    width: 1,
    color: $r('app.color.color_border_subtle')
  })
}

@Builder
function buildNodeButton(
  row: ProxyNodeRowState,
  state: ProxyViewState,
  onSelectNode: (nodeIndex: number) => void
): void {
  Button() {
    Row({ space: $r('app.float.space_md') }) {
      Column({ space: $r('app.float.space_xs') }) {
        Text(row.name)
          .id(`${row.semanticId}.label`)
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(row.type)
          .fontSize($r('app.float.type_caption'))
          .fontColor($r('app.color.color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: $r('app.float.space_xs') }) {
        if (row.runtimeSelected) {
          Text($r('app.string.proxies_selected'))
            .id(`${row.semanticId}.runtime-selected`)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_success'))
        }

        if (shouldShowActivationStatus(row, state)) {
          Text(resolveActivationStatusResource(state))
            .id(`${row.semanticId}.activation`)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_warning'))
        }

        if (row.savedForNextStart) {
          Text($r('app.string.proxies_saved_for_next_start'))
            .id(`${row.semanticId}.saved-intent`)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_info'))
        }

        if (row.isGroup) {
          Text($r('app.string.proxies_nested_group'))
            .id(`${row.semanticId}.nested-group`)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_action_primary'))
        }

        if (row.delayFastest) {
          Text($r('app.string.proxies_delay_fastest_marker'))
            .id(`${row.semanticId}.fastest`)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_status_success'))
        }

        if (shouldShowDelayOutcome(row, state.delayState)) {
          Text(resolveDelayOutcomeResource(row))
            .id(`${row.semanticId}.delay`)
            .fontSize($r('app.float.type_caption'))
            .fontColor(resolveDelayRowColor(row))
        }
      }
      .alignItems(HorizontalAlign.End)

    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
  }
  .id(row.semanticId)
  .enabled(!shouldDisableProxyInteractionsFromRow(state.selectionPending, state.delayState))
  .width('100%')
  .constraintSize({ minHeight: $r('app.float.touch_target_min') })
  .padding($r('app.float.space_md'))
  .backgroundColor($r('app.color.color_surface_card'))
  .borderRadius($r('app.float.radius_card'))
  .border({
    width: 1,
    color: $r('app.color.color_border_subtle')
  })
  .onClick(() => {
    onSelectNode(row.index);
  })
}

function shouldDisableProxyInteractions(state: ProxyViewState): boolean {
  return state.selectionPending || isDelayActionLive(state.delayState);
}

// Keep a primitive dependency in the page tree so ArkUI refreshes the page
// when the parent swaps in a new proxy snapshot during delay polling.
function resolveProxyPageSectionSpacing(_renderVersion: number, delayState: ProxyDelayViewState): Resource {
  return $r('app.float.space_lg');
}

function resolveDelaySectionSpacing(delayState: ProxyDelayViewState): Resource {
  return $r('app.float.space_sm');
}

function shouldDisableProxyInteractionsFromRow(selectionPending: boolean, delayState: ProxyDelayViewState): boolean {
  return selectionPending || isDelayActionLive(delayState);
}

function isDelayActionLive(delayState: ProxyDelayViewState): boolean {
  return delayState === 'STARTING' || delayState === 'RUNNING';
}

function isTerminalDelayState(delayState: ProxyDelayViewState): boolean {
  return delayState === 'COMPLETED' || delayState === 'CANCELLED' || delayState === 'FAILED';
}

function isDelayActionEnabled(state: ProxyViewState): boolean {
  if (state.selectionPending) {
    return false;
  }
  if (isDelayActionLive(state.delayState)) {
    return true;
  }
  return state.status === 'READY' && state.nodes.length > 0;
}

function shouldShowActivationStatus(row: ProxyNodeRowState, state: ProxyViewState): boolean {
  return state.selectionPending &&
    state.activatingRowIndex === row.index &&
    state.activationStage !== 'IDLE' &&
    state.activationStage !== 'FAILED';
}

function resolveActivationStatusResource(state: ProxyViewState): Resource {
  switch (state.activationStage) {
    case 'SAVING_SELECTION':
      return $r('app.string.proxies_activation_transitioning');
    case 'STARTING_VPN':
    case 'CONFIRMING_SELECTION':
      return $r('app.string.proxies_activation_starting_vpn');
    case 'SWITCHING_VPN':
      return $r('app.string.proxies_activation_switching_vpn');
    case 'IDLE':
    case 'FAILED':
    default:
      return $r('app.string.proxies_activation_transitioning');
  }
}

function resolveDelayActionLabel(delayState: ProxyDelayViewState): Resource {
  if (isDelayActionLive(delayState)) {
    return $r('app.string.proxies_delay_action_cancel');
  }
  return $r('app.string.proxies_delay_action_start');
}

function resolveDelayProgressTotal(state: ProxyViewState): number {
  if (state.totalDelayCount > 0) {
    return state.totalDelayCount;
  }
  return 1;
}

function resolveDelayProgressValue(state: ProxyViewState): number {
  const total: number = resolveDelayProgressTotal(state);
  if (state.completedDelayCount > total) {
    return total;
  }
  return state.completedDelayCount;
}

function resolveFastestRow(state: ProxyViewState): ProxyNodeRowState | undefined {
  if (state.fastestDelayNodeIndex === undefined ||
    state.fastestDelayNodeIndex < 0 ||
    state.fastestDelayNodeIndex >= state.nodes.length) {
    return undefined;
  }
  return state.nodes[state.fastestDelayNodeIndex];
}

function shouldShowDelayOutcome(row: ProxyNodeRowState, delayState: ProxyDelayViewState): boolean {
  return row.delayStatus !== 'NONE' || delayState === 'STARTING';
}

function resolveDelayOutcomeResource(row: ProxyNodeRowState): Resource {
  switch (row.delayStatus) {
    case 'WAITING':
      return $r('app.string.proxies_delay_waiting');
    case 'TESTING':
      return $r('app.string.proxies_delay_testing');
    case 'AVAILABLE':
      return $r('app.string.proxies_delay_ms', row.delayMs as number);
    case 'TIMEOUT':
      return $r('app.string.proxies_delay_timeout');
    case 'FAILED':
      return $r('app.string.proxies_delay_failed');
    case 'CANCELLED':
      return $r('app.string.proxies_delay_cancelled');
    case 'UNSUPPORTED':
      return $r('app.string.proxies_delay_unsupported');
    case 'NONE':
    default:
      return $r('app.string.proxies_delay_waiting');
  }
}

function resolveDelayRowColor(row: ProxyNodeRowState) {
  if (row.delayStatus === 'AVAILABLE' && row.delayMs !== undefined) {
    if (row.delayMs <= 300) {
      return $r('app.color.color_status_success');
    }
    if (row.delayMs <= 800) {
      return $r('app.color.color_status_warning');
    }
    return $r('app.color.color_status_danger');
  }
  if (row.delayStatus === 'TIMEOUT') {
    return $r('app.color.color_status_warning');
  }
  if (row.delayStatus === 'FAILED') {
    return $r('app.color.color_status_danger');
  }
  return $r('app.color.color_text_secondary');
}

function resolveErrorMessage(errorCode: ProxyRejectedErrorCode | undefined): Resource {
  switch (errorCode) {
    case 'PROXY_PROFILE_UNAVAILABLE':
      return $r('app.string.proxies_error_profile_unavailable');
    case 'PROXY_RUNTIME_NOT_READY':
      return $r('app.string.proxies_error_runtime_not_ready');
    case 'PROXY_SELECTION_STALE':
      return $r('app.string.proxies_error_selection_stale');
    case 'PROXY_SELECTION_FAILED':
      return $r('app.string.proxies_error_selection_failed');
    case 'PROXY_PERSISTENCE_FAILED':
      return $r('app.string.proxies_error_persistence_failed');
    case 'VPN_SESSION_CHANGED':
      return $r('app.string.proxies_error_session_changed');
    case 'PROXY_QUERY_FAILED':
    default:
      return $r('app.string.proxies_error_query_failed');
  }
}

function resolveActivationErrorMessage(resourceId: OneClickVpnErrorResourceId | undefined): Resource {
  switch (resourceId) {
    case 'proxies_one_click_busy':
      return $r('app.string.proxies_one_click_busy');
    case 'proxies_error_selection_stale':
      return $r('app.string.proxies_error_selection_stale');
    case 'proxies_error_selection_failed':
      return $r('app.string.proxies_error_selection_failed');
    case 'proxies_error_persistence_failed':
      return $r('app.string.proxies_error_persistence_failed');
    case 'error_vpn_profile_unavailable':
      return $r('app.string.error_vpn_profile_unavailable');
    case 'error_vpn_permission_denied':
      return $r('app.string.error_vpn_permission_denied');
    case 'error_vpn_start_failed':
      return $r('app.string.error_vpn_start_failed');
    case 'proxies_one_click_confirmation_timeout':
      return $r('app.string.proxies_one_click_confirmation_timeout');
    case 'proxies_error_session_changed':
    default:
      return $r('app.string.proxies_error_session_changed');
  }
}
