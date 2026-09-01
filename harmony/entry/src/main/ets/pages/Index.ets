import {
  createAppError,
  type CoreRuntimeMode,
  type ProfileApplication,
  type RuntimeLogExportPort,
  type RuntimeLogFilterLevel,
  type RuntimeLogStorePort,
  type VpnRpcRuntimeModeClientPort
} from '@cmfa/shared';
import type { ApplicationComposition, ApplicationCompositionState } from '../bootstrap/ApplicationComposition';
import { getApplicationCompositionFromStorage } from '../bootstrap/CoreComposition';
import { HomePage } from './HomePage';
import { ImportProfileSheet } from './ImportProfileSheet';
import { ProfileDetailPage } from './ProfileDetailPage';
import { ProfilesPage } from './ProfilesPage';
import { LogsPage } from './LogsPage';
import {
  HomeViewModel
} from '../presentation/HomeViewModel';
import type { VpnTrafficMonitorReadPort } from '../vpn/VpnTrafficMonitor';
import {
  ImportProfileViewModel,
  type ImportNavigationIntent
} from '../presentation/ImportProfileViewModel';
import {
  ProfilesViewModel,
  type ProfilesNavigationIntent
} from '../presentation/ProfilesViewModel';
import {
  ProfileDetailViewModel,
  type ProfileDetailNavigationIntent
} from '../presentation/ProfileDetailViewModel';
import { createProxyViewState, type ProxyViewState } from '../presentation/ProxyPresentationModels';
import { ProxyViewModel } from '../presentation/ProxyViewModel';
import {
  LogsViewModel,
  createLogsViewState,
  type LogsViewState
} from '../presentation/LogsViewModel';
import {
  createHomeTrafficState,
  createHomeViewState,
  createImportProfileViewState,
  createProfileDetailViewState,
  createProfilesViewState,
  createSafeErrorState,
  createVpnGlobalCaptureState,
  type HomeViewState,
  type ImportProfileViewState,
  type ProfileDetailViewState,
  type ProfilesViewState,
  type SafeErrorState
} from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

type AppRoute = 'HOME' | 'PROFILES' | 'DETAIL' | 'LOGS';

@Entry
@Component
struct Index {
  private composition?: ApplicationComposition;
  private application?: ProfileApplication;
  private homeViewModel?: HomeViewModel;
  private profilesViewModel?: ProfilesViewModel;
  private importViewModel?: ImportProfileViewModel;
  private profileDetailViewModel?: ProfileDetailViewModel;
  private proxyViewModel?: ProxyViewModel;
  private logsViewModel?: LogsViewModel;
  private runtimeLogStore?: RuntimeLogStorePort;
  private runtimeLogExporter?: RuntimeLogExportPort;
  private compositionSubscriptionId: number = 0;
  private homeSubscriptionId: number = 0;
  private profilesSubscriptionId: number = 0;
  private profilesNavigationSubscriptionId: number = 0;
  private importSubscriptionId: number = 0;
  private importNavigationSubscriptionId: number = 0;
  private profileDetailSubscriptionId: number = 0;
  private profileDetailNavigationSubscriptionId: number = 0;
  private proxySubscriptionId: number = 0;
  private logsSubscriptionId: number = 0;
  private detailProxyLeavePromise?: Promise<boolean>;
  private proxyDisposeDrainFailed: boolean = false;
  private proxyDisposeGeneration: number = 0;
  private detailViewModelProfileId?: string;
  private importHttpAlertOpen: boolean = false;
  private detailHttpAlertOpen: boolean = false;
  private detailDeleteAlertOpen: boolean = false;

