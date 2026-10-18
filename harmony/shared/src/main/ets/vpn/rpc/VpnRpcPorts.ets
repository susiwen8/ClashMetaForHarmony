import type {
  ProxyGroupListQueryResult,
  ProxyGroupQueryResult,
  ProxySelectionResult
} from '../../proxy/ProxyModels';
import type { ProxyDelayResult } from '../../proxy/ProxyDelayModels';
import type {
  VpnProxyCancelDelayTestCommand,
  VpnProxyQueryGroupCommand,
  VpnProxyQueryGroupsCommand,
  VpnProxyReadDelayTestCommand,
  VpnProxySelectCommand,
  VpnProxyStartDelayTestCommand
} from '../../proxy/ProxyPorts';
import type { VpnControllerStopResult, VpnRuntimeSnapshot } from '../VpnModels';
import type { VpnOpaqueCatalog } from './VpnOpaqueCatalog';
import type { CoreRuntimeMode } from '../../core/CoreModels';

export interface VpnRpcCryptoPort {
  prepare(): Promise<void>;
  rootHmac(input: Uint8Array): Promise<Uint8Array>;
  derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array>;
}

export type VpnRpcSocketFailureCode =
  | 'CONNECT_REFUSED'
  | 'ADDRESS_IN_USE'
  | 'SEND_FAILED'
  | 'CLOSED'
  | 'PLATFORM_FAILED';

const VPN_RPC_SOCKET_FAILURE_MESSAGES: Map<VpnRpcSocketFailureCode, string> = new Map<VpnRpcSocketFailureCode, string>([
  ['CONNECT_REFUSED', 'VPN RPC socket connect refused.'],
  ['ADDRESS_IN_USE', 'VPN RPC socket address already in use.'],
  ['SEND_FAILED', 'VPN RPC socket send failed.'],
  ['CLOSED', 'VPN RPC socket closed.'],
  ['PLATFORM_FAILED', 'VPN RPC socket platform failed.']
]);

const VPN_RPC_SOCKET_FAILURE_RETRYABLE: Map<VpnRpcSocketFailureCode, boolean> = new Map<VpnRpcSocketFailureCode, boolean>([
  ['CONNECT_REFUSED', true],
  ['ADDRESS_IN_USE', true],
  ['SEND_FAILED', true],
  ['CLOSED', false],
  ['PLATFORM_FAILED', true]
]);

export class VpnRpcSocketFailure extends Error {
  readonly code: VpnRpcSocketFailureCode;
  readonly retryable: boolean;

  constructor(code: VpnRpcSocketFailureCode) {
    super(requireVpnRpcSocketFailureMessage(code));
    this.code = code;
    this.retryable = requireVpnRpcSocketFailureRetryable(code);
  }
}

export interface VpnRpcSocketConnectionPort {
  send(bytes: Uint8Array): Promise<void>;
  subscribeData(listener: (bytes: Uint8Array) => void): number;
  unsubscribeData(id: number): void;
  subscribeClose(listener: () => void): number;
  unsubscribeClose(id: number): void;
  subscribeError(listener: () => void): number;
  unsubscribeError(id: number): void;
  close(): Promise<void>;
}

export interface VpnRpcSocketClientFactoryPort {
  connect(address: string, timeoutMs: number): Promise<VpnRpcSocketConnectionPort>;
}

export interface VpnRpcSocketServerPort {
  readonly preservePendingCandidate?: boolean;
  listen(address: string, listener: (connection: VpnRpcSocketConnectionPort) => void | Promise<void>): Promise<void>;
  close(): Promise<void>;
}

export interface VpnRpcRandomPort {
  bytes(length: number): Uint8Array;
}

export interface VpnRpcCancelableTaskPort {
  cancel(): void;
}

export interface VpnRpcSchedulerPort {
  schedule(delayMs: number, runner: () => Promise<void>): VpnRpcCancelableTaskPort;
}

export interface VpnRpcClockPort {
  nowMs(): number;
}

export interface VpnRpcRuntimeDispatchPort {
  snapshot(): VpnRuntimeSnapshot;
  catalog(): VpnOpaqueCatalog;
  queryGroups(command: VpnProxyQueryGroupsCommand): Promise<ProxyGroupListQueryResult>;
  queryGroup(command: VpnProxyQueryGroupCommand): Promise<ProxyGroupQueryResult>;
  select(command: VpnProxySelectCommand): Promise<ProxySelectionResult>;
  startDelay(command: VpnProxyStartDelayTestCommand): Promise<ProxyDelayResult>;
  readDelay(command: VpnProxyReadDelayTestCommand): Promise<ProxyDelayResult>;
  cancelDelay(command: VpnProxyCancelDelayTestCommand): Promise<ProxyDelayResult>;
  queryMode?(): Promise<CoreRuntimeMode>;
  setMode?(mode: CoreRuntimeMode): Promise<CoreRuntimeMode>;
  stop(): Promise<VpnControllerStopResult>;
}

export function createVpnRpcSocketFailure(code: VpnRpcSocketFailureCode): VpnRpcSocketFailure {
  return new VpnRpcSocketFailure(code);
}

function requireVpnRpcSocketFailureMessage(code: VpnRpcSocketFailureCode): string {
  const message: string | undefined = VPN_RPC_SOCKET_FAILURE_MESSAGES.get(code);
  if (message === undefined) {
    throw new Error('VPN RPC socket failure message was missing.');
  }
  return message;
}

function requireVpnRpcSocketFailureRetryable(code: VpnRpcSocketFailureCode): boolean {
  const retryable: boolean | undefined = VPN_RPC_SOCKET_FAILURE_RETRYABLE.get(code);
  if (retryable === undefined) {
    throw new Error('VPN RPC socket failure retryable flag was missing.');
  }
  return retryable;
}
