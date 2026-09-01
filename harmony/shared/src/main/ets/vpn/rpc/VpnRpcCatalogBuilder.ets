import type {
  CoreProxyGroupList,
  CoreProxyGroupRef,
  CoreProxyGroupResult,
  CoreProxyNodeSummary,
  CoreProxyQueryContext
} from '../../core/CoreProxyModels';
import type {
  CoreProxyPort,
} from '../../proxy/ProxyPorts';
import { buildVpnOpaqueCatalog, type VpnCatalogGroupInput, type VpnCatalogMemberInput, type VpnOpaqueCatalog } from './VpnOpaqueCatalog';
import type { VpnRpcCryptoPort } from './VpnRpcPorts';

const VPN_RPC_CATALOG_BUILD_GENERATION: number = 1;
const VPN_RPC_CATALOG_MAX_DEPTH: number = 16;
const VPN_RPC_CATALOG_MAX_ENTRIES: number = 4096;

export type VpnRpcCatalogBuildStageReporter = (stage: string) => void;

class VpnRpcCatalogQueryContextValue implements CoreProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;

  constructor(profileHash: string, revisionHash: string, sessionHash: string | null, generation: number) {
    this.profileHash = profileHash;
    this.revisionHash = revisionHash;
    this.sessionHash = sessionHash;
    this.generation = generation;
  }
}

class TraversalBudget {
  private topLevelCount: number = 0;
  private entryCount: number = 0;

  canFitTopLevelCount(nextTopLevelCount: number): boolean {
    return Number.isSafeInteger(nextTopLevelCount) &&
      nextTopLevelCount >= 0 &&
      nextTopLevelCount <= VPN_RPC_CATALOG_MAX_ENTRIES;
  }

  reserveTopLevel(): void {
    this.topLevelCount += 1;
    this.entryCount += 1;
    this.requireWithinLimit();
  }

  reserveMember(): void {
    this.entryCount += 1;
    this.requireWithinLimit();
  }

  private requireWithinLimit(): void {
    if (this.topLevelCount > VPN_RPC_CATALOG_MAX_ENTRIES || this.entryCount > VPN_RPC_CATALOG_MAX_ENTRIES) {
      throw new Error('VPN RPC catalog traversal exceeded the bounded entry limit.');
    }
  }
}

async function buildCatalogSnapshotGroup(
  coreProxy: CoreProxyPort,
  context: CoreProxyQueryContext,
  name: string,
  type: string,
  cache: Map<string, VpnCatalogGroupInput>,
  budget: TraversalBudget,
  depth: number
): Promise<VpnCatalogGroupInput> {
  if (!Number.isSafeInteger(depth) || depth < 0 || depth > VPN_RPC_CATALOG_MAX_DEPTH) {
    throw new Error('VPN RPC catalog traversal exceeded the bounded depth limit.');
  }
  const cached: VpnCatalogGroupInput | undefined = cache.get(name);
  if (cached !== undefined) {
    return cached;
  }
  const group: VpnCatalogGroupInput = {
    name,
    type,
    members: []
  };
  cache.set(name, group);
  const result: CoreProxyGroupResult = await coreProxy.queryProxyGroup(context, name);
  const members: VpnCatalogMemberInput[] = [];
  group.type = result.group.type;
  for (let index: number = 0; index < result.group.nodes.length; index += 1) {
    const node: CoreProxyNodeSummary = result.group.nodes[index];
    budget.reserveMember();
    if (node.isGroup) {
      members.push({
        kind: 'GROUP',
        group: await buildCatalogSnapshotGroup(coreProxy, context, node.name, node.type, cache, budget, depth + 1)
      });
      continue;
    }
    members.push({
      kind: 'TERMINAL',
      name: node.name,
      type: node.type
    });
  }
  group.members = members;
  return group;
}

export async function buildVpnRpcCatalogFromCore(
  crypto: VpnRpcCryptoPort,
  coreProxy: CoreProxyPort,
  profileHash: string,
  revisionHash: string,
  sessionHash: string,
  configPath: string,
  reportStage: VpnRpcCatalogBuildStageReporter = (_stage: string): void => {}
): Promise<VpnOpaqueCatalog> {
  reportStage('rpc.catalog.config.begin');
  await coreProxy.loadConfiguration(configPath);
  reportStage('rpc.catalog.config.ok');
  const context: CoreProxyQueryContext = new VpnRpcCatalogQueryContextValue(
    profileHash,
    revisionHash,
    sessionHash,
    VPN_RPC_CATALOG_BUILD_GENERATION
  );
  reportStage('rpc.catalog.groups.begin');
  const list: CoreProxyGroupList = await coreProxy.queryProxyGroups(context, true);
  reportStage('rpc.catalog.groups.ok');
  reportStage('rpc.catalog.traversal.begin');
  const budget: TraversalBudget = new TraversalBudget();
  if (!budget.canFitTopLevelCount(list.groups.length)) {
    throw new Error('VPN RPC catalog traversal exceeded the bounded entry limit.');
  }
  const cache: Map<string, VpnCatalogGroupInput> = new Map<string, VpnCatalogGroupInput>();
  const groups: VpnCatalogGroupInput[] = [];
  for (let index: number = 0; index < list.groups.length; index += 1) {
    const group: CoreProxyGroupRef = list.groups[index];
    budget.reserveTopLevel();
    groups.push(await buildCatalogSnapshotGroup(coreProxy, context, group.name, group.type, cache, budget, 0));
  }
  reportStage('rpc.catalog.traversal.ok');
  reportStage('rpc.catalog.opaque.begin');
  const catalog: VpnOpaqueCatalog = await buildVpnOpaqueCatalog(crypto, profileHash, revisionHash, groups);
  reportStage('rpc.catalog.opaque.ok');
  return catalog;
}
