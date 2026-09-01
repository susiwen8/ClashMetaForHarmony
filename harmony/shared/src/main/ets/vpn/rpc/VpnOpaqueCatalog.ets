import { normalizeProxyLabel } from '../../proxy/ProxyModels';
import {
  decodeVpnRpcLowercaseHex,
  encodeVpnRpcLowercaseHex,
  encodeVpnRpcU16BE,
  encodeVpnRpcU32BE,
  encodeVpnRpcUtf8
} from './VpnRpcBinaryCodec';
import type { VpnRpcCryptoPort } from './VpnRpcPorts';

const ROOT_PARENT_HEX: string =
  '0000000000000000000000000000000000000000000000000000000000000000';
const HMAC_BYTES: number = 32;
const MAX_DEPTH: number = 16;
const MAX_ENTRIES: number = 4096;
const VPN_RPC_CATALOG_MISMATCH_MESSAGE: string = 'VPN RPC catalog mismatch.';
const HASH_PATTERN: RegExp = /^[0-9a-f]{64}$/;
const TYPE_CODES: string[] = [
  'Direct',
  'Reject',
  'RejectDrop',
  'Compatible',
  'Pass',
  'PassRule',
  'Rematch',
  'Dns',
  'Relay',
  'Selector',
  'Fallback',
  'URLTest',
  'LoadBalance',
  'Shadowsocks',
  'ShadowsocksR',
  'Snell',
  'Socks5',
  'Http',
  'Vmess',
  'Vless',
  'Trojan',
  'Hysteria',
  'Hysteria2',
  'WireGuard',
  'Tuic',
  'Ssh',
  'Mieru',
  'AnyTLS',
  'Sudoku',
  'Masque',
  'TrustTunnel',
  'ShadowQuic',
  'OpenVPN',
  'Tailscale',
  'GostRelay'
];
const KIND_GROUP_CODE: number = 1;
const KIND_TERMINAL_CODE: number = 2;
const EDGE_NORMAL_CODE: number = 1;
const EDGE_CYCLE_UNSUPPORTED_CODE: number = 2;
const CATALOG_SALT_LABEL: string = 'CMFA-VPN-RPC/CATALOG-SALT/v1';
const GROUP_ID_LABEL: string = 'CMFA-VPN-RPC/GROUP-ID/v1';
const NODE_ID_LABEL: string = 'CMFA-VPN-RPC/NODE-ID/v1';
const DIGEST_LABEL: string = 'CMFA-VPN-RPC/CATALOG-DIGEST/v1';

export type VpnOpaqueCatalogKind = 'GROUP' | 'TERMINAL';
export type VpnOpaqueCatalogEdgeState = 'NORMAL' | 'CYCLE_UNSUPPORTED';

export interface VpnCatalogGroupInput {
  name: string;
  type: string;
  members: VpnCatalogMemberInput[];
}

export interface VpnCatalogGroupMemberInput {
  kind: 'GROUP';
  group: VpnCatalogGroupInput;
}

export interface VpnCatalogTerminalMemberInput {
  kind: 'TERMINAL';
  name: string;
  type: string;
}

export type VpnCatalogMemberInput = VpnCatalogGroupMemberInput | VpnCatalogTerminalMemberInput;

export interface VpnOpaqueCatalogWireEntry {
  id: string;
  parentId: string;
  kind: VpnOpaqueCatalogKind;
  type: string;
  depth: number;
  memberIndex: number;
  edgeState: VpnOpaqueCatalogEdgeState;
}

export interface VpnOpaqueCatalogEntry extends VpnOpaqueCatalogWireEntry {
  localName: string;
  childIds: string[];
}

export interface VpnOpaqueCatalog {
  readonly profileHash: string;
  readonly revisionHash: string;
  readonly catalogDigest: string;
  readonly entryCount: number;
  wireEntries(): VpnOpaqueCatalogWireEntry[];
  topLevelGroupIds(): string[];
  resolveLocalName(id: string): string | undefined;
  resolveEntry(id: string): VpnOpaqueCatalogEntry | undefined;
}

export class VpnOpaqueCatalogError extends Error {
  code: 'CATALOG_MISMATCH';
  retryable: false;

  constructor() {
    super(VPN_RPC_CATALOG_MISMATCH_MESSAGE);
    this.code = 'CATALOG_MISMATCH';
    this.retryable = false;
  }
}

