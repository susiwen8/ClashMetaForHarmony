import type { WorkSchedulerExtensionContext } from '@kit.BackgroundTasksKit';
import { createCoreService } from '@cmfa/core';
import {
  ProfileRefreshPlatformFactory,
  type ProfileRefreshPlatformGraph
} from '@cmfa/platform/ProfileRefresh';
import {
  LeasedRemoteProfileRefresher,
  ProfileCommitService,
  RefreshProfileUseCase,
  RefreshProfilesUseCase,
  SerialCommandQueue,
  type CoreService,
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
    try {
      const batch: SubscriptionRefreshBatchPort = this.dependencies.createBatchUseCase(graph);
      await batch.execute({
        mode: 'DUE',
        deadlineMs,
        isCancelled
      });
    } finally {
      await graph.close();
    }
  }
}

export function createSubscriptionRefreshComposition(
  context: WorkSchedulerExtensionContext
): SubscriptionRefreshComposition {
  return new SubscriptionRefreshComposition(context);
}

function createDefaultDependencies(): SubscriptionRefreshCompositionDependencies {
  return {
    createPlatformGraph: async (context: WorkSchedulerExtensionContext): Promise<ProfileRefreshPlatformGraph> =>
      await new ProfileRefreshPlatformFactory(context).create(),
    createBatchUseCase: (graph: ProfileRefreshPlatformGraph): SubscriptionRefreshBatchPort =>
      createDefaultBatchUseCase(graph)
  };
}

function createDefaultBatchUseCase(graph: ProfileRefreshPlatformGraph): RefreshProfilesUseCase {
  const coreService: CoreService = createCoreService();
  const commitService = new ProfileCommitService({
    repository: graph.repository,
    contentStore: graph.contentStore,
    clock: graph.clock
  });
  const leasedRemoteRefresher = new LeasedRemoteProfileRefresher({
    leasePort: graph.profileRefreshLeasePort,
    clock: graph.clock,
    idGenerator: graph.idGenerator
  });
  const refreshUseCase = new RefreshProfileUseCase({
    repository: graph.repository,
    contentStore: graph.contentStore,
    sourceGateway: graph.sourceGateway,
    secretStore: graph.secretStore,
    coreService,
    clock: graph.clock,
    queue: new SerialCommandQueue(),
    commitService,
    leasedRemoteRefresher
  });
  return new RefreshProfilesUseCase({
    repository: graph.repository,
    executor: refreshUseCase,
    clock: graph.clock
  });
}
