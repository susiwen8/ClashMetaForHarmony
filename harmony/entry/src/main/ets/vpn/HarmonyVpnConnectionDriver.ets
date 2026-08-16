import {
  createTunHandle,
  createVpnFailure,
  VpnPlatformPortError,
  type TunHandle,
  type VpnCaptureConfig,
  type VpnPlatformSessionPort
} from '@cmfa/shared';
import {
  PlatformVpnConfigRecord,
  PlatformVpnLinkAddressRecord,
  PlatformVpnNetAddressRecord,
  PlatformVpnRouteInfoRecord
} from './VpnConnectionApi';
import type {
  PlatformVpnConfig,
  PlatformVpnConnection,
  PlatformVpnLinkAddress,
  PlatformVpnNetAddress,
  PlatformVpnRouteInfo,
  VpnConnectionApi
} from './VpnConnectionApi';

const API20: number = 20;
const API22: number = 22;
const IPV4_FAMILY: number = 1;
const IPV6_FAMILY: number = 2;
const IPV4_FULL_CAPTURE_ADDRESS: string = '10.111.222.1/30';
const IPV6_FULL_CAPTURE_ADDRESS: string = 'fd00:111:222::1/126';
const IPV4_DEFAULT_ROUTE: string = '0.0.0.0/0';
const IPV6_DEFAULT_ROUTE: string = '::/0';
const IPV4_DNS: string = '10.111.222.2';
const IPV6_DNS: string = 'fd00:111:222::2';
const SELF_PACKAGE_NAME: string = 'com.github.kr328.clash.harmony';

interface ParsedCidr {
  address: string;
  prefixLength: number;
  family: number;
}

interface LiveHandle {
  sessionId: string;
  vpnId: string;
  connection: PlatformVpnConnection;
}

interface PreparedOwner {
  sessionId: string;
  connection: PlatformVpnConnection;
  processProtected: boolean;
  createInFlight: boolean;
}

class ParsedCidrRecord implements ParsedCidr {
  readonly address: string;
  readonly prefixLength: number;
  readonly family: number;

  constructor(address: string, prefixLength: number, family: number) {
    this.address = address;
    this.prefixLength = prefixLength;
    this.family = family;
  }
}

class LiveHandleRecord implements LiveHandle {
  readonly sessionId: string;
  readonly vpnId: string;
  readonly connection: PlatformVpnConnection;

  constructor(sessionId: string, vpnId: string, connection: PlatformVpnConnection) {
    this.sessionId = sessionId;
    this.vpnId = vpnId;
    this.connection = connection;
  }
}

class PreparedOwnerRecord implements PreparedOwner {
  readonly sessionId: string;
  readonly connection: PlatformVpnConnection;
  processProtected: boolean = false;
  createInFlight: boolean = false;

  constructor(sessionId: string, connection: PlatformVpnConnection) {
    this.sessionId = sessionId;
    this.connection = connection;
  }
}

function vpnFailureDetail(code: string, detail: string): string {
  return createVpnFailure(code, detail).detail;
}

function isPositiveSafeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function normalizeSessionId(sessionId: string): string {
  if (sessionId.trim().length === 0) {
    throw new Error('Vpn connection driver requires a non-empty session id.');
  }
  return sessionId;
}

function splitCidr(value: string): ParsedCidr {
  const separatorIndex: number = value.lastIndexOf('/');
  if (separatorIndex <= 0 || separatorIndex >= value.length - 1) {
    throw new VpnPlatformPortError(
      'PLATFORM_CREATE_FAILED',
      vpnFailureDetail('VPN_CONFIG_INVALID', 'HarmonyOS VPN CIDR translation failed.')
    );
  }
  const address: string = value.slice(0, separatorIndex);
  const prefixLength: number = Number(value.slice(separatorIndex + 1));
  const family: number = address.includes(':') ? IPV6_FAMILY : IPV4_FAMILY;
  if (!Number.isInteger(prefixLength) || prefixLength < 0) {
    throw new VpnPlatformPortError(
      'PLATFORM_CREATE_FAILED',
      vpnFailureDetail('VPN_CONFIG_INVALID', 'HarmonyOS VPN CIDR translation failed.')
    );
  }
  return new ParsedCidrRecord(address, prefixLength, family);
}

function createNetAddress(address: string, family: number): PlatformVpnNetAddress {
  return new PlatformVpnNetAddressRecord(address, family);
}

function createLinkAddress(value: string): PlatformVpnLinkAddress {
  const parsed: ParsedCidr = splitCidr(value);
  return new PlatformVpnLinkAddressRecord(
    createNetAddress(parsed.address, parsed.family),
    parsed.prefixLength
  );
}

function createRoute(value: string): PlatformVpnRouteInfo {
  const parsed: ParsedCidr = splitCidr(value);
  const gatewayAddress: string = parsed.family === IPV6_FAMILY ? '::' : '0.0.0.0';
  return new PlatformVpnRouteInfoRecord(
    '',
    new PlatformVpnLinkAddressRecord(
      createNetAddress(parsed.address, parsed.family),
      parsed.prefixLength
    ),
    createNetAddress(gatewayAddress, parsed.family),
    false,
    true
  );
}

