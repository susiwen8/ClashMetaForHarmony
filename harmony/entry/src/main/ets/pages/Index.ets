import { createAppError, type ProfileApplication } from '@cmfa/shared';
import type { ApplicationComposition, ApplicationCompositionState } from '../bootstrap/ApplicationComposition';
import { getApplicationCompositionFromStorage } from '../bootstrap/CoreComposition';
import { HomePage } from './HomePage';
import { ImportProfileSheet } from './ImportProfileSheet';
import { ProfileDetailPage } from './ProfileDetailPage';
import { ProfilesPage } from './ProfilesPage';
import {
  HomeViewModel
} from '../presentation/HomeViewModel';
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
import {
  createHomeViewState,
  createImportProfileViewState,
  createProfileDetailViewState,
  createProfilesViewState,
  createSafeErrorState,
  safeRemoteHostFromUrl,
  type HomeViewState,
  type ImportProfileViewState,
  type ProfileDetailViewState,
  type ProfilesViewState,
  type SafeErrorState
} from '../presentation/PresentationModels';
import { SafeErrorCard, createEmptySafeErrorState } from '../components/SafeErrorCard';

type AppRoute = 'HOME' | 'PROFILES' | 'DETAIL';

@Entry
@Component
struct Index {
  private composition?: ApplicationComposition;
  private application?: ProfileApplication;
  private homeViewModel?: HomeViewModel;
  private profilesViewModel?: ProfilesViewModel;
  private importViewModel?: ImportProfileViewModel;
  private profileDetailViewModel?: ProfileDetailViewModel;
  private compositionSubscriptionId: number = 0;
  private homeSubscriptionId: number = 0;
  private profilesSubscriptionId: number = 0;
  private profilesNavigationSubscriptionId: number = 0;
  private importSubscriptionId: number = 0;
  private importNavigationSubscriptionId: number = 0;
  private profileDetailSubscriptionId: number = 0;
  private profileDetailNavigationSubscriptionId: number = 0;
  private detailViewModelProfileId?: string;
  private importHttpAlertOpen: boolean = false;
  private detailHttpAlertOpen: boolean = false;
  private detailDeleteAlertOpen: boolean = false;
  private replaceHttpAlertOpen: boolean = false;

  @State private compositionStatus: 'LOADING' | 'READY' | 'ERROR' = 'LOADING';
  @State private compositionError: SafeErrorState | undefined = undefined;
  @State private compactLayout: boolean = false;
  @State private route: AppRoute = 'HOME';
  @State private importSheetVisible: boolean = false;
  @State private detailProfileId: string = '';
  @State private homeState: HomeViewState = createHomeViewState('LOADING', undefined, 'STOPPED', 'DISABLED', undefined, undefined, undefined);
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
    undefined,
    undefined
  );

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
    if (this.route === 'PROFILES') {
      ProfilesPage({
        state: this.profilesState,
        compactLayout: this.compactLayout,
        onOpenAddSheet: () => {
          this.importSheetVisible = true;
        },
        onOpenProfile: (profileId: string) => {
          this.openDetailRoute(profileId);
        }
      })
    } else if (this.route === 'DETAIL' && this.profileDetailViewModel !== undefined) {
      ProfileDetailPage({
        state: this.detailState,
        compactLayout: this.compactLayout,
        viewModel: this.profileDetailViewModel,
        onBack: () => {
          this.route = 'PROFILES';
        },
        onRequestReplaceSubscriptionUrl: () => {
          this.requestReplaceSubscriptionUrl();
        }
      })
    } else {
      HomePage({
        state: this.homeState,
        compactLayout: this.compactLayout,
        onManageProfiles: () => {
          this.route = 'PROFILES';
        },
        onPrimaryAction: () => {
          void this.homeViewModel?.requestPrimaryAction();
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
      this.attachApplication(state.application);
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

  private attachApplication(application: ProfileApplication): void {
    if (this.application === application && this.homeViewModel !== undefined && this.profilesViewModel !== undefined &&
      this.importViewModel !== undefined) {
      return;
    }
    this.disposeViewModels();
    this.application = application;

    this.homeViewModel = new HomeViewModel(application);
    this.homeSubscriptionId = this.homeViewModel.subscribe((state: HomeViewState): void => {
      this.homeState = state;
    });
    this.homeState = this.homeViewModel.current();

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
    this.ensureDetailViewModel(profileId);
    this.detailProfileId = profileId;
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
      this.detailState = state;
      this.synchronizeDetailHttpAlert(state);
      this.synchronizeDeleteAlert(state);
    });
    this.profileDetailNavigationSubscriptionId = this.profileDetailViewModel.subscribeNavigation((intent: ProfileDetailNavigationIntent): void => {
      if (intent.destination === 'BACK') {
        this.route = 'PROFILES';
      }
    });
    this.detailState = this.profileDetailViewModel.current();
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
          void this.profileDetailViewModel?.confirmPlainHttpRefresh();
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

  private requestReplaceSubscriptionUrl(): void {
    const rawUrl: string = this.profileDetailViewModel?.currentReplacementUrlDraft().trim() ?? '';
    if (!rawUrl.startsWith('http://')) {
      void this.profileDetailViewModel?.requestReplaceSubscriptionUrl();
      return;
    }
    const host: string | undefined = safeRemoteHostFromUrl(rawUrl);
    if (host === undefined) {
      void this.profileDetailViewModel?.requestReplaceSubscriptionUrl();
      return;
    }
    if (this.replaceHttpAlertOpen) {
      return;
    }
    this.replaceHttpAlertOpen = true;
    AlertDialog.show({
      title: $r('app.string.import_http_warning_title'),
      message: $r('app.string.import_http_warning_message'),
      subtitle: host,
      primaryButton: {
        value: $r('app.string.import_http_warning_confirm'),
        action: () => {
          this.replaceHttpAlertOpen = false;
          void this.profileDetailViewModel?.requestReplaceSubscriptionUrl();
        }
      },
      secondaryButton: {
        value: $r('app.string.import_http_warning_cancel'),
        action: () => {
          this.replaceHttpAlertOpen = false;
        }
      },
      cancel: () => {
        this.replaceHttpAlertOpen = false;
      }
    });
  }

  private disposeViewModels(): void {
    if (this.homeViewModel !== undefined) {
      this.homeViewModel.unsubscribe(this.homeSubscriptionId);
      this.homeViewModel.dispose();
      this.homeViewModel = undefined;
      this.homeSubscriptionId = 0;
    }
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
    this.disposeDetailViewModel();
    this.application = undefined;
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
    this.detailState = createProfileDetailViewState('IDLE', undefined, false, false, false, false, false, false, undefined, undefined);
  }
}

function lengthToVp(value: Length): number {
  if (typeof value === 'number') {
    return value;
  }
  const parsed: number = Number.parseFloat(`${value}`);
  return Number.isFinite(parsed) ? parsed : 0;
}
