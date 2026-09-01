import { describe, expect, it } from '@ohos/hypium';
import type {
  CoreError,
  CoreProxyGroupList,
  CoreProxyGroupResult,
  CoreProxyQueryContext,
  CoreProxySelectionApplied,
  CoreProxyType
} from '@cmfa/shared';
import { CoreNativeAdapter, type InternalTunNativeModule } from '../main/ets/CoreNativeAdapter';
import {
  decodeProxyGroupList,
  decodeProxyGroupResult,
  decodeProxySelectionApplied
} from '../main/ets/ProxyNativeCodec';

const EXACT_ACCEPTED_PROXY_TYPES: CoreProxyType[] = [
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

class NativeBridgeFailure extends Error {
  code: string;
  detail: string;
  retryable: boolean;

  constructor(code: string, detail: string, retryable: boolean = false) {
    super(detail);
    this.code = code;
    this.detail = detail;
    this.retryable = retryable;
  }
}

class ProxyQueryContextValue implements CoreProxyQueryContext {
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
}

class ProxyNativeCallRecord {
  context?: CoreProxyQueryContext;
  selectableOnly?: boolean;
  groupName?: string;
  memberName?: string;
}

class GroupRefPayloadValue {
  name: string = '';
  type: CoreProxyType = 'Direct';
}

class NodePayloadValue {
  name: string = '';
  type: CoreProxyType = 'Direct';
  isGroup: boolean = false;
  selected: boolean = false;
}

class GroupPayloadValue {
  name: string = '';
  type: CoreProxyType = 'Direct';
  selectedName: string = '';
  nodes: NodePayloadValue[] = [];
}

class GroupPayloadWithExtraValue extends GroupPayloadValue {
  extra: boolean = true;
}

class NodePayloadWithExtraValue extends NodePayloadValue {
  extra: boolean = true;
}

class GroupListEnvelopeValue {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_LIST' = 'GROUP_LIST';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  groups: GroupRefPayloadValue[] = [];
}

class GroupResultEnvelopeValue {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'GROUP_SNAPSHOT' = 'GROUP_SNAPSHOT';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  group: GroupPayloadValue | GroupPayloadWithExtraValue = new GroupPayloadValue();
}

class SelectionAppliedEnvelopeValue {
  schemaVersion: '1.0.0' = '1.0.0';
  kind: 'SELECTION_APPLIED' = 'SELECTION_APPLIED';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  previousName: string = '';
  group: GroupPayloadValue = new GroupPayloadValue();
}

class FakeProxyNativeModule implements InternalTunNativeModule {
  readonly calls: ProxyNativeCallRecord[] = [];
  listRaw: string = '';
  groupRaw: string = '';
  selectionRaw: string = '';
  listReject?: NativeBridgeFailure;
  groupReject?: NativeBridgeFailure;
  selectionReject?: NativeBridgeFailure;
  listThrow?: NativeBridgeFailure;
  groupThrow?: NativeBridgeFailure;
  selectionThrow?: NativeBridgeFailure;
  mutateListContextInPlace: boolean = false;
  mutatedProfileHash: string = buildHex('mutated-native-profile');
  mutatedGeneration: number = 101;

  async queryProxyGroups(context: CoreProxyQueryContext, selectableOnly: boolean): Promise<string> {
    const record = new ProxyNativeCallRecord();
    record.context = context;
    record.selectableOnly = selectableOnly;
    this.calls.push(record);
    if (this.listThrow !== undefined) {
      throw this.listThrow;
    }
    if (this.listReject !== undefined) {
      return await Promise.reject(this.listReject);
    }
    if (this.mutateListContextInPlace) {
      context.profileHash = this.mutatedProfileHash;
      context.generation = this.mutatedGeneration;
      return buildGroupListPayload(context);
    }
    return this.listRaw;
  }

  async queryProxyGroup(context: CoreProxyQueryContext, groupName: string): Promise<string> {
    const record = new ProxyNativeCallRecord();
    record.context = context;
    record.groupName = groupName;
    this.calls.push(record);
    if (this.groupThrow !== undefined) {
      throw this.groupThrow;
    }
    if (this.groupReject !== undefined) {
      return await Promise.reject(this.groupReject);
    }
    return this.groupRaw;
  }

  async selectProxy(context: CoreProxyQueryContext, groupName: string, memberName: string): Promise<string> {
    const record = new ProxyNativeCallRecord();
    record.context = context;
    record.groupName = groupName;
    record.memberName = memberName;
    this.calls.push(record);
    if (this.selectionThrow !== undefined) {
      throw this.selectionThrow;
    }
    if (this.selectionReject !== undefined) {
      return await Promise.reject(this.selectionReject);
    }
    return this.selectionRaw;
  }
}

function buildHex(seed: string): string {
  const alphabet: string = '0123456789abcdef';
  let value: string = '';
  let index: number = seed.length % alphabet.length;
  while (value.length < 64) {
    value += alphabet[index];
    index = (index + 7) % alphabet.length;
  }
  return value;
}

function utf8ByteLength(value: string): number {
  let length: number = 0;
  let index: number = 0;
  while (index < value.length) {
    const codeUnit: number = value.charCodeAt(index);
    if (codeUnit < 0x80) {
      length += 1;
      index += 1;
      continue;
    }
    if (codeUnit < 0x800) {
      length += 2;
      index += 1;
      continue;
    }
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff && index + 1 < value.length) {
      const nextCodeUnit: number = value.charCodeAt(index + 1);
      if (nextCodeUnit >= 0xdc00 && nextCodeUnit <= 0xdfff) {
        length += 4;
        index += 2;
        continue;
      }
    }
    length += 3;
    index += 1;
  }
  return length;
}