type CatalogSnapshotMemberKind = 'GROUP' | 'TERMINAL';

class CatalogTerminalMemberSnapshot {
  readonly kind: CatalogSnapshotMemberKind = 'TERMINAL';
  readonly normalizedName: string;
  readonly normalizedType: string;

  constructor(normalizedName: string, normalizedType: string) {
    this.normalizedName = normalizedName;
    this.normalizedType = normalizedType;
  }
}

class CatalogGroupSnapshot {
  readonly normalizedName: string;
  readonly normalizedType: string;
  private membersInternal: CatalogMemberSnapshot[] = [];

  constructor(normalizedName: string, normalizedType: string) {
    this.normalizedName = normalizedName;
    this.normalizedType = normalizedType;
  }

  replaceMembers(members: CatalogMemberSnapshot[]): void {
    this.membersInternal = members.slice();
  }

  members(): CatalogMemberSnapshot[] {
    return this.membersInternal.slice();
  }
}

class CatalogGroupMemberSnapshot {
  readonly kind: CatalogSnapshotMemberKind = 'GROUP';
  readonly group: CatalogGroupSnapshot;

  constructor(group: CatalogGroupSnapshot) {
    this.group = group;
  }
}

type CatalogMemberSnapshot = CatalogGroupMemberSnapshot | CatalogTerminalMemberSnapshot;

class CatalogSnapshotState {
  readonly groups: Map<VpnCatalogGroupInput, CatalogGroupSnapshot> = new Map<VpnCatalogGroupInput, CatalogGroupSnapshot>();
  readonly memberDefinitions: Set<VpnCatalogMemberInput> = new Set<VpnCatalogMemberInput>();
  definitionCount: number = 0;
}

class VpnOpaqueCatalogWireEntryValue implements VpnOpaqueCatalogWireEntry {
  id: string;
  parentId: string;
  kind: VpnOpaqueCatalogKind;
  type: string;
  depth: number;
  memberIndex: number;
  edgeState: VpnOpaqueCatalogEdgeState;

  constructor(
    id: string,
    parentId: string,
    kind: VpnOpaqueCatalogKind,
    type: string,
    depth: number,
    memberIndex: number,
    edgeState: VpnOpaqueCatalogEdgeState
  ) {
    this.id = id;
    this.parentId = parentId;
    this.kind = kind;
    this.type = type;
    this.depth = depth;
    this.memberIndex = memberIndex;
    this.edgeState = edgeState;
  }
}

class VpnOpaqueCatalogEntryValue extends VpnOpaqueCatalogWireEntryValue implements VpnOpaqueCatalogEntry {
  localName: string;
  childIds: string[];

  constructor(
    id: string,
    parentId: string,
    kind: VpnOpaqueCatalogKind,
    type: string,
    depth: number,
    memberIndex: number,
    edgeState: VpnOpaqueCatalogEdgeState,
    localName: string,
    childIds: string[]
  ) {
    super(id, parentId, kind, type, depth, memberIndex, edgeState);
    this.localName = localName;
    this.childIds = childIds.slice();
  }
}

class InternalCatalogEntry {
  readonly id: string;
  readonly parentId: string;
  readonly kind: VpnOpaqueCatalogKind;
  readonly type: string;
  readonly depth: number;
  readonly memberIndex: number;
  readonly edgeState: VpnOpaqueCatalogEdgeState;
  readonly localName: string;
  readonly childIds: string[] = [];

  constructor(
    id: string,
    parentId: string,
    kind: VpnOpaqueCatalogKind,
    type: string,
    depth: number,
    memberIndex: number,
    edgeState: VpnOpaqueCatalogEdgeState,
    localName: string
  ) {
    this.id = id;
    this.parentId = parentId;
    this.kind = kind;
    this.type = type;
    this.depth = depth;
    this.memberIndex = memberIndex;
    this.edgeState = edgeState;
    this.localName = localName;
  }

  addChildId(childId: string): void {
    this.childIds.push(childId);
  }

  toWireCopy(): VpnOpaqueCatalogWireEntry {
    return new VpnOpaqueCatalogWireEntryValue(
      this.id,
      this.parentId,
      this.kind,
      this.type,
      this.depth,
      this.memberIndex,
      this.edgeState
    );
  }

  toLocalCopy(): VpnOpaqueCatalogEntry {
    return new VpnOpaqueCatalogEntryValue(
      this.id,
      this.parentId,
      this.kind,
      this.type,
      this.depth,
      this.memberIndex,
      this.edgeState,
      this.localName,
      this.childIds
    );
  }
}

