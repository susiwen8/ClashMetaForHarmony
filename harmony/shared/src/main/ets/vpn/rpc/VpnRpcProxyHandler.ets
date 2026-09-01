import type {
  CoreProxyGroupRef,
  CoreProxyGroupSnapshot,
  CoreProxyNodeSummary,
  CoreProxyType
} from '../../core/CoreProxyModels';
import type { Clock } from '../../profile/ProfilePorts';
import {
  createProxyGroupListQuerySnapshot,
  createProxyGroupQuerySnapshot,
  createProxyGroupSnapshot,
  createProxyRejectedError,
  createProxyRejectedResult,
  createProxySelectionAppliedNowResult,
  createProxySelectionAppliedNotPersistedResult,
  createProxySelectionRecord,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyGroupSnapshot,
  type ProxyRejectedErrorCode,
  type ProxyRejectedResult,
  type ProxyRuntimeIdentity,
  type ProxySelectionResult
} from '../../proxy/ProxyModels';
import {
  createProxyDelayNodeResult,
  createProxyDelaySnapshotResult,
  type ProxyDelayNodeState,
  type ProxyDelayNodeResult,
  type ProxyDelayResult
} from '../../proxy/ProxyDelayModels';
import {
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxySelectCommand,
  createVpnProxyStartDelayTestCommand,
  createVpnProxyCancelDelayTestCommand,
  type VpnProxyCancelDelayTestCommand,
  type VpnProxyCommandHandler,
  type VpnProxyQueryGroupCommand,
  type VpnProxyQueryGroupsCommand,
  type VpnProxyReadDelayTestCommand,
  type VpnProxySelectCommand,
  type VpnProxyStartDelayTestCommand
} from '../../proxy/ProxyPorts';
import { VpnRpcTransportFailure } from './VpnRpcAuthenticator';
import { type VpnRpcClientPort } from './VpnRpcClient';
import {
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod
} from './VpnRpcModels';
import {
  createVpnRpcDelayGroupRequestPayload,
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcQueryGroupRequestPayload,
  createVpnRpcSelectNodeRequestPayload,
  type VpnRpcDelayResult,
  type VpnRpcDelaySnapshotPayload,
  type VpnRpcGroupNode,
  type VpnRpcGroupRef,
  type VpnRpcQueryGroupPayload,
  type VpnRpcQueryGroupsPayload,
  type VpnRpcSelectNodeResultPayload
} from './VpnRpcPayloads';
import { type VpnOpaqueCatalog, type VpnOpaqueCatalogEntry } from './VpnOpaqueCatalog';

class DelayNodeDraft {
  readonly entry: VpnOpaqueCatalogEntry;
  readonly status: ProxyDelayNodeState;
  readonly delayMs: number | null;

  constructor(entry: VpnOpaqueCatalogEntry, status: ProxyDelayNodeState, delayMs: number | null) {
    this.entry = entry;
    this.status = status;
    this.delayMs = delayMs;
  }
}

class CoreProxyGroupRefValue implements CoreProxyGroupRef {
  name: string;
  type: CoreProxyType;

  constructor(name: string, type: CoreProxyType) {
    this.name = name;
    this.type = type;
  }
}

class CoreProxyNodeSummaryValue implements CoreProxyNodeSummary {
  name: string;
  type: CoreProxyType;
  isGroup: boolean;
  selected: boolean;

  constructor(name: string, type: CoreProxyType, isGroup: boolean, selected: boolean) {
    this.name = name;
    this.type = type;
    this.isGroup = isGroup;
    this.selected = selected;
  }
}

class CoreProxyGroupSnapshotValue implements CoreProxyGroupSnapshot {
  name: string;
  type: CoreProxyType;
  selectedName: string;
  nodes: CoreProxyNodeSummary[];

  constructor(name: string, type: CoreProxyType, selectedName: string, nodes: CoreProxyNodeSummary[]) {
    this.name = name;
    this.type = type;
    this.selectedName = selectedName;
    this.nodes = nodes.slice();
  }
}

export class VpnRpcProxyHandler implements VpnProxyCommandHandler {
  private readonly client: VpnRpcClientPort;
  private readonly catalog: VpnOpaqueCatalog;
  private readonly clock: Clock;

  constructor(client: VpnRpcClientPort, catalog: VpnOpaqueCatalog, clock: Clock) {
    this.client = client;
    this.catalog = catalog;
    this.clock = clock;
  }

