import type {
  LocalAcquireCommand,
  LocalProfileAcquisition,
  ProfileSourceGateway,
  RemoteAcquireCommand,
  RemoteProfileAcquisition
} from '@cmfa/shared';

export interface LocalProfileAcquirer {
  acquire(command: LocalAcquireCommand): Promise<LocalProfileAcquisition>;
}

export interface RemoteProfileAcquirer {
  acquire(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition>;
}

export interface HarmonyProfileSourceGatewayDependencies {
  localAcquirer: LocalProfileAcquirer;
  remoteAcquirer: RemoteProfileAcquirer;
}

export class HarmonyProfileSourceGateway implements ProfileSourceGateway {
  private readonly localAcquirer: LocalProfileAcquirer;
  private readonly remoteAcquirer: RemoteProfileAcquirer;

  constructor(dependencies: HarmonyProfileSourceGatewayDependencies) {
    this.localAcquirer = dependencies.localAcquirer;
    this.remoteAcquirer = dependencies.remoteAcquirer;
  }

  async acquireLocal(command: LocalAcquireCommand): Promise<LocalProfileAcquisition> {
    return await this.localAcquirer.acquire(command);
  }

  async acquireRemote(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    return await this.remoteAcquirer.acquire(command);
  }
}