class VpnOpaqueCatalogValue implements VpnOpaqueCatalog {
  readonly profileHash: string;
  readonly revisionHash: string;
  readonly catalogDigest: string;
  readonly entryCount: number;
  private readonly orderedEntries: InternalCatalogEntry[];
  private readonly topLevelIdsInternal: string[];
  private readonly entryMap: Map<string, InternalCatalogEntry>;

  constructor(profileHash: string, revisionHash: string, catalogDigest: string, orderedEntries: InternalCatalogEntry[], topLevelIds: string[]) {
    this.profileHash = profileHash;
    this.revisionHash = revisionHash;
    this.catalogDigest = catalogDigest;
    this.entryCount = orderedEntries.length;
    this.orderedEntries = orderedEntries.slice();
    this.topLevelIdsInternal = topLevelIds.slice();
    this.entryMap = new Map<string, InternalCatalogEntry>();
    for (let index: number = 0; index < this.orderedEntries.length; index += 1) {
      const entry: InternalCatalogEntry = this.orderedEntries[index];
      this.entryMap.set(entry.id, entry);
    }
  }

  wireEntries(): VpnOpaqueCatalogWireEntry[] {
    const copies: VpnOpaqueCatalogWireEntry[] = [];
    for (let index: number = 0; index < this.orderedEntries.length; index += 1) {
      copies.push(this.orderedEntries[index].toWireCopy());
    }
    return copies;
  }

  topLevelGroupIds(): string[] {
    return this.topLevelIdsInternal.slice();
  }

  resolveLocalName(id: string): string | undefined {
    const entry: InternalCatalogEntry | undefined = this.entryMap.get(id);
    return entry === undefined ? undefined : entry.localName;
  }

  resolveEntry(id: string): VpnOpaqueCatalogEntry | undefined {
    const entry: InternalCatalogEntry | undefined = this.entryMap.get(id);
    return entry === undefined ? undefined : entry.toLocalCopy();
  }
}

class CatalogBuilder {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly catalogSaltHex: string;
  private readonly orderedEntries: InternalCatalogEntry[] = [];
  private readonly topLevelIds: string[] = [];
  private readonly ids: Set<string> = new Set<string>();

  constructor(crypto: VpnRpcCryptoPort, catalogSaltHex: string) {
    this.crypto = crypto;
    this.catalogSaltHex = catalogSaltHex;
  }

  async appendTopLevelGroups(groups: CatalogGroupSnapshot[]): Promise<void> {
    for (let index: number = 0; index < groups.length; index += 1) {
      const topLevelId: string = await this.appendGroup(groups[index], ROOT_PARENT_HEX, 0, index, []);
      this.topLevelIds.push(topLevelId);
    }
  }

  buildCatalog(profileHash: string, revisionHash: string, catalogDigest: string): VpnOpaqueCatalog {
    return new VpnOpaqueCatalogValue(profileHash, revisionHash, catalogDigest, this.orderedEntries, this.topLevelIds);
  }

  orderedEntryCount(): number {
    return this.orderedEntries.length;
  }

  orderedEntryAt(index: number): InternalCatalogEntry {
    return this.orderedEntries[index];
  }

  private async appendGroup(
    group: CatalogGroupSnapshot,
    parentIdHex: string,
    depth: number,
    memberIndex: number,
    ancestors: CatalogGroupSnapshot[]
  ): Promise<string> {
    requireDepth(depth);
    const groupIdHex: string = await computeGroupIdHex(
      this.crypto,
      this.catalogSaltHex,
      parentIdHex,
      memberIndex,
      group.normalizedName,
      group.normalizedType
    );
    const entry: InternalCatalogEntry = new InternalCatalogEntry(
      groupIdHex,
      parentIdHex,
      'GROUP',
      group.normalizedType,
      depth,
      memberIndex,
      'NORMAL',
      group.normalizedName
    );
    this.appendEntry(entry);
    const safeMembers: CatalogMemberSnapshot[] = group.members();
    const nextAncestors: CatalogGroupSnapshot[] = ancestors.slice();
    nextAncestors.push(group);
    for (let index: number = 0; index < safeMembers.length; index += 1) {
      const childId: string = await this.appendMember(safeMembers[index], entry, depth + 1, index, nextAncestors);
      entry.addChildId(childId);
    }
    return groupIdHex;
  }