  async queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult> {
    const normalizedCommand: VpnProxyQueryGroupsCommand = createVpnProxyQueryGroupsCommand(
      command.identity,
      command.generation,
      command.selectableOnly
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectQueryFailed();
    }
    // QUERY_GROUPS wire v1 is the closed "selectable groups only" method and always carries an empty payload.
    if (!normalizedCommand.selectableOnly) {
      return this.rejectQueryClosed();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'QUERY_GROUPS',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcEmptyPayload()
      );
    } catch (error) {
      return this.mapQueryThrown(error);
    }
    const rejected: ProxyRejectedResult | null = this.readRejectedResponse(
      response,
      'QUERY_GROUPS',
      normalizedCommand.generation,
      false,
      'PROXY_QUERY_FAILED'
    );
    if (rejected !== null) {
      return rejected;
    }
    try {
      const payload: VpnRpcQueryGroupsPayload = response.payload as VpnRpcQueryGroupsPayload;
      this.requireGenerationMatch(response.sessionGeneration, payload.proxyGeneration, normalizedCommand.generation);
      const mappedGroups = this.mapQueryGroupsPayload(payload.groups);
      return createProxyGroupListQuerySnapshot(normalizedCommand.identity, payload.proxyGeneration, mappedGroups);
    } catch {
      return this.rejectQueryFailed();
    }
  }

  async queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult> {
    const normalizedCommand: VpnProxyQueryGroupCommand = createVpnProxyQueryGroupCommand(
      command.identity,
      command.generation,
      command.groupName,
      command.groupPath
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectQueryFailed();
    }
    const groupEntry: VpnOpaqueCatalogEntry | undefined = this.resolveGroupPath(
      normalizedCommand.groupPath ?? [normalizedCommand.groupName]
    );
    if (groupEntry === undefined) {
      return this.rejectQueryFailed();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'QUERY_GROUP',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcQueryGroupRequestPayload(groupEntry.id)
      );
    } catch (error) {
      return this.mapQueryThrown(error);
    }
    const rejected: ProxyRejectedResult | null = this.readRejectedResponse(
      response,
      'QUERY_GROUP',
      normalizedCommand.generation,
      false,
      'PROXY_QUERY_FAILED'
    );
    if (rejected !== null) {
      return rejected;
    }
    try {
      const payload: VpnRpcQueryGroupPayload = response.payload as VpnRpcQueryGroupPayload;
      this.requireGenerationMatch(response.sessionGeneration, payload.proxyGeneration, normalizedCommand.generation);
      if (payload.groupId !== groupEntry.id) {
        throw new Error('group mismatch');
      }
      const mappedSnapshot = this.createGroupSnapshotFromQueryPayload(normalizedCommand, groupEntry, payload);
      return createProxyGroupQuerySnapshot(mappedSnapshot);
    } catch {
      return this.rejectQueryFailed();
    }
  }

  async select(command: VpnProxySelectCommand): Promise<ProxySelectionResult> {
    const normalizedCommand: VpnProxySelectCommand = createVpnProxySelectCommand(
      command.identity,
      command.generation,
      command.groupName,
      command.memberName,
      command.groupPath
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectSelectionStale();
    }
    const groupEntry: VpnOpaqueCatalogEntry | undefined = this.resolveGroupPath(
      normalizedCommand.groupPath ?? [normalizedCommand.groupName]
    );
    if (groupEntry === undefined) {
      return this.rejectSelectionStale();
    }
    const selectedEntry: VpnOpaqueCatalogEntry | undefined = this.findUniqueChildByName(groupEntry, normalizedCommand.memberName, 'TERMINAL');
    if (selectedEntry === undefined) {
      return this.rejectSelectionStale();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'SELECT_NODE',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcSelectNodeRequestPayload(normalizedCommand.generation, groupEntry.id, selectedEntry.id)
      );
    } catch (error) {
      return this.mapSelectThrown(error);
    }
    const rejected: ProxyRejectedResult | null = this.readRejectedResponse(
      response,
      'SELECT_NODE',
      normalizedCommand.generation,
      true,
      'PROXY_SELECTION_FAILED'
    );
    if (rejected !== null) {
      return rejected;
    }
    try {
      const payload: VpnRpcSelectNodeResultPayload = response.payload as VpnRpcSelectNodeResultPayload;
      this.requireGenerationMatch(response.sessionGeneration, payload.proxyGeneration, normalizedCommand.generation);
      if (payload.groupId !== groupEntry.id || payload.selectedNodeId !== selectedEntry.id) {
        throw new Error('selection mismatch');
      }
      const snapshot = this.createStaticGroupSnapshot(normalizedCommand, groupEntry, selectedEntry.id);
      const timestamp: string = this.clock.now();
      const record = createProxySelectionRecord(
        normalizedCommand.identity.profileId,
        groupEntry.localName,
        selectedEntry.localName,
        normalizedCommand.identity.revisionId,
        timestamp
      );
      if (payload.persisted) {
        return createProxySelectionAppliedNowResult(snapshot, record, timestamp);
      }
      return createProxySelectionAppliedNotPersistedResult(
        snapshot,
        record,
        createProxyRejectedError('PROXY_PERSISTENCE_FAILED', false, timestamp),
        timestamp
      );
    } catch {
      return this.rejectSelectionStale();
    }
  }

  async startDelayTest(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult> {
    const normalizedCommand: VpnProxyStartDelayTestCommand = createVpnProxyStartDelayTestCommand(
      command.identity,
      command.generation,
      command.groupName,
      command.groupPath
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectDelayFailed();
    }
    const groupEntry: VpnOpaqueCatalogEntry | undefined = this.resolveGroupPath(
      normalizedCommand.groupPath ?? [normalizedCommand.groupName]
    );
    if (groupEntry === undefined) {
      return this.rejectDelayFailed();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'START_DELAY_TEST',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcDelayGroupRequestPayload(normalizedCommand.generation, groupEntry.id)
      );
    } catch (error) {
      return this.mapDelayThrown(error);
    }
    return this.mapDelayResponse(response, 'START_DELAY_TEST', normalizedCommand.generation, groupEntry.id, normalizedCommand.identity);
  }

  async readDelayTest(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult> {
    const normalizedCommand: VpnProxyReadDelayTestCommand = createVpnProxyReadDelayTestCommand(
      command.identity,
      command.generation,
      command.jobId
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectDelayFailed();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'READ_DELAY_TEST',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcDelayJobRequestPayload(normalizedCommand.jobId)
      );
    } catch (error) {
      return this.mapDelayThrown(error);
    }
    return this.mapDelayResponse(response, 'READ_DELAY_TEST', normalizedCommand.generation, null, normalizedCommand.identity);
  }

  async cancelDelayTest(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult> {
    const normalizedCommand: VpnProxyCancelDelayTestCommand = createVpnProxyCancelDelayTestCommand(
      command.identity,
      command.generation,
      command.jobId
    );
    if (!this.matchesCatalogRevision(normalizedCommand.identity.revisionHash)) {
      return this.rejectDelayFailed();
    }
    if (!this.isClientReadyForRunningRoute()) {
      return this.rejectSessionChanged();
    }
    let response: VpnRpcBody;
    try {
      response = await this.client.request(
        'CANCEL_DELAY_TEST',
        this.createActiveGuards(),
        normalizedCommand.generation,
        createVpnRpcDelayJobRequestPayload(normalizedCommand.jobId)
      );
    } catch (error) {
      return this.mapDelayThrown(error);
    }
    return this.mapDelayResponse(response, 'CANCEL_DELAY_TEST', normalizedCommand.generation, null, normalizedCommand.identity);
  }

  private mapDelayResponse(
    response: VpnRpcBody,
    method: VpnRpcMethod,
    generation: number,
    expectedGroupId: string | null,
    identity: ProxyRuntimeIdentity
  ): ProxyDelayResult {
    const rejected: ProxyRejectedResult | null = this.readRejectedResponse(
      response,
      method,
      generation,
      false,
      'PROXY_DELAY_TEST_FAILED'
    );
    if (rejected !== null) {
      return rejected;
    }
    try {
      const payload: VpnRpcDelaySnapshotPayload = response.payload as VpnRpcDelaySnapshotPayload;
      this.requireGenerationMatch(response.sessionGeneration, payload.proxyGeneration, generation);
      if (expectedGroupId !== null && payload.groupId !== expectedGroupId) {
        throw new Error('group mismatch');
      }
      const groupEntry: VpnOpaqueCatalogEntry | undefined = this.findGroupById(payload.groupId);
      if (groupEntry === undefined) {
        throw new Error('delay group missing');
      }
      const nodes = this.mapDelayNodes(groupEntry, payload.results);
      return this.createDelaySnapshot(identity, payload, groupEntry, nodes);
    } catch {
      return this.rejectDelayFailed();
    }
  }

  private createDelaySnapshot(
    identity: ProxyRuntimeIdentity,
    payload: VpnRpcDelaySnapshotPayload,
    groupEntry: VpnOpaqueCatalogEntry,
    nodes: ProxyDelayNodeResult[]
  ): ProxyDelayResult {
    let availableCount: number = 0;
    let timeoutCount: number = 0;
    let failedCount: number = 0;
    let cancelledCount: number = 0;
    let unsupportedCount: number = 0;
    let completedCount: number = 0;
    for (let index: number = 0; index < nodes.length; index += 1) {
      if (nodes[index].state === 'AVAILABLE') {
        availableCount += 1;
        completedCount += 1;
      } else if (nodes[index].state === 'TIMEOUT') {
        timeoutCount += 1;
        completedCount += 1;
      } else if (nodes[index].state === 'FAILED') {
        failedCount += 1;
        completedCount += 1;
      } else if (nodes[index].state === 'CANCELLED') {
        cancelledCount += 1;
        completedCount += 1;
      } else if (nodes[index].state === 'UNSUPPORTED') {
        unsupportedCount += 1;
        completedCount += 1;
      }
    }
    return createProxyDelaySnapshotResult(
      identity,
      payload.proxyGeneration,
      groupEntry.localName,
      payload.jobId,
      payload.state,
      payload.totalCount,
      payload.totalCount - unsupportedCount,
      completedCount,
      availableCount,
      timeoutCount,
      failedCount,
      cancelledCount,
      unsupportedCount,
      this.findFastestNodeIndex(nodes),
      nodes
    );
  }

  private mapDelayNodes(groupEntry: VpnOpaqueCatalogEntry, results: VpnRpcDelayResult[]): ProxyDelayNodeResult[] {
    const terminalIds: string[] = this.listTerminalChildIds(groupEntry);
    if (results.length !== terminalIds.length) {
      throw new Error('delay node count mismatch');
    }
    const seenIds: Set<string> = new Set<string>();
    let fastestIndex: number | null = null;
    let fastestDelayMs: number | null = null;
    const rawNodes: DelayNodeDraft[] = [];
    for (let index: number = 0; index < results.length; index += 1) {
      const result: VpnRpcDelayResult = results[index];
      if (seenIds.has(result.nodeId)) {
        throw new Error('duplicate delay node id');
      }
      seenIds.add(result.nodeId);
      const entry: VpnOpaqueCatalogEntry | undefined = this.findChildById(groupEntry, result.nodeId, 'TERMINAL');
      if (entry === undefined) {
        throw new Error('unknown delay node id');
      }
      rawNodes.push(new DelayNodeDraft(entry, result.status, result.delayMs));
      if (result.status === 'AVAILABLE' && result.delayMs !== null &&
        (fastestDelayMs === null || result.delayMs < fastestDelayMs)) {
        fastestDelayMs = result.delayMs;
        fastestIndex = index;
      }
    }
    const nodes: ProxyDelayNodeResult[] = [];
    for (let index: number = 0; index < rawNodes.length; index += 1) {
      nodes.push(
        createProxyDelayNodeResult(
          index,
          rawNodes[index].entry.localName,
          this.requireCoreProxyType(rawNodes[index].entry.type),
          rawNodes[index].status,
          rawNodes[index].delayMs,
          fastestIndex === index
        )
      );
    }
    return nodes;
  }

  private findFastestNodeIndex(nodes: ProxyDelayNodeResult[]): number | null {
    for (let index: number = 0; index < nodes.length; index += 1) {
      if (nodes[index].fastest) {
        return index;
      }
    }
    return null;
  }

  private createGroupSnapshotFromQueryPayload(
    command: VpnProxyQueryGroupCommand,
    groupEntry: VpnOpaqueCatalogEntry,
    payload: VpnRpcQueryGroupPayload
  ): ProxyGroupSnapshot {
    const selectedEntry: VpnOpaqueCatalogEntry | undefined =
      payload.selectedNodeId === null
        ? undefined
        : this.findChildById(groupEntry, payload.selectedNodeId, 'GROUP')
          ?? this.findChildById(groupEntry, payload.selectedNodeId, 'TERMINAL');
    if (selectedEntry === undefined) {
      throw new Error('selected node missing');
    }
    const seenIds: Set<string> = new Set<string>();
    let selectedCount: number = 0;
    let selectedNodeMatched: boolean = false;
    if (payload.nodes.length !== groupEntry.childIds.length) {
      throw new Error('group node count mismatch');
    }
    const nodes: CoreProxyNodeSummary[] = [];
    for (let index: number = 0; index < payload.nodes.length; index += 1) {
      const node: VpnRpcGroupNode = payload.nodes[index];
      if (seenIds.has(node.nodeId)) {
        throw new Error('duplicate group node id');
      }
      seenIds.add(node.nodeId);
      const entry: VpnOpaqueCatalogEntry | undefined = this.findChildById(groupEntry, node.nodeId, node.kind);
      if (entry === undefined || entry.type !== node.type) {
        throw new Error('unknown group node');
      }
      if (node.selected) {
        selectedCount += 1;
        selectedNodeMatched = node.nodeId === selectedEntry.id;
      }
      nodes.push(
        new CoreProxyNodeSummaryValue(
          entry.localName,
          this.requireCoreProxyType(entry.type),
          entry.kind === 'GROUP',
          entry.id === selectedEntry.id
        )
      );
    }
    if (selectedCount !== 1 || !selectedNodeMatched) {
      throw new Error('selected node mismatch');
    }
    return createProxyGroupSnapshot(
      command.identity,
      payload.proxyGeneration,
      new CoreProxyGroupSnapshotValue(
        groupEntry.localName,
        this.requireCoreProxyType(groupEntry.type),
        selectedEntry.localName,
        nodes
      )
    );
  }

  private createStaticGroupSnapshot(
    command: VpnProxySelectCommand,
    groupEntry: VpnOpaqueCatalogEntry,
    selectedNodeId: string
  ): ProxyGroupSnapshot {
    const selectedEntry: VpnOpaqueCatalogEntry | undefined = this.findChildById(groupEntry, selectedNodeId, 'TERMINAL');
    if (selectedEntry === undefined) {
      throw new Error('selected node missing');
    }
    const nodes: CoreProxyNodeSummary[] = [];
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(groupEntry.childIds[index]);
      if (entry === undefined) {
        throw new Error('missing child entry');
      }
      nodes.push(
        new CoreProxyNodeSummaryValue(
          entry.localName,
          this.requireCoreProxyType(entry.type),
          entry.kind === 'GROUP',
          entry.kind === 'TERMINAL' && entry.id === selectedEntry.id
        )
      );
    }
    return createProxyGroupSnapshot(
      command.identity,
      command.generation,
      new CoreProxyGroupSnapshotValue(
        groupEntry.localName,
        this.requireCoreProxyType(groupEntry.type),
        selectedEntry.localName,
        nodes
      )
    );
  }

  private mapQueryGroupsPayload(groups: VpnRpcGroupRef[]): CoreProxyGroupRef[] {
    const seenIds: Set<string> = new Set<string>();
    const mapped: CoreProxyGroupRef[] = [];
    for (let index: number = 0; index < groups.length; index += 1) {
      const group: VpnRpcGroupRef = groups[index];
      if (seenIds.has(group.groupId)) {
        throw new Error('duplicate group id');
      }
      seenIds.add(group.groupId);
      const entry: VpnOpaqueCatalogEntry | undefined = this.findTopLevelGroupById(group.groupId);
      if (entry === undefined || entry.type !== group.type) {
        throw new Error('unknown top-level group');
      }
      mapped.push(new CoreProxyGroupRefValue(entry.localName, this.requireCoreProxyType(entry.type)));
    }
    return mapped;
  }

  private requireCoreProxyType(value: string): CoreProxyType {
    switch (value) {
      case 'Direct':
      case 'Reject':
      case 'RejectDrop':
      case 'Compatible':
      case 'Pass':
      case 'PassRule':
      case 'Rematch':
      case 'Dns':
      case 'Relay':
      case 'Selector':
      case 'Fallback':
      case 'URLTest':
      case 'LoadBalance':
      case 'Shadowsocks':
      case 'ShadowsocksR':
      case 'Snell':
      case 'Socks5':
      case 'Http':
      case 'Vmess':
      case 'Vless':
      case 'Trojan':
      case 'Hysteria':
      case 'Hysteria2':
      case 'WireGuard':
      case 'Tuic':
      case 'Ssh':
      case 'Mieru':
      case 'AnyTLS':
      case 'Sudoku':
      case 'Masque':
      case 'TrustTunnel':
      case 'ShadowQuic':
      case 'OpenVPN':
      case 'Tailscale':
      case 'GostRelay':
        return value;
      default:
        throw new Error('proxy type mismatch');
    }
  }

  private createActiveGuards(): VpnRpcGuards {
    return createVpnRpcGuards(this.catalog.profileHash, this.catalog.revisionHash, this.catalog.catalogDigest);
  }

  private matchesCatalogRevision(revisionHash: string): boolean {
    return revisionHash === this.catalog.revisionHash;
  }

  private isClientReadyForRunningRoute(): boolean {
    if (this.client.state() !== 'READY') {
      return false;
    }
    return this.client.snapshot().state === 'RUNNING';
  }

  private requireGenerationMatch(responseGeneration: number, payloadGeneration: number, expectedGeneration: number): void {
    if (responseGeneration !== expectedGeneration || payloadGeneration !== expectedGeneration) {
      throw new Error('generation mismatch');
    }
  }

  private readRejectedResponse(
    response: VpnRpcBody,
    method: VpnRpcMethod,
    generation: number,
    staleOnCatalogMismatch: boolean,
    fallbackCode: ProxyRejectedErrorCode
  ): ProxyRejectedResult | null {
    try {
      this.requireResponseShape(response, method, generation);
    } catch {
      return this.reject(fallbackCode, fallbackCode === 'PROXY_QUERY_FAILED' || fallbackCode === 'PROXY_DELAY_TEST_FAILED');
    }
    if (response.ok === false && response.error !== null) {
      return this.mapRpcError(response.error.code, staleOnCatalogMismatch, fallbackCode);
    }
    if (response.ok !== true || response.error !== null) {
      return this.reject(fallbackCode, fallbackCode === 'PROXY_QUERY_FAILED' || fallbackCode === 'PROXY_DELAY_TEST_FAILED');
    }
    return null;
  }

  private requireResponseShape(response: VpnRpcBody, method: VpnRpcMethod, generation: number): void {
    if (response.kind !== 'RESPONSE' ||
      response.method !== method ||
      !this.guardsEqual(response.guards, this.createActiveGuards()) ||
      response.sessionGeneration !== generation ||
      ((response.ok === true) === (response.ok === false))) {
      throw new Error('response mismatch');
    }
  }

  private guardsEqual(left: VpnRpcGuards, right: VpnRpcGuards): boolean {
    return left.profileHash === right.profileHash &&
      left.revisionHash === right.revisionHash &&
      left.catalogDigest === right.catalogDigest;
  }

  private mapRpcError(
    code: string,
    staleOnCatalogMismatch: boolean,
    fallbackCode: ProxyRejectedErrorCode
  ): ProxyRejectedResult {
    if (code === 'SESSION_CHANGED') {
      return this.rejectSessionChanged();
    }
    if (code === 'CATALOG_MISMATCH' && staleOnCatalogMismatch) {
      return this.rejectSelectionStale();
    }
    return this.reject(fallbackCode, fallbackCode === 'PROXY_QUERY_FAILED' || fallbackCode === 'PROXY_DELAY_TEST_FAILED');
  }

  private mapQueryThrown(error: Object): ProxyRejectedResult {
    if (this.isSessionChangedFailure(error)) {
      return this.rejectSessionChanged();
    }
    return this.rejectQueryFailed();
  }

  private mapSelectThrown(error: Object): ProxyRejectedResult {
    if (this.isSessionChangedFailure(error)) {
      return this.rejectSessionChanged();
    }
    return this.rejectSelectionFailed();
  }

  private mapDelayThrown(error: Object): ProxyRejectedResult {
    if (this.isSessionChangedFailure(error)) {
      return this.rejectSessionChanged();
    }
    return this.rejectDelayFailed();
  }

  private isSessionChangedFailure(error: Object): boolean {
    return error instanceof VpnRpcTransportFailure && error.code === 'SESSION_CHANGED';
  }

  private reject(code: ProxyRejectedErrorCode, retryable: boolean): ProxyRejectedResult {
    return createProxyRejectedResult(createProxyRejectedError(code, retryable, this.clock.now()));
  }

  private rejectQueryFailed(): ProxyRejectedResult {
    return this.reject('PROXY_QUERY_FAILED', true);
  }

  private rejectQueryClosed(): ProxyRejectedResult {
    return this.reject('PROXY_QUERY_FAILED', false);
  }

  private rejectSelectionStale(): ProxyRejectedResult {
    return this.reject('PROXY_SELECTION_STALE', false);
  }

  private rejectSelectionFailed(): ProxyRejectedResult {
    return this.reject('PROXY_SELECTION_FAILED', false);
  }

  private rejectDelayFailed(): ProxyRejectedResult {
    return this.reject('PROXY_DELAY_TEST_FAILED', true);
  }

  private rejectSessionChanged(): ProxyRejectedResult {
    return this.reject('VPN_SESSION_CHANGED', false);
  }

  private findUniqueTopLevelGroupByName(groupName: string): VpnOpaqueCatalogEntry | undefined {
    const matches: VpnOpaqueCatalogEntry[] = [];
    const ids: string[] = this.catalog.topLevelGroupIds();
    for (let index: number = 0; index < ids.length; index += 1) {
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(ids[index]);
      if (entry !== undefined && entry.kind === 'GROUP' && entry.localName === groupName) {
        matches.push(entry);
      }
    }
    return matches.length === 1 ? matches[0] : undefined;
  }

  private resolveGroupPath(groupPath: string[]): VpnOpaqueCatalogEntry | undefined {
    const firstSegment: string | undefined = groupPath[0];
    if (firstSegment === undefined) {
      return undefined;
    }
    let current: VpnOpaqueCatalogEntry | undefined = this.findUniqueTopLevelGroupByName(firstSegment);
    if (current === undefined) {
      return undefined;
    }
    for (let index: number = 1; index < groupPath.length; index += 1) {
      current = this.findUniqueChildByName(current, groupPath[index], 'GROUP');
      if (current === undefined) {
        return undefined;
      }
    }
    return current;
  }

  private findTopLevelGroupById(groupId: string): VpnOpaqueCatalogEntry | undefined {
    const ids: string[] = this.catalog.topLevelGroupIds();
    for (let index: number = 0; index < ids.length; index += 1) {
      if (ids[index] !== groupId) {
        continue;
      }
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(ids[index]);
      if (entry !== undefined && entry.kind === 'GROUP') {
        return entry;
      }
    }
    return undefined;
  }

  private findGroupById(groupId: string): VpnOpaqueCatalogEntry | undefined {
    const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(groupId);
    if (entry === undefined || entry.kind !== 'GROUP') {
      return undefined;
    }
    return entry;
  }

  private findUniqueChildByName(
    groupEntry: VpnOpaqueCatalogEntry,
    name: string,
    kind: 'GROUP' | 'TERMINAL'
  ): VpnOpaqueCatalogEntry | undefined {
    const matches: VpnOpaqueCatalogEntry[] = [];
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(groupEntry.childIds[index]);
      if (entry !== undefined && entry.kind === kind && entry.localName === name) {
        matches.push(entry);
      }
    }
    return matches.length === 1 ? matches[0] : undefined;
  }

  private findChildById(
    groupEntry: VpnOpaqueCatalogEntry,
    childId: string,
    kind: 'GROUP' | 'TERMINAL'
  ): VpnOpaqueCatalogEntry | undefined {
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      if (groupEntry.childIds[index] !== childId) {
        continue;
      }
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(childId);
      if (entry !== undefined && entry.kind === kind) {
        return entry;
      }
      return undefined;
    }
    return undefined;
  }

  private listTerminalChildIds(groupEntry: VpnOpaqueCatalogEntry): string[] {
    const ids: string[] = [];
    for (let index: number = 0; index < groupEntry.childIds.length; index += 1) {
      const entry: VpnOpaqueCatalogEntry | undefined = this.catalog.resolveEntry(groupEntry.childIds[index]);
      if (entry !== undefined && entry.kind === 'TERMINAL') {
        ids.push(entry.id);
      }
    }
    return ids;
  }
}
