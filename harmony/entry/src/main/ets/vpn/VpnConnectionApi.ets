import { vpnExtension } from '@kit.NetworkKit';
import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';

export interface PlatformVpnNetAddress {
  address: string;
  family?: number;
  port?: number;
}

export interface PlatformVpnLinkAddress {
  address: PlatformVpnNetAddress;
  prefixLength: number;
}

export interface PlatformVpnRouteInfo {
  interface: string;
  destination: PlatformVpnLinkAddress;
  gateway: PlatformVpnNetAddress;
  hasGateway: boolean;
  isDefaultRoute: boolean;
  isExcludedRoute?: boolean;
}

export interface PlatformVpnConfig {
  vpnId?: string;
  addresses: PlatformVpnLinkAddress[];
  routes?: PlatformVpnRouteInfo[];
  dnsAddresses?: string[];
  searchDomains?: string[];
  mtu?: number;
  isIPv4Accepted?: boolean;
  isIPv6Accepted?: boolean;
  isInternal?: boolean;
  isBlocking?: boolean;
  trustedApplications?: string[];
  blockedApplications?: string[];
}

export class PlatformVpnNetAddressRecord implements PlatformVpnNetAddress {
  readonly address: string;
  readonly family?: number;
  readonly port?: number;

  constructor(address: string, family?: number, port?: number) {
    this.address = address;
    this.family = family;
    this.port = port;
  }
}

export class PlatformVpnLinkAddressRecord implements PlatformVpnLinkAddress {
  readonly address: PlatformVpnNetAddress;
  readonly prefixLength: number;

  constructor(address: PlatformVpnNetAddress, prefixLength: number) {
    this.address = address;
    this.prefixLength = prefixLength;
  }
}

export class PlatformVpnRouteInfoRecord implements PlatformVpnRouteInfo {
  readonly interface: string;
  readonly destination: PlatformVpnLinkAddress;
  readonly gateway: PlatformVpnNetAddress;
  readonly hasGateway: boolean;
  readonly isDefaultRoute: boolean;
  readonly isExcludedRoute?: boolean;

  constructor(
    interfaceName: string,
    destination: PlatformVpnLinkAddress,
    gateway: PlatformVpnNetAddress,
    hasGateway: boolean,
    isDefaultRoute: boolean,
    isExcludedRoute?: boolean
  ) {
    this.interface = interfaceName;
    this.destination = destination;
    this.gateway = gateway;
    this.hasGateway = hasGateway;
    this.isDefaultRoute = isDefaultRoute;
    this.isExcludedRoute = isExcludedRoute;
  }
}

export class PlatformVpnConfigRecord implements PlatformVpnConfig {
  readonly vpnId?: string;
  readonly addresses: PlatformVpnLinkAddress[];
  readonly routes?: PlatformVpnRouteInfo[];
  readonly dnsAddresses?: string[];
  readonly searchDomains?: string[];
  readonly mtu?: number;
  readonly isIPv4Accepted?: boolean;
  readonly isIPv6Accepted?: boolean;
  readonly isInternal?: boolean;
  readonly isBlocking?: boolean;
  readonly trustedApplications?: string[];
  readonly blockedApplications?: string[];

  constructor(
    vpnId: string | undefined,
    addresses: PlatformVpnLinkAddress[],
    routes?: PlatformVpnRouteInfo[],
    dnsAddresses?: string[],
    searchDomains?: string[],
    mtu?: number,
    isIPv4Accepted?: boolean,
    isIPv6Accepted?: boolean,
    isInternal?: boolean,
    isBlocking?: boolean,
    trustedApplications?: string[],
    blockedApplications?: string[]
  ) {
    this.vpnId = vpnId;
    this.addresses = addresses;
    this.routes = routes;
    this.dnsAddresses = dnsAddresses;
    this.searchDomains = searchDomains;
    this.mtu = mtu;
    this.isIPv4Accepted = isIPv4Accepted;
    this.isIPv6Accepted = isIPv6Accepted;
    this.isInternal = isInternal;
    this.isBlocking = isBlocking;
    this.trustedApplications = trustedApplications;
    this.blockedApplications = blockedApplications;
  }
}

export interface PlatformVpnConnection {
  create(config: PlatformVpnConfig): Promise<number>;
  generateVpnId(): Promise<string>;
  protect(socketFd: number): Promise<void>;
  destroy(): Promise<void>;
  destroyWithVpnId(vpnId: string): Promise<void>;
  protectProcessNet(): Promise<void>;
}

export interface VpnConnectionApi {
  sdkApiVersion(): number;
  createConnection(): PlatformVpnConnection;
}

export type SdkApiVersionResolver = (context: common.VpnExtensionContext) => number;

class SystemPlatformVpnConnection implements PlatformVpnConnection {
  private readonly connection: vpnExtension.VpnConnection;

  constructor(connection: vpnExtension.VpnConnection) {
    this.connection = connection;
  }

  async create(config: PlatformVpnConfig): Promise<number> {
    return await this.connection.create(config as vpnExtension.VpnConfig);
  }

  async generateVpnId(): Promise<string> {
    return await this.connection.generateVpnId();
  }

  async protect(socketFd: number): Promise<void> {
    await this.connection.protect(socketFd);
  }

  async destroy(): Promise<void> {
    await this.connection.destroy();
  }

  async destroyWithVpnId(vpnId: string): Promise<void> {
    await this.connection.destroy(vpnId);
  }

  async protectProcessNet(): Promise<void> {
    await this.connection.protectProcessNet();
  }
}

function defaultSdkApiVersionResolver(context: common.VpnExtensionContext): number {
  void context;
  return deviceInfo.sdkApiVersion;
}

export class HarmonyVpnConnectionApi implements VpnConnectionApi {
  private readonly context: common.VpnExtensionContext;
  private readonly resolveSdkApiVersion: SdkApiVersionResolver;

  constructor(context: common.VpnExtensionContext, resolveSdkApiVersion: SdkApiVersionResolver) {
    this.context = context;
    this.resolveSdkApiVersion = resolveSdkApiVersion;
  }

  sdkApiVersion(): number {
    return this.resolveSdkApiVersion(this.context);
  }

  createConnection(): PlatformVpnConnection {
    return new SystemPlatformVpnConnection(vpnExtension.createVpnConnection(this.context));
  }
}

export { defaultSdkApiVersionResolver };