  private async appendMember(
    member: CatalogMemberSnapshot,
    parentEntry: InternalCatalogEntry,
    depth: number,
    memberIndex: number,
    ancestors: CatalogGroupSnapshot[]
  ): Promise<string> {
    requireDepth(depth);
    if (member.kind === 'GROUP') {
      const groupMember: CatalogGroupMemberSnapshot = member as CatalogGroupMemberSnapshot;
      const childGroup: CatalogGroupSnapshot = groupMember.group;
      if (containsAncestor(ancestors, childGroup)) {
        return this.appendCycleEdge(childGroup, parentEntry.id, depth, memberIndex);
      }
      return this.appendGroup(childGroup, parentEntry.id, depth, memberIndex, ancestors);
    }
    if (member.kind === 'TERMINAL') {
      const terminalMember: CatalogTerminalMemberSnapshot = member as CatalogTerminalMemberSnapshot;
      return this.appendTerminal(
        parentEntry.id,
        depth,
        memberIndex,
        terminalMember.normalizedName,
        terminalMember.normalizedType,
        'NORMAL'
      );
    }
    catalogMismatch();
  }

  private async appendCycleEdge(
    group: CatalogGroupSnapshot,
    parentIdHex: string,
    depth: number,
    memberIndex: number
  ): Promise<string> {
    return this.appendTerminal(
      parentIdHex,
      depth,
      memberIndex,
      group.normalizedName,
      group.normalizedType,
      'CYCLE_UNSUPPORTED'
    );
  }

  private async appendTerminal(
    parentIdHex: string,
    depth: number,
    memberIndex: number,
    normalizedName: string,
    normalizedType: string,
    edgeState: VpnOpaqueCatalogEdgeState
  ): Promise<string> {
    const nodeIdHex: string = await computeNodeIdHex(
      this.crypto,
      this.catalogSaltHex,
      parentIdHex,
      memberIndex,
      normalizedName,
      normalizedType
    );
    const entry: InternalCatalogEntry = new InternalCatalogEntry(
      nodeIdHex,
      parentIdHex,
      'TERMINAL',
      normalizedType,
      depth,
      memberIndex,
      edgeState,
      normalizedName
    );
    this.appendEntry(entry);
    return nodeIdHex;
  }

  private appendEntry(entry: InternalCatalogEntry): void {
    if (this.orderedEntries.length >= MAX_ENTRIES) {
      catalogMismatch();
    }
    if (this.ids.has(entry.id)) {
      catalogMismatch();
    }
    this.ids.add(entry.id);
    this.orderedEntries.push(entry);
  }
}

function catalogMismatch(): never {
  throw new VpnOpaqueCatalogError();
}

function requireString(value: string): string {
  if (typeof value !== 'string') {
    catalogMismatch();
  }
  return value;
}

function requireDepth(depth: number): void {
  if (!Number.isSafeInteger(depth) || depth < 0 || depth > MAX_DEPTH) {
    catalogMismatch();
  }
}

function containsAncestor(ancestors: CatalogGroupSnapshot[], target: CatalogGroupSnapshot): boolean {
  for (let index: number = 0; index < ancestors.length; index += 1) {
    if (ancestors[index] === target) {
      return true;
    }
  }
  return false;
}

function requireGroupReference(group: VpnCatalogGroupInput): VpnCatalogGroupInput {
  if (group === null || group === undefined || typeof group !== 'object') {
    catalogMismatch();
  }
  return group;
}

function requireMemberReference(member: VpnCatalogMemberInput): VpnCatalogMemberInput {
  if (member === null || member === undefined || typeof member !== 'object') {
    catalogMismatch();
  }
  return member;
}

function snapshotDefinition(state: CatalogSnapshotState): void {
  state.definitionCount += 1;
  if (state.definitionCount > MAX_ENTRIES) {
    catalogMismatch();
  }
}

function readGroupName(group: VpnCatalogGroupInput): string {
  try {
    return requireString(group.name);
  } catch (_error) {
    catalogMismatch();
  }
}

function readGroupType(group: VpnCatalogGroupInput): string {
  try {
    return requireString(group.type);
  } catch (_error) {
    catalogMismatch();
  }
}

