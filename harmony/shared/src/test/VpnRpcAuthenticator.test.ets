import { describe, expect, it } from '@ohos/hypium';
import {
  VpnRpcFramer,
  constantTimeEqualVpnRpcBytes,
  decodeVpnRpcLowercaseHex,
  type VpnRpcDecodedFrame
} from '../../Index';
import {
  VpnRpcClientAuthenticator,
  VpnRpcServerAuthenticator,
  VpnRpcTransportFailure,
  deriveVpnRpcSocketAddress,
  type VpnRpcAuthenticatedConnection,
  type VpnRpcProtectedBody,
  type VpnRpcServerAuthenticationResult
} from '../main/ets/vpn/rpc/VpnRpcAuthenticator';
import {
  createVpnRpcClientAuthBody,
  type VpnRpcBody,
  type VpnRpcClientAuthBody,
  type VpnRpcServerHelloBody
} from '../main/ets/vpn/rpc/VpnRpcModels';
import { decodeVpnRpcBodyBytes, encodeVpnRpcBody } from '../main/ets/vpn/rpc/VpnRpcBodyCodec';
import { decodeVpnRpcUtf8, encodeVpnRpcU32BE, encodeVpnRpcUtf8 } from '../main/ets/vpn/rpc/VpnRpcBinaryCodec';
import {
  CLIENT_AUTH_INPUT_HEX,
  C2S_KEY_INPUT_HEX,
  FRAME_MAC_INPUT_HEX,
  GOLDEN_C2S_KEY_HEX,
  GOLDEN_CLIENT_EPOCH,
  GOLDEN_CLIENT_NONCE_HEX,
  GOLDEN_CLIENT_PROOF_HEX,
  GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX,
  GOLDEN_FRAME_MAC_HEX,
  GOLDEN_PING_BODY_HEX,
  GOLDEN_PING_BODY_LENGTH,
  GOLDEN_PING_BODY_TEXT,
  GOLDEN_PROTOCOL_MISMATCH_MAC_HEX,
  GOLDEN_S2C_KEY_HEX,
  GOLDEN_SERVER_INSTANCE_HEX,
  GOLDEN_SERVER_NONCE_HEX,
  GOLDEN_SERVER_PROOF_HEX,
  GOLDEN_SERVER_RESPONSE_MAC_HEX,
  GOLDEN_SOCKET_ADDRESS,
  GOLDEN_WRONG_EPOCH_MAC_HEX,
  S2C_KEY_INPUT_HEX,
  SERVER_AUTH_INPUT_HEX,
  SOCKET_ADDRESS_INPUT_HEX,
  VPN_RPC_AUTH_FAILED_CODE,
  VPN_RPC_AUTH_FAILED_MESSAGE,
  VPN_RPC_AUTH_FAILED_RETRYABLE,
  VPN_RPC_AUTH_TIMEOUT_MS,
  VPN_RPC_FRAME_INVALID_CODE,
  VPN_RPC_FRAME_INVALID_MESSAGE,
  VPN_RPC_FRAME_INVALID_RETRYABLE,
  VPN_RPC_PROTOCOL_MISMATCH_CODE,
  VPN_RPC_PROTOCOL_MISMATCH_MESSAGE,
  VPN_RPC_PROTOCOL_MISMATCH_RETRYABLE,
  VPN_RPC_RPC_UNAVAILABLE_CODE,
  VPN_RPC_RPC_UNAVAILABLE_MESSAGE,
  VPN_RPC_RPC_UNAVAILABLE_RETRYABLE,
  VPN_RPC_TIMEOUT_MESSAGE,
  type FixtureOutgoingBodyBuilder,
  FixtureVpnRpcCryptoPort,
  FixtureVpnRpcRandomPort,
  FixtureVpnRpcSchedulerPort,
  createAppendixABodyBuilder,
  createAppendixABodyBytes,
  createAppendixARequestBody,
  createFrameMacInputForBytes,
  createGoldenClientAuth,
  createGoldenClientRandomPort,
  createGoldenContractSummary,
  createGoldenCryptoPort,
  createGoldenServerAuth,
  createGoldenServerHello,
  createGoldenServerRandomPort,
  createInvalidJsonBodyBytes,
  createMutatedMacBytesFirstByte,
  createMutatedMacBytesLastByte,
  createMutatedProofFirstByte,
  createMutatedProofLastByte,
  createPingRequestBuilder,
  createPingResponseBuilder,
  createPingRequestBody,
  createPingResponseBody,
  hexBytes
} from './fakes/VpnRpcFakes';

class AuthenticatedPair {
  readonly client: VpnRpcClientAuthenticator;
  readonly server: VpnRpcServerAuthenticator;
  readonly clientConnection: VpnRpcAuthenticatedConnection;
  readonly serverConnection: VpnRpcAuthenticatedConnection;
  readonly clientCrypto: FixtureVpnRpcCryptoPort;
  readonly serverCrypto: FixtureVpnRpcCryptoPort;
  readonly clientRandom: FixtureVpnRpcRandomPort;
  readonly serverRandom: FixtureVpnRpcRandomPort;
  readonly clientScheduler: FixtureVpnRpcSchedulerPort;
  readonly serverScheduler: FixtureVpnRpcSchedulerPort;
  readonly serverHello = createGoldenServerHello();
  readonly clientAuth = createGoldenClientAuth();
  readonly serverResult: VpnRpcServerAuthenticationResult;

  constructor(
    client: VpnRpcClientAuthenticator,
    server: VpnRpcServerAuthenticator,
    clientConnection: VpnRpcAuthenticatedConnection,
    serverConnection: VpnRpcAuthenticatedConnection,
    clientCrypto: FixtureVpnRpcCryptoPort,
    serverCrypto: FixtureVpnRpcCryptoPort,
    clientRandom: FixtureVpnRpcRandomPort,
    serverRandom: FixtureVpnRpcRandomPort,
    clientScheduler: FixtureVpnRpcSchedulerPort,
    serverScheduler: FixtureVpnRpcSchedulerPort,
    serverResult: VpnRpcServerAuthenticationResult
  ) {
    this.client = client;
    this.server = server;
    this.clientConnection = clientConnection;
    this.serverConnection = serverConnection;
    this.clientCrypto = clientCrypto;
    this.serverCrypto = serverCrypto;
    this.clientRandom = clientRandom;
    this.serverRandom = serverRandom;
    this.clientScheduler = clientScheduler;
    this.serverScheduler = serverScheduler;
    this.serverResult = serverResult;
  }
}

