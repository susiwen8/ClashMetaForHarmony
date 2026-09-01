import { describe, expect, it } from '@ohos/hypium';
import { expectThrowsMessage, type FakeClock } from './fakes/ProfileFakes';
import { FakeClock as ProfileFakeClock } from './fakes/ProfileFakes';
import { encodeVpnRpcBodyToText } from '../main/ets/vpn/rpc/VpnRpcBodyCodec';
import {
  buildVpnOpaqueCatalog,
  type VpnCatalogGroupInput,
  type VpnCatalogGroupMemberInput,
  type VpnCatalogMemberInput,
  type VpnCatalogTerminalMemberInput,
  type VpnOpaqueCatalog,
  type VpnOpaqueCatalogEntry
} from '../main/ets/vpn/rpc/VpnOpaqueCatalog';
import {
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcError,
  createVpnRpcGuards,
  type VpnRpcBody,
  type VpnRpcGuards,
  type VpnRpcMethod
} from '../main/ets/vpn/rpc/VpnRpcModels';
import {
  createVpnRpcDelayGroupRequestPayload,
  createVpnRpcDelayJobRequestPayload,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcEmptyPayload,
  createVpnRpcGroupNode,
  createVpnRpcGroupRef,
  type VpnRpcQueryGroupPayload,
  createVpnRpcQueryGroupPayload,
  createVpnRpcQueryGroupsPayload,
  createVpnRpcSelectNodeResultPayload,
  type VpnRpcPayload
} from '../main/ets/vpn/rpc/VpnRpcPayloads';
import { VpnRpcTransportFailure } from '../main/ets/vpn/rpc/VpnRpcAuthenticator';
import {
  type VpnRpcClientPort,
  type VpnRpcClientState,
  type VpnRpcEventListener,
  type VpnRpcTrafficCounters
} from '../main/ets/vpn/rpc/VpnRpcClient';
import { type VpnRpcCryptoPort } from '../main/ets/vpn/rpc/VpnRpcPorts';
import {
  createProxyRuntimeIdentity,
  createVpnProxyCancelDelayTestCommand,
  createVpnProxyQueryGroupCommand,
  createVpnProxyQueryGroupsCommand,
  createVpnProxyReadDelayTestCommand,
  createVpnProxySelectCommand,
  createVpnProxyStartDelayTestCommand,
  type ProxyDelayResult,
  type ProxyGroupListQueryResult,
  type ProxyGroupQueryResult,
  type ProxyRejectedErrorCode,
  type ProxySelectionResult,
  VpnRpcProxyHandler
} from '../../Index';
import { createVpnRuntimeSnapshot, createVpnStartRequest, type VpnRuntimeSnapshot, type VpnRuntimeState } from '../main/ets/vpn/VpnModels';

const PROFILE_HASH: string = '1111111111111111111111111111111111111111111111111111111111111111';
const REVISION_HASH: string = '2222222222222222222222222222222222222222222222222222222222222222';
const ALT_REVISION_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const PROFILE_ID: string = 'profile-main';
const REVISION_ID: string = '2026-08-26T08:00:00.000Z';
const SESSION_ID: string = 'vpn-session-1';
const TIMESTAMP_1: string = '2026-08-26T09:00:00.000Z';
const TIMESTAMP_2: string = '2026-08-26T09:00:01.000Z';
const TIMESTAMP_3: string = '2026-08-26T09:00:02.000Z';
const UNKNOWN_ID: string = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
const CORE_JOB_ID: string = 'core-delay-job-1';
const PRIVATE_PROFILE_PATH: string = '/data/user/0/cmfa/files/profiles/private.yaml';

class FixtureGroup implements VpnCatalogGroupInput {
  name: string;
  type: string;
  members: VpnCatalogMemberInput[];

  constructor(name: string, type: string, members: VpnCatalogMemberInput[]) {
    this.name = name;
    this.type = type;
    this.members = members;
  }
}

class FixtureGroupMember implements VpnCatalogGroupMemberInput {
  kind: 'GROUP' = 'GROUP';
  group: VpnCatalogGroupInput;

  constructor(group: VpnCatalogGroupInput) {
    this.group = group;
  }
}

class FixtureTerminalMember implements VpnCatalogTerminalMemberInput {
  kind: 'TERMINAL' = 'TERMINAL';
  name: string;
  type: string;

  constructor(name: string, type: string) {
    this.name = name;
    this.type = type;
  }
}

class CatalogCryptoPort implements VpnRpcCryptoPort {
  async prepare(): Promise<void> {}

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return this.hash(17, new Uint8Array(0), input);
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return this.hash(53, key, input);
  }

  private hash(seed: number, key: Uint8Array, input: Uint8Array): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(32);
    let acc: number = seed;
    for (let index: number = 0; index < key.length; index += 1) {
      acc = (acc + key[index] + index + 3) & 0xff;
    }
    for (let index: number = 0; index < input.length; index += 1) {
      acc = (acc + input[index] + index + 11) & 0xff;
    }
    for (let index: number = 0; index < bytes.length; index += 1) {
      const keyByte: number = key.length === 0 ? seed : key[index % key.length];
      const inputByte: number = input.length === 0 ? seed : input[index % input.length];
      acc = (acc + keyByte + inputByte + (index * 13)) & 0xff;
      bytes[index] = acc ^ ((keyByte + inputByte + index) & 0xff);
    }
    return bytes;
  }
}