function readGroupMembers(group: VpnCatalogGroupInput): VpnCatalogMemberInput[] {
  let rawMembers: VpnCatalogMemberInput[];
  try {
    rawMembers = group.members;
  } catch (_error) {
    catalogMismatch();
  }
  if (!Array.isArray(rawMembers)) {
    catalogMismatch();
  }
  const copiedMembers: VpnCatalogMemberInput[] = [];
  let length: number = 0;
  try {
    length = rawMembers.length;
  } catch (_error) {
    catalogMismatch();
  }
  for (let index: number = 0; index < length; index += 1) {
    try {
      copiedMembers.push(rawMembers[index]);
    } catch (_error) {
      catalogMismatch();
    }
  }
  return copiedMembers;
}

function readMemberKind(member: VpnCatalogMemberInput): 'GROUP' | 'TERMINAL' {
  try {
    const kind: string = requireString(member.kind as string);
    if (kind === 'GROUP' || kind === 'TERMINAL') {
      return kind;
    }
  } catch (_error) {
    catalogMismatch();
  }
  catalogMismatch();
}

function readMemberGroup(member: VpnCatalogGroupMemberInput): VpnCatalogGroupInput {
  try {
    return requireGroupReference(member.group);
  } catch (_error) {
    catalogMismatch();
  }
}

function readTerminalName(member: VpnCatalogTerminalMemberInput): string {
  try {
    return requireString(member.name);
  } catch (_error) {
    catalogMismatch();
  }
}

function readTerminalType(member: VpnCatalogTerminalMemberInput): string {
  try {
    return requireString(member.type);
  } catch (_error) {
    catalogMismatch();
  }
}

function snapshotMember(member: VpnCatalogMemberInput, state: CatalogSnapshotState): CatalogMemberSnapshot {
  const safeMember: VpnCatalogMemberInput = requireMemberReference(member);
  if (!state.memberDefinitions.has(safeMember)) {
    state.memberDefinitions.add(safeMember);
    snapshotDefinition(state);
  }
  const kind: 'GROUP' | 'TERMINAL' = readMemberKind(safeMember);
  if (kind === 'GROUP') {
    return new CatalogGroupMemberSnapshot(snapshotGroup(readMemberGroup(safeMember as VpnCatalogGroupMemberInput), state));
  }
  return new CatalogTerminalMemberSnapshot(
    normalizeCatalogName(readTerminalName(safeMember as VpnCatalogTerminalMemberInput), 'VPN opaque catalog node name'),
    normalizeCatalogType(readTerminalType(safeMember as VpnCatalogTerminalMemberInput))
  );
}

function snapshotGroup(group: VpnCatalogGroupInput, state: CatalogSnapshotState): CatalogGroupSnapshot {
  const safeGroup: VpnCatalogGroupInput = requireGroupReference(group);
  const existing: CatalogGroupSnapshot | undefined = state.groups.get(safeGroup);
  if (existing !== undefined) {
    return existing;
  }
  snapshotDefinition(state);
  const snapshot: CatalogGroupSnapshot = new CatalogGroupSnapshot(
    normalizeCatalogName(readGroupName(safeGroup), 'VPN opaque catalog group name'),
    normalizeCatalogType(readGroupType(safeGroup))
  );
  state.groups.set(safeGroup, snapshot);
  const rawMembers: VpnCatalogMemberInput[] = readGroupMembers(safeGroup);
  const memberSnapshots: CatalogMemberSnapshot[] = [];
  for (let index: number = 0; index < rawMembers.length; index += 1) {
    memberSnapshots.push(snapshotMember(rawMembers[index], state));
  }
  snapshot.replaceMembers(memberSnapshots);
  return snapshot;
}

function snapshotTopLevelGroups(groups: VpnCatalogGroupInput[]): CatalogGroupSnapshot[] {
  const state: CatalogSnapshotState = new CatalogSnapshotState();
  if (!Array.isArray(groups)) {
    catalogMismatch();
  }
  const snapshots: CatalogGroupSnapshot[] = [];
  let length: number = 0;
  try {
    length = groups.length;
  } catch (_error) {
    catalogMismatch();
  }
  for (let index: number = 0; index < length; index += 1) {
    let group: VpnCatalogGroupInput;
    try {
      group = groups[index];
    } catch (_error) {
      catalogMismatch();
    }
    snapshots.push(snapshotGroup(group, state));
  }
  return snapshots;
}

function normalizeCatalogHash(rawValue: string, label: string): string {
  if (!HASH_PATTERN.test(rawValue)) {
    catalogMismatch();
  }
  return rawValue;
}

