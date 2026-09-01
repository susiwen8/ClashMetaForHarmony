import { describe, expect, it } from '@ohos/hypium';
import type {
  CoreError,
  CoreProxyDelaySnapshot,
  CoreProxyQueryContext,
  CoreProxyType
} from '@cmfa/shared';
import { CoreNativeAdapter, type InternalTunNativeModule } from '../main/ets/CoreNativeAdapter';
import {
  decodeCancelProxyDelayTest,
  decodeReadProxyDelayTest,
  decodeStartProxyDelayTest
} from '../main/ets/ProxyDelayNativeCodec';

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

class DelayNodePayloadValue {
  index: number = 0;
  name: string = '';
  type: CoreProxyType = 'Direct';
  state: 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED' = 'WAITING';
  delayMs: number | null = null;
  source: 'PROVIDER' | 'FALLBACK' | null = null;
  fastest: boolean = false;
}

class DelaySnapshotPayloadValue {
  schemaVersion: '1.0.0' = '1.0.0';
  jobId: string = '';
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED' = 'RUNNING';
  profileHash: string = '';
  revisionHash: string = '';
  sessionHash: string | null = null;
  generation: number = 0;
  groupName: string = '';
  totalCount: number = 0;
  testableCount: number = 0;
  completedCount: number = 0;
  availableCount: number = 0;
  timeoutCount: number = 0;
  failedCount: number = 0;
  cancelledCount: number = 0;
  unsupportedCount: number = 0;
  fastestNodeIndex: number | null = null;
  nodes: DelayNodePayloadValue[] = [];
}

class DelayNativeCallRecord {
  context?: CoreProxyQueryContext;
  groupName?: string;
  jobId?: string;
}

class FakeDelayNativeModule implements InternalTunNativeModule {
  readonly calls: DelayNativeCallRecord[] = [];
  startRaw: string = '';
  readRaw: string = '';
  cancelRaw: string = '';
  startThrow?: NativeBridgeFailure;
  readReject?: NativeBridgeFailure;
  cancelReject?: NativeBridgeFailure;
  mutateStartContextInPlace: boolean = false;
  mutatedProfileHash: string = buildHex('mutated-delay-profile');
  mutatedGeneration: number = 77;

  async startProxyDelayTest(context: CoreProxyQueryContext, groupName: string): Promise<string> {
    const record = new DelayNativeCallRecord();
    record.context = context;
    record.groupName = groupName;
    this.calls.push(record);
    if (this.startThrow !== undefined) {
      throw this.startThrow;
    }
    if (this.mutateStartContextInPlace) {
      context.profileHash = this.mutatedProfileHash;
      context.generation = this.mutatedGeneration;
      return buildDelaySnapshotPayload(context, groupName, fixedJobId(), 'RUNNING', buildRunningNodes());
    }
    return this.startRaw;
  }

  async readProxyDelayTest(jobId: string): Promise<string> {
    const record = new DelayNativeCallRecord();
    record.jobId = jobId;
    this.calls.push(record);
    if (this.readReject !== undefined) {
      return await Promise.reject(this.readReject);
    }
    return this.readRaw;
  }