function createPlatformVpnConfig(vpnId: string): PlatformVpnConfig {
  const addresses: PlatformVpnLinkAddress[] = [
    createLinkAddress(IPV4_FULL_CAPTURE_ADDRESS),
    createLinkAddress(IPV6_FULL_CAPTURE_ADDRESS)
  ];
  const routes: PlatformVpnRouteInfo[] = [
    createRoute(IPV4_DEFAULT_ROUTE),
    createRoute(IPV6_DEFAULT_ROUTE)
  ];
  return new PlatformVpnConfigRecord(
    vpnId,
    addresses,
    routes,
    [IPV4_DNS, IPV6_DNS],
    undefined,
    1500,
    true,
    true,
    undefined,
    false,
    undefined,
    [SELF_PACKAGE_NAME]
  );
}

export class HarmonyVpnConnectionDriver implements VpnPlatformSessionPort {
  private readonly api: VpnConnectionApi;
  private readonly sessionId: string;
  private pendingOwner?: PreparedOwner;
  private preparePromise?: Promise<PreparedOwner>;
  private liveHandle?: LiveHandle;

  constructor(api: VpnConnectionApi, sessionId: string) {
    this.api = api;
    this.sessionId = normalizeSessionId(sessionId);
  }

  async protectProcess(): Promise<void> {
    if (this.liveHandle !== undefined) {
      return;
    }
    await this.ensurePreparedOwner();
  }

  async create(config: VpnCaptureConfig): Promise<TunHandle> {
    this.assertExactCaptureConfig(config);
    if (this.liveHandle !== undefined) {
      throw new Error('Vpn connection driver already owns a live handle.');
    }

    const owner: PreparedOwner = await this.ensurePreparedOwner();
    if (owner.createInFlight) {
      throw new Error('Vpn connection driver is already creating a live handle.');
    }
    owner.createInFlight = true;

    let generatedVpnId: string | undefined = undefined;
    try {
      generatedVpnId = await this.generateVpnIdInternal(owner.connection);
      const fd: number = await this.createTunFdInternal(owner.connection, generatedVpnId);
      if (!isPositiveSafeInteger(fd)) {
        throw new VpnPlatformPortError(
          'PLATFORM_CREATE_FAILED',
          vpnFailureDetail(
            'VPN_TUN_FD_INVALID',
            'HarmonyOS VPN returned an invalid Tun file descriptor.'
          )
        );
      }

      this.liveHandle = new LiveHandleRecord(this.sessionId, generatedVpnId, owner.connection);
      this.pendingOwner = undefined;
      owner.createInFlight = false;
      return createTunHandle(fd, generatedVpnId, this.sessionId);
    } catch (error) {
      const primaryError: Error = error as Error;
      try {
        await this.cleanupCreateFailure(owner.connection, generatedVpnId);
      } finally {
        owner.createInFlight = false;
        if (this.pendingOwner === owner) {
          this.pendingOwner = undefined;
        }
      }
      throw primaryError;
    }
  }

  async protectSocket(fd: number): Promise<void> {
    const liveHandle: LiveHandle = this.requireLiveHandle();
    if (!isPositiveSafeInteger(fd)) {
      throw new VpnPlatformPortError(
        'PROTECT_SOCKET_FAILED',
        vpnFailureDetail(
          'VPN_SOCKET_PROTECT_FAILED',
          'HarmonyOS socket protection requires a positive safe file descriptor.'
        )
      );
    }
    if (this.api.sdkApiVersion() < API22) {
      try {
        await liveHandle.connection.protect(fd);
      } catch (_) {
        throw new VpnPlatformPortError(
          'PROTECT_SOCKET_FAILED',
          vpnFailureDetail('VPN_SOCKET_PROTECT_FAILED', 'HarmonyOS socket protection failed.')
        );
      }
    }
  }

  async destroy(vpnId: string): Promise<void> {
    const liveHandle: LiveHandle | undefined = this.liveHandle;
    if (liveHandle === undefined) {
      return;
    }
    if (liveHandle.vpnId !== vpnId) {
      throw new Error(`Vpn connection driver refuses to destroy non-owner vpn ${vpnId}.`);
    }

    try {
      await liveHandle.connection.destroyWithVpnId(vpnId);
      this.liveHandle = undefined;
    } catch (_) {
      throw new Error(vpnFailureDetail('VPN_STOP_FAILED', 'HarmonyOS VPN destroy failed.'));
    }
  }

  private requireLiveHandle(): LiveHandle {
    if (this.liveHandle === undefined) {
      throw new Error('Vpn connection driver requires a live handle.');
    }
    return this.liveHandle;
  }