  @State private compositionStatus: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  @State private compositionError: SafeErrorState | undefined = undefined;
  @State private compactLayout: boolean = false;
  @State private route: AppRoute = 'HOME';
  @State private importSheetVisible: boolean = false;
  @State private detailProfileId: string = '';
  @State private detailCommandPending: boolean = false;
  @State private detailCommandCompleted: boolean = false;
  @State private detailCanManageProxies: boolean = false;
  @State private detailProxyExpanded: boolean = false;
  @State private homeSelectedProxyGroupName: string = '';
  @State private homeSelectedProxyNodeName: string = '';
  @State private proxyRenderVersion: number = 0;
  @State private logsState: LogsViewState = createLogsViewState([], 0, 'ALL', '', false, false, 'NONE', false);
  @State private homeState: HomeViewState = createHomeViewState(
    'LOADING',
    undefined,
    false,
    '',
    '',
    createVpnGlobalCaptureState('STOPPED', 'DISABLED', false, false, [], undefined, false, 0, undefined, undefined),
    createHomeTrafficState(false, false, 0, 0, 0, 0, false),
    undefined
  );
  @State private profilesState: ProfilesViewState = createProfilesViewState('LOADING', [], undefined);
  @State private importState: ImportProfileViewState = createImportProfileViewState('IDLE', undefined, undefined, undefined, undefined);
  @State private detailState: ProfileDetailViewState = createProfileDetailViewState(
    'IDLE',
    undefined,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    undefined,
    undefined
  );
  @State private proxyState: ProxyViewState = createProxyViewState('IDLE', [], [], {
    selectionPending: false,
    warning: 'NONE'
  });

  aboutToAppear(): void {
    this.bindCompositionFromStorage();
  }

  aboutToDisappear(): void {
    if (this.composition !== undefined && this.compositionSubscriptionId !== 0) {
      this.composition.unsubscribe(this.compositionSubscriptionId);
      this.compositionSubscriptionId = 0;
    }
    this.disposeViewModels();
  }