  async cancelProxyDelayTest(jobId: string): Promise<string> {
    const record = new DelayNativeCallRecord();
    record.jobId = jobId;
    this.calls.push(record);
    if (this.cancelReject !== undefined) {
      return await Promise.reject(this.cancelReject);
    }
    return this.cancelRaw;
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

function fixedJobId(): string {
  return '0123456789abcdef0123456789abcdef';
}

function buildContext(sessionHash: string | null = buildHex('delay-session'), generation: number = 21): CoreProxyQueryContext {
  const context = new ProxyQueryContextValue();
  context.profileHash = buildHex('delay-profile');
  context.revisionHash = buildHex('delay-revision');
  context.sessionHash = sessionHash;
  context.generation = generation;
  return context;
}

function buildNode(
  index: number,
  name: string,
  state: 'WAITING' | 'TESTING' | 'AVAILABLE' | 'TIMEOUT' | 'FAILED' | 'CANCELLED' | 'UNSUPPORTED',
  delayMs: number | null,
  source: 'PROVIDER' | 'FALLBACK' | null,
  fastest: boolean
): DelayNodePayloadValue {
  const node = new DelayNodePayloadValue();
  node.index = index;
  node.name = name;
  node.type = index === 0 ? 'URLTest' : index === 1 ? 'Trojan' : 'Shadowsocks';
  node.state = state;
  node.delayMs = delayMs;
  node.source = source;
  node.fastest = fastest;
  return node;
}

function buildRunningNodes(): DelayNodePayloadValue[] {
  return [
    buildNode(0, 'waiting-node', 'WAITING', null, 'PROVIDER', false),
    buildNode(1, 'ready-node', 'AVAILABLE', 82, 'FALLBACK', true),
    buildNode(2, 'unsupported-node', 'UNSUPPORTED', null, null, false)
  ];
}

function buildCompletedNodes(): DelayNodePayloadValue[] {
  return [
    buildNode(0, 'ready-node', 'AVAILABLE', 82, 'FALLBACK', true),
    buildNode(1, 'timeout-node', 'TIMEOUT', null, 'PROVIDER', false),
    buildNode(2, 'unsupported-node', 'UNSUPPORTED', null, null, false)
  ];
}

function buildDelayPayloadWithExactDelay(delayMs: number): string {
  const context: CoreProxyQueryContext = buildContext();
  return `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":1,"testableCount":1,"completedCount":1,"availableCount":1,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":0,"fastestNodeIndex":0,"nodes":[{"index":0,"name":"ready-node","type":"Trojan","state":"AVAILABLE","delayMs":${delayMs},"source":"PROVIDER","fastest":true}]}`;
}

function buildDuplicateRootKeyPayload(context: CoreProxyQueryContext): string {
  return `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":1,"testableCount":1,"completedCount":1,"availableCount":1,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":0,"fastestNodeIndex":0,"nodes":[{"index":0,"name":"ready-node","type":"Trojan","state":"AVAILABLE","delayMs":42,"source":"PROVIDER","fastest":true}],"groupName":"duplicate-group"}`;
}

function buildDuplicateNestedNodeKeyPayload(context: CoreProxyQueryContext): string {
  return `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":1,"testableCount":1,"completedCount":1,"availableCount":1,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":0,"fastestNodeIndex":0,"nodes":[{"index":0,"name":"ready-node","\\u006eame":"duplicate-node","type":"Trojan","state":"AVAILABLE","delayMs":42,"source":"PROVIDER","fastest":true}]}`;
}

function buildDelaySnapshotPayload(
  context: CoreProxyQueryContext,
  groupName: string,
  jobId: string,
  state: 'RUNNING' | 'COMPLETED' | 'CANCELLED' | 'FAILED',
  nodes: DelayNodePayloadValue[]
): string {
  const payload = new DelaySnapshotPayloadValue();
  payload.jobId = jobId;
  payload.state = state;
  payload.profileHash = context.profileHash;
  payload.revisionHash = context.revisionHash;
  payload.sessionHash = context.sessionHash;
  payload.generation = context.generation;
  payload.groupName = groupName;
  payload.totalCount = nodes.length;
  payload.testableCount = 0;
  payload.completedCount = 0;
  payload.availableCount = 0;
  payload.timeoutCount = 0;
  payload.failedCount = 0;
  payload.cancelledCount = 0;
  payload.unsupportedCount = 0;
  payload.fastestNodeIndex = null;
  let fastestDelay: number = 0;
  for (let index: number = 0; index < nodes.length; index += 1) {
    const node: DelayNodePayloadValue = nodes[index];
    if (node.state === 'UNSUPPORTED') {
      payload.unsupportedCount += 1;
    } else {
      payload.testableCount += 1;
    }
    if (node.state !== 'WAITING' && node.state !== 'TESTING') {
      payload.completedCount += 1;
    }
    if (node.state === 'AVAILABLE') {
      payload.availableCount += 1;
      const delay: number = node.delayMs as number;
      if (payload.fastestNodeIndex === null || delay < fastestDelay) {
        fastestDelay = delay;
        payload.fastestNodeIndex = index;
      }
    } else if (node.state === 'TIMEOUT') {
      payload.timeoutCount += 1;
    } else if (node.state === 'FAILED') {
      payload.failedCount += 1;
    } else if (node.state === 'CANCELLED') {
      payload.cancelledCount += 1;
    }
  }
  payload.nodes = nodes;
  return JSON.stringify(payload);
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

export default function proxyDelayNativeCodecTestsuite(): void {
  describe('ProxyDelayNativeCodecTest', () => {
    it('decodesDelaySnapshotsAndReturnsDeepClonedPublicData', 0, () => {
      const context: CoreProxyQueryContext = buildContext();
      const raw: string = buildDelaySnapshotPayload(context, 'url-test', fixedJobId(), 'COMPLETED', buildCompletedNodes());

      const decoded: CoreProxyDelaySnapshot = decodeStartProxyDelayTest(raw, context, 'url-test');
      expect(decoded.schemaVersion).assertEqual('1.0.0');
      expect(decoded.jobId).assertEqual(fixedJobId());
      expect(decoded.nodes.length).assertEqual(3);
      expect(decoded.nodes[1].state).assertEqual('TIMEOUT');
      expect(decoded.nodes[0].fastest).assertTrue();

      decoded.nodes[0].name = 'mutated';
      const decodedAgain: CoreProxyDelaySnapshot = decodeReadProxyDelayTest(raw, fixedJobId());
      expect(decodedAgain.nodes[0].name).assertEqual('ready-node');
    });

    it('rejectsUnknownMissingMalformedPrototypeAndPrivacyViolations', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('delay-redacted'), 23);
      const rawJson: string =
        `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":1,"testableCount":1,"completedCount":1,"availableCount":1,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":0,"fastestNodeIndex":0,"nodes":[{"index":0,"name":"leak-node","type":"Trojan","state":"AVAILABLE","delayMs":42,"source":"PROVIDER","fastest":true,"extra":true}]}`;

      const error: CoreError = await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeStartProxyDelayTest(rawJson, context, 'url-test') as Object,
        ['leak-node', context.profileHash, rawJson]
      );
      expect(error.context?.operation).assertEqual('startProxyDelayTest');

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeReadProxyDelayTest('{"jobId":"bad"}', fixedJobId()) as Object,
        ['{"jobId":"bad"}']
      );

      const protoPayload: string =
        `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":0,"testableCount":0,"completedCount":0,"availableCount":0,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":0,"fastestNodeIndex":null,"nodes":[],"__proto__":0}`;
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeCancelProxyDelayTest(protoPayload, fixedJobId()) as Object,
        ['__proto__', context.profileHash, protoPayload]
      );
    });