function normalizeCatalogName(rawValue: string, label: string): string {
  try {
    return normalizeProxyLabel(rawValue.trim(), label);
  } catch (_error) {
    catalogMismatch();
  }
}

function normalizeCatalogType(rawValue: string): string {
  for (let index: number = 0; index < TYPE_CODES.length; index += 1) {
    if (TYPE_CODES[index] === rawValue) {
      return rawValue;
    }
  }
  catalogMismatch();
}

function typeCode(rawValue: string): number {
  for (let index: number = 0; index < TYPE_CODES.length; index += 1) {
    if (TYPE_CODES[index] === rawValue) {
      return index + 1;
    }
  }
  catalogMismatch();
}

function kindCode(kind: VpnOpaqueCatalogKind): number {
  return kind === 'GROUP' ? KIND_GROUP_CODE : KIND_TERMINAL_CODE;
}

function edgeStateCode(edgeState: VpnOpaqueCatalogEdgeState): number {
  return edgeState === 'NORMAL' ? EDGE_NORMAL_CODE : EDGE_CYCLE_UNSUPPORTED_CODE;
}

function joinBytes(parts: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    totalLength += parts[index].length;
  }
  const result: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    result.set(parts[index], offset);
    offset += parts[index].length;
  }
  return result;
}

function lpBytes(bytes: Uint8Array): Uint8Array {
  return joinBytes([encodeVpnRpcU32BE(bytes.length), bytes]);
}

function zeroBytes(bytes: Uint8Array | null): void {
  if (bytes !== null) {
    bytes.fill(0);
  }
}

function requireOwnedHmac(bytes: Uint8Array): Uint8Array {
  const copied: Uint8Array = bytes.slice();
  zeroBytes(bytes);
  if (copied.length !== HMAC_BYTES) {
    zeroBytes(copied);
    catalogMismatch();
  }
  return copied;
}

async function computeOwnedRootHmac(crypto: VpnRpcCryptoPort, inputBytes: Uint8Array): Promise<Uint8Array> {
  let result: Uint8Array | null = null;
  try {
    result = await crypto.rootHmac(inputBytes);
    return requireOwnedHmac(result);
  } catch (_error) {
    catalogMismatch();
  } finally {
    zeroBytes(inputBytes);
    zeroBytes(result);
  }
}

async function computeOwnedDerivedHmac(crypto: VpnRpcCryptoPort, keyBytes: Uint8Array, inputBytes: Uint8Array): Promise<Uint8Array> {
  let result: Uint8Array | null = null;
  try {
    result = await crypto.derivedHmac(keyBytes, inputBytes);
    return requireOwnedHmac(result);
  } catch (_error) {
    catalogMismatch();
  } finally {
    zeroBytes(keyBytes);
    zeroBytes(inputBytes);
    zeroBytes(result);
  }
}

function decodeExactHex(rawValue: string): Uint8Array {
  try {
    return decodeVpnRpcLowercaseHex(rawValue);
  } catch (_error) {
    catalogMismatch();
  }
}

function buildCatalogSaltInput(profileHash: string, revisionHash: string): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(CATALOG_SALT_LABEL),
    new Uint8Array([0x00]),
    decodeExactHex(profileHash),
    decodeExactHex(revisionHash)
  ]);
}

function buildGroupIdInput(parentIdHex: string, memberIndex: number, normalizedName: string, normalizedType: string): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(GROUP_ID_LABEL),
    new Uint8Array([0x00]),
    decodeExactHex(parentIdHex),
    encodeVpnRpcU32BE(memberIndex),
    lpBytes(encodeVpnRpcUtf8(normalizedName)),
    encodeVpnRpcU16BE(typeCode(normalizedType))
  ]);
}

function buildNodeIdInput(parentIdHex: string, memberIndex: number, normalizedName: string, normalizedType: string): Uint8Array {
  return joinBytes([
    encodeVpnRpcUtf8(NODE_ID_LABEL),
    new Uint8Array([0x00]),
    decodeExactHex(parentIdHex),
    encodeVpnRpcU32BE(memberIndex),
    lpBytes(encodeVpnRpcUtf8(normalizedName)),
    encodeVpnRpcU16BE(typeCode(normalizedType))
  ]);
}