class FakeVpnRpcClient implements VpnRpcClientPort {
  readonly requests: VpnRpcBody[] = [];
  readonly responses: Array<VpnRpcBody | VpnRpcTransportFailure | Error> = [];
  stateValue: VpnRpcClientState = 'READY';
  snapshotValue: VpnRuntimeSnapshot = createVpnRuntimeSnapshot({
    state: 'RUNNING',
    activeRequest: createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID),
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: true,
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });

  async connect(): Promise<void> {}

  async connectOnce(): Promise<void> {}

  async refreshTrafficCounters(): Promise<VpnRpcTrafficCounters> {
    const counters: VpnRpcTrafficCounters = {
      txBytes: this.snapshotValue.tunSnapshot?.counters.txBytes ?? 0,
      rxBytes: this.snapshotValue.tunSnapshot?.counters.rxBytes ?? 0
    };
    return counters;
  }

  state(): VpnRpcClientState {
    return this.stateValue;
  }

  snapshot(): VpnRuntimeSnapshot {
    return createVpnRuntimeSnapshot({
      state: this.snapshotValue.state,
      activeRequest: this.snapshotValue.activeRequest,
      activeHandle: this.snapshotValue.activeHandle,
      captureConfig: this.snapshotValue.captureConfig,
      tunSnapshot: this.snapshotValue.tunSnapshot,
      notificationActive: this.snapshotValue.notificationActive,
      recoveryAttempt: this.snapshotValue.recoveryAttempt,
      scheduledRetryDelayMs: this.snapshotValue.scheduledRetryDelayMs,
      lastFailure: this.snapshotValue.lastFailure
    });
  }

  activeContext() {
    return null;
  }

  subscribe(_listener: VpnRpcEventListener): number {
    return 1;
  }

  unsubscribe(_id: number): void {}

  async close(): Promise<void> {}

  async request(method: VpnRpcMethod, guards: VpnRpcGuards, generation: number, payload: VpnRpcPayload): Promise<VpnRpcBody> {
    const ordinal: number = this.requests.length + 1;
    const request: VpnRpcBody = createVpnRpcBodyRequest(
      ordinal,
      1,
      ordinal,
      `00000000-0000-4000-8000-${`${ordinal}`.padStart(12, '0')}`,
      method,
      generation,
      guards,
      payload
    );
    this.requests.push(request);
    const next: VpnRpcBody | VpnRpcTransportFailure | Error | undefined = this.responses.shift();
    if (next === undefined) {
      throw new Error('Missing scripted VPN RPC response.');
    }
    if (next instanceof VpnRpcTransportFailure) {
      throw next;
    }
    if (next instanceof Error) {
      throw next;
    }
    return next;
  }
}

function buildClock(values: string[]): FakeClock {
  return new ProfileFakeClock(values);
}

async function buildCatalog(): Promise<VpnOpaqueCatalog> {
  return await buildVpnOpaqueCatalog(new CatalogCryptoPort(), PROFILE_HASH, REVISION_HASH, createCatalogInput());
}

function createSnapshot(state: VpnRuntimeState): VpnRuntimeSnapshot {
  return createVpnRuntimeSnapshot({
    state,
    activeRequest: state === 'RUNNING'
      ? createVpnStartRequest(PROFILE_ID, REVISION_ID, SESSION_ID)
      : null,
    activeHandle: null,
    captureConfig: null,
    tunSnapshot: null,
    notificationActive: state === 'RUNNING',
    recoveryAttempt: 0,
    scheduledRetryDelayMs: null,
    lastFailure: null
  });
}

function createCatalogInput(): VpnCatalogGroupInput[] {
  return [
    createGroup('Gateway', 'Selector', [
      createNestedGroup('Shared', 'Fallback', [createTerminal('Tokyo', 'Trojan')]),
      createTerminal('Dup', 'Vmess'),
      createTerminal('Dup', 'Vmess')
    ]),
    createGroup('Mirror', 'Selector', [
      createNestedGroup('Shared', 'Fallback', [createTerminal('Osaka', 'Snell')])
    ]),
    createGroup('Selector Group', 'Selector', [
      createTerminal('Alpha', 'Shadowsocks'),
      createTerminal('Beta', 'Trojan')
    ]),
    createGroup('Delay Lab', 'URLTest', [
      createTerminal('Wait', 'Direct'),
      createTerminal('Test', 'Shadowsocks'),
      createTerminal('Fast', 'Trojan'),
      createTerminal('Slow', 'Vmess'),
      createTerminal('Fail', 'Snell'),
      createTerminal('Cancel', 'Socks5'),
      createTerminal('Unsupported', 'Relay')
    ]),
    createGroup('Duplicate Nest Root', 'Selector', [
      createNestedGroup('Branch', 'Fallback', [createTerminal('Left', 'Trojan')]),
      createNestedGroup('Branch', 'Fallback', [createTerminal('Right', 'Snell')])
    ])
  ];
}

function createGroup(name: string, type: string, members: VpnCatalogMemberInput[]): VpnCatalogGroupInput {
  return new FixtureGroup(name, type, members);
}

function createNestedGroup(name: string, type: string, members: VpnCatalogMemberInput[]): VpnCatalogMemberInput {
  return new FixtureGroupMember(createGroup(name, type, members));
}

function createTerminal(name: string, type: string): VpnCatalogMemberInput {
  return new FixtureTerminalMember(name, type);
}

function createIdentity(revisionHash: string = REVISION_HASH) {
  return createProxyRuntimeIdentity(PROFILE_ID, REVISION_ID, revisionHash, SESSION_ID);
}

