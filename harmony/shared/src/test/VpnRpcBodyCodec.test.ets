import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnRpcClientAuthBody,
  createVpnRpcServerAuthBody,
  createVpnRpcServerHelloBody,
  decodeVpnRpcClientAuthBodyBytes,
  decodeVpnRpcClientAuthBodyText,
  decodeVpnRpcBodyBytes,
  decodeVpnRpcBodyText,
  decodeVpnRpcServerAuthBodyBytes,
  decodeVpnRpcServerAuthBodyText,
  decodeVpnRpcServerHelloBodyBytes,
  decodeVpnRpcServerHelloBodyText,
  encodeVpnRpcClientAuthBody,
  encodeVpnRpcClientAuthBodyToText,
  encodeVpnRpcBody,
  encodeVpnRpcBodyToText,
  encodeVpnRpcServerAuthBody,
  encodeVpnRpcServerAuthBodyToText,
  encodeVpnRpcServerHelloBody,
  encodeVpnRpcServerHelloBodyToText,
  type VpnRpcClientAuthBody,
  type VpnRpcServerAuthBody,
  type VpnRpcServerHelloBody,
  type VpnRpcBody
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
const UPPERCASE_BAD_HANDSHAKE_HEX: string = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const UPPERCASE_BAD_HANDSHAKE_PROOF: string = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const REQUEST_ID: string = '00000000-0000-4000-8000-000000000001';
const TX_BYTES: number = 1234;
const RX_BYTES: number = 5678;
const SERVER_HELLO_TEXT: string =
  `{"protocolVersion":1,"serverNonce":"${SERVER_NONCE}","serverInstance":"${SERVER_INSTANCE}"}`;
const SERVER_HELLO_HEX: string =
  '7b2270726f746f636f6c56657273696f6e223a312c227365727665724e6f6e6365223a2232303231323232333234323532363237323832393261326232633264326532663330333133323333333433353336333733383339336133623363336433653366222c22736572766572496e7374616e6365223a223630363136323633363436353636363736383639366136623663366436653666227d';
const CLIENT_AUTH_TEXT: string =
  `{"protocolVersion":1,"clientNonce":"${CLIENT_NONCE}","clientProof":"${CLIENT_PROOF}"}`;
const CLIENT_AUTH_HEX: string =
  '7b2270726f746f636f6c56657273696f6e223a312c22636c69656e744e6f6e6365223a2234303431343234333434343534363437343834393461346234633464346534663530353135323533353435353536353735383539356135623563356435653566222c22636c69656e7450726f6f66223a2239373131323066633734323135373131623764653138343838316562383039656638636238626666393162323363663534353266316233633739373931386436227d';
const SERVER_AUTH_TEXT: string =
  `{"protocolVersion":1,"clientEpoch":7,"serverProof":"${SERVER_PROOF}"}`;
const SERVER_AUTH_HEX: string =
  '7b2270726f746f636f6c56657273696f6e223a312c22636c69656e7445706f6368223a372c2273657276657250726f6f66223a2233636237393665653237613965343064306565333964643431333231363733323432646434633235623333613365666230366661313831666162646563356366227d';
const APPENDIX_A_PING_BODY: string =
  '{"protocolVersion":1,"kind":"REQUEST","sequence":1,"clientEpoch":7,"requestOrdinal":1,"requestId":"00000000-0000-4000-8000-000000000001","method":"PING","sessionGeneration":0,"guards":{"profileHash":null,"revisionHash":null,"catalogDigest":null},"ok":null,"error":null,"payload":{}}';