function buildContext(sessionHash: string | null = buildHex('session'), generation: number = 7): CoreProxyQueryContext {
  const context = new ProxyQueryContextValue();
  context.profileHash = buildHex('profile');
  context.revisionHash = buildHex('revision');
  context.sessionHash = sessionHash;
  context.generation = generation;
  return context;
}

function createGroupRef(name: string, type: CoreProxyType): GroupRefPayloadValue {
  const group = new GroupRefPayloadValue();
  group.name = name;
  group.type = type;
  return group;
}

function createNode(name: string, type: CoreProxyType, isGroup: boolean, selected: boolean): NodePayloadValue {
  const node = new NodePayloadValue();
  node.name = name;
  node.type = type;
  node.isGroup = isGroup;
  node.selected = selected;
  return node;
}

function createNodeWithExtra(name: string, type: CoreProxyType, isGroup: boolean, selected: boolean): NodePayloadWithExtraValue {
  const node = new NodePayloadWithExtraValue();
  node.name = name;
  node.type = type;
  node.isGroup = isGroup;
  node.selected = selected;
  return node;
}

function createGroup(name: string, type: CoreProxyType, selectedName: string, nodes: NodePayloadValue[]): GroupPayloadValue {
  const group = new GroupPayloadValue();
  group.name = name;
  group.type = type;
  group.selectedName = selectedName;
  group.nodes = nodes;
  return group;
}

function buildGroupListPayload(context: CoreProxyQueryContext): string {
  const payload = new GroupListEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  payload.groups = [
    createGroupRef('select', 'Selector'),
    createGroupRef('节点-東京', 'Vmess')
  ];
  return JSON.stringify(payload);
}

function buildSingleGroupListPayload(context: CoreProxyQueryContext, name: string, type: CoreProxyType): string {
  const payload = new GroupListEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const groups: GroupRefPayloadValue[] = [];
  groups.push(createGroupRef(name, type));
  payload.groups = groups;
  return JSON.stringify(payload);
}

function buildGroupResultPayload(context: CoreProxyQueryContext, selectedName: string = 'node-a'): string {
  const payload = new GroupResultEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNode('node-a', 'Vmess', false, selectedName === 'node-a'));
  nodes.push(createNode('fallback', 'Fallback', true, selectedName === 'fallback'));
  payload.group = createGroup('auto', 'URLTest', selectedName, nodes);
  return JSON.stringify(payload);
}