function forbiddenFragments(): string[] {
  return [
    GOLDEN_SERVER_NONCE_HEX,
    GOLDEN_CLIENT_NONCE_HEX,
    GOLDEN_SERVER_INSTANCE_HEX,
    GOLDEN_CLIENT_PROOF_HEX,
    GOLDEN_SERVER_PROOF_HEX,
    GOLDEN_C2S_KEY_HEX,
    GOLDEN_S2C_KEY_HEX,
    GOLDEN_FRAME_MAC_HEX,
    GOLDEN_PING_BODY_TEXT,
    GOLDEN_SOCKET_ADDRESS,
    '00000000-0000-4000-8000-000000000001',
    'fixture-random',
    'fixture-scheduler',
    'Missing root HMAC fixture mapping.',
    'Missing derived HMAC fixture mapping.',
    'Invalid VPN RPC body'
  ];
}

function createPromiseSignal(): Promise<void> {
  return Promise.resolve();
}

async function flushAsyncTurns(turns: number = 4): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await createPromiseSignal();
  }
}

function createPingResponseText(sequence: number = 1): string {
  return decodeVpnRpcUtf8(encodeVpnRpcBody(createPingResponseBody(sequence)));
}

function replaceProtocolVersionToken(bodyText: string, token: string): string {
  return bodyText.replace('"protocolVersion":1', `"protocolVersion":${token}`);
}

function createFrameBytes(bodyBytes: Uint8Array): Uint8Array {
  const header: Uint8Array = encodeVpnRpcU32BE(bodyBytes.length);
  const frameBytes: Uint8Array = new Uint8Array(header.length + bodyBytes.length);
  frameBytes.set(header, 0);
  frameBytes.set(bodyBytes, header.length);
  return frameBytes;
}

async function ignorePromiseResult<T>(promise: Promise<T>): Promise<void> {
  await promise;
}

async function expectTransportFailure(
  run: () => Promise<void>,
  code: string,
  message: string,
  retryable: boolean,
  extraForbidden: string[] = []
): Promise<void> {
  let failure: VpnRpcTransportFailure | undefined = undefined;
  try {
    await run();
  } catch (error) {
    if (error instanceof VpnRpcTransportFailure) {
      failure = error;
    } else if (error instanceof Error) {
      throw error;
    } else {
      throw new Error('Expected a VpnRpcTransportFailure instance.');
    }
  }
  expect(failure === undefined).assertFalse();
  if (failure === undefined) {
    return;
  }
  expect(failure.message).assertEqual(message);
  expect(failure.code).assertEqual(code);
  expect(failure.retryable).assertEqual(retryable);
  const fragments: string[] = forbiddenFragments().concat(extraForbidden);
  for (let index: number = 0; index < fragments.length; index += 1) {
    expect(failure.message.includes(fragments[index])).assertFalse();
  }
}

function expectSchedulerCanceledExactlyOnce(scheduler: FixtureVpnRpcSchedulerPort): void {
  expect(scheduler.tasks.length).assertEqual(1);
  expect(scheduler.latest().cancelable.cancelCount).assertEqual(1);
}

function expectAllZero(bytes: Uint8Array): void {
  for (let index: number = 0; index < bytes.length; index += 1) {
    expect(bytes[index]).assertEqual(0);
  }
}

function expectAllZeroRefs(buffers: Uint8Array[]): void {
  for (let index: number = 0; index < buffers.length; index += 1) {
    expectAllZero(buffers[index]);
  }
}

function expectNotAllZero(bytes: Uint8Array): void {
  let sawNonZero: boolean = false;
  for (let index: number = 0; index < bytes.length; index += 1) {
    if (bytes[index] !== 0) {
      sawNonZero = true;
      break;
    }
  }
  expect(sawNonZero).assertTrue();
}

async function createAuthenticatedPair(): Promise<AuthenticatedPair> {
  const clientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
  const serverCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
  const clientRandom: FixtureVpnRpcRandomPort = createGoldenClientRandomPort();
  const serverRandom: FixtureVpnRpcRandomPort = createGoldenServerRandomPort();
  const clientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
  const serverScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
  const client: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(clientCrypto, clientRandom, clientScheduler);
  const server: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(serverCrypto, serverRandom, serverScheduler);
  const serverHello = await server.begin();
  const clientAuth = await client.begin(serverHello);
  const serverResult: VpnRpcServerAuthenticationResult = await server.acceptClientAuth(clientAuth, GOLDEN_CLIENT_EPOCH);
  const clientConnection: VpnRpcAuthenticatedConnection = await client.acceptServerAuth(serverResult.serverAuth);
  return new AuthenticatedPair(
    client,
    server,
    clientConnection,
    serverResult.connection,
    clientCrypto,
    serverCrypto,
    clientRandom,
    serverRandom,
    clientScheduler,
    serverScheduler,
    serverResult
  );
}

function mutateAll(outputs: Uint8Array[]): void {
  for (let index: number = 0; index < outputs.length; index += 1) {
    if (outputs[index].length > 0) {
      outputs[index][0] ^= 0xff;
    }
  }
}