const APPENDIX_A_PING_BODY_HEX: string =
  '7b2270726f746f636f6c56657273696f6e223a312c226b696e64223a2252455155455354222c2273657175656e6365223a312c22636c69656e7445706f6368223a372c22726571756573744f7264696e616c223a312c22726571756573744964223a2230303030303030302d303030302d343030302d383030302d303030303030303030303031222c226d6574686f64223a2250494e47222c2273657373696f6e47656e65726174696f6e223a302c22677561726473223a7b2270726f66696c6548617368223a6e756c6c2c227265766973696f6e48617368223a6e756c6c2c22636174616c6f67446967657374223a6e756c6c7d2c226f6b223a6e756c6c2c226572726f72223a6e756c6c2c227061796c6f6164223a7b7d7d';
const ACTIVE_GUARDS_TEXT: string =
  `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}"}`;
const NULL_GUARDS_TEXT: string = '{"profileHash":null,"revisionHash":null,"catalogDigest":null}';
const CATALOG_GUARDS_TEXT: string =
  `{"profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":null}`;
const RUNTIME_PAYLOAD_TEXT: string =
  `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":${TX_BYTES},"rxBytes":${RX_BYTES}}`;
const DELAY_PAYLOAD_TEXT: string =
  `{"jobId":"${JOB_ID}","delayRevision":8,"proxyGeneration":3,"groupId":"${GROUP_ID}","state":"RUNNING","totalCount":2,"completedCount":1,"results":[{"nodeId":"${NODE_ID}","status":"AVAILABLE","delayMs":41},{"nodeId":"${OTHER_NODE_ID}","status":"WAITING","delayMs":null}]}`;

function stringifyBodyBytes(bytes: Uint8Array): string {
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += String.fromCharCode(bytes[index]);
  }
  return result;
}

function asciiBytes(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let index: number = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index);
  }
  return bytes;
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

function hexBytes(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    const value: number = bytes[index];
    result += alphabet[(value >>> 4) & 0x0f];
    result += alphabet[value & 0x0f];
  }
  return result;
}

function expectThrowsMessageWithoutLeak(block: () => void, expectedFragment: string, forbiddenFragment: string): void {
  let didThrow: boolean = false;
  try {
    block();
  } catch (error) {
    didThrow = true;
    const message: string = error instanceof Error ? error.message : `${error}`;
    if (!message.includes(expectedFragment)) {
      throw new Error(`Expected "${message}" to include "${expectedFragment}".`);
    }
    if (message.includes(forbiddenFragment)) {
      throw new Error(`Expected "${message}" not to include "${forbiddenFragment}".`);
    }
  }
  if (!didThrow) {
    throw new Error(`Expected block to throw "${expectedFragment}".`);
  }
}

class RawGuardsText {
  profileHashText: string = `"${PROFILE_HASH}"`;
  revisionHashText: string = `"${REVISION_HASH}"`;
  catalogDigestText: string = `"${CATALOG_DIGEST}"`;
  extraFieldText: string | null = null;

  toText(): string {
    const extra: string = this.extraFieldText === null ? '' : `,${this.extraFieldText}`;
    return `{"profileHash":${this.profileHashText},"revisionHash":${this.revisionHashText},"catalogDigest":${this.catalogDigestText}${extra}}`;
  }
}

class RawBodyText {
  kind: 'REQUEST' | 'RESPONSE' | 'EVENT' = 'REQUEST';
  method: string = 'PING';
  sequence: string = '1';
  clientEpoch: string = '7';
  requestOrdinalText: string = '1';
  requestIdText: string = `"${REQUEST_ID}"`;
  sessionGeneration: string = '0';
  guardsText: string = '{"profileHash":null,"revisionHash":null,"catalogDigest":null}';
  okText: string = 'null';
  errorText: string = 'null';
  payloadText: string = '{}';
  omitError: boolean = false;
  extraFieldText: string | null = null;