  private assertExactCaptureConfig(config: VpnCaptureConfig): void {
    if (
      config.addresses.length !== 2 ||
      config.addresses[0] !== IPV4_FULL_CAPTURE_ADDRESS ||
      config.addresses[1] !== IPV6_FULL_CAPTURE_ADDRESS
    ) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail(
          'VPN_CONFIG_INVALID',
          'HarmonyOS VPN addresses drifted from the exact full-capture policy.'
        )
      );
    }
    if (
      config.routes.length !== 2 ||
      config.routes[0] !== IPV4_DEFAULT_ROUTE ||
      config.routes[1] !== IPV6_DEFAULT_ROUTE
    ) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail(
          'VPN_CONFIG_INVALID',
          'HarmonyOS VPN routes drifted from the exact full-capture policy.'
        )
      );
    }
    if (
      config.dnsServers.length !== 2 ||
      config.dnsServers[0] !== IPV4_DNS ||
      config.dnsServers[1] !== IPV6_DNS
    ) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail(
          'VPN_CONFIG_INVALID',
          'HarmonyOS VPN dns drifted from the exact full-capture policy.'
        )
      );
    }
    if (config.mtu !== 1500 || !config.ipv4 || !config.ipv6 || config.isBlocking) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail(
          'VPN_CONFIG_INVALID',
          'HarmonyOS VPN flags drifted from the exact full-capture policy.'
        )
      );
    }
    if (
      config.trustedApplications.length !== 0 ||
      config.blockedApplications.length !== 1 ||
      config.blockedApplications[0] !== SELF_PACKAGE_NAME
    ) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail(
          'VPN_CONFIG_INVALID',
          'HarmonyOS VPN application lists drifted from the exact full-capture policy.'
        )
      );
    }
  }

  private async ensurePreparedOwner(): Promise<PreparedOwner> {
    if (this.liveHandle !== undefined) {
      return new PreparedOwnerRecord(this.liveHandle.sessionId, this.liveHandle.connection);
    }
    if (this.pendingOwner !== undefined && this.preparePromise === undefined) {
      return this.pendingOwner;
    }
    if (this.preparePromise !== undefined) {
      return await this.preparePromise;
    }

    let connection: PlatformVpnConnection;
    try {
      connection = this.api.createConnection();
    } catch (_) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS VPN connection creation failed.')
      );
    }

    const owner: PreparedOwner = new PreparedOwnerRecord(this.sessionId, connection);
    this.pendingOwner = owner;
    this.preparePromise = this.finishPreparingOwner(owner);
    try {
      return await this.preparePromise;
    } finally {
      this.preparePromise = undefined;
    }
  }

  private async finishPreparingOwner(owner: PreparedOwner): Promise<PreparedOwner> {
    try {
      if (this.api.sdkApiVersion() >= API22) {
        if (!owner.processProtected) {
          await this.protectProcessInternal(owner.connection);
          owner.processProtected = true;
        }
      }
      return owner;
    } catch (error) {
      this.pendingOwner = undefined;
      await this.cleanupCreateFailure(owner.connection);
      throw error as Error;
    }
  }

  private async protectProcessInternal(connection: PlatformVpnConnection): Promise<void> {
    try {
      await connection.protectProcessNet();
    } catch (_) {
      throw new VpnPlatformPortError(
        'PROCESS_PROTECT_FAILED',
        vpnFailureDetail('VPN_SOCKET_PROTECT_FAILED', 'HarmonyOS process protection failed.')
      );
    }
  }

  private async generateVpnIdInternal(connection: PlatformVpnConnection): Promise<string> {
    if (this.api.sdkApiVersion() < API20) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS VPN id generation requires API 20+.')
      );
    }
    try {
      return await connection.generateVpnId();
    } catch (_) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS vpn id generation failed.')
      );
    }
  }

  private async createTunFdInternal(
    connection: PlatformVpnConnection,
    vpnId: string
  ): Promise<number> {
    try {
      return await connection.create(createPlatformVpnConfig(vpnId));
    } catch (error) {
      if (isBusinessErrorWithCode(error, 2203001)) {
        throw new VpnPlatformPortError(
          'CONSENT_DENIED',
          vpnFailureDetail('VPN_PERMISSION_DENIED', 'HarmonyOS VPN consent was denied.')
        );
      }
      if (isBusinessErrorWithCode(error, 2203002)) {
        throw new VpnPlatformPortError(
          'ALREADY_ACTIVE',
          vpnFailureDetail('VPN_ALREADY_ACTIVE', 'HarmonyOS VPN session is already active.')
        );
      }
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS vpn create failed.')
      );
    }
  }

  private async cleanupCreateFailure(
    connection: PlatformVpnConnection,
    vpnId?: string
  ): Promise<void> {
    try {
      if (vpnId !== undefined) {
        await connection.destroyWithVpnId(vpnId);
        return;
      }
      await connection.destroy();
    } catch (_) {
    }
  }
}

interface BusinessErrorShape {
  code?: number;
}

function isBusinessErrorWithCode(error: Object | undefined, code: number): boolean {
  const record: BusinessErrorShape = error as BusinessErrorShape;
  return record.code === code;
}
