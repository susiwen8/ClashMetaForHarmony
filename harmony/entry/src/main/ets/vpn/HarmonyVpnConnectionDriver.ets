import {
  createTunHandle,
  createVpnFailure,
  OwnershipStoreCorruptError,
  VpnPlatformPortError,
  type TunHandle,
  type VpnCaptureConfig,
  type VpnPlatformOwnershipPhase,
  type VpnPlatformOwnershipRecord,
  type VpnPlatformOwnershipStorePort,
  type VpnPlatformSessionPort
} from '@cmfa/shared';
import {
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
const DESTROY_ALREADY_RELEASED_ERROR_CODE: number = 19900001;

interface ParsedCidr {
  address: string;
  prefixLength: number;
  family: number;
}

interface LiveHandle {
  sessionId: string;
  vpnId: string;
  connection: PlatformVpnConnection;
  platformDestroyed: boolean;
  persistedPhase: VpnPlatformOwnershipPhase;
}

interface PreparedOwner {
  sessionId: string;
  vpnId: string;
  connection: PlatformVpnConnection;
  storeWasEmpty: boolean;
  persistedPhase: VpnPlatformOwnershipPhase;
  processProtected: boolean;
  createInFlight: boolean;
  platformDestroyed: boolean;
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
  platformDestroyed: boolean;
  persistedPhase: VpnPlatformOwnershipPhase;

  constructor(
    sessionId: string,
    vpnId: string,
    connection: PlatformVpnConnection,
    platformDestroyed: boolean,
    persistedPhase: VpnPlatformOwnershipPhase
  ) {
    this.sessionId = sessionId;
    this.vpnId = vpnId;
    this.connection = connection;
    this.platformDestroyed = platformDestroyed;
    this.persistedPhase = persistedPhase;
  }
}

class PreparedOwnerRecord implements PreparedOwner {
  readonly sessionId: string;
  vpnId: string = '';
  connection: PlatformVpnConnection;
  storeWasEmpty: boolean = true;
  persistedPhase: VpnPlatformOwnershipPhase = 'PREPARED';
  processProtected: boolean = false;
  createInFlight: boolean = false;
  platformDestroyed: boolean = false;

  constructor(sessionId: string, connection: PlatformVpnConnection) {
    this.sessionId = sessionId;
    this.connection = connection;
  }
}

function vpnFailureDetail(code: string, detail: string): string {
  return createVpnFailure(code, detail).detail;
}

class OwnershipRecord implements VpnPlatformOwnershipRecord {
  readonly phase: VpnPlatformOwnershipPhase;
  readonly vpnId: string;

  constructor(phase: VpnPlatformOwnershipPhase, vpnId: string) {
    this.phase = phase;
    this.vpnId = vpnId;
  }
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

function createOwnershipRecord(phase: VpnPlatformOwnershipPhase, vpnId: string): VpnPlatformOwnershipRecord {
  return new OwnershipRecord(phase, vpnId);
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
  const platformConfig: PlatformVpnConfig = {
    vpnId,
    addresses,
    routes,
    dnsAddresses: [IPV4_DNS, IPV6_DNS],
    mtu: 1500,
    isIPv4Accepted: true,
    isIPv6Accepted: true,
    isBlocking: false,
    trustedApplications: [],
    blockedApplications: [SELF_PACKAGE_NAME]
  };
  return platformConfig;
}

export class HarmonyVpnConnectionDriver implements VpnPlatformSessionPort {
  private readonly api: VpnConnectionApi;
  private readonly sessionId: string;
  private readonly store: VpnPlatformOwnershipStorePort;
  private readonly reportStageLifecycle?: (stage: string) => void;
  private pendingOwner?: PreparedOwner;
  private preparePromise?: Promise<PreparedOwner>;
  private liveHandle?: LiveHandle;

  constructor(
    api: VpnConnectionApi,
    sessionId: string,
    store: VpnPlatformOwnershipStorePort,
    reportStageLifecycle?: (stage: string) => void
  ) {
    this.api = api;
    this.sessionId = normalizeSessionId(sessionId);
    this.store = store;
    this.reportStageLifecycle = reportStageLifecycle;
  }

  async protectProcess(): Promise<void> {
    if (this.liveHandle !== undefined) {
      return;
    }
    await this.ensurePreparedOwner();
  }

  async create(config: VpnCaptureConfig): Promise<TunHandle> {
    this.reportStage('platform.config.begin');
    try {
      this.assertExactCaptureConfig(config);
      this.reportStage('platform.config.ok');
    } catch (error) {
      this.reportStage('platform.config.failed');
      throw error as Error;
    }
    if (this.liveHandle !== undefined) {
      throw new Error('Vpn connection driver already owns a live handle.');
    }

    const owner: PreparedOwner = await this.ensurePreparedOwner();
    if (owner.createInFlight) {
      throw new Error('Vpn connection driver is already creating a live handle.');
    }
    owner.createInFlight = true;

    try {
      const fd: number = await this.createTunFdInternal(owner);
      if (!isPositiveSafeInteger(fd)) {
        this.reportStage('platform.fd.failed');
        throw new VpnPlatformPortError(
          'PLATFORM_CREATE_FAILED',
          vpnFailureDetail(
            'VPN_TUN_FD_INVALID',
            'HarmonyOS VPN returned an invalid Tun file descriptor.'
          )
        );
      }
      this.reportStage('platform.fd.ok');

      await this.store.write(createOwnershipRecord('ACTIVE', owner.vpnId));
      owner.persistedPhase = 'ACTIVE';
      this.liveHandle = new LiveHandleRecord(
        this.sessionId,
        owner.vpnId,
        owner.connection,
        false,
        owner.persistedPhase
      );
      this.pendingOwner = undefined;
      owner.createInFlight = false;
      return createTunHandle(fd, owner.vpnId, this.sessionId);
    } catch (error) {
      const primaryError: Error = error as Error;
      try {
        await this.cleanupCreateFailure(owner);
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
      if (!liveHandle.platformDestroyed) {
        await this.destroyStoredPlatformOwner(liveHandle.connection, liveHandle.vpnId);
        liveHandle.platformDestroyed = true;
      }
      if (liveHandle.persistedPhase !== 'RELEASED') {
        await this.store.write(createOwnershipRecord('RELEASED', vpnId));
        liveHandle.persistedPhase = 'RELEASED';
      }
      await this.store.clearExpected(createOwnershipRecord('RELEASED', vpnId));
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
      const persistedOwnership: VpnPlatformOwnershipRecord | null = await this.store.read();
      owner.storeWasEmpty = persistedOwnership === null;
      if (persistedOwnership !== null) {
        await this.recoverPersistedOwner(owner, persistedOwnership);
      }
      owner.vpnId = await this.generateVpnId(owner.connection);
      if (this.api.sdkApiVersion() >= API22) {
        if (!owner.processProtected) {
          await this.protectProcessInternal(owner.connection);
          owner.processProtected = true;
        }
      }
      await this.store.write(createOwnershipRecord('PREPARED', owner.vpnId));
      owner.persistedPhase = 'PREPARED';
      return owner;
    } catch (error) {
      this.pendingOwner = undefined;
      if (!(error instanceof OwnershipStoreCorruptError)) {
        await this.cleanupPreparedOwner(owner);
      }
      throw error as Error;
    }
  }

  private async recoverPersistedOwner(
    owner: PreparedOwner,
    persistedOwnership: VpnPlatformOwnershipRecord
  ): Promise<void> {
    if (persistedOwnership.phase === 'RELEASED') {
      await this.store.clearExpected(createOwnershipRecord('RELEASED', persistedOwnership.vpnId));
      return;
    }
    try {
      await this.destroyStoredPlatformOwner(owner.connection, persistedOwnership.vpnId);
      await this.store.write(createOwnershipRecord('RELEASED', persistedOwnership.vpnId));
      await this.store.clearExpected(createOwnershipRecord('RELEASED', persistedOwnership.vpnId));
    } catch (_) {
      throw new VpnPlatformPortError(
        'ALREADY_ACTIVE',
        vpnFailureDetail('VPN_ALREADY_ACTIVE', 'HarmonyOS VPN session is already active.')
      );
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

  private async generateVpnId(connection: PlatformVpnConnection): Promise<string> {
    try {
      return await connection.generateVpnId();
    } catch (_) {
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS vpn create failed.')
      );
    }
  }

  private async createTunFdInternal(owner: PreparedOwner): Promise<number> {
    const connection: PlatformVpnConnection = owner.connection;
    const platformConfig: PlatformVpnConfig = createPlatformVpnConfig(owner.vpnId);
    this.reportStage('platform.connection.begin');
    try {
      const fd: number = await connection.create(platformConfig);
      this.reportStage('platform.connection.ok');
      return fd;
    } catch (error) {
      if (isBusinessErrorWithCode(error, 2203001)) {
        this.reportStage('platform.connection.consent');
        throw new VpnPlatformPortError(
          'CONSENT_DENIED',
          vpnFailureDetail('VPN_PERMISSION_DENIED', 'HarmonyOS VPN consent was denied.')
        );
      }
      if (isBusinessErrorWithCode(error, 2203002)) {
        this.reportStage('platform.connection.active');
        if (!owner.storeWasEmpty) {
          throw new VpnPlatformPortError(
            'ALREADY_ACTIVE',
            vpnFailureDetail('VPN_ALREADY_ACTIVE', 'HarmonyOS VPN session is already active.')
          );
        }
        return await this.reclaimLegacyVpnAndRetryCreate(owner, platformConfig);
      }
      if (isBusinessErrorWithCode(error, 401)) {
        this.reportStage('platform.connection.parameter');
      } else if (isBusinessErrorWithCode(error, 2200001)) {
        this.reportStage('platform.connection.invalid');
      } else if (isBusinessErrorWithCode(error, 2200002)) {
        this.reportStage('platform.connection.service');
      } else if (isBusinessErrorWithCode(error, 2200003)) {
        this.reportStage('platform.connection.internal');
      } else {
        this.reportStage('platform.connection.failed');
      }
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS vpn create failed.')
      );
    }
  }

  private async reclaimLegacyVpnAndRetryCreate(
    owner: PreparedOwner,
    platformConfig: PlatformVpnConfig
  ): Promise<number> {
    this.reportStage('platform.connection.legacy-reclaim.begin');
    try {
      await owner.connection.destroy();
      this.reportStage('platform.connection.legacy-reclaim.ok');
    } catch (_) {
      this.reportStage('platform.connection.legacy-reclaim.failed');
      throw new VpnPlatformPortError(
        'ALREADY_ACTIVE',
        vpnFailureDetail('VPN_ALREADY_ACTIVE', 'HarmonyOS VPN session is already active.')
      );
    }

    this.reportStage('platform.connection.retry.begin');
    try {
      const retryConnection: PlatformVpnConnection = this.api.createConnection();
      if (this.api.sdkApiVersion() >= API22) {
        await this.protectProcessInternal(retryConnection);
      }
      owner.connection = retryConnection;
      const fd: number = await retryConnection.create(platformConfig);
      this.reportStage('platform.connection.retry.ok');
      return fd;
    } catch (error) {
      if (isBusinessErrorWithCode(error, 2203001)) {
        this.reportStage('platform.connection.retry.consent');
        throw new VpnPlatformPortError(
          'CONSENT_DENIED',
          vpnFailureDetail('VPN_PERMISSION_DENIED', 'HarmonyOS VPN consent was denied.')
        );
      }
      if (isBusinessErrorWithCode(error, 2203002)) {
        this.reportStage('platform.connection.retry.active');
        throw new VpnPlatformPortError(
          'ALREADY_ACTIVE',
          vpnFailureDetail('VPN_ALREADY_ACTIVE', 'HarmonyOS VPN session is already active.')
        );
      }
      if (isBusinessErrorWithCode(error, 401)) {
        this.reportStage('platform.connection.retry.parameter');
      } else if (isBusinessErrorWithCode(error, 2200001)) {
        this.reportStage('platform.connection.retry.invalid');
      } else if (isBusinessErrorWithCode(error, 2200002)) {
        this.reportStage('platform.connection.retry.service');
      } else if (isBusinessErrorWithCode(error, 2200003)) {
        this.reportStage('platform.connection.retry.internal');
      } else {
        this.reportStage('platform.connection.retry.failed');
      }
      throw new VpnPlatformPortError(
        'PLATFORM_CREATE_FAILED',
        vpnFailureDetail('VPN_CREATE_FAILED', 'HarmonyOS vpn create failed.')
      );
    }
  }

  private reportStage(stage: string): void {
    try {
      this.reportStageLifecycle?.(stage);
    } catch (_) {
    }
  }

  private async destroyStoredPlatformOwner(connection: PlatformVpnConnection, vpnId: string): Promise<void> {
    try {
      await connection.destroyWithVpnId(vpnId);
    } catch (error) {
      if (isBusinessErrorWithCode(error, DESTROY_ALREADY_RELEASED_ERROR_CODE)) {
        return;
      }
      throw error as Error;
    }
  }

  private async cleanupPreparedOwner(owner: PreparedOwner): Promise<void> {
    if (owner.vpnId.length === 0) {
      return;
    }
    try {
      if (!owner.platformDestroyed) {
        await this.destroyStoredPlatformOwner(owner.connection, owner.vpnId);
        owner.platformDestroyed = true;
      }
      await this.store.write(createOwnershipRecord('RELEASED', owner.vpnId));
      owner.persistedPhase = 'RELEASED';
      await this.store.clearExpected(createOwnershipRecord('RELEASED', owner.vpnId));
    } catch (_) {
    }
  }

  private async cleanupCreateFailure(owner: PreparedOwner): Promise<void> {
    try {
      if (!owner.platformDestroyed) {
        await this.destroyStoredPlatformOwner(owner.connection, owner.vpnId);
        owner.platformDestroyed = true;
      }
      if (owner.persistedPhase !== 'RELEASED') {
        await this.store.write(createOwnershipRecord('RELEASED', owner.vpnId));
        owner.persistedPhase = 'RELEASED';
      }
      await this.store.clearExpected(createOwnershipRecord('RELEASED', owner.vpnId));
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