  toText(): string {
    const pieces: string[] = [
      '"protocolVersion":1',
      `"kind":"${this.kind}"`,
      `"sequence":${this.sequence}`,
      `"clientEpoch":${this.clientEpoch}`,
      `"requestOrdinal":${this.requestOrdinalText}`,
      `"requestId":${this.requestIdText}`,
      `"method":"${this.method}"`,
      `"sessionGeneration":${this.sessionGeneration}`,
      `"guards":${this.guardsText}`,
      `"ok":${this.okText}`
    ];
    if (!this.omitError) {
      pieces.push(`"error":${this.errorText}`);
    }
    pieces.push(`"payload":${this.payloadText}`);
    if (this.extraFieldText !== null) {
      pieces.push(this.extraFieldText);
    }
    return `{${pieces.join(',')}}`;
  }
}

export default function vpnRpcBodyCodecTestsuite() {
  describe('VpnRpcBodyCodecTest', () => {
    it('pinsCanonicalServerHelloHandshakeBytesExactly', 0, () => {
      const body: VpnRpcServerHelloBody = createVpnRpcServerHelloBody(1, SERVER_NONCE, SERVER_INSTANCE);
      const encoded: Uint8Array = encodeVpnRpcServerHelloBody(body);
      const decodedFromText: VpnRpcServerHelloBody = decodeVpnRpcServerHelloBodyText(SERVER_HELLO_TEXT);

      expect(encodeVpnRpcServerHelloBodyToText(body)).assertEqual(SERVER_HELLO_TEXT);
      expect(stringifyBodyBytes(encoded)).assertEqual(SERVER_HELLO_TEXT);
      expect(encoded.length).assertEqual(154);
      expect(hexBytes(encoded)).assertEqual(SERVER_HELLO_HEX);
      expect(encodeVpnRpcServerHelloBodyToText(decodedFromText)).assertEqual(SERVER_HELLO_TEXT);
      expect(decodedFromText.serverNonce).assertEqual(SERVER_NONCE);
      expect(decodeVpnRpcServerHelloBodyBytes(encoded).serverInstance).assertEqual(SERVER_INSTANCE);
    });

    it('pinsCanonicalClientAuthHandshakeBytesExactly', 0, () => {
      const body: VpnRpcClientAuthBody = createVpnRpcClientAuthBody(1, CLIENT_NONCE, CLIENT_PROOF);
      const encoded: Uint8Array = encodeVpnRpcClientAuthBody(body);
      const decodedFromText: VpnRpcClientAuthBody = decodeVpnRpcClientAuthBodyText(CLIENT_AUTH_TEXT);

      expect(encodeVpnRpcClientAuthBodyToText(body)).assertEqual(CLIENT_AUTH_TEXT);
      expect(stringifyBodyBytes(encoded)).assertEqual(CLIENT_AUTH_TEXT);
      expect(encoded.length).assertEqual(183);
      expect(hexBytes(encoded)).assertEqual(CLIENT_AUTH_HEX);
      expect(encodeVpnRpcClientAuthBodyToText(decodedFromText)).assertEqual(CLIENT_AUTH_TEXT);
      expect(decodedFromText.clientProof).assertEqual(CLIENT_PROOF);
      expect(decodeVpnRpcClientAuthBodyBytes(encoded).clientNonce).assertEqual(CLIENT_NONCE);
    });

    it('pinsCanonicalServerAuthHandshakeBytesExactly', 0, () => {
      const body: VpnRpcServerAuthBody = createVpnRpcServerAuthBody(1, 7, SERVER_PROOF);
      const encoded: Uint8Array = encodeVpnRpcServerAuthBody(body);
      const decodedFromText: VpnRpcServerAuthBody = decodeVpnRpcServerAuthBodyText(SERVER_AUTH_TEXT);

      expect(encodeVpnRpcServerAuthBodyToText(body)).assertEqual(SERVER_AUTH_TEXT);
      expect(stringifyBodyBytes(encoded)).assertEqual(SERVER_AUTH_TEXT);
      expect(encoded.length).assertEqual(118);
      expect(hexBytes(encoded)).assertEqual(SERVER_AUTH_HEX);
      expect(encodeVpnRpcServerAuthBodyToText(decodedFromText)).assertEqual(SERVER_AUTH_TEXT);
      expect(decodedFromText.clientEpoch).assertEqual(7);
      expect(decodeVpnRpcServerAuthBodyBytes(encoded).serverProof).assertEqual(SERVER_PROOF);
    });

    it('rejectsStructuralAndNonCanonicalHandshakeBodies', 0, () => {
      expectThrowsMessage(() => {
        encodeVpnRpcServerHelloBodyToText({
          protocolVersion: 1,
          serverNonce: SERVER_NONCE,
          serverInstance: SERVER_INSTANCE
        });
      }, 'createVpnRpcServerHelloBody');

      expectThrowsMessage(() => {
        encodeVpnRpcClientAuthBody({
          protocolVersion: 1,
          clientNonce: CLIENT_NONCE,
          clientProof: CLIENT_PROOF
        });
      }, 'createVpnRpcClientAuthBody');

      expectThrowsMessage(() => {
        encodeVpnRpcServerAuthBodyToText({
          protocolVersion: 1,
          clientEpoch: 7,
          serverProof: SERVER_PROOF
        });
      }, 'createVpnRpcServerAuthBody');

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":1,"serverInstance":"${SERVER_INSTANCE}","serverNonce":"${SERVER_NONCE}"}`);
      }, 'keyOrder');

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":1,"serverNonce":"${SERVER_NONCE}"}`);
      }, 'missing');

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":1,"serverNonce":"${SERVER_NONCE}","serverInstance":"${SERVER_INSTANCE}","kind":"REQUEST"}`);
      }, 'extra');

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":1,"serverNonce":"${SERVER_NONCE}","serverInstance":"${SERVER_INSTANCE}","serverInstance":"${SERVER_INSTANCE}"}`);
      }, 'body');

      expectThrowsMessageWithoutLeak(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":1,"serverNonce":"${UPPERCASE_BAD_HANDSHAKE_HEX}","serverInstance":"${SERVER_INSTANCE}"}`);
      }, 'lowercase hexadecimal', UPPERCASE_BAD_HANDSHAKE_HEX);

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyText(`{"protocolVersion":2,"serverNonce":"${SERVER_NONCE}","serverInstance":"${SERVER_INSTANCE}"}`);
      }, 'protocolVersion');

      expectThrowsMessage(() => {
        decodeVpnRpcClientAuthBodyText(`{"protocolVersion":1,"clientNonce":"${CLIENT_NONCE}","clientProof":"${CLIENT_PROOF}","clientProof":"${CLIENT_PROOF}"}`);
      }, 'body');

      expectThrowsMessageWithoutLeak(() => {
        decodeVpnRpcClientAuthBodyText(`{"protocolVersion":1,"clientNonce":"${CLIENT_NONCE}","clientProof":"${UPPERCASE_BAD_HANDSHAKE_PROOF}"}`);
      }, 'lowercase hexadecimal', UPPERCASE_BAD_HANDSHAKE_PROOF);

      expectThrowsMessage(() => {
        decodeVpnRpcServerAuthBodyText(`{"protocolVersion":1,"clientEpoch":9007199254740992,"serverProof":"${SERVER_PROOF}"}`);
      }, 'body');

      expectThrowsMessage(() => {
        decodeVpnRpcServerAuthBodyText(`{"protocolVersion":1,"serverProof":"${SERVER_PROOF}"}`);
      }, 'missing');

      expectThrowsMessage(() => {
        decodeVpnRpcServerHelloBodyBytes(new Uint8Array([0xef, 0xbb, 0xbf, 0x7b, 0x7d]));
      }, 'bom');

      expectThrowsMessage(() => {
        decodeVpnRpcClientAuthBodyBytes(new Uint8Array([0xc3, 0x28]));
      }, 'utf8');

      expectThrowsMessage(() => {
        decodeVpnRpcServerAuthBodyBytes(new Uint8Array([0x7b, 0x00, 0x7d]));
      }, 'nul');
    });

    it('pinsAppendixAGoldenPingBytesExactly', 0, () => {
      const body: VpnRpcBody = decodeVpnRpcBodyText(APPENDIX_A_PING_BODY);
      const encoded: Uint8Array = encodeVpnRpcBody(body);

      expect(encodeVpnRpcBodyToText(body)).assertEqual(APPENDIX_A_PING_BODY);
      expect(stringifyBodyBytes(encoded)).assertEqual(APPENDIX_A_PING_BODY);
      expect(encoded.length).assertEqual(282);
      expect(hexBytes(encoded)).assertEqual(APPENDIX_A_PING_BODY_HEX);
      expect(decodeVpnRpcBodyBytes(encoded).requestId).assertEqual(REQUEST_ID);
    });

    it('pinsCanonicalByteAndTextCoverageAcrossRequestsResponsesErrorsAndEvents', 0, () => {
      const canonicalBodies: string[] = [
        bodyText('REQUEST', 1, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'null', 'null', '{}'),
        bodyText('REQUEST', 2, 7, '2', '"00000000-0000-4000-8000-000000000002"', 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'null', 'null', '{}'),
        bodyText('REQUEST', 3, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'null', 'null', '{}'),
        bodyText('REQUEST', 4, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', '{}'),
        bodyText('REQUEST', 5, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', `{"groupId":"${GROUP_ID}"}`),
        bodyText('REQUEST', 6, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', `{"proxyGeneration":3,"groupId":"${GROUP_ID}","nodeId":"${NODE_ID}"}`),
        bodyText('REQUEST', 7, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', `{"proxyGeneration":3,"groupId":"${GROUP_ID}"}`),
        bodyText('REQUEST', 8, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', `{"jobId":"${JOB_ID}"}`),
        bodyText('REQUEST', 9, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', `{"jobId":"${JOB_ID}"}`),
        bodyText('REQUEST', 10, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', '{}'),
        bodyText('RESPONSE', 11, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'true', 'null', `{"serverInstance":"${SERVER_INSTANCE}"}`),
        bodyText('RESPONSE', 12, 7, '2', '"00000000-0000-4000-8000-000000000002"', 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT),
        bodyText('RESPONSE', 13, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'true', 'null', `{"catalogDigest":"${CATALOG_DIGEST}","entryCount":2}`),
        bodyText('RESPONSE', 14, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', `{"proxyGeneration":3,"groups":[{"groupId":"${GROUP_ID}","type":"Selector","isSelectable":true}]}`),
        bodyText('RESPONSE', 15, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","nodes":[{"nodeId":"${NODE_ID}","kind":"TERMINAL","type":"Vmess","selected":true},{"nodeId":"${OTHER_NODE_ID}","kind":"GROUP","type":"Selector","selected":false}]}`),
        bodyText('RESPONSE', 16, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","persisted":true}`),
        bodyText('RESPONSE', 17, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT),
        bodyText('RESPONSE', 18, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT),
        bodyText('RESPONSE', 19, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', DELAY_PAYLOAD_TEXT),
        bodyText('RESPONSE', 20, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'true', 'null', RUNTIME_PAYLOAD_TEXT),
        bodyText('RESPONSE', 21, 7, '1', `"${REQUEST_ID}"`, 'PING', 0, NULL_GUARDS_TEXT, 'false', '{"code":"PROTOCOL_MISMATCH","retryable":false}', '{}'),
        bodyText('RESPONSE', 22, 7, '2', '"00000000-0000-4000-8000-000000000002"', 'GET_SNAPSHOT', 0, NULL_GUARDS_TEXT, 'false', '{"code":"RPC_UNAVAILABLE","retryable":true}', '{}'),
        bodyText('RESPONSE', 23, 7, '3', '"00000000-0000-4000-8000-000000000003"', 'GET_CATALOG_DIGEST', 4, CATALOG_GUARDS_TEXT, 'false', '{"code":"CATALOG_MISMATCH","retryable":true}', '{}'),
        bodyText('RESPONSE', 24, 7, '4', '"00000000-0000-4000-8000-000000000004"', 'QUERY_GROUPS', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"CORE_OPERATION_FAILED","retryable":true}', '{}'),
        bodyText('RESPONSE', 25, 7, '5', '"00000000-0000-4000-8000-000000000005"', 'QUERY_GROUP', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"FRAME_INVALID","retryable":false}', '{}'),
        bodyText('RESPONSE', 26, 7, '6', '"00000000-0000-4000-8000-000000000006"', 'SELECT_NODE', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"COMMAND_BUSY","retryable":true}', '{}'),
        bodyText('RESPONSE', 27, 7, '7', '"00000000-0000-4000-8000-000000000007"', 'START_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"COMMAND_TIMEOUT","retryable":true}', '{}'),
        bodyText('RESPONSE', 28, 7, '8', '"00000000-0000-4000-8000-000000000008"', 'READ_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"SESSION_CHANGED","retryable":true}', '{}'),
        bodyText('RESPONSE', 29, 7, '9', '"00000000-0000-4000-8000-000000000009"', 'CANCEL_DELAY_TEST', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"REQUEST_REPLAY_EXPIRED","retryable":false}', '{}'),
        bodyText('RESPONSE', 30, 7, '10', '"00000000-0000-4000-8000-000000000010"', 'STOP_VPN', 4, ACTIVE_GUARDS_TEXT, 'false', '{"code":"SERVER_STOPPING","retryable":true}', '{}'),
        bodyText('EVENT', 31, 7, 'null', 'null', 'RUNTIME_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', RUNTIME_PAYLOAD_TEXT),
        bodyText('EVENT', 32, 7, 'null', 'null', 'DELAY_CHANGED', 4, ACTIVE_GUARDS_TEXT, 'null', 'null', DELAY_PAYLOAD_TEXT),
        bodyText('EVENT', 33, 7, 'null', 'null', 'SERVER_STOPPING', 0, NULL_GUARDS_TEXT, 'null', 'null', '{}')
      ];

      for (let index: number = 0; index < canonicalBodies.length; index += 1) {
        const decoded: VpnRpcBody = decodeVpnRpcBodyText(canonicalBodies[index]);
        const encodedBytes: Uint8Array = encodeVpnRpcBody(decoded);
        expect(encodeVpnRpcBodyToText(decoded)).assertEqual(canonicalBodies[index]);
        expect(stringifyBodyBytes(encodedBytes)).assertEqual(canonicalBodies[index]);
        expect(decodeVpnRpcBodyBytes(asciiBytes(canonicalBodies[index])).method).assertEqual(decoded.method);
      }
    });

    it('rejectsMissingExtraAndSemanticallyInvalidKeysThroughDecoder', 0, () => {
      const extraGuards = new RawGuardsText();
      extraGuards.extraFieldText = '"rogue":null';
      const extraBody = new RawBodyText();
      extraBody.method = 'QUERY_GROUPS';
      extraBody.sessionGeneration = '4';
      extraBody.guardsText = extraGuards.toText();
      extraBody.extraFieldText = '"rogue":true';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(extraBody.toText());
      }, 'extra');

      const missingError = new RawBodyText();
      missingError.omitError = true;
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(missingError.toText());
      }, 'missing');

      const invalidMethod = new RawBodyText();
      invalidMethod.method = 'NOT_ALLOWED';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(invalidMethod.toText());
      }, 'method');

      const errorEventMethod = new RawBodyText();
      errorEventMethod.kind = 'RESPONSE';
      errorEventMethod.method = 'RUNTIME_CHANGED';
      errorEventMethod.sequence = '7';
      errorEventMethod.sessionGeneration = '4';
      errorEventMethod.guardsText = ACTIVE_GUARDS_TEXT;
      errorEventMethod.okText = 'false';
      errorEventMethod.errorText = '{"code":"FRAME_INVALID","retryable":false}';
      errorEventMethod.payloadText = '{}';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(errorEventMethod.toText());
      }, 'method');

      const errorResponseNonEmptyPayload = new RawBodyText();
      errorResponseNonEmptyPayload.kind = 'RESPONSE';
      errorResponseNonEmptyPayload.method = 'PING';
      errorResponseNonEmptyPayload.okText = 'false';
      errorResponseNonEmptyPayload.errorText = '{"code":"FRAME_INVALID","retryable":false}';
      errorResponseNonEmptyPayload.payloadText = `{"serverInstance":"${SERVER_INSTANCE}"}`;
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(errorResponseNonEmptyPayload.toText());
      }, 'extra');

      const invalidAvailableDelay = new RawBodyText();
      invalidAvailableDelay.kind = 'RESPONSE';
      invalidAvailableDelay.method = 'READ_DELAY_TEST';
      invalidAvailableDelay.sequence = '8';
      invalidAvailableDelay.sessionGeneration = '4';
      invalidAvailableDelay.guardsText = new RawGuardsText().toText();
      invalidAvailableDelay.okText = 'true';
      invalidAvailableDelay.errorText = 'null';
      invalidAvailableDelay.payloadText =
        `{"jobId":"${JOB_ID}","delayRevision":2,"proxyGeneration":3,"groupId":"${GROUP_ID}","state":"RUNNING","totalCount":1,"completedCount":1,"results":[{"nodeId":"${NODE_ID}","status":"AVAILABLE","delayMs":null}]}`;
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(invalidAvailableDelay.toText());
      }, 'delayMs');

      const invalidResponseInvariant = new RawBodyText();
      invalidResponseInvariant.kind = 'RESPONSE';
      invalidResponseInvariant.method = 'PING';
      invalidResponseInvariant.okText = 'null';
      invalidResponseInvariant.errorText = 'null';
      invalidResponseInvariant.payloadText = `{"serverInstance":"${SERVER_INSTANCE}"}`;
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(invalidResponseInvariant.toText());
      }, 'ok');

      const bomText = new RawBodyText();
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(`\uFEFF${bomText.toText()}`);
      }, 'bom');

      const nulText = new RawBodyText();
      nulText.method = `PING${String.fromCharCode(0)}`;
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(nulText.toText());
      }, 'nul');

      const duplicateTopLevel: string =
        '{"protocolVersion":1,"kind":"REQUEST","sequence":1,"clientEpoch":7,"requestOrdinal":1,"requestId":"00000000-0000-4000-8000-000000000001","method":"PING","sessionGeneration":0,"guards":{"profileHash":null,"revisionHash":null,"catalogDigest":null},"ok":null,"error":null,"payload":{},"payload":{}}';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(duplicateTopLevel);
      }, 'body');

      const duplicateGuards = bodyText(
        'REQUEST',
        1,
        7,
        '1',
        `"${REQUEST_ID}"`,
        'PING',
        0,
        '{"profileHash":null,"revisionHash":null,"catalogDigest":null,"catalogDigest":null}',
        'null',
        'null',
        '{}'
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(duplicateGuards);
      }, 'body');

      const duplicateError = bodyText(
        'RESPONSE',
        1,
        7,
        '1',
        `"${REQUEST_ID}"`,
        'PING',
        0,
        NULL_GUARDS_TEXT,
        'false',
        '{"code":"FRAME_INVALID","retryable":false,"code":"FRAME_INVALID"}',
        '{}'
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(duplicateError);
      }, 'body');

      const duplicatePayload = bodyText(
        'RESPONSE',
        15,
        7,
        '5',
        `"${REQUEST_ID}"`,
        'QUERY_GROUP',
        4,
        ACTIVE_GUARDS_TEXT,
        'true',
        'null',
        `{"proxyGeneration":3,"groupId":"${GROUP_ID}","selectedNodeId":"${NODE_ID}","groupId":"${GROUP_ID}","nodes":[{"nodeId":"${NODE_ID}","kind":"TERMINAL","type":"Vmess","selected":true}]}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(duplicatePayload);
      }, 'body');

      const duplicateArrayItem = bodyText(
        'RESPONSE',
        17,
        7,
        '7',
        `"${REQUEST_ID}"`,
        'START_DELAY_TEST',
        4,
        ACTIVE_GUARDS_TEXT,
        'true',
        'null',
        `{"jobId":"${JOB_ID}","delayRevision":8,"proxyGeneration":3,"groupId":"${GROUP_ID}","state":"RUNNING","totalCount":1,"completedCount":1,"results":[{"nodeId":"${NODE_ID}","status":"AVAILABLE","delayMs":41,"status":"AVAILABLE"}]}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(duplicateArrayItem);
      }, 'body');

      const unsafeInteger = new RawBodyText();
      unsafeInteger.sequence = '9007199254740992';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(unsafeInteger.toText());
      }, 'body');

      const leadingZeroInteger = new RawBodyText();
      leadingZeroInteger.sequence = '01';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(leadingZeroInteger.toText());
      }, 'body');

      const plusInteger = new RawBodyText();
      plusInteger.sequence = '+1';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(plusInteger.toText());
      }, 'body');

      const fractionInteger = new RawBodyText();
      fractionInteger.sequence = '1.5';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(fractionInteger.toText());
      }, 'body');

      const exponentInteger = new RawBodyText();
      exponentInteger.sequence = '1e2';
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(exponentInteger.toText());
      }, 'body');

      expectThrowsMessage(() => {
        decodeVpnRpcBodyBytes(new Uint8Array([0xef, 0xbb, 0xbf, 0x7b, 0x7d]));
      }, 'bom');

      expectThrowsMessage(() => {
        decodeVpnRpcBodyBytes(new Uint8Array([0xc3, 0x28]));
      }, 'utf8');

      expectThrowsMessage(() => {
        decodeVpnRpcBodyBytes(new Uint8Array([0x7b, 0x00, 0x7d]));
      }, 'nul');
    });

    it('rejectsRuntimeSnapshotTrafficCounterContractViolations', 0, () => {
      const missingTrafficCounters = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":${TX_BYTES}}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(missingTrafficCounters);
      }, 'missing');

      const extraRuntimeField = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":${TX_BYTES},"rxBytes":${RX_BYTES},"rogue":0}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(extraRuntimeField);
      }, 'extra');

      const reorderedTrafficCounters = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"rxBytes":${RX_BYTES},"txBytes":${TX_BYTES}}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(reorderedTrafficCounters);
      }, 'keyOrder');

      const negativeTrafficCounters = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":-1,"rxBytes":${RX_BYTES}}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(negativeTrafficCounters);
      }, 'body');

      const fractionalTrafficCounters = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":${TX_BYTES},"rxBytes":1.5}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(fractionalTrafficCounters);
      }, 'body');

      const unsafeTrafficCounters = bodyText(
        'EVENT',
        31,
        7,
        'null',
        'null',
        'RUNTIME_CHANGED',
        4,
        ACTIVE_GUARDS_TEXT,
        'null',
        'null',
        `{"state":"RUNNING","profileHash":"${PROFILE_HASH}","revisionHash":"${REVISION_HASH}","catalogDigest":"${CATALOG_DIGEST}","notificationActive":true,"recoveryAttempt":1,"scheduledRetryDelayMs":null,"runtimeFailureCode":null,"txBytes":9007199254740992,"rxBytes":${RX_BYTES}}`
      );
      expectThrowsMessage(() => {
        decodeVpnRpcBodyText(unsafeTrafficCounters);
      }, 'body');
    });
  });
}
