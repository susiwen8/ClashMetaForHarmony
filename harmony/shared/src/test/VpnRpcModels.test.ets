import { describe, expect, it } from '@ohos/hypium';
import {
  VPN_FAILURE_CODES,
  createVpnRpcBodyErrorResponse,
  createVpnRpcBodyRequest,
  createVpnRpcClientAuthBody,
  createVpnRpcDelayResult,
  createVpnRpcDelaySnapshotPayload,
  createVpnRpcError,
  createVpnRpcGuards,
  createVpnRpcServerAuthBody,
  createVpnRpcServerHelloBody,
  decodeVpnRpcBodyBytes,
  decodeVpnRpcBodyText,
  encodeVpnRpcBody,
  listVpnRpcDelayStatuses,
  listVpnRpcErrorCodes,
  listVpnRpcEventMethods,
  listVpnRpcKinds,
  listVpnRpcMethods,
  listVpnRpcRequestMethods,
  listVpnRpcResponseMethods,
  type VpnRpcBody,
  type VpnRpcGuards
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
const SERVER_NONCE: string = '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const CLIENT_NONCE: string = '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f';
const CLIENT_PROOF: string = '971120fc74215711b7de184881eb809ef8cb8bff91b23cf5452f1b3c797918d6';
const SERVER_PROOF: string = '3cb796ee27a9e40d0ee39dd41321673242dd4c25b33a3efb06fa181fabdec5cf';
const REQUEST_ID: string = '00000000-0000-4000-8000-000000000001';
const OTHER_REQUEST_ID: string = '00000000-0000-4000-8000-000000000002';
const APPENDIX_A_PING_BODY: string =
  '{"protocolVersion":1,"kind":"REQUEST","sequence":1,"clientEpoch":7,"requestOrdinal":1,"requestId":"00000000-0000-4000-8000-000000000001","method":"PING","sessionGeneration":0,"guards":{"profileHash":null,"revisionHash":null,"catalogDigest":null},"ok":null,"error":null,"payload":{}}';

function buildActiveGuards(): VpnRpcGuards {
  return createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, CATALOG_DIGEST);
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

export default function vpnRpcModelsTestsuite() {
  describe('VpnRpcModelsTest', () => {
    it('exposesClosedKindsMethodsErrorsAndHandshakeBodies', 0, () => {
      expect(listVpnRpcKinds().join(',')).assertEqual('REQUEST,RESPONSE,EVENT');
      expect(listVpnRpcRequestMethods().join(',')).assertEqual(
        'PING,GET_SNAPSHOT,GET_CATALOG_DIGEST,GET_MODE,SET_MODE,QUERY_GROUPS,QUERY_GROUP,SELECT_NODE,START_DELAY_TEST,READ_DELAY_TEST,CANCEL_DELAY_TEST,STOP_VPN'
      );
      expect(listVpnRpcResponseMethods().join(',')).assertEqual(
        'PING,GET_SNAPSHOT,GET_CATALOG_DIGEST,GET_MODE,SET_MODE,QUERY_GROUPS,QUERY_GROUP,SELECT_NODE,START_DELAY_TEST,READ_DELAY_TEST,CANCEL_DELAY_TEST,STOP_VPN'
      );
      expect(listVpnRpcEventMethods().join(',')).assertEqual('RUNTIME_CHANGED,DELAY_CHANGED,SERVER_STOPPING');
      expect(listVpnRpcMethods().join(',')).assertEqual(
        'PING,GET_SNAPSHOT,GET_CATALOG_DIGEST,GET_MODE,SET_MODE,QUERY_GROUPS,QUERY_GROUP,SELECT_NODE,START_DELAY_TEST,READ_DELAY_TEST,CANCEL_DELAY_TEST,STOP_VPN,RUNTIME_CHANGED,DELAY_CHANGED,SERVER_STOPPING'
      );
      expect(listVpnRpcErrorCodes().join(',')).assertEqual(
        'RPC_UNAVAILABLE,RPC_DISCONNECTED,AUTH_FAILED,PROTOCOL_MISMATCH,FRAME_INVALID,SESSION_CHANGED,CATALOG_MISMATCH,COMMAND_BUSY,COMMAND_TIMEOUT,CORE_OPERATION_FAILED,REQUEST_REPLAY_EXPIRED,SERVER_STOPPING'
      );
      expect(listVpnRpcDelayStatuses().join(',')).assertEqual(
        'WAITING,TESTING,AVAILABLE,TIMEOUT,FAILED,CANCELLED,UNSUPPORTED'
      );
      expect(VPN_FAILURE_CODES.includes('VPN_SYSTEM_REVOKED')).assertTrue();

      const hello = createVpnRpcServerHelloBody(1, SERVER_NONCE, SERVER_INSTANCE);
      const clientAuth = createVpnRpcClientAuthBody(1, CLIENT_NONCE, CLIENT_PROOF);
      const serverAuth = createVpnRpcServerAuthBody(1, 7, SERVER_PROOF);

      expect(hello.serverNonce).assertEqual(SERVER_NONCE);
      expect(clientAuth.clientProof).assertEqual(CLIENT_PROOF);
      expect(serverAuth.clientEpoch).assertEqual(7);
    });

    it('enforcesBodyInvariantsGuardRulesFormatsAndCloneIsolation', 0, () => {
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(1, 7, 1, REQUEST_ID, 'PING', 0, buildActiveGuards(), decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload);
      }, 'PING');
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(
          1,
          7,
          1,
          REQUEST_ID,
          'GET_CATALOG_DIGEST',
          0,
          createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, null),
          decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload
        );
      }, 'sessionGeneration');
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(
          1,
          7,
          1,
          REQUEST_ID,
          'SELECT_NODE',
          4,
          createVpnRpcGuards(PROFILE_HASH, REVISION_HASH, null),
          decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload
        );
      }, 'catalogDigest');
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(0, 7, 1, REQUEST_ID, 'PING', 0, createVpnRpcGuards(null, null, null), decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload);
      }, 'sequence');
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(1, 7, Number.MAX_SAFE_INTEGER + 1, REQUEST_ID, 'PING', 0, createVpnRpcGuards(null, null, null), decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload);
      }, 'requestOrdinal');
      expectThrowsMessage(() => {
        createVpnRpcBodyRequest(1, 7, 1, '00000000-0000-4000-8000-00000000000A', 'PING', 0, createVpnRpcGuards(null, null, null), decodeVpnRpcBodyText(APPENDIX_A_PING_BODY).payload);
      }, 'requestId');
      expectThrowsMessage(() => {
        createVpnRpcBodyErrorResponse(
          2,
          7,
          1,
          REQUEST_ID,
          'RUNTIME_CHANGED',
          4,
          buildActiveGuards(),
          createVpnRpcError('FRAME_INVALID', false)
        );
      }, 'RESPONSE');
      expectThrowsMessage(() => {
        createVpnRpcDelayResult(NODE_ID, 'AVAILABLE', null);
      }, 'delayMs');
      expectThrowsMessage(() => {
        createVpnRpcDelaySnapshotPayload(JOB_ID, 1, 3, GROUP_ID, 'RUNNING', 1, 2, [
          createVpnRpcDelayResult(NODE_ID, 'WAITING', null)
        ]);
      }, 'completedCount');
      expectThrowsMessage(() => {
        createVpnRpcServerHelloBody(1, 'not-hex', SERVER_INSTANCE);
      }, 'serverNonce');
      expectThrowsMessage(() => {
        createVpnRpcClientAuthBody(1, CLIENT_NONCE, 'XYZ');
      }, 'clientProof');

      const originalText: string = bodyText(
        'RESPONSE',
        40,
        9,
        '4',
        `"${REQUEST_ID}"`,
        'QUERY_GROUP',
        4,
        `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`,
        'true',
        'null',
        `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","nodes":[{"nodeId":"${NODE_ID}","kind":"TERMINAL","type":"Vmess","selected":true},{"nodeId":"${OTHER_NODE_ID}","kind":"GROUP","type":"Selector","selected":false}]}`
      );
      const original: VpnRpcBody = decodeVpnRpcBodyText(originalText);
      const clone: VpnRpcBody = decodeVpnRpcBodyBytes(encodeVpnRpcBody(original));
      clone.requestId = OTHER_REQUEST_ID;

      expect(original.requestId).assertEqual(REQUEST_ID);
      expect(clone.requestId).assertEqual(OTHER_REQUEST_ID);
      expect(JSON.stringify(clone).includes('groupName')).assertFalse();
      expect(JSON.stringify(clone).includes('nodeName')).assertFalse();
      expect(JSON.stringify(createVpnRpcError('RPC_UNAVAILABLE', true)).includes('endpoint')).assertFalse();
    });
  });
}