function requireEntry(catalog: VpnOpaqueCatalog, id: string): VpnOpaqueCatalogEntry {
  const entry: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(id);
  if (entry === undefined) {
    throw new Error('Expected catalog entry.');
  }
  return entry;
}

function requireTopLevelEntry(catalog: VpnOpaqueCatalog, index: number): VpnOpaqueCatalogEntry {
  const id: string | undefined = catalog.topLevelGroupIds()[index];
  if (id === undefined) {
    throw new Error('Missing top-level group.');
  }
  return requireEntry(catalog, id);
}

function requireChildEntry(catalog: VpnOpaqueCatalog, parent: VpnOpaqueCatalogEntry, index: number): VpnOpaqueCatalogEntry {
  const childId: string | undefined = parent.childIds[index];
  if (childId === undefined) {
    throw new Error('Missing child entry.');
  }
  return requireEntry(catalog, childId);
}

function createSuccessResponse(
  method: VpnRpcMethod,
  generation: number,
  guards: VpnRpcGuards,
  payload: VpnRpcPayload
): VpnRpcBody {
  return createVpnRpcBodySuccessResponse(
    1,
    1,
    1,
    '00000000-0000-4000-8000-000000000001',
    method,
    generation,
    guards,
    payload
  );
}

function createErrorResponse(
  method: VpnRpcMethod,
  generation: number,
  guards: VpnRpcGuards,
  code: string,
  retryable: boolean
): VpnRpcBody {
  return createVpnRpcBodyErrorResponse(
    1,
    1,
    1,
    '00000000-0000-4000-8000-000000000001',
    method,
    generation,
    guards,
    createVpnRpcError(code, retryable)
  );
}

function expectRejected(
  result: ProxyGroupListQueryResult | ProxyGroupQueryResult | ProxySelectionResult | ProxyDelayResult,
  code: ProxyRejectedErrorCode,
  retryable: boolean
): void {
  expect(result.kind).assertEqual('REJECTED');
  if (result.kind === 'REJECTED') {
    expect(result.error.code).assertEqual(code);
    expect(result.error.retryable).assertEqual(retryable);
  }
}

function assertNoRawLeaks(body: VpnRpcBody, fragments: string[]): void {
  const encoded: string = encodeVpnRpcBodyToText(body);
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(encoded.includes(fragments[index])).assertFalse();
  }
}

