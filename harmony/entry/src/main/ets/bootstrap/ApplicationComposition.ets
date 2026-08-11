import type { AppError, ProfileApplication } from '@cmfa/shared';

export type ApplicationCompositionState =
  | { status: 'LOADING' }
  | { status: 'READY'; application: ProfileApplication }
  | { status: 'ERROR'; error: AppError };

export interface ApplicationComposition {
  initialize(): Promise<void>;
  state(): ApplicationCompositionState;
  subscribe(listener: (state: ApplicationCompositionState) => void): number;
  unsubscribe(id: number): void;
  close(): Promise<void>;
}