export default function vpnRpcAuthenticatorTestsuite() {
  describe('VpnRpcAuthenticatorTest', () => {
    it('matchesAppendixAGoldenHandshakeAddressKeyAndFrameVectorsEndToEnd', 0, async () => {
      const addressCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const socketAddress: string = await deriveVpnRpcSocketAddress(addressCrypto);
      const pair: AuthenticatedPair = await createAuthenticatedPair();
      const protectedBody: VpnRpcProtectedBody = await pair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      const decodedBody: VpnRpcBody = await pair.serverConnection.decodeIncomingFrame(
        protectedBody.bodyBytes,
        protectedBody.macBytes
      );

      expect(socketAddress).assertEqual(GOLDEN_SOCKET_ADDRESS);
      expect(pair.serverRandom.requests.join(',')).assertEqual('32,16');
      expect(pair.clientRandom.requests.join(',')).assertEqual('32');
      expect(pair.serverHello.serverNonce).assertEqual(GOLDEN_SERVER_NONCE_HEX);
      expect(pair.serverHello.serverInstance).assertEqual(GOLDEN_SERVER_INSTANCE_HEX);
      expect(pair.clientAuth.clientProof).assertEqual(GOLDEN_CLIENT_PROOF_HEX);
      expect(pair.serverResult.serverAuth.serverProof).assertEqual(GOLDEN_SERVER_PROOF_HEX);
      expect(pair.serverResult.serverAuth.clientEpoch).assertEqual(GOLDEN_CLIENT_EPOCH);
      expect(createGoldenContractSummary()).assertEqual([
        GOLDEN_SOCKET_ADDRESS,
        GOLDEN_CLIENT_PROOF_HEX,
        GOLDEN_SERVER_PROOF_HEX,
        GOLDEN_C2S_KEY_HEX,
        GOLDEN_S2C_KEY_HEX,
        GOLDEN_FRAME_MAC_HEX,
        GOLDEN_PING_BODY_TEXT
      ].join('|'));
      expect(addressCrypto.rootInputsHex.join('|')).assertEqual(SOCKET_ADDRESS_INPUT_HEX);
      expect(pair.clientCrypto.rootInputsHex.join('|')).assertEqual(
        [CLIENT_AUTH_INPUT_HEX, SERVER_AUTH_INPUT_HEX, C2S_KEY_INPUT_HEX, S2C_KEY_INPUT_HEX].join('|')
      );
      expect(pair.serverCrypto.rootInputsHex.join('|')).assertEqual(
        [CLIENT_AUTH_INPUT_HEX, SERVER_AUTH_INPUT_HEX, C2S_KEY_INPUT_HEX, S2C_KEY_INPUT_HEX].join('|')
      );
      expect(createAppendixABodyBytes().length).assertEqual(GOLDEN_PING_BODY_LENGTH);
      expect(hexBytes(createAppendixABodyBytes())).assertEqual(GOLDEN_PING_BODY_HEX);
      expect(hexBytes(protectedBody.bodyBytes)).assertEqual(GOLDEN_PING_BODY_HEX);
      expect(hexBytes(protectedBody.macBytes)).assertEqual(GOLDEN_FRAME_MAC_HEX);
      expect(pair.clientCrypto.derivedCalls[0]).assertEqual(`${GOLDEN_C2S_KEY_HEX}:${FRAME_MAC_INPUT_HEX}`);
      expect(pair.serverCrypto.derivedCalls[0]).assertEqual(`${GOLDEN_C2S_KEY_HEX}:${FRAME_MAC_INPUT_HEX}`);
      expect(hexBytes(encodeVpnRpcBody(decodedBody))).assertEqual(GOLDEN_PING_BODY_HEX);
      expect(decodeVpnRpcBodyBytes(protectedBody.bodyBytes).clientEpoch).assertEqual(GOLDEN_CLIENT_EPOCH);
      expectSchedulerCanceledExactlyOnce(pair.clientScheduler);
      expectSchedulerCanceledExactlyOnce(pair.serverScheduler);
    });

    it('reExportsBinaryCodecAndFramerFromSharedIndex', 0, () => {
      const framer: VpnRpcFramer = new VpnRpcFramer();
      const frames: VpnRpcDecodedFrame[] = framer.push(createFrameBytes(createAppendixABodyBytes()), false);

      expect(constantTimeEqualVpnRpcBytes(createAppendixABodyBytes(), createAppendixABodyBytes())).assertTrue();
      expect(frames.length).assertEqual(1);
      expect(hexBytes(frames[0].bodyBytes)).assertEqual(GOLDEN_PING_BODY_HEX);
    });

    it('rejectsConcurrentBeginCallsAndLateBeginCompletionAfterTimeoutOrDispose', 0, async () => {
      const clientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      clientCrypto.blockNextPrepareCalls(1);
      const clientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const client: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        clientCrypto,
        createGoldenClientRandomPort(),
        clientScheduler
      );
      const firstClientBegin: Promise<VpnRpcClientAuthBody> = client.begin(createGoldenServerHello());
      await flushAsyncTurns();
      expect(clientScheduler.tasks.length).assertEqual(1);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(client.begin(createGoldenServerHello())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expect(clientScheduler.tasks.length).assertEqual(1);
      clientCrypto.deferredPrepareCalls[0].resolve();
      expect((await firstClientBegin).clientProof).assertEqual(GOLDEN_CLIENT_PROOF_HEX);

      const serverCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      serverCrypto.blockNextPrepareCalls(1);
      const serverScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const server: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        serverCrypto,
        createGoldenServerRandomPort(),
        serverScheduler
      );
      const firstServerBegin: Promise<VpnRpcServerHelloBody> = server.begin();
      await flushAsyncTurns();
      expect(serverScheduler.tasks.length).assertEqual(1);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(server.begin()),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expect(serverScheduler.tasks.length).assertEqual(1);
      serverCrypto.deferredPrepareCalls[0].resolve();
      expect((await firstServerBegin).serverNonce).assertEqual(GOLDEN_SERVER_NONCE_HEX);

      const timeoutClientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      timeoutClientCrypto.blockNextPrepareCalls(1);
      const timeoutClientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const timeoutClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        timeoutClientCrypto,
        createGoldenClientRandomPort(),
        timeoutClientScheduler
      );
      const timeoutBegin: Promise<VpnRpcClientAuthBody> = timeoutClient.begin(createGoldenServerHello());
      await flushAsyncTurns();
      await timeoutClientScheduler.latest().run();
      timeoutClientCrypto.deferredPrepareCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(timeoutBegin),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_TIMEOUT_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(timeoutClientScheduler);

      const disposedServerCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      disposedServerCrypto.blockNextPrepareCalls(1);
      const disposedServerScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const disposedServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        disposedServerCrypto,
        createGoldenServerRandomPort(),
        disposedServerScheduler
      );
      const disposedBegin: Promise<VpnRpcServerHelloBody> = disposedServer.begin();
      await flushAsyncTurns();
      disposedServer.dispose();
      disposedServerCrypto.deferredPrepareCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(disposedBegin),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(disposedServerScheduler);
    });

    it('rejectsConcurrentAcceptCallsAndLateAcceptCompletionAfterTimeoutOrDispose', 0, async () => {
      const clientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const clientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const client: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        clientCrypto,
        createGoldenClientRandomPort(),
        clientScheduler
      );
      const clientAuth: VpnRpcClientAuthBody = await client.begin(createGoldenServerHello());
      clientCrypto.blockNextRootCalls(1);
      const firstClientAccept: Promise<VpnRpcAuthenticatedConnection> = client.acceptServerAuth(createGoldenServerAuth());
      await flushAsyncTurns();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(client.acceptServerAuth(createGoldenServerAuth())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      clientCrypto.deferredRootCalls[0].resolve();
      const firstClientConnection: VpnRpcAuthenticatedConnection = await firstClientAccept;
      firstClientConnection.dispose();
      expect(clientAuth.clientProof).assertEqual(GOLDEN_CLIENT_PROOF_HEX);

      const serverCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const serverScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const server: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        serverCrypto,
        createGoldenServerRandomPort(),
        serverScheduler
      );
      const hello: VpnRpcServerHelloBody = await server.begin();
      expect(hello.serverInstance).assertEqual(GOLDEN_SERVER_INSTANCE_HEX);
      serverCrypto.blockNextRootCalls(1);
      const firstServerAccept: Promise<VpnRpcServerAuthenticationResult> =
        server.acceptClientAuth(createGoldenClientAuth(), GOLDEN_CLIENT_EPOCH);
      await flushAsyncTurns();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(server.acceptClientAuth(createGoldenClientAuth(), GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      serverCrypto.deferredRootCalls[0].resolve();
      const firstServerResult: VpnRpcServerAuthenticationResult = await firstServerAccept;
      firstServerResult.connection.dispose();

      const timeoutAcceptClientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const timeoutAcceptClientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const timeoutAcceptClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        timeoutAcceptClientCrypto,
        createGoldenClientRandomPort(),
        timeoutAcceptClientScheduler
      );
      await timeoutAcceptClient.begin(createGoldenServerHello());
      timeoutAcceptClientCrypto.blockNextRootCalls(1);
      const timeoutAcceptPromise: Promise<VpnRpcAuthenticatedConnection> =
        timeoutAcceptClient.acceptServerAuth(createGoldenServerAuth());
      await flushAsyncTurns();
      await timeoutAcceptClientScheduler.latest().run();
      timeoutAcceptClientCrypto.deferredRootCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(timeoutAcceptPromise),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_TIMEOUT_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(timeoutAcceptClientScheduler);

      const disposedAcceptServerCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const disposedAcceptServerScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const disposedAcceptServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        disposedAcceptServerCrypto,
        createGoldenServerRandomPort(),
        disposedAcceptServerScheduler
      );
      await disposedAcceptServer.begin();
      disposedAcceptServerCrypto.blockNextRootCalls(1);
      const disposedAcceptPromise: Promise<VpnRpcServerAuthenticationResult> =
        disposedAcceptServer.acceptClientAuth(createGoldenClientAuth(), GOLDEN_CLIENT_EPOCH);
      await flushAsyncTurns();
      disposedAcceptServer.dispose();
      disposedAcceptServerCrypto.deferredRootCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(disposedAcceptPromise),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(disposedAcceptServerScheduler);
    });

    it('keepsClientAndServerRolesSeparatedAndSupportsBothDirections', 0, async () => {
      const clientToServerPair: AuthenticatedPair = await createAuthenticatedPair();
      const clientProtected: VpnRpcProtectedBody = await clientToServerPair.clientConnection.encodeOutgoingBody(
        createAppendixABodyBuilder()
      );
      const serverDecoded: VpnRpcBody = await clientToServerPair.serverConnection.decodeIncomingFrame(
        clientProtected.bodyBytes,
        clientProtected.macBytes
      );

      expect(hexBytes(encodeVpnRpcBody(serverDecoded))).assertEqual(hexBytes(createAppendixABodyBytes()));
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            clientToServerPair.clientConnection.decodeIncomingFrame(clientProtected.bodyBytes, clientProtected.macBytes)
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const serverToClientPair: AuthenticatedPair = await createAuthenticatedPair();
      const responseBody: VpnRpcBody = createPingResponseBody(1);
      serverToClientPair.serverCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      serverToClientPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      const serverProtected: VpnRpcProtectedBody = await serverToClientPair.serverConnection.encodeOutgoingBody(
        createPingResponseBuilder(1, '00000000-0000-4000-8000-000000000001')
      );
      const clientDecoded: VpnRpcBody = await serverToClientPair.clientConnection.decodeIncomingFrame(
        serverProtected.bodyBytes,
        serverProtected.macBytes
      );

      expect(hexBytes(serverProtected.macBytes)).assertEqual(GOLDEN_SERVER_RESPONSE_MAC_HEX);
      expect(clientDecoded.sequence).assertEqual(1);
      expect(clientDecoded.method).assertEqual('PING');
      expect(clientDecoded.clientEpoch).assertEqual(GOLDEN_CLIENT_EPOCH);
    });

    it('enforcesHandshakeStateOneShotAndConstantTimeProofFailures', 0, async () => {
      const clientBeforeBegin: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(clientBeforeBegin.acceptServerAuth(createGoldenServerAuth())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const serverBeforeBegin: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        createGoldenCryptoPort(),
        createGoldenServerRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(serverBeforeBegin.acceptClientAuth(createGoldenClientAuth(), GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const beginTwiceServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        createGoldenCryptoPort(),
        createGoldenServerRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const beginTwiceHello = await beginTwiceServer.begin();
      expect(beginTwiceHello.serverNonce).assertEqual(GOLDEN_SERVER_NONCE_HEX);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(beginTwiceServer.begin()),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const beginTwiceClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const clientFirstAuth = await beginTwiceClient.begin(createGoldenServerHello());
      expect(clientFirstAuth.clientProof).assertEqual(GOLDEN_CLIENT_PROOF_HEX);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(beginTwiceClient.begin(createGoldenServerHello())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const badFirstServerCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const badFirstServerScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const badFirstServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        badFirstServerCrypto,
        createGoldenServerRandomPort(),
        badFirstServerScheduler
      );
      const badFirstHello = await badFirstServer.begin();
      const badFirstClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const badFirstAuth = await badFirstClient.begin(badFirstHello);
      const badFirstProof = createVpnRpcClientAuthBody(1, badFirstAuth.clientNonce, createMutatedProofFirstByte(badFirstAuth.clientProof));
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(badFirstServer.acceptClientAuth(badFirstProof, GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(badFirstServerScheduler);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(badFirstServer.acceptClientAuth(createGoldenClientAuth(), GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const badLastServerScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const badLastServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        createGoldenCryptoPort(),
        createGoldenServerRandomPort(),
        badLastServerScheduler
      );
      const badLastHello = await badLastServer.begin();
      const badLastClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const badLastAuth = await badLastClient.begin(badLastHello);
      const badLastProof = createVpnRpcClientAuthBody(1, badLastAuth.clientNonce, createMutatedProofLastByte(badLastAuth.clientProof));
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(badLastServer.acceptClientAuth(badLastProof, GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expectSchedulerCanceledExactlyOnce(badLastServerScheduler);

      const pair: AuthenticatedPair = await createAuthenticatedPair();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(pair.server.acceptClientAuth(pair.clientAuth, GOLDEN_CLIENT_EPOCH)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(pair.client.acceptServerAuth(pair.serverResult.serverAuth)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      pair.client.dispose();
      pair.client.dispose();
      pair.server.dispose();
      pair.server.dispose();
      expectSchedulerCanceledExactlyOnce(pair.clientScheduler);
      expectSchedulerCanceledExactlyOnce(pair.serverScheduler);
    });

    it('mapsDependencyFailuresAndTimeoutsWithoutLeakingDetails', 0, async () => {
      const addressPrepareCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      addressPrepareCrypto.prepareError = new Error(`fixture-prepare ${GOLDEN_SERVER_NONCE_HEX}`);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(deriveVpnRpcSocketAddress(addressPrepareCrypto)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const shortClientRandom: FixtureVpnRpcRandomPort = new FixtureVpnRpcRandomPort([decodeVpnRpcLowercaseHex(GOLDEN_CLIENT_NONCE_HEX).slice(0, 31)]);
      const shortClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        shortClientRandom,
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(shortClient.begin(createGoldenServerHello())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const shortServerRandom: FixtureVpnRpcRandomPort = new FixtureVpnRpcRandomPort([
        decodeVpnRpcLowercaseHex(GOLDEN_SERVER_NONCE_HEX),
        decodeVpnRpcLowercaseHex(GOLDEN_SERVER_INSTANCE_HEX).slice(0, 15)
      ]);
      const shortServer: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        createGoldenCryptoPort(),
        shortServerRandom,
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(shortServer.begin()),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const schedulerThrow: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      schedulerThrow.throwOnSchedule = true;
      const schedulerFailClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        schedulerThrow
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(schedulerFailClient.begin(createGoldenServerHello())),
        VPN_RPC_RPC_UNAVAILABLE_CODE,
        VPN_RPC_RPC_UNAVAILABLE_MESSAGE,
        VPN_RPC_RPC_UNAVAILABLE_RETRYABLE
      );

      const rootHmacFailCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      rootHmacFailCrypto.rootHmacError = new Error(`fixture-root ${GOLDEN_CLIENT_PROOF_HEX}`);
      const rootHmacFailClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        rootHmacFailCrypto,
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(rootHmacFailClient.begin(createGoldenServerHello())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const wrongRootLengthCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      wrongRootLengthCrypto.rootOutputLengthOverride = 31;
      const wrongRootLengthClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        wrongRootLengthCrypto,
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(wrongRootLengthClient.begin(createGoldenServerHello())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const timeoutCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const timeoutScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const timeoutClient: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        timeoutCrypto,
        createGoldenClientRandomPort(),
        timeoutScheduler
      );
      const timeoutAuth = await timeoutClient.begin(createGoldenServerHello());
      expect(timeoutAuth.clientProof).assertEqual(GOLDEN_CLIENT_PROOF_HEX);
      expect(timeoutScheduler.delays.join(',')).assertEqual(`${VPN_RPC_AUTH_TIMEOUT_MS}`);
      await timeoutScheduler.latest().run();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(timeoutClient.acceptServerAuth(createGoldenServerAuth())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_TIMEOUT_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      timeoutClient.dispose();
      timeoutClient.dispose();
      expectSchedulerCanceledExactlyOnce(timeoutScheduler);

      const derivedFailPair: AuthenticatedPair = await createAuthenticatedPair();
      derivedFailPair.clientCrypto.derivedHmacError = new Error(`fixture-derived ${GOLDEN_FRAME_MAC_HEX}`);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(derivedFailPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(derivedFailPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder())),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
    });

    it('enforcesOutgoingIncomingSequenceEpochAndMacRules', 0, async () => {
      const outgoingPair: AuthenticatedPair = await createAuthenticatedPair();
      const firstProtected: VpnRpcProtectedBody = await outgoingPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      expect(hexBytes(firstProtected.macBytes)).assertEqual(GOLDEN_FRAME_MAC_HEX);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          outgoingPair.clientConnection.encodeOutgoingBody(
            (sequence: number, clientEpoch: number): VpnRpcBody => createPingRequestBody(sequence + 1, 3, '00000000-0000-4000-8000-000000000003', clientEpoch)
          )
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const incomingPair: AuthenticatedPair = await createAuthenticatedPair();
      const responseBody1: VpnRpcBody = createPingResponseBody(1);
      const responseBody2: VpnRpcBody = createPingResponseBody(2, 2, '00000000-0000-4000-8000-000000000002');
      incomingPair.serverCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody1, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      incomingPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody1, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      incomingPair.serverCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody2, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      incomingPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody2, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      const responseProtected1: VpnRpcProtectedBody = await incomingPair.serverConnection.encodeOutgoingBody(
        createPingResponseBuilder(1, '00000000-0000-4000-8000-000000000001')
      );
      const responseProtected2: VpnRpcProtectedBody = await incomingPair.serverConnection.encodeOutgoingBody(
        createPingResponseBuilder(2, '00000000-0000-4000-8000-000000000002')
      );
      expect((await incomingPair.clientConnection.decodeIncomingFrame(responseProtected1.bodyBytes, responseProtected1.macBytes)).sequence).assertEqual(1);
      expect((await incomingPair.clientConnection.decodeIncomingFrame(responseProtected2.bodyBytes, responseProtected2.macBytes)).sequence).assertEqual(2);
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            incomingPair.clientConnection.decodeIncomingFrame(responseProtected1.bodyBytes, responseProtected1.macBytes)
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const gapPair: AuthenticatedPair = await createAuthenticatedPair();
      gapPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody2, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            gapPair.clientConnection.decodeIncomingFrame(
              encodeVpnRpcBody(responseBody2),
              decodeVpnRpcLowercaseHex(GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX)
            )
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const wrongEpochPair: AuthenticatedPair = await createAuthenticatedPair();
      const wrongEpochBody: VpnRpcBody = createPingRequestBody(1, 1, '00000000-0000-4000-8000-000000000001', GOLDEN_CLIENT_EPOCH - 1);
      wrongEpochPair.serverCrypto.addFrameMacMapping(GOLDEN_C2S_KEY_HEX, wrongEpochBody, GOLDEN_WRONG_EPOCH_MAC_HEX);
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            wrongEpochPair.serverConnection.decodeIncomingFrame(
              encodeVpnRpcBody(wrongEpochBody),
              decodeVpnRpcLowercaseHex(GOLDEN_WRONG_EPOCH_MAC_HEX)
            )
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const badMacFirstPair: AuthenticatedPair = await createAuthenticatedPair();
      const validProtected: VpnRpcProtectedBody = await badMacFirstPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            badMacFirstPair.serverConnection.decodeIncomingFrame(validProtected.bodyBytes, createMutatedMacBytesFirstByte())
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const badMacLastPair: AuthenticatedPair = await createAuthenticatedPair();
      const validProtectedLast: VpnRpcProtectedBody = await badMacLastPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            badMacLastPair.serverConnection.decodeIncomingFrame(validProtectedLast.bodyBytes, createMutatedMacBytesLastByte())
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
    });

    it('rejectsBadMacBeforeBodyDecodeAndDisposesConnectionsAfterFatalErrors', 0, async () => {
      const pair: AuthenticatedPair = await createAuthenticatedPair();
      const validProtected: VpnRpcProtectedBody = await pair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            pair.serverConnection.decodeIncomingFrame(createInvalidJsonBodyBytes(), createMutatedMacBytesFirstByte())
          ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(pair.serverConnection.decodeIncomingFrame(validProtected.bodyBytes, validProtected.macBytes)),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
    });

    it('copiesInputsAndOutputsAndZeroizesTemporaryBuffersWhilePreservingOutputs', 0, async () => {
      const clientCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const serverCrypto: FixtureVpnRpcCryptoPort = createGoldenCryptoPort();
      const clientRandom: FixtureVpnRpcRandomPort = createGoldenClientRandomPort();
      const serverRandom: FixtureVpnRpcRandomPort = createGoldenServerRandomPort();
      const clientScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const serverScheduler: FixtureVpnRpcSchedulerPort = new FixtureVpnRpcSchedulerPort();
      const client: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(clientCrypto, clientRandom, clientScheduler);
      const server: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(serverCrypto, serverRandom, serverScheduler);
      const hello = await server.begin();
      serverRandom.returnedRefs[0][0] ^= 0xff;
      expect(hello.serverNonce).assertEqual(GOLDEN_SERVER_NONCE_HEX);
      const clientAuth = await client.begin(hello);
      clientRandom.returnedRefs[0][0] ^= 0xff;
      expect(clientAuth.clientNonce).assertEqual(GOLDEN_CLIENT_NONCE_HEX);
      const serverResult: VpnRpcServerAuthenticationResult = await server.acceptClientAuth(clientAuth, GOLDEN_CLIENT_EPOCH);
      const clientConnection: VpnRpcAuthenticatedConnection = await client.acceptServerAuth(serverResult.serverAuth);
      expectAllZeroRefs(clientCrypto.rootOutputs);
      expectAllZeroRefs(serverCrypto.rootOutputs);
      const encodePromise: Promise<VpnRpcProtectedBody> = clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      const protectedBody: VpnRpcProtectedBody = await encodePromise;
      expect(hexBytes(protectedBody.macBytes)).assertEqual(GOLDEN_FRAME_MAC_HEX);
      expect(hexBytes(protectedBody.bodyBytes)).assertEqual(GOLDEN_PING_BODY_HEX);
      expectAllZeroRefs(clientCrypto.derivedOutputs);

      const responseBody: VpnRpcBody = createPingResponseBody(1);
      serverCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      const responseProtected: VpnRpcProtectedBody = await serverResult.connection.encodeOutgoingBody(
        createPingResponseBuilder(1, '00000000-0000-4000-8000-000000000001')
      );
      clientCrypto.blockNextDerivedCalls(1);
      const decodePromise: Promise<VpnRpcBody> = clientConnection.decodeIncomingFrame(
        responseProtected.bodyBytes,
        responseProtected.macBytes
      );
      await flushAsyncTurns();
      responseProtected.bodyBytes[0] ^= 0xff;
      responseProtected.macBytes[0] ^= 0xff;
      clientCrypto.deferredDerivedCalls[0].resolve();
      expect((await decodePromise).sequence).assertEqual(1);
      expectAllZeroRefs(serverCrypto.derivedOutputs);

      expectAllZeroRefs(clientCrypto.derivedKeyRefs);
      expectAllZeroRefs(serverCrypto.derivedKeyRefs);
      clientConnection.dispose();
      clientConnection.dispose();
      serverResult.connection.dispose();
      serverResult.connection.dispose();
    });

    it('capturesAuthoritativeSequenceAndEpochInsideSerializedBuilder', 0, async () => {
      const queuedPair: AuthenticatedPair = await createAuthenticatedPair();
      const capturedSequences: number[] = [];
      const capturedEpochs: number[] = [];
      const firstBuilder: FixtureOutgoingBodyBuilder = (sequence: number, clientEpoch: number): VpnRpcBody => {
        capturedSequences.push(sequence);
        capturedEpochs.push(clientEpoch);
        return createPingRequestBody(sequence, 1, '00000000-0000-4000-8000-000000000001', clientEpoch);
      };
      const secondBuilder: FixtureOutgoingBodyBuilder = (sequence: number, clientEpoch: number): VpnRpcBody => {
        capturedSequences.push(sequence);
        capturedEpochs.push(clientEpoch);
        return createPingRequestBody(sequence, 2, '00000000-0000-4000-8000-000000000002', clientEpoch);
      };
      const secondBody: VpnRpcBody = createPingRequestBody(2, 2, '00000000-0000-4000-8000-000000000002');
      queuedPair.clientCrypto.addFrameMacMapping(GOLDEN_C2S_KEY_HEX, createAppendixARequestBody(), GOLDEN_FRAME_MAC_HEX);
      queuedPair.clientCrypto.addFrameMacMapping(GOLDEN_C2S_KEY_HEX, secondBody, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      queuedPair.clientCrypto.blockNextDerivedCalls(2);

      const firstPromise: Promise<VpnRpcProtectedBody> =
        queuedPair.clientConnection.encodeOutgoingBody(firstBuilder);
      const secondPromise: Promise<VpnRpcProtectedBody> = queuedPair.clientConnection.encodeOutgoingBody(secondBuilder);

      await flushAsyncTurns();
      expect(capturedSequences.join(',')).assertEqual('1');
      expect(capturedEpochs.join(',')).assertEqual(`${GOLDEN_CLIENT_EPOCH}`);
      expect(queuedPair.clientCrypto.derivedCalls.length).assertEqual(1);
      expect(queuedPair.clientCrypto.deferredDerivedCalls.length).assertEqual(1);

      queuedPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await flushAsyncTurns();
      expect(capturedSequences.join(',')).assertEqual('1,2');
      expect(capturedEpochs.join(',')).assertEqual(`${GOLDEN_CLIENT_EPOCH},${GOLDEN_CLIENT_EPOCH}`);
      expect(queuedPair.clientCrypto.derivedCalls.length).assertEqual(2);
      expect(queuedPair.clientCrypto.deferredDerivedCalls.length).assertEqual(2);

      queuedPair.clientCrypto.deferredDerivedCalls[1].resolve();
      const firstProtected: VpnRpcProtectedBody = await firstPromise;
      const secondProtected: VpnRpcProtectedBody = await secondPromise;
      expect(hexBytes(firstProtected.macBytes)).assertEqual(GOLDEN_FRAME_MAC_HEX);
      expect(hexBytes(secondProtected.macBytes)).assertEqual(GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);

      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          queuedPair.clientConnection.encodeOutgoingBody(
            (sequence: number, clientEpoch: number): VpnRpcBody =>
              createPingRequestBody(sequence + 1, 3, '00000000-0000-4000-8000-000000000003', clientEpoch)
          )
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          queuedPair.clientConnection.encodeOutgoingBody(
            (sequence: number, clientEpoch: number): VpnRpcBody =>
              createPingRequestBody(sequence, 4, '00000000-0000-4000-8000-000000000004', clientEpoch + 1)
          )
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );

      const fatalPair: AuthenticatedPair = await createAuthenticatedPair();
      fatalPair.clientCrypto.blockNextDerivedCalls(1);
      const fatalFirstPromise: Promise<VpnRpcProtectedBody> =
        fatalPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      const fatalSecondPromise: Promise<VpnRpcProtectedBody> =
        fatalPair.clientConnection.encodeOutgoingBody(secondBuilder);

      await flushAsyncTurns();
      expect(fatalPair.clientCrypto.derivedCalls.length).assertEqual(1);
      fatalPair.clientCrypto.deferredDerivedCalls[0].reject(new Error(`fixture-derived ${GOLDEN_FRAME_MAC_HEX}`));
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(fatalFirstPromise),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(fatalSecondPromise),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );
      expect(fatalPair.clientCrypto.derivedCalls.length).assertEqual(1);
    });

    it('capsPendingIncomingAndOutgoingOperationsAtSixtyFourAndFailClosesOnOverflow', 0, async () => {
      const incomingPair: AuthenticatedPair = await createAuthenticatedPair();
      const responseBody1: VpnRpcBody = createPingResponseBody(1);
      incomingPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody1, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      incomingPair.clientCrypto.blockNextDerivedCalls(1);
      const responseBytes1: Uint8Array = encodeVpnRpcBody(responseBody1);
      const firstIncomingPromise: Promise<VpnRpcBody> = incomingPair.clientConnection.decodeIncomingFrame(
        responseBytes1,
        decodeVpnRpcLowercaseHex(GOLDEN_SERVER_RESPONSE_MAC_HEX)
      );
      const queuedIncomingHandled: Promise<void>[] = [];
      for (let index: number = 2; index <= 64; index += 1) {
        const body: VpnRpcBody = createPingResponseBody(index, index, `00000000-0000-4000-8000-${`${index}`.padStart(12, '0')}`);
        incomingPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, body, `${index}`.padStart(64, '0'));
        queuedIncomingHandled.push(ignorePromiseResult(
          incomingPair.clientConnection.decodeIncomingFrame(
            encodeVpnRpcBody(body),
            decodeVpnRpcLowercaseHex(`${index}`.padStart(64, '0'))
          )
        ));
      }
      await flushAsyncTurns();
      expect(incomingPair.clientCrypto.derivedCalls.length).assertEqual(1);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          incomingPair.clientConnection.decodeIncomingFrame(
            encodeVpnRpcBody(createPingResponseBody(65, 65, '00000000-0000-4000-8000-000000000065')),
            decodeVpnRpcLowercaseHex('65'.padStart(64, '0'))
          )
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      incomingPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(firstIncomingPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      for (let index: number = 0; index < queuedIncomingHandled.length; index += 1) {
        await expectTransportFailure(
          (): Promise<void> => queuedIncomingHandled[index],
          VPN_RPC_FRAME_INVALID_CODE,
          VPN_RPC_FRAME_INVALID_MESSAGE,
          VPN_RPC_FRAME_INVALID_RETRYABLE
        );
      }
      expect(incomingPair.clientCrypto.derivedCalls.length).assertEqual(1);

      const outgoingPair: AuthenticatedPair = await createAuthenticatedPair();
      outgoingPair.clientCrypto.addFrameMacMapping(GOLDEN_C2S_KEY_HEX, createAppendixARequestBody(), GOLDEN_FRAME_MAC_HEX);
      outgoingPair.clientCrypto.blockNextDerivedCalls(1);
      const firstOutgoingPromise: Promise<VpnRpcProtectedBody> =
        outgoingPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      const queuedOutgoingHandled: Promise<void>[] = [];
      for (let index: number = 2; index <= 64; index += 1) {
        const body: VpnRpcBody = createPingRequestBody(index, index, `00000000-0000-4000-8000-${`${index}`.padStart(12, '0')}`);
        outgoingPair.clientCrypto.addFrameMacMapping(GOLDEN_C2S_KEY_HEX, body, `${index + 100}`.padStart(64, '0'));
        queuedOutgoingHandled.push(ignorePromiseResult(
          outgoingPair.clientConnection.encodeOutgoingBody(
            createPingRequestBuilder(index, `00000000-0000-4000-8000-${`${index}`.padStart(12, '0')}`)
          )
        ));
      }
      await flushAsyncTurns();
      expect(outgoingPair.clientCrypto.derivedCalls.length).assertEqual(1);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          outgoingPair.clientConnection.encodeOutgoingBody(
            createPingRequestBuilder(65, '00000000-0000-4000-8000-000000000065')
          )
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      outgoingPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(firstOutgoingPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      for (let index: number = 0; index < queuedOutgoingHandled.length; index += 1) {
        await expectTransportFailure(
          (): Promise<void> => queuedOutgoingHandled[index],
          VPN_RPC_FRAME_INVALID_CODE,
          VPN_RPC_FRAME_INVALID_MESSAGE,
          VPN_RPC_FRAME_INVALID_RETRYABLE
        );
      }
      expect(outgoingPair.clientCrypto.derivedCalls.length).assertEqual(1);
    });

    it('serializesConcurrentIncomingMacWorkPerDirectionAndPreservesTerminalFailures', 0, async () => {
      const queuedPair: AuthenticatedPair = await createAuthenticatedPair();
      const responseBody1: VpnRpcBody = createPingResponseBody(1);
      const responseBody2: VpnRpcBody = createPingResponseBody(2, 2, '00000000-0000-4000-8000-000000000002');
      const responseBytes1: Uint8Array = encodeVpnRpcBody(responseBody1);
      const responseBytes2: Uint8Array = encodeVpnRpcBody(responseBody2);
      queuedPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody1, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      queuedPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody2, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      queuedPair.clientCrypto.blockNextDerivedCalls(2);

      const firstPromise: Promise<VpnRpcBody> =
        queuedPair.clientConnection.decodeIncomingFrame(responseBytes1, decodeVpnRpcLowercaseHex(GOLDEN_SERVER_RESPONSE_MAC_HEX));
      const secondPromise: Promise<VpnRpcBody> =
        queuedPair.clientConnection.decodeIncomingFrame(responseBytes2, decodeVpnRpcLowercaseHex(GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX));

      await flushAsyncTurns();
      expect(queuedPair.clientCrypto.derivedCalls.length).assertEqual(1);
      expect(queuedPair.clientCrypto.deferredDerivedCalls.length).assertEqual(1);

      queuedPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await flushAsyncTurns();
      expect(queuedPair.clientCrypto.derivedCalls.length).assertEqual(2);
      expect(queuedPair.clientCrypto.deferredDerivedCalls.length).assertEqual(2);

      queuedPair.clientCrypto.deferredDerivedCalls[1].resolve();
      expect((await firstPromise).sequence).assertEqual(1);
      expect((await secondPromise).sequence).assertEqual(2);

      const fatalPair: AuthenticatedPair = await createAuthenticatedPair();
      fatalPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody1, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      fatalPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody2, GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX);
      fatalPair.clientCrypto.blockNextDerivedCalls(1);
      const fatalFirstPromise: Promise<VpnRpcBody> =
        fatalPair.clientConnection.decodeIncomingFrame(responseBytes1, createMutatedMacBytesFirstByte());
      const fatalSecondPromise: Promise<VpnRpcBody> =
        fatalPair.clientConnection.decodeIncomingFrame(responseBytes2, decodeVpnRpcLowercaseHex(GOLDEN_CLIENT_SECOND_FRAME_MAC_HEX));

      await flushAsyncTurns();
      expect(fatalPair.clientCrypto.derivedCalls.length).assertEqual(1);
      fatalPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(fatalFirstPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(fatalSecondPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      expect(fatalPair.clientCrypto.derivedCalls.length).assertEqual(1);
    });

    it('rejectsInFlightOutgoingAndIncomingOperationsAfterDisposeBeforeDeferredHmacResolves', 0, async () => {
      const outgoingPair: AuthenticatedPair = await createAuthenticatedPair();
      outgoingPair.clientCrypto.blockNextDerivedCalls(1);
      const outgoingPromise: Promise<VpnRpcProtectedBody> =
        outgoingPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder());
      await flushAsyncTurns();
      expect(outgoingPair.clientCrypto.derivedCalls.length).assertEqual(1);
      outgoingPair.clientConnection.dispose();
      outgoingPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(outgoingPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      expectAllZero(outgoingPair.clientCrypto.derivedKeyRefs[0]);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(outgoingPair.clientConnection.encodeOutgoingBody(createAppendixABodyBuilder())),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      expect(outgoingPair.clientCrypto.derivedCalls.length).assertEqual(1);

      const incomingPair: AuthenticatedPair = await createAuthenticatedPair();
      const responseBody: VpnRpcBody = createPingResponseBody(1);
      const responseBytes: Uint8Array = encodeVpnRpcBody(responseBody);
      incomingPair.clientCrypto.addFrameMacMapping(GOLDEN_S2C_KEY_HEX, responseBody, GOLDEN_SERVER_RESPONSE_MAC_HEX);
      incomingPair.clientCrypto.blockNextDerivedCalls(1);
      const incomingPromise: Promise<VpnRpcBody> = incomingPair.clientConnection.decodeIncomingFrame(
        responseBytes,
        decodeVpnRpcLowercaseHex(GOLDEN_SERVER_RESPONSE_MAC_HEX)
      );
      await flushAsyncTurns();
      expect(incomingPair.clientCrypto.derivedCalls.length).assertEqual(1);
      incomingPair.clientConnection.dispose();
      incomingPair.clientCrypto.deferredDerivedCalls[0].resolve();
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(incomingPromise),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      expectAllZero(incomingPair.clientCrypto.derivedKeyRefs[0]);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(
          incomingPair.clientConnection.decodeIncomingFrame(responseBytes, decodeVpnRpcLowercaseHex(GOLDEN_SERVER_RESPONSE_MAC_HEX))
        ),
        VPN_RPC_FRAME_INVALID_CODE,
        VPN_RPC_FRAME_INVALID_MESSAGE,
        VPN_RPC_FRAME_INVALID_RETRYABLE
      );
      expect(incomingPair.clientCrypto.derivedCalls.length).assertEqual(1);
    });

    it('rejectsUnsafeEpochValuesAndClassifiesOnlyCanonicalIncomingVersionMismatches', 0, async () => {
      const serverForEpoch: VpnRpcServerAuthenticator = new VpnRpcServerAuthenticator(
        createGoldenCryptoPort(),
        createGoldenServerRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const hello = await serverForEpoch.begin();
      const clientForEpoch: VpnRpcClientAuthenticator = new VpnRpcClientAuthenticator(
        createGoldenCryptoPort(),
        createGoldenClientRandomPort(),
        new FixtureVpnRpcSchedulerPort()
      );
      const auth = await clientForEpoch.begin(hello);
      await expectTransportFailure(
        (): Promise<void> => ignorePromiseResult(serverForEpoch.acceptClientAuth(auth, 0)),
        VPN_RPC_AUTH_FAILED_CODE,
        VPN_RPC_AUTH_FAILED_MESSAGE,
        VPN_RPC_AUTH_FAILED_RETRYABLE
      );

      const protocolPair: AuthenticatedPair = await createAuthenticatedPair();
      const baseResponseText: string = createPingResponseText(1);
      const protocolBytes: Uint8Array = encodeVpnRpcUtf8(replaceProtocolVersionToken(baseResponseText, '2'));
      protocolPair.clientCrypto.addDerivedMapping(
        GOLDEN_S2C_KEY_HEX,
        hexBytes(createFrameMacInputForBytes(protocolBytes)),
        GOLDEN_PROTOCOL_MISMATCH_MAC_HEX
      );
      await expectTransportFailure(
        (): Promise<void> =>
          ignorePromiseResult(
            protocolPair.clientConnection.decodeIncomingFrame(
              protocolBytes,
              decodeVpnRpcLowercaseHex(GOLDEN_PROTOCOL_MISMATCH_MAC_HEX)
            )
          ),
        VPN_RPC_PROTOCOL_MISMATCH_CODE,
        VPN_RPC_PROTOCOL_MISMATCH_MESSAGE,
        VPN_RPC_PROTOCOL_MISMATCH_RETRYABLE
      );

      const malformedTexts: string[] = [
        replaceProtocolVersionToken(baseResponseText, '2').slice(0, replaceProtocolVersionToken(baseResponseText, '2').length - 1),
        `${replaceProtocolVersionToken(baseResponseText, '2')} `,
        replaceProtocolVersionToken(baseResponseText, '"2"'),
        replaceProtocolVersionToken(baseResponseText, '02'),
        replaceProtocolVersionToken(baseResponseText, '2e0'),
        replaceProtocolVersionToken(baseResponseText, '2').replace(',"kind":"RESPONSE"', ''),
        replaceProtocolVersionToken(baseResponseText, '2').replace(
          '{"protocolVersion":2,"kind":"RESPONSE"',
          '{"kind":"RESPONSE","protocolVersion":2'
        ),
        replaceProtocolVersionToken(baseResponseText, '2').replace(
          '"payload":{"serverInstance":"606162636465666768696a6b6c6d6e6f"}}',
          '"payload":{"serverInstance":"606162636465666768696a6b6c6d6e6f"},"extra":1}'
        )
      ];
      const malformedMacs: string[] = [
        '8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0',
        'a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0',
        'c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0',
        'e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00',
        '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
        '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40',
        '4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60',
        '6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80'
      ];
      for (let index: number = 0; index < malformedTexts.length; index += 1) {
        const malformedPair: AuthenticatedPair = await createAuthenticatedPair();
        const malformedBytes: Uint8Array = encodeVpnRpcUtf8(malformedTexts[index]);
        malformedPair.clientCrypto.addDerivedMapping(
          GOLDEN_S2C_KEY_HEX,
          hexBytes(createFrameMacInputForBytes(malformedBytes)),
          malformedMacs[index]
        );
        await expectTransportFailure(
          (): Promise<void> =>
            ignorePromiseResult(
              malformedPair.clientConnection.decodeIncomingFrame(
                malformedBytes,
                decodeVpnRpcLowercaseHex(malformedMacs[index])
              )
            ),
          VPN_RPC_FRAME_INVALID_CODE,
          VPN_RPC_FRAME_INVALID_MESSAGE,
          VPN_RPC_FRAME_INVALID_RETRYABLE
        );
      }
    });
  });
}