function buildDigestInput(entries: InternalCatalogEntry[]): Uint8Array {
  const parts: Uint8Array[] = [
    encodeVpnRpcUtf8(DIGEST_LABEL),
    new Uint8Array([0x00]),
    encodeVpnRpcU32BE(entries.length)
  ];
  for (let index: number = 0; index < entries.length; index += 1) {
    const entry: InternalCatalogEntry = entries[index];
    parts.push(encodeVpnRpcU16BE(kindCode(entry.kind)));
    parts.push(encodeVpnRpcU16BE(typeCode(entry.type)));
    parts.push(encodeVpnRpcU16BE(entry.depth));
    parts.push(encodeVpnRpcU32BE(entry.memberIndex));
    parts.push(decodeExactHex(entry.parentId));
    parts.push(decodeExactHex(entry.id));
    parts.push(encodeVpnRpcU16BE(edgeStateCode(entry.edgeState)));
  }
  return joinBytes(parts);
}

async function computeCatalogSaltHex(
  crypto: VpnRpcCryptoPort,
  profileHash: string,
  revisionHash: string
): Promise<string> {
  const saltBytes: Uint8Array = await computeOwnedRootHmac(crypto, buildCatalogSaltInput(profileHash, revisionHash));
  try {
    return encodeVpnRpcLowercaseHex(saltBytes);
  } finally {
    zeroBytes(saltBytes);
  }
}

async function computeGroupIdHex(
  crypto: VpnRpcCryptoPort,
  catalogSaltHex: string,
  parentIdHex: string,
  memberIndex: number,
  normalizedName: string,
  normalizedType: string
): Promise<string> {
  const groupIdBytes: Uint8Array = await computeOwnedDerivedHmac(
    crypto,
    decodeExactHex(catalogSaltHex),
    buildGroupIdInput(parentIdHex, memberIndex, normalizedName, normalizedType)
  );
  try {
    return encodeVpnRpcLowercaseHex(groupIdBytes);
  } finally {
    zeroBytes(groupIdBytes);
  }
}

async function computeNodeIdHex(
  crypto: VpnRpcCryptoPort,
  catalogSaltHex: string,
  parentIdHex: string,
  memberIndex: number,
  normalizedName: string,
  normalizedType: string
): Promise<string> {
  const nodeIdBytes: Uint8Array = await computeOwnedDerivedHmac(
    crypto,
    decodeExactHex(catalogSaltHex),
    buildNodeIdInput(parentIdHex, memberIndex, normalizedName, normalizedType)
  );
  try {
    return encodeVpnRpcLowercaseHex(nodeIdBytes);
  } finally {
    zeroBytes(nodeIdBytes);
  }
}

async function computeCatalogDigestHex(
  crypto: VpnRpcCryptoPort,
  catalogSaltHex: string,
  entries: InternalCatalogEntry[]
): Promise<string> {
  const digestBytes: Uint8Array = await computeOwnedDerivedHmac(
    crypto,
    decodeExactHex(catalogSaltHex),
    buildDigestInput(entries)
  );
  try {
    return encodeVpnRpcLowercaseHex(digestBytes);
  } finally {
    zeroBytes(digestBytes);
  }
}

export async function buildVpnOpaqueCatalog(
  crypto: VpnRpcCryptoPort,
  profileHash: string,
  revisionHash: string,
  groups: VpnCatalogGroupInput[]
): Promise<VpnOpaqueCatalog> {
  const safeProfileHash: string = normalizeCatalogHash(requireString(profileHash), 'VPN opaque catalog profileHash');
  const safeRevisionHash: string = normalizeCatalogHash(requireString(revisionHash), 'VPN opaque catalog revisionHash');
  const safeGroups: CatalogGroupSnapshot[] = snapshotTopLevelGroups(groups);
  try {
    await crypto.prepare();
  } catch (_error) {
    catalogMismatch();
  }
  const catalogSaltHex: string = await computeCatalogSaltHex(crypto, safeProfileHash, safeRevisionHash);
  const builder: CatalogBuilder = new CatalogBuilder(crypto, catalogSaltHex);
  await builder.appendTopLevelGroups(safeGroups);
  const entries: InternalCatalogEntry[] = [];
  for (let index: number = 0; index < builder.orderedEntryCount(); index += 1) {
    entries.push(builder.orderedEntryAt(index));
  }
  const catalogDigest: string = await computeCatalogDigestHex(crypto, catalogSaltHex, entries);
  return builder.buildCatalog(safeProfileHash, safeRevisionHash, catalogDigest);
}
