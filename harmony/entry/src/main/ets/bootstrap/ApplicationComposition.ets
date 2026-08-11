import type { AppError, ProfileApplication } from '@cmfa/shared';

interface ApplicationCompositionLoadingState {
  status: 'LOADING';
}

interface ApplicationCompositionReadyState {
  status: 'READY';
  application: ProfileApplication;
}

interface ApplicationCompositionErrorState {
  status: 'ERROR';
  error: AppError;
}

export type ApplicationCompositionState =
  | ApplicationCompositionLoadingState
  | ApplicationCompositionReadyState
  | ApplicationCompositionErrorState;

export interface ApplicationComposition {
  initialize(): Promise<void>;
  state(): ApplicationCompositionState;
  subscribe(listener: (state: ApplicationCompositionState) => void): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}
