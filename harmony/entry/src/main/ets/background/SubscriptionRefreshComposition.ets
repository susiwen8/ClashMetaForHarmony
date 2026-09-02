import type { WorkSchedulerExtensionContext } from '@kit.BackgroundTasksKit';
import { createCoreService } from '@cmfa/core';
import {
  ProfileRefreshPlatformFactory,
  type ProfileRefreshPlatformGraph
} from '@cmfa/platform/ProfileRefresh';
import {
  LeasedRemoteProfileRefresher,
  type LeasedRemoteProfileRefresherDependencies,
  ProfileCommitService,
  type ProfileCommitServiceDependencies,
  RefreshProfileUseCase,
  type RefreshProfileUseCaseDependencies,
  RefreshProfilesUseCase,
  type RefreshProfilesUseCaseDependencies,
  SerialCommandQueue,
  type CoreService,
  type ProfileRefreshExecutorPort,
  type RefreshProfilesCommand,
  type RefreshProfilesResult
} from '@cmfa/shared';

export interface SubscriptionRefreshWorkComposition {
  run(deadlineMs: number, isCancelled: () => boolean): Promise<void>;
}

export interface SubscriptionRefreshBatchPort {
  execute(command: RefreshProfilesCommand): Promise<RefreshProfilesResult>;
}

export interface SubscriptionRefreshCompositionDependencies {
  createPlatformGraph(context: WorkSchedulerExtensionContext): Promise<ProfileRefreshPlatformGraph>;
  createBatchUseCase(graph: ProfileRefreshPlatformGraph): SubscriptionRefreshBatchPort;
}

class DefaultSubscriptionRefreshCompositionDependencies implements SubscriptionRefreshCompositionDependencies {
  async createPlatformGraph(context: WorkSchedulerExtensionContext): Promise<ProfileRefreshPlatformGraph> {
    return await new ProfileRefreshPlatformFactory(context).create();
  }

  createBatchUseCase(graph: ProfileRefreshPlatformGraph): SubscriptionRefreshBatchPort {
    return createDefaultBatchUseCase(graph);
  }
}

export class SubscriptionRefreshComposition implements SubscriptionRefreshWorkComposition {
  private readonly context: WorkSchedulerExtensionContext;
  private readonly dependencies: SubscriptionRefreshCompositionDependencies;

  constructor(
    context: WorkSchedulerExtensionContext,
    dependencies?: SubscriptionRefreshCompositionDependencies
  ) {
    this.context = context;
    this.dependencies = dependencies ?? createDefaultDependencies();
  }

  async run(deadlineMs: number, isCancelled: () => boolean): Promise<void> {
    const graph: ProfileRefreshPlatformGraph = await this.dependencies.createPlatformGraph(this.context);
    let primaryError: Error | undefined = undefined;
    try {
      const batch: SubscriptionRefreshBatchPort = this.dependencies.createBatchUseCase(graph);
      await batch.execute({
        mode: 'DUE',
        deadlineMs,
        isCancelled
      });
    } catch (error) {
      primaryError = error instanceof Error ? error : new Error('Subscription refresh batch failed.');
    } finally {
      try {
        await graph.close();
      } catch (closeError) {
        if (primaryError === undefined) {
          throw closeError instanceof Error ? closeError : new Error('Subscription refresh graph close failed.');
        }
      }
    }
    if (primaryError !== undefined) {
      throw primaryError;
    }
  }
}

export function createSubscriptionRefreshComposition(
  context: WorkSchedulerExtensionContext
): SubscriptionRefreshComposition {
  return new SubscriptionRefreshComposition(context);
}

function createDefaultDependencies(): SubscriptionRefreshCompositionDependencies {
  return new DefaultSubscriptionRefreshCompositionDependencies();
}

function createDefaultBatchUseCase(graph: ProfileRefreshPlatformGraph): RefreshProfilesUseCase {
  const coreService: CoreService = createCoreService();
  const commitServiceDependencies: ProfileCommitServiceDependencies = {
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: graph.clock
  };
  const commitService = new ProfileCommitService(commitServiceDependencies);
  const leasedRemoteRefresherDependencies: LeasedRemoteProfileRefresherDependencies = {
    leasePort: graph.profileRefreshLeasePort,
    clock: graph.clock,
    idGenerator: graph.idGenerator
  };
  const leasedRemoteRefresher = new LeasedRemoteProfileRefresher(leasedRemoteRefresherDependencies);
  const refreshUseCaseDependencies: RefreshProfileUseCaseDependencies = {
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway: graph.sourceGateway,
    secretStore: graph.secretStore,
    coreService,
    clock: graph.clock,
    queue: new SerialCommandQueue(),
    commitService,
    leasedRemoteRefresher
  };
  const refreshUseCase = new RefreshProfileUseCase(refreshUseCaseDependencies);
  const refreshProfilesUseCaseDependencies: RefreshProfilesUseCaseDependencies = {
    repository: graph.repository,
    executor: refreshUseCase as ProfileRefreshExecutorPort,
    clock: graph.clock
  };
  return new RefreshProfilesUseCase(refreshProfilesUseCaseDependencies);
}