function buildSelectionAppliedPayload(
  context: CoreProxyQueryContext,
  previousName: string = 'old-node',
  selectedName: string = 'node-b'
): string {
  const payload = new SelectionAppliedEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  payload.previousName = previousName;
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNode('node-a', 'Vmess', false, false));
  nodes.push(createNode('node-b', 'Trojan', false, true));
  payload.group = createGroup('select', 'Selector', selectedName, nodes);
  return JSON.stringify(payload);
}

function buildSingleNodeGroupResultPayload(
  context: CoreProxyQueryContext,
  selectedName: string,
  type: CoreProxyType
): string {
  const payload = new GroupResultEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNode(selectedName, type, false, true));
  payload.group = createGroup('group-under-test', 'Selector', selectedName, nodes);
  return JSON.stringify(payload);
}

function buildGroupResultWithExtraNode(context: CoreProxyQueryContext): string {
  const payload = new GroupResultEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const group = new GroupPayloadValue();
  group.name = 'auto';
  group.type = 'URLTest';
  group.selectedName = 'node-a';
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNodeWithExtra('node-a', 'Vmess', false, true));
  group.nodes = nodes;
  payload.group = group;
  return JSON.stringify(payload);
}

function buildDuplicateMemberPayload(context: CoreProxyQueryContext): string {
  const payload = new GroupResultEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNode('node-a', 'Vmess', false, true));
  nodes.push(createNode('node-a', 'Trojan', false, false));
  payload.group = createGroup('auto', 'URLTest', 'node-a', nodes);
  return JSON.stringify(payload);
}

function buildTooManyGroupsPayload(context: CoreProxyQueryContext): string {
  const payload = new GroupListEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const groups: GroupRefPayloadValue[] = [];
  for (let index: number = 0; index < 129; index += 1) {
    groups.push(createGroupRef(`group-${index}`, 'Selector'));
  }
  payload.groups = groups;
  return JSON.stringify(payload);
}

function buildInvalidSelectionPayload(context: CoreProxyQueryContext): string {
  const payload = new GroupResultEnvelopeValue();
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  const nodes: NodePayloadValue[] = [];
  nodes.push(createNode('node-a', 'Vmess', false, true));
  nodes.push(createNode('node-b', 'Trojan', false, false));
  payload.group = createGroup('auto', 'URLTest', 'missing-node', nodes);
  return JSON.stringify(payload);
}

function buildMinimalGroupListPayload(context: CoreProxyQueryContext): string {
  return `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":${context.sessionHash === null ? 'null' : `"${context.sessionHash}"`},"generation":${context.generation},"groups":[]}`;
}

function padJsonWithTrailingWhitespace(basePayload: string, targetBytes: number): string {
  const currentBytes: number = utf8ByteLength(basePayload);
  const paddingBytes: number = targetBytes - currentBytes;
  if (paddingBytes < 0) {
    throw new Error('targetBytes must be >= current payload bytes.');
  }
  return `${basePayload}${' '.repeat(paddingBytes)}`;
}

function buildGroupListPayloadWithGeneration(context: CoreProxyQueryContext, rawGeneration: string): string {
  return `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":${context.sessionHash === null ? 'null' : `"${context.sessionHash}"`},"generation":${rawGeneration},"groups":[]}`;
}

function toCoreError(error: Object): CoreError {
  return error as CoreError;
}

async function expectProxyBridgeInvalid(invoke: () => Promise<Object>, forbiddenFragments: string[]): Promise<CoreError> {
  try {
    await invoke();
    expect().assertFail();
  } catch (error) {
    const coreError: CoreError = toCoreError(error as Object);
    expect(coreError.code).assertEqual('PROXY_BRIDGE_INVALID');
    expect(coreError.retryable).assertFalse();
    expect(coreError.context?.status).assertEqual(-1);
    for (let index: number = 0; index < forbiddenFragments.length; index += 1) {
      expect(coreError.detail.includes(forbiddenFragments[index])).assertFalse();
      expect(coreError.message.includes(forbiddenFragments[index])).assertFalse();
    }
    return coreError;
  }
  throw new Error('unreachable');
}

