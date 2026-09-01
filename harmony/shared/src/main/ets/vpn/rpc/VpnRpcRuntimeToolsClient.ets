import type { CoreRuntimeMode } from '../../core/CoreModels';
import type { VpnRpcClientContext } from '../VpnPorts';
import type { VpnRpcClientPort } from './VpnRpcClient';
import type { VpnRpcBody } from './VpnRpcModels';
import {
  cloneVpnRpcRuntimeModePayload,
  createVpnRpcEmptyPayload,
  createVpnRpcRuntimeModePayload,
  type VpnRpcRuntimeModePayload
} from './VpnRpcPayloads';

export interface VpnRpcRuntimeModeClientPort {
  queryMode(): Promise<CoreRuntimeMode>;
  setMode(mode: CoreRuntimeMode): Promise<CoreRuntimeMode>;
}
export class VpnRpcRuntimeToolsClient implements VpnRpcRuntimeModeClientPort {
  private readonly client: VpnRpcClientPort;

  constructor(client: VpnRpcClientPort) {
    this.client = client;
  }

  async queryMode(): Promise<CoreRuntimeMode> {
    const context: VpnRpcClientContext = await this.requireContext();
    const response: VpnRpcBody = await this.client.request(
      'GET_MODE',
      context.guards,
      context.sessionGeneration,
      createVpnRpcEmptyPayload()
    );
    return this.requireMode(response, 'GET_MODE');
  }

  async setMode(mode: CoreRuntimeMode): Promise<CoreRuntimeMode> {
    const context: VpnRpcClientContext = await this.requireContext();
    const response: VpnRpcBody = await this.client.request(
      'SET_MODE',
      context.guards,
      context.sessionGeneration,
      createVpnRpcRuntimeModePayload(mode)
    );
    return this.requireMode(response, 'SET_MODE');
  }

  private async requireContext(): Promise<VpnRpcClientContext> {
    await this.client.connect();
    const context: VpnRpcClientContext | null = this.client.activeContext();
    if (context === null || context.sessionGeneration <= 0) {
      throw new Error('VPN runtime mode is unavailable.');
    }
    return context;
  }

  private requireMode(response: VpnRpcBody, method: 'GET_MODE' | 'SET_MODE'): CoreRuntimeMode {
    if (response.method !== method || response.ok !== true) {
      throw new Error('VPN runtime mode operation failed.');
    }
    const payload: VpnRpcRuntimeModePayload = cloneVpnRpcRuntimeModePayload(
      response.payload as VpnRpcRuntimeModePayload
    );
    return payload.mode;
  }
}
