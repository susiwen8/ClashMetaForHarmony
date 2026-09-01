export type CoreProxyType =
  | 'Direct'
  | 'Reject'
  | 'RejectDrop'
  | 'Compatible'
  | 'Pass'
  | 'PassRule'
  | 'Rematch'
  | 'Dns'
  | 'Relay'
  | 'Selector'
  | 'Fallback'
  | 'URLTest'
  | 'LoadBalance'
  | 'Shadowsocks'
  | 'ShadowsocksR'
  | 'Snell'
  | 'Socks5'
  | 'Http'
  | 'Vmess'
  | 'Vless'
  | 'Trojan'
  | 'Hysteria'
  | 'Hysteria2'
  | 'WireGuard'
  | 'Tuic'
  | 'Ssh'
  | 'Mieru'
  | 'AnyTLS'
  | 'Sudoku'
  | 'Masque'
  | 'TrustTunnel'
  | 'ShadowQuic'
  | 'OpenVPN'
  | 'Tailscale'
  | 'GostRelay';

export const CORE_PROXY_SCHEMA_VERSION: '1.0.0' = '1.0.0';

export interface CoreProxyQueryContext {
  profileHash: string;
  revisionHash: string;
  sessionHash: string | null;
  generation: number;
}

export interface CoreProxyGroupRef {
  name: string;
  type: CoreProxyType;
}

export interface CoreProxyNodeSummary {
  name: string;
  type: CoreProxyType;
  isGroup: boolean;
  selected: boolean;
}

export interface CoreProxyGroupSnapshot {
  name: string;
  type: CoreProxyType;
  selectedName: string;
  nodes: CoreProxyNodeSummary[];
}

export interface CoreProxyGroupList extends CoreProxyQueryContext {
  schemaVersion: '1.0.0';
  kind: 'GROUP_LIST';
  groups: CoreProxyGroupRef[];
}

export interface CoreProxyGroupResult extends CoreProxyQueryContext {
  schemaVersion: '1.0.0';
  kind: 'GROUP_SNAPSHOT';
  group: CoreProxyGroupSnapshot;
}

export interface CoreProxySelectionApplied extends CoreProxyQueryContext {
  schemaVersion: '1.0.0';
  kind: 'SELECTION_APPLIED';
  previousName: string;
  group: CoreProxyGroupSnapshot;
}

class CoreProxyQueryContextValue implements CoreProxyQueryContext {
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
}

class CoreProxyGroupRefValue implements CoreProxyGroupRef {
  name: string = '';
  type: CoreProxyType = 'Direct';
}

class CoreProxyNodeSummaryValue implements CoreProxyNodeSummary {
  name: string = '';
  type: CoreProxyType = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class CoreProxyGroupSnapshotValue implements CoreProxyGroupSnapshot {
  name: string = '';
  type: CoreProxyType = 'Direct';
  selectedName: string = '';
  nodes: CoreProxyNodeSummary[] = [];
}

class CoreProxyGroupListValue extends CoreProxyQueryContextValue implements CoreProxyGroupList {
  schemaVersion: '1.0.0' = CORE_PROXY_SCHEMA_VERSION;
  kind: 'GROUP_LIST' = 'GROUP_LIST';
  groups: CoreProxyGroupRef[] = [];
}

class CoreProxyGroupResultValue extends CoreProxyQueryContextValue implements CoreProxyGroupResult {
  schemaVersion: '1.0.0' = CORE_PROXY_SCHEMA_VERSION;
  kind: 'GROUP_SNAPSHOT' = 'GROUP_SNAPSHOT';
  group: CoreProxyGroupSnapshot = new CoreProxyGroupSnapshotValue();
}

class CoreProxySelectionAppliedValue extends CoreProxyQueryContextValue implements CoreProxySelectionApplied {
  schemaVersion: '1.0.0' = CORE_PROXY_SCHEMA_VERSION;
  kind: 'SELECTION_APPLIED' = 'SELECTION_APPLIED';
  previousName: string = '';
  group: CoreProxyGroupSnapshot = new CoreProxyGroupSnapshotValue();
}

export function cloneCoreProxyQueryContext(context: CoreProxyQueryContext): CoreProxyQueryContext {
  const clone = new CoreProxyQueryContextValue();
  clone.profileHash = context.profileHash;
  clone.revisionHash = context.revisionHash;
  clone.sessionHash = context.sessionHash;
  clone.generation = context.generation;
  return clone;
}

export function cloneCoreProxyGroupRef(group: CoreProxyGroupRef): CoreProxyGroupRef {
  const clone = new CoreProxyGroupRefValue();
  clone.name = group.name;
  clone.type = group.type;
  return clone;
}

export function cloneCoreProxyNodeSummary(node: CoreProxyNodeSummary): CoreProxyNodeSummary {
  const clone = new CoreProxyNodeSummaryValue();
  clone.name = node.name;
  clone.type = node.type;
  clone.isGroup = node.isGroup;
  clone.selected = node.selected;
  return clone;
}

export function cloneCoreProxyGroupSnapshot(group: CoreProxyGroupSnapshot): CoreProxyGroupSnapshot {
  const clone = new CoreProxyGroupSnapshotValue();
  clone.name = group.name;
  clone.type = group.type;
  clone.selectedName = group.selectedName;
  const nodes: CoreProxyNodeSummary[] = [];
  for (let index: number = 0; index < group.nodes.length; index += 1) {
    nodes.push(cloneCoreProxyNodeSummary(group.nodes[index]));
  }
  clone.nodes = nodes;
  return clone;
}

export function cloneCoreProxyGroupList(result: CoreProxyGroupList): CoreProxyGroupList {
  const clone = new CoreProxyGroupListValue();
  clone.profileHash = result.profileHash;
  clone.revisionHash = result.revisionHash;
  clone.sessionHash = result.sessionHash;
  clone.generation = result.generation;
  const groups: CoreProxyGroupRef[] = [];
  for (let index: number = 0; index < result.groups.length; index += 1) {
    groups.push(cloneCoreProxyGroupRef(result.groups[index]));
  }
  clone.groups = groups;
  return clone;
}

export function cloneCoreProxyGroupResult(result: CoreProxyGroupResult): CoreProxyGroupResult {
  const clone = new CoreProxyGroupResultValue();
  clone.profileHash = result.profileHash;
  clone.revisionHash = result.revisionHash;
  clone.sessionHash = result.sessionHash;
  clone.generation = result.generation;
  clone.group = cloneCoreProxyGroupSnapshot(result.group);
  return clone;
}

export function cloneCoreProxySelectionApplied(result: CoreProxySelectionApplied): CoreProxySelectionApplied {
  const clone = new CoreProxySelectionAppliedValue();
  clone.profileHash = result.profileHash;
  clone.revisionHash = result.revisionHash;
  clone.sessionHash = result.sessionHash;
  clone.generation = result.generation;
  clone.previousName = result.previousName;
  clone.group = cloneCoreProxyGroupSnapshot(result.group);
  return clone;
}