function createUtf8OverflowString(): string {
  return '中'.repeat(349526);
}

function createLoneSurrogateName(prefixLength: number): string {
  return `${'a'.repeat(prefixLength)}\uD800`;
}

export default function proxyNativeCodecTestsuite(): void {
  describe('ProxyNativeCodecTest', () => {
    it('decodesGroupListAndReturnsClonedPublicData', 0, () => {
      const context: CoreProxyQueryContext = buildContext();
      const decoded: CoreProxyGroupList = decodeProxyGroupList(buildGroupListPayload(context), context);

      expect(decoded.schemaVersion).assertEqual('1.0.0');
      expect(decoded.kind).assertEqual('GROUP_LIST');
      expect(decoded.groups.length).assertEqual(2);
      expect(decoded.groups[0].name).assertEqual('select');
      expect(decoded.groups[1].name).assertEqual('节点-東京');

      decoded.groups[0].name = 'mutated';
      const decodedAgain: CoreProxyGroupList = decodeProxyGroupList(buildGroupListPayload(context), context);
      expect(decodedAgain.groups[0].name).assertEqual('select');
    });

    it('rejectsMalformedPayloadShapesAndSanitizesDecoderErrors', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('session-redacted'), 9);
      const rawName: string = 'leak-node';
      const rawHash: string = context.profileHash;
      const rawJson: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groups":[{"name":"${rawName}","type":"Selector","extra":true}]}`;
      const error: CoreError = await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(rawJson, context) as Object,
        [rawName, rawHash, rawJson]
      );
      expect(error.context?.operation).assertEqual('queryProxyGroups');
    });

    it('rejectsNonStringMalformedJsonAndOversizedPayloads', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(null, 11);
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(42 as Object, context) as Object,
        ['42']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList('{bad json', context) as Object,
        ['{bad json']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(createUtf8OverflowString(), context) as Object,
        ['中中中']
      );
    });

    it('acceptsEveryAllowlistedProxyTypeAndRejectsUnknownTypes', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('types-session'), 12);
      for (let index: number = 0; index < EXACT_ACCEPTED_PROXY_TYPES.length; index += 1) {
        const type: CoreProxyType = EXACT_ACCEPTED_PROXY_TYPES[index];
        const list: CoreProxyGroupList = decodeProxyGroupList(buildSingleGroupListPayload(context, `group-${index}`, type), context);
        const result: CoreProxyGroupResult = decodeProxyGroupResult(
          buildSingleNodeGroupResultPayload(context, `node-${index}`, type),
          context
        );
        expect(list.groups[0].type).assertEqual(type);
        expect(result.group.nodes[0].type).assertEqual(type);
      }

      const unknownGroupTypePayload: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groups":[{"name":"unknown-group","type":"NotAProxy"}]}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(unknownGroupTypePayload, context) as Object,
        ['NotAProxy', context.profileHash]
      );

      const unknownNodeTypePayload: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_SNAPSHOT","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"group":{"name":"auto","type":"Selector","selectedName":"node-unknown","nodes":[{"name":"node-unknown","type":"NotAProxy","isGroup":false,"selected":true}]}}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupResult(unknownNodeTypePayload, context) as Object,
        ['NotAProxy', context.profileHash]
      );
    });

    it('acceptsExactlyOneMiBPayloadAndRejectsOneByteOver', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('size-session'), 14);
      const minimalPayload: string = buildMinimalGroupListPayload(context);
      const exactPayload: string = padJsonWithTrailingWhitespace(minimalPayload, 1024 * 1024);
      const overPayload: string = `${exactPayload} `;

      expect(utf8ByteLength(exactPayload)).assertEqual(1024 * 1024);
      expect(utf8ByteLength(overPayload)).assertEqual(1024 * 1024 + 1);
      expect(decodeProxyGroupList(exactPayload, context).groups.length).assertEqual(0);
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(overPayload, context) as Object,
        [context.profileHash]
      );
    });

    it('pinsTextEncoderLoneSurrogateBoundarySemanticsAt256Bytes', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('surrogate-session'), 16);
      const exactName: string = createLoneSurrogateName(253);
      const overName: string = createLoneSurrogateName(254);

      expect(utf8ByteLength(exactName)).assertEqual(256);
      expect(utf8ByteLength(overName)).assertEqual(257);
      expect(decodeProxyGroupList(buildSingleGroupListPayload(context, exactName, 'Selector'), context).groups[0].name).assertEqual(exactName);
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(buildSingleGroupListPayload(context, overName, 'Selector'), context) as Object,
        [context.profileHash]
      );
    });

    it('rejectsZeroFractionalAndUnsafeGenerationValues', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('generation-session'), 18);
      const zeroPayload: string = buildGroupListPayloadWithGeneration(context, '0');
      const fractionalPayload: string = buildGroupListPayloadWithGeneration(context, '1.5');
      const unsafePayload: string = buildGroupListPayloadWithGeneration(context, '9007199254740992');

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(zeroPayload, context) as Object,
        [context.profileHash]
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(fractionalPayload, context) as Object,
        [context.profileHash]
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(unsafePayload, context) as Object,
        [context.profileHash]
      );
    });

    it('rejectsContextMismatchesAndNestedExactKeyViolations', 0, async () => {
      const expected: CoreProxyQueryContext = buildContext(buildHex('expected'), 13);
      const actual: CoreProxyQueryContext = buildContext(buildHex('different'), 13);
      const forbidden: string[] = [];
      if (expected.sessionHash !== null) {
        forbidden.push(expected.sessionHash);
      }
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(buildGroupListPayload(actual), expected) as Object,
        forbidden
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupResult(buildGroupResultWithExtraNode(expected), expected) as Object,
        ['extra']
      );
    });

    it('rejectsMaliciousPrototypeKeysAtTopEnvelopeAndNestedLevelsWithoutEchoingThem', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('proto-session'), 15);
      const rawName: string = 'leak-proxy-node';
      const rawHash: string = context.profileHash;
      const topEnvelopePayload: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groups":[],"__proto__":true}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(topEnvelopePayload, context) as Object,
        ['__proto__', rawHash, topEnvelopePayload]
      );

      const groupRefPayload: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_LIST","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groups":[{"name":"${rawName}","type":"Selector","constructor":false}]}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(groupRefPayload, context) as Object,
        ['constructor', rawName, rawHash, groupRefPayload]
      );

      const groupSnapshotPayload: string =
        `{"schemaVersion":"1.0.0","kind":"GROUP_SNAPSHOT","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"group":{"name":"auto","type":"URLTest","selectedName":"${rawName}","nodes":[{"name":"${rawName}","type":"Vmess","isGroup":false,"selected":true}],"prototype":0}}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupResult(groupSnapshotPayload, context) as Object,
        ['prototype', rawName, rawHash, groupSnapshotPayload]
      );

      const nodePayload: string =
        `{"schemaVersion":"1.0.0","kind":"SELECTION_APPLIED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"previousName":"","group":{"name":"select","type":"Selector","selectedName":"${rawName}","nodes":[{"name":"${rawName}","type":"Trojan","isGroup":false,"selected":true,"__proto__":"poison"}]}}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxySelectionApplied(nodePayload, context) as Object,
        ['__proto__', rawName, rawHash, nodePayload]
      );
    });

    it('rejectsDuplicateMembersCountViolationsAndSelectionInvariantBreaks', 0, async () => {
      const context: CoreProxyQueryContext = buildContext();
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupResult(buildDuplicateMemberPayload(context), context) as Object,
        ['node-a']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupList(buildTooManyGroupsPayload(context), context) as Object,
        ['group-128']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeProxyGroupResult(buildInvalidSelectionPayload(context), context) as Object,
        ['missing-node']
      );
    });

    it('acceptsOrdinaryUnicodeAndAllowsPreviousSelectionOutsideCurrentMembers', 0, () => {
      const context: CoreProxyQueryContext = buildContext(null, 17);
      const groupResult: CoreProxyGroupResult = decodeProxyGroupResult(buildGroupResultPayload(context, 'fallback'), context);
      const applied: CoreProxySelectionApplied = decodeProxySelectionApplied(
        buildSelectionAppliedPayload(context, 'removed-历史', 'node-b'),
        context
      );

      expect(groupResult.group.nodes[1].name).assertEqual('fallback');
      expect(applied.previousName).assertEqual('removed-历史');
      expect(applied.group.selectedName).assertEqual('node-b');
    });

    it('adapterNormalizesNativeThrowsRejectionsValidatesPayloadAndPassesExactArguments', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('adapter-session'), 19);
      const module = new FakeProxyNativeModule();
      module.listRaw = buildGroupListPayload(context);
      module.groupRaw = buildGroupResultPayload(context);
      module.selectionRaw = buildSelectionAppliedPayload(context, 'previous-removed', 'node-b');
      const adapter = new CoreNativeAdapter(module);

      const list: CoreProxyGroupList = await adapter.queryProxyGroups(context, true);
      const group: CoreProxyGroupResult = await adapter.queryProxyGroup(context, 'select');
      const selection: CoreProxySelectionApplied = await adapter.selectProxy(context, 'select', 'node-b');

      expect(list.groups.length).assertEqual(2);
      expect(group.group.selectedName).assertEqual(group.group.nodes[0].name);
      expect(selection.group.selectedName).assertEqual('node-b');
      expect(module.calls.length).assertEqual(3);
      expect(module.calls[0].selectableOnly).assertTrue();
      expect(module.calls[1].groupName).assertEqual('select');
      expect(module.calls[2].memberName).assertEqual('node-b');

      context.profileHash = buildHex('mutated');
      expect(module.calls[0].context?.profileHash).assertEqual(buildHex('profile'));

      module.listThrow = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'native threw list');
      try {
        await adapter.queryProxyGroups(buildContext(), false);
        expect().assertFail();
      } catch (error) {
        const coreError: CoreError = toCoreError(error as Object);
        expect(coreError.code).assertEqual('CMFA_BACKEND_ERROR');
      }

      module.listThrow = undefined;
      module.groupReject = new NativeBridgeFailure('CMFA_CORE_UNAVAILABLE', 'native rejected group');
      try {
        await adapter.queryProxyGroup(buildContext(), 'group-name');
        expect().assertFail();
      } catch (error) {
        const coreError: CoreError = toCoreError(error as Object);
        expect(coreError.code).assertEqual('CMFA_CORE_UNAVAILABLE');
      }

      module.groupReject = undefined;
      module.selectionRaw = '{"schemaVersion":"1.0.0","kind":"GROUP_SNAPSHOT"}';
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => await adapter.selectProxy(buildContext(), 'group-name', 'member-name') as Object,
        ['group-name', 'member-name']
      );
    });

    it('adapterRejectsWhenNativeMutatesContextBeforeEchoingItBack', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('caller-context'), 20);
      const originalProfileHash: string = context.profileHash;
      const module = new FakeProxyNativeModule();
      module.mutateListContextInPlace = true;
      module.mutatedProfileHash = buildHex('mutated-in-native');
      module.mutatedGeneration = 222;
      const adapter = new CoreNativeAdapter(module);

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => await adapter.queryProxyGroups(context, false) as Object,
        [originalProfileHash, module.mutatedProfileHash]
      );
      expect(context.profileHash).assertEqual(originalProfileHash);
      expect(context.generation).assertEqual(20);
      expect(module.calls[0].context?.profileHash).assertEqual(module.mutatedProfileHash);
      expect(module.calls[0].context?.generation).assertEqual(module.mutatedGeneration);
    });
  });
}