  build() {
    Navigation() {
      Stack() {
        if (this.compositionStatus === 'READY') {
          this.buildReadyRoute();
        } else if (this.compositionStatus === 'ERROR') {
          this.buildErrorState();
        } else {
          this.buildLoadingState();
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.importSheetVisible, this.buildImportSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true
    })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.compactLayout = lengthToVp(newValue.width) < 420;
    })
  }

  @Builder
  private buildReadyRoute(): void {
    if (this.route === 'LOGS' && this.logsViewModel !== undefined) {
      LogsPage({
        state: this.logsState,
        onBack: () => {
          this.closeLogs();
        },
        onRefresh: () => {
          void this.logsViewModel?.refresh();
        },
        onClear: () => {
          void this.logsViewModel?.clearLogs();
        },
        onExport: () => {
          void this.logsViewModel?.exportLogs();
        },
        onLevelChange: (level: RuntimeLogFilterLevel) => {
          this.logsViewModel?.setLevel(level);
        },
        onSearchChange: (text: string) => {
          this.logsViewModel?.setSearchText(text);
        }
      })
    } else if (this.route === 'PROFILES') {
      ProfilesPage({
        state: this.profilesState,
        compactLayout: this.compactLayout,
        onBack: () => {
          this.route = 'HOME';
        },
        onOpenAddSheet: () => {
          this.importSheetVisible = true;
        },
        onOpenProfile: (profileId: string) => {
          this.openDetailRoute(profileId);
        },
        onRefreshAll: () => {
          void this.profilesViewModel?.requestRefreshAll();
        }
      })
    } else if (this.route === 'DETAIL' && this.profileDetailViewModel !== undefined) {
      ProfileDetailPage({
        state: this.detailState,
        commandPending: $detailCommandPending,
        commandCompleted: $detailCommandCompleted,
        canManageProxies: $detailCanManageProxies,
        proxyExpanded: $detailProxyExpanded,
        proxyState: this.proxyState,
        proxyRenderVersion: this.proxyRenderVersion,
        compactLayout: this.compactLayout,
        viewModel: this.profileDetailViewModel,
        onBack: () => {
          void this.leaveDetailProxyManager('PROFILES');
        },
        onToggleProxyManager: () => {
          this.toggleDetailProxyManager();
        },
        onRetryProxy: () => {
          void this.proxyViewModel?.retry();
        },
        onOpenProxyGroup: (groupIndex: number) => {
          void this.proxyViewModel?.openGroup(groupIndex);
        },
        onSelectProxyNode: (nodeIndex: number) => {
          void this.proxyViewModel?.activateNode(nodeIndex);
        },
        onProxyDelayAction: () => {
          void this.proxyViewModel?.toggleDelayTest();
        }
      })
    } else {
      HomePage({
        state: this.homeState,
        selectedProxyGroupName: $homeSelectedProxyGroupName,
        selectedProxyNodeName: $homeSelectedProxyNodeName,
        compactLayout: this.compactLayout,
        onManageProfiles: () => {
          this.route = 'PROFILES';
        },
        onOpenLogs: () => {
          this.openLogs();
        },
        onVpnAction: () => {
          void this.homeViewModel?.requestVpnAction();
        },
        onRuntimeModeSelect: (mode: CoreRuntimeMode) => {
          void this.homeViewModel?.requestRuntimeMode(mode);
        }
      })
    }
  }

  @Builder
  private buildImportSheet(): void {
    if (this.importViewModel !== undefined) {
      ImportProfileSheet({
        state: this.importState,
        compactLayout: this.compactLayout,
        viewModel: this.importViewModel,
        onClose: () => {
          this.importSheetVisible = false;
        }
      })
    }
  }

  @Builder
  private buildLoadingState(): void {
    Column({ space: $r('app.float.space_lg') }) {
      Text($r('app.string.app_loading'))
        .fontSize($r('app.float.type_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.color_text_primary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .safeAreaPadding({
      top: $r('app.float.page_padding_compact'),
      bottom: $r('app.float.page_padding_compact')
    })
  }

  @Builder
  private buildErrorState(): void {
    Column({ space: $r('app.float.space_lg') }) {
      Text($r('app.string.home_title'))
        .fontSize($r('app.float.type_headline'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.color_text_primary'))

      SafeErrorCard({ error: this.compositionError ?? createEmptySafeErrorState() })
    }
    .width('100%')
    .height('100%')
    .padding(this.compactLayout ? $r('app.float.page_padding_compact') : $r('app.float.page_padding_regular'))
    .alignItems(HorizontalAlign.Start)
    .safeAreaPadding({
      top: $r('app.float.page_padding_compact'),
      bottom: $r('app.float.page_padding_compact')
    })
  }

  private bindCompositionFromStorage(): void {
    const storage: LocalStorage | undefined = this.getUIContext().getSharedLocalStorage();
    const composition: ApplicationComposition | undefined = getApplicationCompositionFromStorage(storage);
    if (composition === undefined) {
      this.applyCompositionError(createSafeErrorState(createAppError('PERSISTENCE', 'Application composition storage missing.', {
        retryable: false
      })));
      return;
    }
    this.composition = composition;
    this.compositionSubscriptionId = this.composition.subscribe((state: ApplicationCompositionState): void => {
      this.applyCompositionState(state);
    });
    this.applyCompositionState(this.composition.state());
  }

  private applyCompositionState(state: ApplicationCompositionState): void {
    if (state.status === 'READY') {
      this.compositionStatus = 'READY';
      this.compositionError = undefined;
      this.attachApplication(
        state.application,
        state.vpnRegistry,
        state.runtimeModeClient,
        state.trafficMonitor,
        state.runtimeLogStore,
        state.runtimeLogExporter
      );
      return;
    }
    if (state.status === 'ERROR') {
      this.applyCompositionError(createSafeErrorState(state.error));
      return;
    }
    this.compositionStatus = 'LOADING';
    this.compositionError = undefined;
  }

  private applyCompositionError(error: SafeErrorState | undefined): void {
    this.compositionStatus = 'ERROR';
    this.compositionError = error;
    this.disposeViewModels();
  }

  private handleProxyDisposeResult(didDrain: boolean, disposeGeneration: number): void {
    if (disposeGeneration !== this.proxyDisposeGeneration) {
      return;
    }
    this.proxyDisposeDrainFailed = !didDrain;
    if (didDrain) {
      return;
    }
    const cleanupError: SafeErrorState | undefined = createSafeErrorState(createAppError(
      'RUNTIME_STOP',
      'Proxy delay lifecycle cleanup failed.',
      {
        code: 'PROXY_DELAY_DRAIN_FAILED',
        retryable: true
      }
    ));
    this.compositionStatus = 'ERROR';
    this.compositionError = cleanupError;
  }

  private attachApplication(
    application: ProfileApplication,
    vpnRegistry: import('../vpn/VpnSessionRegistry').VpnSessionRegistry,
    runtimeModeClient?: VpnRpcRuntimeModeClientPort,
    trafficMonitor?: VpnTrafficMonitorReadPort,
    runtimeLogStore?: RuntimeLogStorePort,
    runtimeLogExporter?: RuntimeLogExportPort
  ): void {
    if (this.application === application && this.homeViewModel !== undefined && this.profilesViewModel !== undefined &&
      this.importViewModel !== undefined && this.proxyViewModel !== undefined) {
      return;
    }
    this.disposeViewModels();
    this.application = application;
    this.runtimeLogStore = runtimeLogStore;
    this.runtimeLogExporter = runtimeLogExporter;
    this.proxyDisposeGeneration += 1;
    this.proxyDisposeDrainFailed = false;

    this.homeViewModel = new HomeViewModel(application, vpnRegistry, runtimeModeClient, trafficMonitor);
    this.homeSubscriptionId = this.homeViewModel.subscribe((state: HomeViewState): void => {
      this.homeState = state;
      this.homeSelectedProxyGroupName = state.selectedProxyGroupName;
      this.homeSelectedProxyNodeName = state.selectedProxyNodeName;
      this.synchronizeDetailProxyEligibility();
    });
    this.homeState = this.homeViewModel.current();
    this.homeSelectedProxyGroupName = this.homeState.selectedProxyGroupName;
    this.homeSelectedProxyNodeName = this.homeState.selectedProxyNodeName;
    this.synchronizeDetailProxyEligibility();

    this.profilesViewModel = new ProfilesViewModel(application);
    this.profilesSubscriptionId = this.profilesViewModel.subscribe((state: ProfilesViewState): void => {
      this.profilesState = state;
    });
    this.profilesNavigationSubscriptionId = this.profilesViewModel.subscribeNavigation((intent: ProfilesNavigationIntent): void => {
      this.handleProfilesNavigation(intent);
    });
    this.profilesState = this.profilesViewModel.current();

    this.importViewModel = new ImportProfileViewModel(application);
    this.importSubscriptionId = this.importViewModel.subscribe((state: ImportProfileViewState): void => {
      this.importState = state;
      this.synchronizeImportHttpAlert(state);
      if (state.status === 'COMPLETED') {
        this.importSheetVisible = false;
      }
    });
    this.importNavigationSubscriptionId = this.importViewModel.subscribeNavigation((intent: ImportNavigationIntent): void => {
      this.importSheetVisible = false;
      this.openDetailRoute(intent.profileId);
    });
    this.importState = this.importViewModel.current();

    this.proxyViewModel = new ProxyViewModel(application);
    this.proxySubscriptionId = this.proxyViewModel.subscribe((state: ProxyViewState): void => {
      this.proxyState = state;
      this.proxyRenderVersion = this.proxyRenderVersion + 1;
    });
    this.proxyState = this.proxyViewModel.current();
  }

  private openLogs(): void {
    const store: RuntimeLogStorePort | undefined = this.runtimeLogStore;
    const exporter: RuntimeLogExportPort | undefined = this.runtimeLogExporter;
    if (store === undefined || exporter === undefined) {
      return;
    }
    this.disposeLogsViewModel();
    const viewModel = new LogsViewModel(store, exporter);
    this.logsViewModel = viewModel;
    this.logsSubscriptionId = viewModel.subscribe((state: LogsViewState): void => {
      this.logsState = state;
    });
    this.logsState = viewModel.current();
    this.route = 'LOGS';
    viewModel.start();
  }

  private closeLogs(): void {
    this.disposeLogsViewModel();
    this.route = 'HOME';
  }

  private toggleDetailProxyManager(): void {
    if (this.detailProxyExpanded) {
      void this.leaveDetailProxyManager();
      return;
    }
    if (!this.detailCanManageProxies || this.detailProfileId.length === 0) {
      return;
    }
    this.proxyState = createProxyViewState('LOADING', [], [], {
      selectionPending: false,
      warning: 'NONE'
    });
    this.detailProxyExpanded = true;
    void this.proxyViewModel?.load(this.detailProfileId);
  }

  private async leaveDetailProxyManager(destination?: 'PROFILES'): Promise<boolean> {
    if (!this.detailProxyExpanded) {
      if (destination !== undefined && this.route === 'DETAIL') {
        this.route = destination;
      }
      return true;
    }
    if (this.detailProxyLeavePromise !== undefined) {
      const concurrentResult: boolean = await this.detailProxyLeavePromise;
      if (concurrentResult && destination !== undefined && this.route === 'DETAIL') {
        this.route = destination;
      }
      return concurrentResult;
    }
    const proxyViewModel: ProxyViewModel | undefined = this.proxyViewModel;
    if (proxyViewModel === undefined) {
      this.resetDetailProxySurface();
      if (destination !== undefined && this.route === 'DETAIL') {
        this.route = destination;
      }
      return true;
    }
    const leavePromise: Promise<boolean> = proxyViewModel.leave().then(() => true, () => false);
    this.detailProxyLeavePromise = leavePromise;
    const didLeave: boolean = await leavePromise;
    if (this.detailProxyLeavePromise === leavePromise) {
      this.detailProxyLeavePromise = undefined;
    }
    if (!didLeave || this.proxyViewModel !== proxyViewModel) {
      return false;
    }
    this.resetDetailProxySurface();
    if (destination !== undefined && this.route === 'DETAIL') {
      this.route = destination;
    }
    return true;
  }

  private synchronizeDetailProxyEligibility(): void {
    const detailProfileId: string = this.detailState.profile?.id ?? '';
    const activeProfileId: string | undefined = this.homeState.activeProfile?.id;
    const identityMatches: boolean = detailProfileId.length > 0 &&
      activeProfileId !== undefined &&
      detailProfileId === activeProfileId;
    this.detailCanManageProxies = identityMatches && this.homeState.canManageProxies;
    if (this.detailProxyExpanded && activeProfileId !== this.detailProfileId) {
      void this.leaveDetailProxyManager();
    }
  }

  private resetDetailProxySurface(): void {
    this.detailProxyExpanded = false;
    this.proxyState = createProxyViewState('IDLE', [], [], {
      selectionPending: false,
      warning: 'NONE'
    });
    this.proxyRenderVersion = this.proxyRenderVersion + 1;
  }

  private handleProfilesNavigation(intent: ProfilesNavigationIntent): void {
    if (intent.destination === 'ADD_SHEET') {
      this.importSheetVisible = true;
      return;
    }
    if (intent.profileId !== undefined) {
      this.openDetailRoute(intent.profileId);
    }
  }

  private openDetailRoute(profileId: string): void {
    if (this.detailProxyExpanded && profileId !== this.detailProfileId) {
      void this.openDetailRouteAfterProxyLeave(profileId);
      return;
    }
    this.activateDetailRoute(profileId);
  }

  private async openDetailRouteAfterProxyLeave(profileId: string): Promise<void> {
    if (await this.leaveDetailProxyManager()) {
      this.activateDetailRoute(profileId);
    }
  }

  private activateDetailRoute(profileId: string): void {
    this.ensureDetailViewModel(profileId);
    this.detailProfileId = profileId;
    this.synchronizeDetailProxyEligibility();
    this.route = 'DETAIL';
  }

  private ensureDetailViewModel(profileId: string): void {
    if (this.application === undefined) {
      return;
    }
    if (this.profileDetailViewModel !== undefined && this.detailViewModelProfileId === profileId) {
      return;
    }
    this.disposeDetailViewModel();
    this.profileDetailViewModel = new ProfileDetailViewModel(this.application, profileId);
    this.detailViewModelProfileId = profileId;
    this.profileDetailSubscriptionId = this.profileDetailViewModel.subscribe((state: ProfileDetailViewState): void => {
      const previousDetailState: ProfileDetailViewState = this.detailState;
      const shouldReloadProxyState: boolean = this.shouldReloadDetailProxyAfterCommand(previousDetailState, state);
      this.detailState = state;
      this.detailCommandPending = state.status === 'SUBMITTING';
      this.detailCommandCompleted = state.status === 'COMPLETED';
      this.synchronizeDetailProxyEligibility();
      this.synchronizeDetailHttpAlert(state);
      this.synchronizeDeleteAlert(state);
      if (shouldReloadProxyState) {
        void this.proxyViewModel?.load(this.detailProfileId);
      }
    });
    this.profileDetailNavigationSubscriptionId = this.profileDetailViewModel.subscribeNavigation((intent: ProfileDetailNavigationIntent): void => {
      if (intent.destination === 'BACK') {
        void this.leaveDetailProxyManager('PROFILES');
      }
    });
    this.detailState = this.profileDetailViewModel.current();
    this.detailCommandPending = this.detailState.status === 'SUBMITTING';
    this.detailCommandCompleted = this.detailState.status === 'COMPLETED';
    this.synchronizeDetailProxyEligibility();
  }

  private synchronizeImportHttpAlert(state: ImportProfileViewState): void {
    if (state.status !== 'CONFIRMING_HTTP' || state.httpConfirmationHost === undefined) {
      this.importHttpAlertOpen = false;
      return;
    }
    if (this.importHttpAlertOpen) {
      return;
    }
    this.importHttpAlertOpen = true;
    AlertDialog.show({
      title: $r('app.string.import_http_warning_title'),
      message: $r('app.string.import_http_warning_message'),
      subtitle: state.httpConfirmationHost,
      primaryButton: {
        value: $r('app.string.import_http_warning_confirm'),
        action: () => {
          this.importHttpAlertOpen = false;
          void this.importViewModel?.confirmPlainHttpImport();
        }
      },
      secondaryButton: {
        value: $r('app.string.import_http_warning_cancel'),
        action: () => {
          this.importHttpAlertOpen = false;
          this.importViewModel?.cancelPlainHttpConfirmation();
        }
      },
      cancel: () => {
        this.importHttpAlertOpen = false;
        this.importViewModel?.cancelPlainHttpConfirmation();
      }
    });
  }

  private synchronizeDetailHttpAlert(state: ProfileDetailViewState): void {
    if (state.status !== 'CONFIRMING_HTTP' || state.httpConfirmationHost === undefined) {
      this.detailHttpAlertOpen = false;
      return;
    }
    if (this.detailHttpAlertOpen) {
      return;
    }
    this.detailHttpAlertOpen = true;
    AlertDialog.show({
      title: $r('app.string.import_http_warning_title'),
      message: $r('app.string.import_http_warning_message'),
      subtitle: state.httpConfirmationHost,
      primaryButton: {
        value: $r('app.string.import_http_warning_confirm'),
        action: () => {
          this.detailHttpAlertOpen = false;
          void this.profileDetailViewModel?.confirmPlainHttpAction();
        }
      },
      secondaryButton: {
        value: $r('app.string.import_http_warning_cancel'),
        action: () => {
          this.detailHttpAlertOpen = false;
          this.profileDetailViewModel?.cancelPlainHttpConfirmation();
        }
      },
      cancel: () => {
        this.detailHttpAlertOpen = false;
        this.profileDetailViewModel?.cancelPlainHttpConfirmation();
      }
    });
  }

  private shouldReloadDetailProxyAfterCommand(previousState: ProfileDetailViewState, nextState: ProfileDetailViewState): boolean {
    const activeProfileId: string | undefined = this.homeState.activeProfile?.id;
    const nextProfileId: string = nextState.profile?.id ?? '';
    return previousState.status === 'SUBMITTING' &&
      nextState.status === 'COMPLETED' &&
      this.route === 'DETAIL' &&
      this.detailProxyExpanded &&
      this.detailProxyLeavePromise === undefined &&
      nextProfileId.length > 0 &&
      nextProfileId === this.detailProfileId &&
      activeProfileId === this.detailProfileId;
  }

  private synchronizeDeleteAlert(state: ProfileDetailViewState): void {
    if (!state.confirmingDelete) {
      this.detailDeleteAlertOpen = false;
      return;
    }
    if (this.detailDeleteAlertOpen) {
      return;
    }
    this.detailDeleteAlertOpen = true;
    AlertDialog.show({
      title: $r('app.string.detail_delete_confirm_title'),
      message: $r('app.string.detail_delete_confirm_message'),
      primaryButton: {
        value: $r('app.string.detail_delete_confirm_action'),
        action: () => {
          this.detailDeleteAlertOpen = false;
          void this.profileDetailViewModel?.confirmDelete();
        }
      },
      secondaryButton: {
        value: $r('app.string.detail_delete_cancel'),
        action: () => {
          this.detailDeleteAlertOpen = false;
          this.profileDetailViewModel?.cancelDelete();
        }
      },
      cancel: () => {
        this.detailDeleteAlertOpen = false;
        this.profileDetailViewModel?.cancelDelete();
      }
    });
  }

  private disposeViewModels(): void {
    const disposeGeneration: number = this.proxyDisposeGeneration + 1;
    this.proxyDisposeGeneration = disposeGeneration;
    this.disposeLogsViewModel();
    if (this.homeViewModel !== undefined) {
      this.homeViewModel.unsubscribe(this.homeSubscriptionId);
      this.homeViewModel.dispose();
      this.homeViewModel = undefined;
      this.homeSubscriptionId = 0;
    }
    this.homeState = createHomeViewState(
      'LOADING',
      undefined,
      false,
      '',
      '',
      createVpnGlobalCaptureState('STOPPED', 'DISABLED', false, false, [], undefined, false, 0, undefined, undefined),
      createHomeTrafficState(false, false, 0, 0, 0, 0, false),
      undefined
    );
    this.detailCanManageProxies = false;
    this.detailProxyExpanded = false;
    this.homeSelectedProxyGroupName = '';
    this.homeSelectedProxyNodeName = '';
    if (this.profilesViewModel !== undefined) {
      this.profilesViewModel.unsubscribe(this.profilesSubscriptionId);
      this.profilesViewModel.unsubscribeNavigation(this.profilesNavigationSubscriptionId);
      this.profilesViewModel.dispose();
      this.profilesViewModel = undefined;
      this.profilesSubscriptionId = 0;
      this.profilesNavigationSubscriptionId = 0;
    }
    if (this.importViewModel !== undefined) {
      this.importViewModel.unsubscribe(this.importSubscriptionId);
      this.importViewModel.unsubscribeNavigation(this.importNavigationSubscriptionId);
      this.importViewModel.dispose();
      this.importViewModel = undefined;
      this.importSubscriptionId = 0;
      this.importNavigationSubscriptionId = 0;
    }
    if (this.proxyViewModel !== undefined) {
      this.proxyViewModel.unsubscribe(this.proxySubscriptionId);
      void this.proxyViewModel.dispose().then((didDrain: boolean): void => {
        this.handleProxyDisposeResult(didDrain, disposeGeneration);
      });
      this.proxyViewModel = undefined;
      this.proxySubscriptionId = 0;
    }
    this.detailProxyLeavePromise = undefined;
    this.disposeDetailViewModel();
    this.proxyState = createProxyViewState('IDLE', [], [], {
      selectionPending: false,
      warning: 'NONE'
    });
    this.proxyRenderVersion = 0;
    this.application = undefined;
    this.runtimeLogStore = undefined;
    this.runtimeLogExporter = undefined;
  }

  private disposeLogsViewModel(): void {
    if (this.logsViewModel !== undefined) {
      this.logsViewModel.unsubscribe(this.logsSubscriptionId);
      this.logsViewModel.dispose();
      this.logsViewModel = undefined;
      this.logsSubscriptionId = 0;
    }
    this.logsState = createLogsViewState([], 0, 'ALL', '', false, false, 'NONE', false);
  }

  private disposeDetailViewModel(): void {
    if (this.profileDetailViewModel !== undefined) {
      this.profileDetailViewModel.unsubscribe(this.profileDetailSubscriptionId);
      this.profileDetailViewModel.unsubscribeNavigation(this.profileDetailNavigationSubscriptionId);
      this.profileDetailViewModel.dispose();
      this.profileDetailViewModel = undefined;
      this.detailViewModelProfileId = undefined;
      this.profileDetailSubscriptionId = 0;
      this.profileDetailNavigationSubscriptionId = 0;
    }
    this.detailState = createProfileDetailViewState('IDLE', undefined, false, false, false, false, false, false, false, undefined, undefined);
    this.detailCommandPending = false;
    this.detailCommandCompleted = false;
    this.detailCanManageProxies = false;
    this.detailProfileId = '';
  }
}

function lengthToVp(value: Length): number {
  if (typeof value === 'number') {
    return value;
  }
  const parsed: number = Number.parseFloat(`${value}`);
  return Number.isFinite(parsed) ? parsed : 0;
}