    it('rejectsDuplicateRootAndNestedNodeKeysBeforeJsonCollapse', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('duplicate-session'), 24);
      const duplicateRootPayload: string = buildDuplicateRootKeyPayload(context);
      const duplicateNestedPayload: string = buildDuplicateNestedNodeKeyPayload(context);

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeStartProxyDelayTest(duplicateRootPayload, context, 'url-test') as Object,
        ['duplicate-group', context.profileHash, duplicateRootPayload]
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeReadProxyDelayTest(duplicateNestedPayload, fixedJobId()) as Object,
        ['duplicate-node', 'ready-node', context.profileHash, duplicateNestedPayload]
      );
    });

    it('enforcesIdentityCountersFastestAndTerminalRules', 0, async () => {
      const context: CoreProxyQueryContext = buildContext();
      const wrongGroupPayload: string = buildDelaySnapshotPayload(context, 'other-group', fixedJobId(), 'RUNNING', buildRunningNodes());
      const wrongJobPayload: string = buildDelaySnapshotPayload(context, 'url-test', 'fedcba9876543210fedcba9876543210', 'COMPLETED', buildCompletedNodes());
      const liveCompletedPayload: string =
        `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":3,"testableCount":2,"completedCount":3,"availableCount":1,"timeoutCount":0,"failedCount":0,"cancelledCount":0,"unsupportedCount":1,"fastestNodeIndex":1,"nodes":[{"index":0,"name":"waiting-node","type":"URLTest","state":"WAITING","delayMs":null,"source":"PROVIDER","fastest":false},{"index":1,"name":"ready-node","type":"Trojan","state":"AVAILABLE","delayMs":82,"source":"FALLBACK","fastest":true},{"index":2,"name":"unsupported-node","type":"Shadowsocks","state":"UNSUPPORTED","delayMs":null,"source":null,"fastest":false}]}`;
      const badCountPayload: string =
        `{"schemaVersion":"1.0.0","jobId":"${fixedJobId()}","state":"COMPLETED","profileHash":"${context.profileHash}","revisionHash":"${context.revisionHash}","sessionHash":"${context.sessionHash}","generation":${context.generation},"groupName":"url-test","totalCount":99,"testableCount":2,"completedCount":3,"availableCount":1,"timeoutCount":1,"failedCount":0,"cancelledCount":0,"unsupportedCount":1,"fastestNodeIndex":1,"nodes":[{"index":0,"name":"ready-node","type":"URLTest","state":"AVAILABLE","delayMs":82,"source":"FALLBACK","fastest":true},{"index":1,"name":"timeout-node","type":"Trojan","state":"TIMEOUT","delayMs":null,"source":"PROVIDER","fastest":false},{"index":2,"name":"unsupported-node","type":"Shadowsocks","state":"UNSUPPORTED","delayMs":null,"source":null,"fastest":false}]}`;

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeStartProxyDelayTest(wrongGroupPayload, context, 'url-test') as Object,
        ['other-group']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeReadProxyDelayTest(wrongJobPayload, fixedJobId()) as Object,
        ['fedcba9876543210fedcba9876543210']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeCancelProxyDelayTest(liveCompletedPayload, fixedJobId()) as Object,
        ['WAITING']
      );
      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeReadProxyDelayTest(badCountPayload, fixedJobId()) as Object,
        ['99']
      );
    });

    it('acceptsUint16DelayUpperBoundAndRejectsOverflow', 0, async () => {
      const accepted: CoreProxyDelaySnapshot = decodeReadProxyDelayTest(buildDelayPayloadWithExactDelay(65535), fixedJobId());
      expect(accepted.nodes[0].delayMs).assertEqual(65535);

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => decodeReadProxyDelayTest(buildDelayPayloadWithExactDelay(65536), fixedJobId()) as Object,
        ['65536']
      );
    });

    it('adapterClonesDelayRequestsResultsAndNormalizesNativeErrors', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('adapter-delay-session'), 31);
      const module = new FakeDelayNativeModule();
      module.startRaw = buildDelaySnapshotPayload(context, 'url-test', fixedJobId(), 'RUNNING', buildRunningNodes());
      module.readRaw = buildDelaySnapshotPayload(context, 'url-test', fixedJobId(), 'COMPLETED', buildCompletedNodes());
      module.cancelRaw = buildDelaySnapshotPayload(context, 'url-test', fixedJobId(), 'CANCELLED', buildCompletedNodes());
      const adapter = new CoreNativeAdapter(module);

      const started: CoreProxyDelaySnapshot = await adapter.startProxyDelayTest(context, 'url-test');
      const read: CoreProxyDelaySnapshot = await adapter.readProxyDelayTest(fixedJobId());
      const cancelled: CoreProxyDelaySnapshot = await adapter.cancelProxyDelayTest(fixedJobId());

      expect(started.state).assertEqual('RUNNING');
      expect(read.state).assertEqual('COMPLETED');
      expect(cancelled.state).assertEqual('CANCELLED');
      expect(module.calls.length).assertEqual(3);
      expect(module.calls[0].groupName).assertEqual('url-test');
      expect(module.calls[1].jobId).assertEqual(fixedJobId());
      expect(module.calls[2].jobId).assertEqual(fixedJobId());

      context.profileHash = buildHex('mutated-caller');
      expect(module.calls[0].context?.profileHash).assertEqual(buildHex('delay-profile'));

      started.nodes[0].name = 'mutated-result';
      const startedAgain: CoreProxyDelaySnapshot = await adapter.startProxyDelayTest(buildContext(buildHex('adapter-delay-session'), 31), 'url-test');
      expect(startedAgain.nodes[0].name).assertEqual('waiting-node');

      module.startThrow = new NativeBridgeFailure('CMFA_BACKEND_ERROR', 'delay start exploded');
      try {
        await adapter.startProxyDelayTest(buildContext(), 'url-test');
        expect().assertFail();
      } catch (error) {
        const coreError: CoreError = toCoreError(error as Object);
        expect(coreError.code).assertEqual('CMFA_BACKEND_ERROR');
      }

      module.startThrow = undefined;
      module.readReject = new NativeBridgeFailure('CMFA_CORE_UNAVAILABLE', 'delay read rejected');
      try {
        await adapter.readProxyDelayTest(fixedJobId());
        expect().assertFail();
      } catch (error) {
        const coreError: CoreError = toCoreError(error as Object);
        expect(coreError.code).assertEqual('CMFA_CORE_UNAVAILABLE');
      }
    });

    it('adapterRejectsWhenNativeMutatesContextBeforeEchoingDelaySnapshot', 0, async () => {
      const context: CoreProxyQueryContext = buildContext(buildHex('delay-caller-context'), 41);
      const originalProfileHash: string = context.profileHash;
      const module = new FakeDelayNativeModule();
      module.mutateStartContextInPlace = true;
      const adapter = new CoreNativeAdapter(module);

      await expectProxyBridgeInvalid(
        async (): Promise<Object> => await adapter.startProxyDelayTest(context, 'url-test') as Object,
        [originalProfileHash, module.mutatedProfileHash]
      );
      expect(context.profileHash).assertEqual(originalProfileHash);
      expect(context.generation).assertEqual(41);
      expect(module.calls[0].context?.profileHash).assertEqual(module.mutatedProfileHash);
      expect(module.calls[0].context?.generation).assertEqual(module.mutatedGeneration);
    });
  });
}
