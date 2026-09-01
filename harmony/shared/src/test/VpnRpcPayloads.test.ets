import { describe, expect, it } from '@ohos/hypium';
import {
  cloneVpnRpcRuntimeSnapshotPayload,
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyRequest,
  createVpnRpcBodySuccessResponse,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcError,
  createVpnRpcGuards,
  createVpnRpcRuntimeSnapshotPayload,
  createVpnRpcRuntimeModePayload,
  cloneVpnRpcRuntimeModePayload,
  decodeVpnRpcBodyText,
  encodeVpnRpcBodyToText,
  type VpnRpcBody,
  type VpnRpcDelaySnapshotPayload,
  type VpnRpcGuards,
  type VpnRpcRuntimeSnapshotPayload,
  type VpnRpcRuntimeModePayload
} from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';

const PROFILE_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const REVISION_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const CATALOG_DIGEST: string = '439490f7d5c249e4568e736a9e7a0f45c674f6fb355adf8d61d82a1d0276f219';
const GROUP_ID: string = 'f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a1';
const NODE_ID: string = 'b0a8d82ab2b6e1ad9a5e2eccc169707e55492a94a5f346435864b66a78284757';
const OTHER_NODE_ID: string = 'c0a8d82ab2b6e1ad9a5e2eccc169707e55492a94a5f346435864b66a78284758';
const JOB_ID: string = '17490f3b8bcfcabf9fea8acbfb448aa912d0c4c000ea6404603201571ca79f34';
const SERVER_INSTANCE: string = '606162636465666768696a6b6c6d6e6f';
const REQUEST_ID: string = '00000000-0000-4000-8000-000000000001';
const OTHER_REQUEST_ID: string = '00000000-0000-4000-8000-000000000002';
const TX_BYTES: number = 1234;
const RX_BYTES: number = 5678;
const ACTIVE_GUARDS_TEXT: string =
  `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`;
const NULL_GUARDS_TEXT: string = '{"profileHash":null,"revisionHash":null,"catalogDigest":null}';
const CATALOG_GUARDS_TEXT: string =
  `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":null}`;
const RUNTIME_PAYLOAD_TEXT: string =
  `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":${TX_BYTES},"rxBytes":${RX_BYTES}}`;
const DELAY_PAYLOAD_TEXT: string =
  `{"jobId":"${JOB_ID}","delayRevision":8,"proxyGeneration":3,"groupId":"${GROUP_ID}","state":"RUNNING","totalCount":2,"completedCount":1,"results":[{"nodeId":"${NODE_ID}","status":"AVAILABLE","delayMs":41},{"nodeId":"${OTHER_NODE_ID}","status":"WAITING","delayMs":null}]}`;
const QUERY_GROUPS_SUCCESS_PAYLOAD_TEXT: string =
  `{"proxyGeneration":3,"groups":[{"groupId":"${GROUP_ID}","type":"Selector","isSelectable":true}]}`;
const QUERY_GROUP_SUCCESS_PAYLOAD_TEXT: string =
  `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","nodes":[{"nodeId":"${NODE_ID}","kind":"TERMINAL","type":"Vmess","selected":true},{"nodeId":"${OTHER_NODE_ID}","kind":"GROUP","type":"Selector","selected":false}]}`;
const SELECT_NODE_SUCCESS_PAYLOAD_TEXT: string =
  `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","persisted":true}`;
const EMPTY_ERROR_PAYLOAD_TEXT: string = '{}';
const PROTOCOL_MISMATCH_ERROR_TEXT: string = '{"code":"PROTOCOL_MISMATCH","retryable":false}';
const RPC_UNAVAILABLE_ERROR_TEXT: string = '{"code":"RPC_UNAVAILABLE","retryable":true}';
const CATALOG_MISMATCH_ERROR_TEXT: string = '{"code":"CATALOG_MISMATCH","retryable":true}';
const CORE_OPERATION_FAILED_ERROR_TEXT: string = '{"code":"CORE_OPERATION_FAILED","retryable":true}';
const FRAME_INVALID_ERROR_TEXT: string = '{"code":"FRAME_INVALID","retryable":false}';
const COMMAND_BUSY_ERROR_TEXT: string = '{"code":"COMMAND_BUSY","retryable":true}';
const COMMAND_TIMEOUT_ERROR_TEXT: string = '{"code":"COMMAND_TIMEOUT","retryable":true}';
const SESSION_CHANGED_ERROR_TEXT: string = '{"code":"SESSION_CHANGED","retryable":true}';
const REQUEST_REPLAY_EXPIRED_ERROR_TEXT: string = '{"code":"REQUEST_REPLAY_EXPIRED","retryable":false}';
const SERVER_STOPPING_ERROR_TEXT: string = '{"code":"SERVER_STOPPING","retryable":true}';

function buildActiveGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST);
}

function buildRuntimeSnapshotPayload(): VpnRpcRuntimeSnapshotPayload {
  return createVpnRpcRuntimeSnapshotPayload('RUNNING', PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST, true, 1, null, null, TX_BYTES, RX_BYTES);
}

function buildDelayPayload(): VpnRpcDelaySnapshotPayload {
  return createVpnRpcDelaySnapshotPayload(
    JOB_ID,
    8,
    3,
    GROUP_ID,
    'RUNNING',
    2,
    1,
    [
      createVpnRpcDelayResult(NODE_ID, 'AVAILABLE', 41),
      createVpnRpcDelayResult(OTHER_NODE_ID, 'WAITING', null)
    ]
  );
}

function bodyText(
  kind: 'REQUEST' | 'RESPONSE' | 'EVENT',
  sequence: number,
  clientEpoch: number,
  requestOrdinalText: string,
  requestIdText: string,
  method: string,
  sessionGeneration: number,
  guardsText: string,
  okText: string,
  errorText: string,
  payloadText: string
): string {
  return `{"protocolVersion":1,"kind":"${kind}","sequence":${sequence},"clientEpoch":${clientEpoch},"requestOrdinal":${requestOrdinalText},"requestId":${requestIdText},"method":"${method}","sessionGeneration":${sessionGeneration},"guards":${guardsText},"ok":${okText},"error":${errorText},"payload":${payloadText}}`;
}

class BodyCase {
  body: VpnRpcBody;
  expectedText: string;

  constructor(body: VpnRpcBody, expectedText: string) {
    this.body = body;
    this.expectedText = expectedText;
  }
}