export default function vpnRpcProxyHandlerTestsuite() {
  describe('VpnRpcProxyHandlerTest', () => {
    it('clonesAndValidatesExplicitGroupPathsAndDefaultsToTerminalSegment', 0, () => {
      const pathInput: string[] = ['Gateway', 'Shared'];
      const queryCommand = createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Shared', pathInput);
      const selectCommand = createVpnProxySelectCommand(createIdentity(), 7, 'Shared', 'Tokyo', pathInput);
      const delayCommand = createVpnProxyStartDelayTestCommand(createIdentity(), 7, 'Shared', pathInput);

      pathInput[0] = 'Tampered';
      pathInput[1] = 'Changed';

      expect(queryCommand.groupPath?.length ?? 0).assertEqual(2);
      expect(queryCommand.groupPath?.[0] ?? '').assertEqual('Gateway');
      expect(queryCommand.groupPath?.[1] ?? '').assertEqual('Shared');
      expect(selectCommand.groupPath?.[0] ?? '').assertEqual('Gateway');
      expect(delayCommand.groupPath?.[1] ?? '').assertEqual('Shared');
      expect((createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Gateway').groupPath ?? []).join('/')).assertEqual('Gateway');
      expectThrowsMessage((): void => {
        createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Shared', []);
      }, 'Proxy command path must contain between 1 and 16 segments.');
      expectThrowsMessage((): void => {
        createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Shared', ['Gateway', 'Wrong']);
      }, 'Proxy command path terminal segment must match the requested target.');
    });

    it('mapsQueryGroupsAndGroupOpaqueIdsWithoutRawLeaksAndReturnsCallerOwnedResults', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const mirror: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 1);
      const sharedGroup: VpnOpaqueCatalogEntry = requireEntry(catalog, gateway.childIds[0]);
      const duplicateFirst: VpnOpaqueCatalogEntry = requireEntry(catalog, gateway.childIds[1]);
      const duplicateSecond: VpnOpaqueCatalogEntry = requireEntry(catalog, gateway.childIds[2]);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1]));
      const groupPayload: VpnRpcQueryGroupPayload = createVpnRpcQueryGroupPayload(7, gateway.id, duplicateSecond.id, [
        createVpnRpcGroupNode(sharedGroup.id, sharedGroup.kind, sharedGroup.type, false),
        createVpnRpcGroupNode(duplicateFirst.id, duplicateFirst.kind, duplicateFirst.type, false),
        createVpnRpcGroupNode(duplicateSecond.id, duplicateSecond.kind, duplicateSecond.type, true)
      ]);
      const groupResponseBody: VpnRpcBody = createSuccessResponse(
        'QUERY_GROUP',
        7,
        guards,
        groupPayload
      );

      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUPS',
          7,
          guards,
          createVpnRpcQueryGroupsPayload(7, [
            createVpnRpcGroupRef(mirror.id, mirror.type, true),
            createVpnRpcGroupRef(gateway.id, gateway.type, true)
          ])
        )
      );
      client.responses.push(
        groupResponseBody
      );

      const groupsResult: ProxyGroupListQueryResult = await handler.queryGroups(
        createVpnProxyQueryGroupsCommand(createIdentity(), 7, true)
      );
      const groupResult: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Gateway')
      );

      expect(groupsResult.kind).assertEqual('SNAPSHOT');
      if (groupsResult.kind === 'SNAPSHOT') {
        expect(groupsResult.generation).assertEqual(7);
        expect(groupsResult.groups.length).assertEqual(2);
        expect(groupsResult.groups[0].name).assertEqual('Mirror');
        expect(groupsResult.groups[1].name).assertEqual('Gateway');
      }

      expect(groupResult.kind).assertEqual('SNAPSHOT');
      if (groupResult.kind === 'SNAPSHOT') {
        expect(groupResult.snapshot.generation).assertEqual(7);
        expect(groupResult.snapshot.group.name).assertEqual('Gateway');
        expect(groupResult.snapshot.group.selectedName).assertEqual('Dup');
        expect(groupResult.snapshot.group.nodes.length).assertEqual(3);
        expect(groupResult.snapshot.group.nodes[0].name).assertEqual('Shared');
        expect(groupResult.snapshot.group.nodes[0].isGroup).assertTrue();
        expect(groupResult.snapshot.group.nodes[1].name).assertEqual('Dup');
        expect(groupResult.snapshot.group.nodes[1].selected).assertFalse();
        expect(groupResult.snapshot.group.nodes[2].name).assertEqual('Dup');
        expect(groupResult.snapshot.group.nodes[2].selected).assertTrue();
      }

      const firstRequest: VpnRpcBody = client.requests[0];
      const secondRequest: VpnRpcBody = client.requests[1];
      expect(firstRequest.method).assertEqual('QUERY_GROUPS');
      expect(secondRequest.method).assertEqual('QUERY_GROUP');
      expect(secondRequest.guards.catalogDigest).assertEqual(catalog.catalogDigest);
      assertNoRawLeaks(firstRequest, ['Gateway', 'Mirror', PROFILE_ID, REVISION_ID, PRIVATE_PROFILE_PATH]);
      assertNoRawLeaks(secondRequest, ['Gateway', 'Shared', 'Dup', 'Tokyo', PROFILE_ID, REVISION_ID, PRIVATE_PROFILE_PATH]);

      if (groupResult.kind === 'SNAPSHOT') {
        groupResult.snapshot.group.nodes[2].selected = false;
      }
      groupPayload.selectedNodeId = duplicateFirst.id;
      expect(groupResult.kind).assertEqual('SNAPSHOT');
      if (groupResult.kind === 'SNAPSHOT') {
        expect(groupResult.snapshot.group.nodes[2].selected).assertFalse();
        expect(groupResult.snapshot.group.selectedName).assertEqual('Dup');
      }
    });

    it('mapsSelectedGroupChildrenFromQueryPayloadWithoutRawLeaks', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const sharedGroup: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 0);
      const duplicateFirst: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 1);
      const duplicateSecond: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 2);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1]));

      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUP',
          19,
          guards,
          createVpnRpcQueryGroupPayload(19, gateway.id, sharedGroup.id, [
            createVpnRpcGroupNode(sharedGroup.id, sharedGroup.kind, sharedGroup.type, true),
            createVpnRpcGroupNode(duplicateFirst.id, duplicateFirst.kind, duplicateFirst.type, false),
            createVpnRpcGroupNode(duplicateSecond.id, duplicateSecond.kind, duplicateSecond.type, false)
          ])
        )
      );

      const groupResult: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 19, 'Gateway')
      );

      expect(groupResult.kind).assertEqual('SNAPSHOT');
      if (groupResult.kind === 'SNAPSHOT') {
        expect(groupResult.snapshot.group.selectedName).assertEqual('Shared');
        expect(groupResult.snapshot.group.nodes.length).assertEqual(3);
        expect(groupResult.snapshot.group.nodes[0].name).assertEqual('Shared');
        expect(groupResult.snapshot.group.nodes[0].isGroup).assertTrue();
        expect(groupResult.snapshot.group.nodes[0].selected).assertTrue();
        expect(groupResult.snapshot.group.nodes[1].selected).assertFalse();
        expect(groupResult.snapshot.group.nodes[2].selected).assertFalse();
      }

      expect(client.requests.length).assertEqual(1);
      assertNoRawLeaks(client.requests[0], ['Gateway', 'Shared', 'Dup', 'Tokyo']);
    });

    it('rejectsSelectedGroupPayloadWhenSelectedFlagMovesToAnotherChild', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const sharedGroup: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 0);
      const duplicateFirst: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 1);
      const duplicateSecond: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 2);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1]));
      const response: VpnRpcBody = createSuccessResponse(
        'QUERY_GROUP',
        23,
        guards,
        createVpnRpcQueryGroupPayload(23, gateway.id, sharedGroup.id, [
          createVpnRpcGroupNode(sharedGroup.id, sharedGroup.kind, sharedGroup.type, true),
          createVpnRpcGroupNode(duplicateFirst.id, duplicateFirst.kind, duplicateFirst.type, false),
          createVpnRpcGroupNode(duplicateSecond.id, duplicateSecond.kind, duplicateSecond.type, false)
        ])
      );
      const payload: VpnRpcQueryGroupPayload = response.payload as VpnRpcQueryGroupPayload;
      payload.nodes[0].selected = false;
      payload.nodes[1].selected = true;

      client.responses.push(
        response
      );

      const groupResult: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 23, 'Gateway')
      );

      expectRejected(groupResult, 'PROXY_QUERY_FAILED', true);
      expect(client.requests.length).assertEqual(1);
      assertNoRawLeaks(client.requests[0], ['Gateway', 'Shared', 'Dup', 'Tokyo']);
    });

    it('rejectsNonSelectableQueryGroupsLocallyWithoutRpcAndKeepsTruePathOnWire', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2]));

      const rejected: ProxyGroupListQueryResult = await handler.queryGroups(
        createVpnProxyQueryGroupsCommand(createIdentity(), 9, false)
      );

      expectRejected(rejected, 'PROXY_QUERY_FAILED', false);
      expect(client.requests.length).assertEqual(0);

      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUPS',
          9,
          guards,
          createVpnRpcQueryGroupsPayload(9, [createVpnRpcGroupRef(gateway.id, gateway.type, true)])
        )
      );
      const accepted: ProxyGroupListQueryResult = await handler.queryGroups(
        createVpnProxyQueryGroupsCommand(createIdentity(), 9, true)
      );

      expect(accepted.kind).assertEqual('SNAPSHOT');
      expect(client.requests.length).assertEqual(1);
      expect(encodeVpnRpcBodyToText(client.requests[0].payload)).assertEqual('{}');
    });

    it('routesNestedGroupPathsForQuerySelectAndDelayAndFailsClosedWithoutExactPath', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const mirror: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 1);
      const gatewayShared: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gateway, 0);
      const mirrorShared: VpnOpaqueCatalogEntry = requireChildEntry(catalog, mirror, 0);
      const gatewayTokyo: VpnOpaqueCatalogEntry = requireChildEntry(catalog, gatewayShared, 0);
      const mirrorOsaka: VpnOpaqueCatalogEntry = requireChildEntry(catalog, mirrorShared, 0);
      const duplicateNestRoot: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 4);
      const queryPathInput: string[] = ['Gateway', 'Shared'];
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_1]));

      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUP',
          17,
          guards,
          createVpnRpcQueryGroupPayload(17, gatewayShared.id, gatewayTokyo.id, [
            createVpnRpcGroupNode(gatewayTokyo.id, gatewayTokyo.kind, gatewayTokyo.type, true)
          ])
        )
      );
      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUP',
          17,
          guards,
          createVpnRpcQueryGroupPayload(17, mirrorShared.id, mirrorOsaka.id, [
            createVpnRpcGroupNode(mirrorOsaka.id, mirrorOsaka.kind, mirrorOsaka.type, true)
          ])
        )
      );
      client.responses.push(
        createSuccessResponse(
          'SELECT_NODE',
          17,
          guards,
          createVpnRpcSelectNodeResultPayload(17, gatewayShared.id, gatewayTokyo.id, true)
        )
      );
      client.responses.push(
        createSuccessResponse(
          'START_DELAY_TEST',
          17,
          guards,
          createVpnRpcDelaySnapshotPayload(
            mirrorOsaka.id,
            1,
            17,
            mirrorShared.id,
            'RUNNING',
            1,
            1,
            [createVpnRpcDelayResult(mirrorOsaka.id, 'AVAILABLE', 55)]
          )
        )
      );

      const gatewayCommand = createVpnProxyQueryGroupCommand(createIdentity(), 17, 'Shared', queryPathInput);
      queryPathInput[0] = 'Mirror';
      const gatewayResult: ProxyGroupQueryResult = await handler.queryGroup(gatewayCommand);
      const mirrorResult: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 17, 'Shared', ['Mirror', 'Shared'])
      );
      const nestedSelect: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 17, 'Shared', 'Tokyo', ['Gateway', 'Shared'])
      );
      const nestedDelay: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 17, 'Shared', ['Mirror', 'Shared'])
      );
      const missingPath: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 17, 'Shared')
      );
      const ambiguousPath: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 17, 'Branch', ['Duplicate Nest Root', 'Branch'])
      );

      expect(gatewayResult.kind).assertEqual('SNAPSHOT');
      if (gatewayResult.kind === 'SNAPSHOT') {
        expect(gatewayResult.snapshot.group.name).assertEqual('Shared');
        expect(gatewayResult.snapshot.group.selectedName).assertEqual('Tokyo');
      }
      expect(mirrorResult.kind).assertEqual('SNAPSHOT');
      if (mirrorResult.kind === 'SNAPSHOT') {
        expect(mirrorResult.snapshot.group.name).assertEqual('Shared');
        expect(mirrorResult.snapshot.group.selectedName).assertEqual('Osaka');
      }
      expect(catalog.resolveLocalName(gatewayShared.id) ?? '').assertEqual('Shared');
      expect(catalog.resolveLocalName(mirrorShared.id) ?? '').assertEqual('Shared');
      expect(nestedSelect.kind).assertEqual('APPLIED_NOW');
      if (nestedSelect.kind === 'APPLIED_NOW') {
        expect(nestedSelect.snapshot.group.name).assertEqual('Shared');
        expect(nestedSelect.snapshot.group.selectedName).assertEqual('Tokyo');
      }
      expect(nestedDelay.kind).assertEqual('SNAPSHOT');
      if (nestedDelay.kind === 'SNAPSHOT') {
        expect(nestedDelay.groupName).assertEqual('Shared');
        expect(nestedDelay.nodes[0].name).assertEqual('Osaka');
      }
      expectRejected(missingPath, 'PROXY_QUERY_FAILED', true);
      expectRejected(ambiguousPath, 'PROXY_QUERY_FAILED', true);
      expect(client.requests.length).assertEqual(4);
      expect(encodeVpnRpcBodyToText(client.requests[0]).includes(gatewayShared.id)).assertTrue();
      expect(encodeVpnRpcBodyToText(client.requests[1]).includes(mirrorShared.id)).assertTrue();
      expect(gatewayShared.id === mirrorShared.id).assertFalse();
      assertNoRawLeaks(client.requests[0], ['Gateway', 'Shared', 'Tokyo', 'Mirror']);
      assertNoRawLeaks(client.requests[1], ['Gateway', 'Shared', 'Osaka', 'Mirror']);
      assertNoRawLeaks(client.requests[2], ['Gateway', 'Shared', 'Tokyo']);
      assertNoRawLeaks(client.requests[3], ['Mirror', 'Shared', 'Osaka']);
      expect(encodeVpnRpcBodyToText(client.requests[3]).includes(mirrorShared.id)).assertTrue();
      expect(encodeVpnRpcBodyToText(client.requests[3]).includes(mirrorOsaka.id)).assertFalse();
    });

    it('failsClosedForLocalCatalogMismatchUnknownOpaqueIdsAndHasZeroRpcSideEffectsOnPreflight', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const gateway: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]));

      const localQueryRejected: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(ALT_REVISION_HASH), 7, 'Gateway')
      );
      const localSelectRejected: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 7, 'Selector Group', 'Missing')
      );
      const localDelayRejected: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 7, 'Missing Group')
      );

      expectRejected(localQueryRejected, 'PROXY_QUERY_FAILED', true);
      expectRejected(localSelectRejected, 'PROXY_SELECTION_STALE', false);
      expectRejected(localDelayRejected, 'PROXY_DELAY_TEST_FAILED', true);
      expect(client.requests.length).assertEqual(0);

      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUPS',
          7,
          guards,
          createVpnRpcQueryGroupsPayload(7, [createVpnRpcGroupRef(UNKNOWN_ID, gateway.type, true)])
        )
      );
      client.responses.push(
        createSuccessResponse(
          'QUERY_GROUP',
          7,
          guards,
          createVpnRpcQueryGroupPayload(7, gateway.id, UNKNOWN_ID, [
            createVpnRpcGroupNode(UNKNOWN_ID, 'TERMINAL', 'Vmess', true)
          ])
        )
      );

      const remoteGroupsRejected: ProxyGroupListQueryResult = await handler.queryGroups(
        createVpnProxyQueryGroupsCommand(createIdentity(), 7, true)
      );
      const remoteGroupRejected: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 7, 'Gateway')
      );

      expectRejected(remoteGroupsRejected, 'PROXY_QUERY_FAILED', true);
      expectRejected(remoteGroupRejected, 'PROXY_QUERY_FAILED', true);
      expect(client.requests.length).assertEqual(2);
    });

    it('mapsSelectAppliedNowAndAppliedNotPersistedAndSanitizesMismatchAndTransportErrors', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const selectorGroup: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 2);
      const alphaNode: VpnOpaqueCatalogEntry = requireEntry(catalog, selectorGroup.childIds[0]);
      const betaNode: VpnOpaqueCatalogEntry = requireEntry(catalog, selectorGroup.childIds[1]);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]));

      client.responses.push(
        createSuccessResponse(
          'SELECT_NODE',
          11,
          guards,
          createVpnRpcSelectNodeResultPayload(11, selectorGroup.id, betaNode.id, true)
        )
      );
      client.responses.push(
        createSuccessResponse(
          'SELECT_NODE',
          11,
          guards,
          createVpnRpcSelectNodeResultPayload(11, selectorGroup.id, alphaNode.id, false)
        )
      );
      client.responses.push(createErrorResponse('SELECT_NODE', 11, guards, 'CATALOG_MISMATCH', true));
      client.responses.push(new VpnRpcTransportFailure('VPN RPC disconnected.', 'RPC_DISCONNECTED', false));

      const appliedNow: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 11, 'Selector Group', 'Beta')
      );
      const appliedNotPersisted: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 11, 'Selector Group', 'Alpha')
      );
      const staleSelection: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 11, 'Selector Group', 'Alpha')
      );
      const disconnectedSelection: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 11, 'Selector Group', 'Alpha')
      );

      expect(appliedNow.kind).assertEqual('APPLIED_NOW');
      if (appliedNow.kind === 'APPLIED_NOW') {
        expect(appliedNow.snapshot.group.selectedName).assertEqual('Beta');
        expect(appliedNow.record.selectedNodeName).assertEqual('Beta');
        expect(appliedNow.confirmedAt).assertEqual(TIMESTAMP_1);
      }

      expect(appliedNotPersisted.kind).assertEqual('APPLIED_NOT_PERSISTED');
      if (appliedNotPersisted.kind === 'APPLIED_NOT_PERSISTED') {
        expect(appliedNotPersisted.snapshot.group.selectedName).assertEqual('Alpha');
        expect(appliedNotPersisted.record.selectedNodeName).assertEqual('Alpha');
        expect(appliedNotPersisted.error.code).assertEqual('PROXY_PERSISTENCE_FAILED');
        expect(appliedNotPersisted.confirmedAt).assertEqual(TIMESTAMP_2);
      }

      expectRejected(staleSelection, 'PROXY_SELECTION_STALE', false);
      expectRejected(disconnectedSelection, 'PROXY_SELECTION_FAILED', false);
      assertNoRawLeaks(client.requests[0], ['Selector Group', 'Alpha', 'Beta', PROFILE_ID, REVISION_ID]);
    });

    it('rejectsClientAndRuntimeNonReadyStatesBeforeAnyRpcRequest', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3, TIMESTAMP_1, TIMESTAMP_2]));

      client.stateValue = 'DISCONNECTED';
      const disconnectedQuery: ProxyGroupListQueryResult = await handler.queryGroups(
        createVpnProxyQueryGroupsCommand(createIdentity(), 19, true)
      );

      client.stateValue = 'RECONNECTING';
      const reconnectingSelect: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 19, 'Selector Group', 'Alpha')
      );

      client.stateValue = 'READY';
      client.snapshotValue = createSnapshot('STOPPED');
      const stoppedDelay: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 19, 'Delay Lab')
      );

      client.stateValue = 'CLOSED';
      client.snapshotValue = createSnapshot('RUNNING');
      const closedQuery: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 19, 'Gateway')
      );

      client.stateValue = 'READY';
      client.snapshotValue = createSnapshot('STOPPING');
      const stoppingDelayRead: ProxyDelayResult = await handler.readDelayTest(
        createVpnProxyReadDelayTestCommand(createIdentity(), 19, UNKNOWN_ID)
      );

      expectRejected(disconnectedQuery, 'VPN_SESSION_CHANGED', false);
      expectRejected(reconnectingSelect, 'VPN_SESSION_CHANGED', false);
      expectRejected(stoppedDelay, 'VPN_SESSION_CHANGED', false);
      expectRejected(closedQuery, 'VPN_SESSION_CHANGED', false);
      expectRejected(stoppingDelayRead, 'VPN_SESSION_CHANGED', false);
      expect(client.requests.length).assertEqual(0);

      client.stateValue = 'READY';
      client.snapshotValue = createSnapshot('RUNNING');
      const selectorGroup: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 2);
      const alphaNode: VpnOpaqueCatalogEntry = requireEntry(catalog, selectorGroup.childIds[0]);
      client.responses.push(
        createSuccessResponse(
          'SELECT_NODE',
          19,
          createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest),
          createVpnRpcSelectNodeResultPayload(19, selectorGroup.id, alphaNode.id, true)
        )
      );

      const readySelection: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 19, 'Selector Group', 'Alpha')
      );
      expect(readySelection.kind).assertEqual('APPLIED_NOW');
      expect(client.requests.length).assertEqual(1);
    });

    it('mapsThrownSessionChangedFailuresToNonRetryableRouteParity', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]));

      client.responses.push(new VpnRpcTransportFailure('session changed', 'SESSION_CHANGED', true));
      client.responses.push(new VpnRpcTransportFailure('session changed', 'SESSION_CHANGED', true));
      client.responses.push(new VpnRpcTransportFailure('session changed', 'SESSION_CHANGED', true));

      const queryRejected: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 23, 'Gateway')
      );
      const selectRejected: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 23, 'Selector Group', 'Alpha')
      );
      const delayRejected: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 23, 'Delay Lab')
      );

      expectRejected(queryRejected, 'VPN_SESSION_CHANGED', false);
      expectRejected(selectRejected, 'VPN_SESSION_CHANGED', false);
      expectRejected(delayRejected, 'VPN_SESSION_CHANGED', false);
      expect(client.requests.length).assertEqual(3);
    });

    it('mapsServerSessionChangedResponsesToNonRetryableRouteParity', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2, TIMESTAMP_3]));

      client.responses.push(createErrorResponse('QUERY_GROUP', 29, guards, 'SESSION_CHANGED', true));
      client.responses.push(createErrorResponse('SELECT_NODE', 29, guards, 'SESSION_CHANGED', true));
      client.responses.push(createErrorResponse('START_DELAY_TEST', 29, guards, 'SESSION_CHANGED', true));

      const queryRejected: ProxyGroupQueryResult = await handler.queryGroup(
        createVpnProxyQueryGroupCommand(createIdentity(), 29, 'Gateway')
      );
      const selectRejected: ProxySelectionResult = await handler.select(
        createVpnProxySelectCommand(createIdentity(), 29, 'Selector Group', 'Alpha')
      );
      const delayRejected: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 29, 'Delay Lab')
      );

      expectRejected(queryRejected, 'VPN_SESSION_CHANGED', false);
      expectRejected(selectRejected, 'VPN_SESSION_CHANGED', false);
      expectRejected(delayRejected, 'VPN_SESSION_CHANGED', false);
      expect(client.requests.length).assertEqual(3);
    });

    it('mapsDelaySnapshotsAcrossAllJobAndNodeStatesAndSanitizesTimeoutsAndSessionChanges', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog();
      const guards: VpnRpcGuards = createVpnRpcGuards(catalog.profileHash, catalog.revisionHash, catalog.catalogDigest);
      const delayGroup: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 3);
      const waitNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[0]);
      const testNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[1]);
      const fastNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[2]);
      const slowNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[3]);
      const failNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[4]);
      const cancelNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[5]);
      const unsupportedNode: VpnOpaqueCatalogEntry = requireEntry(catalog, delayGroup.childIds[6]);
      const client: FakeVpnRpcClient = new FakeVpnRpcClient();
      const handler = new VpnRpcProxyHandler(client, catalog, buildClock([TIMESTAMP_1, TIMESTAMP_2]));

      client.responses.push(
        createSuccessResponse(
          'START_DELAY_TEST',
          13,
          guards,
          createVpnRpcDelaySnapshotPayload(
            waitNode.id,
            3,
            13,
            delayGroup.id,
            'RUNNING',
            7,
            5,
            [
              createVpnRpcDelayResult(waitNode.id, 'WAITING', null),
              createVpnRpcDelayResult(testNode.id, 'TESTING', null),
              createVpnRpcDelayResult(fastNode.id, 'AVAILABLE', 90),
              createVpnRpcDelayResult(slowNode.id, 'TIMEOUT', null),
              createVpnRpcDelayResult(failNode.id, 'FAILED', null),
              createVpnRpcDelayResult(cancelNode.id, 'CANCELLED', null),
              createVpnRpcDelayResult(unsupportedNode.id, 'UNSUPPORTED', null)
            ]
          )
        )
      );
      client.responses.push(
        createSuccessResponse(
          'READ_DELAY_TEST',
          13,
          guards,
          createVpnRpcDelaySnapshotPayload(
            waitNode.id,
            4,
            13,
            delayGroup.id,
            'COMPLETED',
            7,
            7,
            [
              createVpnRpcDelayResult(waitNode.id, 'TIMEOUT', null),
              createVpnRpcDelayResult(testNode.id, 'FAILED', null),
              createVpnRpcDelayResult(fastNode.id, 'AVAILABLE', 90),
              createVpnRpcDelayResult(slowNode.id, 'TIMEOUT', null),
              createVpnRpcDelayResult(failNode.id, 'FAILED', null),
              createVpnRpcDelayResult(cancelNode.id, 'CANCELLED', null),
              createVpnRpcDelayResult(unsupportedNode.id, 'UNSUPPORTED', null)
            ]
          )
        )
      );
      client.responses.push(
        createSuccessResponse(
          'CANCEL_DELAY_TEST',
          13,
          guards,
          createVpnRpcDelaySnapshotPayload(
            waitNode.id,
            5,
            13,
            delayGroup.id,
            'CANCELLED',
            7,
            7,
            [
              createVpnRpcDelayResult(waitNode.id, 'CANCELLED', null),
              createVpnRpcDelayResult(testNode.id, 'CANCELLED', null),
              createVpnRpcDelayResult(fastNode.id, 'AVAILABLE', 90),
              createVpnRpcDelayResult(slowNode.id, 'TIMEOUT', null),
              createVpnRpcDelayResult(failNode.id, 'FAILED', null),
              createVpnRpcDelayResult(cancelNode.id, 'CANCELLED', null),
              createVpnRpcDelayResult(unsupportedNode.id, 'UNSUPPORTED', null)
            ]
          )
        )
      );
      client.responses.push(createErrorResponse('READ_DELAY_TEST', 13, guards, 'SESSION_CHANGED', true));
      client.responses.push(new VpnRpcTransportFailure('VPN RPC command timed out.', 'COMMAND_TIMEOUT', true));

      const started: ProxyDelayResult = await handler.startDelayTest(
        createVpnProxyStartDelayTestCommand(createIdentity(), 13, 'Delay Lab')
      );
      const completed: ProxyDelayResult = await handler.readDelayTest(
        createVpnProxyReadDelayTestCommand(createIdentity(), 13, waitNode.id)
      );
      const cancelled: ProxyDelayResult = await handler.cancelDelayTest(
        createVpnProxyCancelDelayTestCommand(createIdentity(), 13, waitNode.id)
      );
      const changedSession: ProxyDelayResult = await handler.readDelayTest(
        createVpnProxyReadDelayTestCommand(createIdentity(), 13, waitNode.id)
      );
      const timedOut: ProxyDelayResult = await handler.readDelayTest(
        createVpnProxyReadDelayTestCommand(createIdentity(), 13, waitNode.id)
      );

      expect(started.kind).assertEqual('SNAPSHOT');
      if (started.kind === 'SNAPSHOT') {
        expect(started.state).assertEqual('RUNNING');
        expect(started.groupName).assertEqual('Delay Lab');
        expect(started.jobId).assertEqual(waitNode.id);
        expect(started.totalCount).assertEqual(7);
        expect(started.testableCount).assertEqual(6);
        expect(started.completedCount).assertEqual(5);
        expect(started.availableCount).assertEqual(1);
        expect(started.timeoutCount).assertEqual(1);
        expect(started.failedCount).assertEqual(1);
        expect(started.cancelledCount).assertEqual(1);
        expect(started.unsupportedCount).assertEqual(1);
        expect(started.fastestNodeIndex).assertEqual(2);
        expect(started.nodes[2].name).assertEqual('Fast');
        expect(started.nodes[2].fastest).assertTrue();
        expect(started.nodes[2].delayMs ?? 0).assertEqual(90);
      }

      expect(completed.kind).assertEqual('SNAPSHOT');
      if (completed.kind === 'SNAPSHOT') {
        expect(completed.state).assertEqual('COMPLETED');
        expect(completed.completedCount).assertEqual(7);
      }

      expect(cancelled.kind).assertEqual('SNAPSHOT');
      if (cancelled.kind === 'SNAPSHOT') {
        expect(cancelled.state).assertEqual('CANCELLED');
      }

      expectRejected(changedSession, 'VPN_SESSION_CHANGED', false);
      expectRejected(timedOut, 'PROXY_DELAY_TEST_FAILED', true);
      assertNoRawLeaks(client.requests[0], ['Delay Lab', 'Fast', CORE_JOB_ID, PROFILE_ID, REVISION_ID, PRIVATE_PROFILE_PATH]);
      assertNoRawLeaks(client.requests[1], [CORE_JOB_ID, PRIVATE_PROFILE_PATH]);
    });
  });
}