export default function vpnRpcPayloadsTestsuite() {
  describe('VpnRpcPayloadsTest', () => {
    it('roundTripsClosedRuntimeModeRequestsAndResponses', 0, () => {
      const guards: VpnRpcGuards = buildActiveGuards();
      const setPayload: VpnRpcRuntimeModePayload = createVpnRpcRuntimeModePayload('GLOBAL');
      const request: VpnRpcBody = createVpnRpcBodyRequest(
        71,
        7,
        31,
        REQUEST_ID,
        'SET_MODE',
        4,
        guards,
        setPayload
      );
      const response: VpnRpcBody = createVpnRpcBodySuccessResponse(
        72,
        7,
        31,
        REQUEST_ID,
        'SET_MODE',
        4,
        guards,
        cloneVpnRpcRuntimeModePayload(setPayload)
      );
      const encodedRequest: string = encodeVpnRpcBodyToText(request);
      const encodedResponse: string = encodeVpnRpcBodyToText(response);

      expect(encodedRequest).assertEqual(
        bodyText('REQUEST', 71, 7, '31', `"${REQUEST_ID}"`, 'SET_MODE', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', '{"mode":"GLOBAL"}')
      );
      expect(encodedResponse).assertEqual(
        bodyText('RESPONSE', 72, 7, '31', `"${REQUEST_ID}"`, 'SET_MODE', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', '{"mode":"GLOBAL"}')
      );
      expect((decodeVpnRpcBodyText(encodedRequest).payload as VpnRpcRuntimeModePayload).mode).assertEqual('GLOBAL');
      expect((decodeVpnRpcBodyText(encodedResponse).payload as VpnRpcRuntimeModePayload).mode).assertEqual('GLOBAL');
      expectThrowsMessage(() => {
        createVpnRpcRuntimeModePayload('SCRIPT');
      }, 'VpnRpcRuntimeModePayload mode must stay inside the closed runtime mode contract.');
    });

    it('createsClonesAndValidatesRuntimeSnapshotTrafficCounters', 0, () => {
      const created: VpnRpcRuntimeSnapshotPayload = buildRuntimeSnapshotPayload();
      const cloned: VpnRpcRuntimeSnapshotPayload = cloneVpnRpcRuntimeSnapshotPayload(created);
      const encodedText: string = encodeVpnRpcBodyToText(
        decodeVpnRpcBodyText(bodyText('EVENT', 31, 7, 'null', 'null', 'RUNTIME_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', RUNTIME_PAYLOAD_TEXT))
      );

      expect(created.txBytes).assertEqual(TX_BYTES);
      expect(created.rxBytes).assertEqual(RX_BYTES);
      expect(cloned.txBytes).assertEqual(TX_BYTES);
      expect(cloned.rxBytes).assertEqual(RX_BYTES);
      expect(encodedText).assertEqual(bodyText('EVENT', 31, 7, 'null', 'null', 'RUNTIME_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', RUNTIME_PAYLOAD_TEXT));

      expectThrowsMessage(() => {
        createVpnRpcRuntimeSnapshotPayload('RUNNING', PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST, true, 1, null, null, -1, RX_BYTES);
      }, 'VpnRpcRuntimeSnapshotPayload txBytes must be a safe non-negative integer.');

      expectThrowsMessage(() => {
        createVpnRpcRuntimeSnapshotPayload('RUNNING', PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST, true, 1, null, null, TX_BYTES, 1.5);
      }, 'VpnRpcRuntimeSnapshotPayload rxBytes must be a safe non-negative integer.');

      expectThrowsMessage(() => {
        createVpnRpcRuntimeSnapshotPayload('RUNNING', PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST, true, 1, null, null, 9007199254740992, RX_BYTES);
      }, 'VpnRpcRuntimeSnapshotPayload txBytes must be a safe non-negative integer.');
    });

    it('encodesAndDecodesEveryMethodRequestSuccessErrorAndEventWithExactPayloadShapes', 0, () => {
      const runtimePayload: VpnRpcRuntimeSnapshotPayload = buildRuntimeSnapshotPayload();
      const delayPayload: VpnRpcDelaySnapshotPayload = buildDelayPayload();
      const activeGuards: VpnRpcGuards = buildActiveGuards();
      const requestCases: BodyCase[] = [
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              1,
              7,
              '1',
              `"${REQUEST_ID}"`,
              'PING',
              0,
              '{"profileHash":null,"revisionHash":null,"catalogDigest":null}',
              'null',
              'null',
              '{}'
            )
          ),
          bodyText(
            'REQUEST',
            1,
            7,
            '1',
            `"${REQUEST_ID}"`,
            'PING',
            0,
            '{"profileHash":null,"revisionHash":null,"catalogDigest":null}',
            'null',
            'null',
            '{}'
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              2,
              7,
              '2',
              `"${OTHER_REQUEST_ID}"`,
              'GET_SNAPSHOT',
              0,
              '{"profileHash":null,"revisionHash":null,"catalogDigest":null}',
              'null',
              'null',
              '{}'
            )
          ),
          bodyText(
            'REQUEST',
            2,
            7,
            '2',
            `"${OTHER_REQUEST_ID}"`,
            'GET_SNAPSHOT',
            0,
            '{"profileHash":null,"revisionHash":null,"catalogDigest":null}',
            'null',
            'null',
            '{}'
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              3,
              7,
              '3',
              '"00000000-0000-4000-8000-000000000003"',
              'GET_CATALOG_DIGEST',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":null}`,
              'null',
              'null',
              '{}'
            )
          ),
          bodyText(
            'REQUEST',
            3,
            7,
            '3',
            '"00000000-0000-4000-8000-000000000003"',
            'GET_CATALOG_DIGEST',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":null}`,
            'null',
            'null',
            '{}'
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              4,
              7,
              '4',
              '"00000000-0000-4000-8000-000000000004"',
              'QUERY_GROUPS',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              '{}'
            )
          ),
          bodyText(
            'REQUEST',
            4,
            7,
            '4',
            '"00000000-0000-4000-8000-000000000004"',
            'QUERY_GROUPS',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            '{}'
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              5,
              7,
              '5',
              '"00000000-0000-4000-8000-000000000005"',
              'QUERY_GROUP',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              `{"groupId":"${GROUP_ID}"}`
            )
          ),
          bodyText(
            'REQUEST',
            5,
            7,
            '5',
            '"00000000-0000-4000-8000-000000000005"',
            'QUERY_GROUP',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            `{"groupId":"${GROUP_ID}"}`
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              6,
              7,
              '6',
              '"00000000-0000-4000-8000-000000000006"',
              'SELECT_NODE',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              `{"proxyGeneration":3,"groupId":"${GROUP_ID}","nodeId":"${NODE_ID}"}`
            )
          ),
          bodyText(
            'REQUEST',
            6,
            7,
            '6',
            '"00000000-0000-4000-8000-000000000006"',
            'SELECT_NODE',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            `{"proxyGeneration":3,"groupId":"${GROUP_ID}","nodeId":"${NODE_ID}"}`
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              7,
              7,
              '7',
              '"00000000-0000-4000-8000-000000000007"',
              'START_DELAY_TEST',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              `{"proxyGeneration":3,"groupId":"${GROUP_ID}"}`
            )
          ),
          bodyText(
            'REQUEST',
            7,
            7,
            '7',
            '"00000000-0000-4000-8000-000000000007"',
            'START_DELAY_TEST',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            `{"proxyGeneration":3,"groupId":"${GROUP_ID}"}`
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              8,
              7,
              '8',
              '"00000000-0000-4000-8000-000000000008"',
              'READ_DELAY_TEST',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              `{"jobId":"${JOB_ID}"}`
            )
          ),
          bodyText(
            'REQUEST',
            8,
            7,
            '8',
            '"00000000-0000-4000-8000-000000000008"',
            'READ_DELAY_TEST',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            `{"jobId":"${JOB_ID}"}`
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              9,
              7,
              '9',
              '"00000000-0000-4000-8000-000000000009"',
              'CANCEL_DELAY_TEST',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              `{"jobId":"${JOB_ID}"}`
            )
          ),
          bodyText(
            'REQUEST',
            9,
            7,
            '9',
            '"00000000-0000-4000-8000-000000000009"',
            'CANCEL_DELAY_TEST',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            `{"jobId":"${JOB_ID}"}`
          )
        ),
        new BodyCase(
          decodeVpnRpcBodyText(
            bodyText(
              'REQUEST',
              10,
              7,
              '10',
              '"00000000-0000-4000-8000-000000000010"',
              'STOP_VPN',
              4,
              `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
              'null',
              'null',
              '{}'
            )
          ),
          bodyText(
            'REQUEST',
            10,
            7,
            '10',
            '"00000000-0000-4000-8000-000000000010"',
            'STOP_VPN',
            4,
            `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
            'null',
            'null',
            '{}'
          )
        )
      ];

      const successCases: BodyCase[] = [
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 11, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'true', 'null', `{"serverInstance":"${SERVER_INSTANCE}"}`)),
          bodyText('RESPONSE', 11, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'true', 'null', `{"serverInstance":"${SERVER_INSTANCE}"}`)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 12, 7, '2', `"${OTHER_REQUEST_ID}"`, 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 12, 7, '2', `"${OTHER_REQUEST_ID}"`, 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 13, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'true', 'null', `{"catalogDigest":"${CATALOG_DIGEST}","entryCount":2}`)),
          bodyText('RESPONSE', 13, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'true', 'null', `{"catalogDigest":"${CATALOG_DIGEST}","entryCount":2}`)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 14, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', QUERY_GROUPS_SUCCESS_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 14, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', QUERY_GROUPS_SUCCESS_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 15, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', QUERY_GROUP_SUCCESS_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 15, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', QUERY_GROUP_SUCCESS_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 16, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', SELECT_NODE_SUCCESS_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 16, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', SELECT_NODE_SUCCESS_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 17, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 17, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 18, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 18, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 19, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 19, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('RESPONSE', 20, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT)),
          bodyText('RESPONSE', 20, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT)
        )
      ];
      const errorCases: BodyCase[] = [
        new BodyCase(
          createVpnRpcBodyErrorResponse(21, 7, 1, REQUEST_ID, 'PING', 0, createVpnRpcGuards(null, null, null), createVpnRpcError('PROTOCOL_MISMATCH', false)),
          bodyText('RESPONSE', 21, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'false', PROTOCOL_MISMATCH_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(22, 7, 2, OTHER_REQUEST_ID, 'GET_SNAPSHOT', 0, createVpnRpcGuards(null, null, null), createVpnRpcError('RPC_UNAVAILABLE', true)),
          bodyText('RESPONSE', 22, 7, '2', `"${OTHER_REQUEST_ID}"`, 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'false', RPC_UNAVAILABLE_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(23, 7, 3, '00000000-0000-4000-8000-000000000003', 'GET_CATALOG_DIGEST', 4, createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, null), createVpnRpcError('CATALOG_MISMATCH', true)),
          bodyText('RESPONSE', 23, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'false', CATALOG_MISMATCH_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(24, 7, 4, '00000000-0000-4000-8000-000000000004', 'QUERY_GROUPS', 4, activeGuards, createVpnRpcError('CORE_OPERATION_FAILED', true)),
          bodyText('RESPONSE', 24, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'false', CORE_OPERATION_FAILED_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(25, 7, 5, '00000000-0000-4000-8000-000000000005', 'QUERY_GROUP', 4, activeGuards, createVpnRpcError('FRAME_INVALID', false)),
          bodyText('RESPONSE', 25, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'false', FRAME_INVALID_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(26, 7, 6, '00000000-0000-4000-8000-000000000006', 'SELECT_NODE', 4, activeGuards, createVpnRpcError('COMMAND_BUSY', true)),
          bodyText('RESPONSE', 26, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'false', COMMAND_BUSY_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(27, 7, 7, '00000000-0000-4000-8000-000000000007', 'START_DELAY_TEST', 4, activeGuards, createVpnRpcError('COMMAND_TIMEOUT', true)),
          bodyText('RESPONSE', 27, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', COMMAND_TIMEOUT_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(28, 7, 8, '00000000-0000-4000-8000-000000000008', 'READ_DELAY_TEST', 4, activeGuards, createVpnRpcError('SESSION_CHANGED', true)),
          bodyText('RESPONSE', 28, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', SESSION_CHANGED_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(29, 7, 9, '00000000-0000-4000-8000-000000000009', 'CANCEL_DELAY_TEST', 4, activeGuards, createVpnRpcError('REQUEST_REPLAY_EXPIRED', false)),
          bodyText('RESPONSE', 29, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', REQUEST_REPLAY_EXPIRED_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        ),
        new BodyCase(
          createVpnRpcBodyErrorResponse(30, 7, 10, '00000000-0000-4000-8000-000000000010', 'STOP_VPN', 4, activeGuards, createVpnRpcError('SERVER_STOPPING', true)),
          bodyText('RESPONSE', 30, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'false', SERVER_STOPPING_ERROR_TEXT, EMPTY_ERROR_PAYLOAD_TEXT)
        )
      ];
      const eventCases: BodyCase[] = [
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('EVENT', 31, 7, 'null', 'null', 'RUNTIME_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', RUNTIME_PAYLOAD_TEXT)),
          bodyText('EVENT', 31, 7, 'null', 'null', 'RUNTIME_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', RUNTIME_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('EVENT', 32, 7, 'null', 'null', 'DELAY_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', DELAY_PAYLOAD_TEXT)),
          bodyText('EVENT', 32, 7, 'null', 'null', 'DELAY_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', DELAY_PAYLOAD_TEXT)
        ),
        new BodyCase(
          decodeVpnRpcBodyText(bodyText('EVENT', 33, 7, 'null', 'null', 'SERVER_STOPPING', 0, NULL_GUARDS_TEXT, 'null', 'null', '{}')),
          bodyText('EVENT', 33, 7, 'null', 'null', 'SERVER_STOPPING', 0, NULL_GUARDS_TEXT, 'null', 'null', '{}')
        )
      ];

      for (let index: number = 0; index < requestCases.length; index += 1) {
        const actual: string = encodeVpnRpcBodyToText(requestCases[index].body);
        expect(actual).assertEqual(requestCases[index].expectedText);
        expect(decodeVpnRpcBodyText(actual).method).assertEqual(requestCases[index].body.method);
      }
      for (let index: number = 0; index < successCases.length; index += 1) {
        const actual: string = encodeVpnRpcBodyToText(successCases[index].body);
        const decoded: VpnRpcBody = decodeVpnRpcBodyText(actual);
        expect(actual).assertEqual(successCases[index].expectedText);
        expect(decoded.kind).assertEqual('RESPONSE');
        expect(decoded.ok).assertTrue();
        expect(decoded.error).assertNull();
      }
      for (let index: number = 0; index < errorCases.length; index += 1) {
        const actual: string = encodeVpnRpcBodyToText(errorCases[index].body);
        const decoded: VpnRpcBody = decodeVpnRpcBodyText(actual);
        expect(actual).assertEqual(errorCases[index].expectedText);
        expect(decoded.kind).assertEqual('RESPONSE');
        expect(decoded.ok).assertFalse();
        expect(decoded.error?.code).assertEqual(errorCases[index].body.error?.code);
      }
      for (let index: number = 0; index < eventCases.length; index += 1) {
        const actual: string = encodeVpnRpcBodyToText(eventCases[index].body);
        const decoded: VpnRpcBody = decodeVpnRpcBodyText(actual);
        expect(actual).assertEqual(eventCases[index].expectedText);
        expect(decoded.kind).assertEqual('EVENT');
        expect(decoded.requestOrdinal).assertNull();
        expect(decoded.requestId).assertNull();
      }
    });
  });
}
