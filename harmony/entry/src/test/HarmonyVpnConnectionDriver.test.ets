import { describe, expect, it } from '@ohos/hypium';
import {
  createVpnCaptureConfig,
  OwnershipStoreCorruptError,
  VpnPlatformPortError,
  type VpnCaptureConfig,
  type VpnPlatformOwnershipBinding,
  type VpnPlatformOwnershipPhase,
  type VpnPlatformOwnershipRecord,
  type VpnPlatformOwnershipStorePort
} from '@cmfa/shared';
import { HarmonyVpnConnectionDriver } from '../main/ets/vpn/HarmonyVpnConnectionDriver';
import type {
  PlatformVpnConfig,
  PlatformVpnConnection,
  VpnConnectionApi
} from '../main/ets/vpn/VpnConnectionApi';

type TestOwnershipBinding = 'PLATFORM_ID' | 'LEGACY_GLOBAL' | 'MISSING';

class FakeBusinessError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

function requireFakeError(error: Error | FakeBusinessError | undefined): Error {
  if (error === undefined) {
    return new Error('Expected fake error.');
  }
  return error;
}

class FakePlatformVpnConnection implements PlatformVpnConnection {
  readonly log: string[] = [];
  readonly createConfigs: PlatformVpnConfig[] = [];
  createFd: number = 41;
  generatedVpnId: string = 'vpn-generated-1';
  createError?: Error | FakeBusinessError;
  generateVpnIdError?: Error | FakeBusinessError;
  protectProcessError?: Error | FakeBusinessError;
  protectError?: Error | FakeBusinessError;
  destroyError?: Error | FakeBusinessError;
  destroyWithVpnIdError?: Error | FakeBusinessError;

  async create(config: PlatformVpnConfig): Promise<number> {
    this.log.push('create');
    this.createConfigs.push(config);
    if (this.createError !== undefined) {
      throw requireFakeError(this.createError);
    }
    return this.createFd;
  }

  async generateVpnId(): Promise<string> {
    this.log.push('generateVpnId');
    if (this.generateVpnIdError !== undefined) {
      throw requireFakeError(this.generateVpnIdError);
    }
    return this.generatedVpnId;
  }

  async protect(socketFd: number): Promise<void> {
    this.log.push(`protect:${socketFd}`);
    if (this.protectError !== undefined) {
      throw requireFakeError(this.protectError);
    }
  }

  async destroy(): Promise<void> {
    this.log.push('destroy');
    if (this.destroyError !== undefined) {
      throw requireFakeError(this.destroyError);
    }
  }

  async destroyWithVpnId(vpnId: string): Promise<void> {
    this.log.push(`destroyWithVpnId:${vpnId}`);
    if (this.destroyWithVpnIdError !== undefined) {
      throw requireFakeError(this.destroyWithVpnIdError);
    }
  }

  async protectProcessNet(): Promise<void> {
    this.log.push('protectProcessNet');
    if (this.protectProcessError !== undefined) {
      throw requireFakeError(this.protectProcessError);
    }
  }
}

class FakeVpnConnectionApi implements VpnConnectionApi {
  readonly connection: FakePlatformVpnConnection;
  replacementConnection?: FakePlatformVpnConnection;
  readonly sdkApiVersionValue: number;
  createConnectionCalls: number = 0;

  constructor(sdkApiVersionValue: number, connection?: FakePlatformVpnConnection) {
    this.sdkApiVersionValue = sdkApiVersionValue;
    this.connection = connection ?? new FakePlatformVpnConnection();
  }

  sdkApiVersion(): number {
    return this.sdkApiVersionValue;
  }

  createConnection(): PlatformVpnConnection {
    this.createConnectionCalls += 1;
    if (this.createConnectionCalls > 1 && this.replacementConnection !== undefined) {
      return this.replacementConnection;
    }
    return this.connection;
  }
}

class FakeOwnershipStore implements VpnPlatformOwnershipStorePort {
  readonly log: string[] = [];
  readValue: VpnPlatformOwnershipRecord | null = null;
  readError?: Object;
  writeError?: Object;
  failWritePhase?: VpnPlatformOwnershipPhase;
  failWriteError?: Object;
  clearError?: Object;

  async read(): Promise<VpnPlatformOwnershipRecord | null> {
    this.log.push('read');
    if (this.readError !== undefined) {
      throw this.readError as Error;
    }
    return this.readValue;
  }

  async write(ownership: VpnPlatformOwnershipRecord): Promise<void> {
    this.log.push(`write:${ownership.phase}:${ownership.vpnId}:${readOwnershipBinding(ownership)}`);
    if (this.failWritePhase === ownership.phase) {
      throw (this.failWriteError ?? new Error(`write failed for ${ownership.phase}`)) as Error;
    }
    if (this.writeError !== undefined) {
      throw this.writeError as Error;
    }
    this.readValue = createOwnership(ownership.phase, ownership.vpnId, readOwnershipBinding(ownership));
  }

  async clearExpected(ownership: VpnPlatformOwnershipRecord): Promise<void> {
    this.log.push(`clearExpected:${ownership.phase}:${ownership.vpnId}:${readOwnershipBinding(ownership)}`);
    if (this.clearError !== undefined) {
      throw this.clearError as Error;
    }
    if (
      this.readValue?.phase === ownership.phase &&
      this.readValue.vpnId === ownership.vpnId &&
      readOwnershipBinding(this.readValue) === readOwnershipBinding(ownership)
    ) {
      this.readValue = null;
    }
  }
}

class OwnershipRecord implements VpnPlatformOwnershipRecord {
  readonly phase: VpnPlatformOwnershipPhase;
  readonly vpnId: string;
  readonly binding: VpnPlatformOwnershipBinding;

  constructor(phase: VpnPlatformOwnershipPhase, vpnId: string, binding: VpnPlatformOwnershipBinding) {
    this.phase = phase;
    this.vpnId = vpnId;
    this.binding = binding;
  }
}

function readOwnershipBinding(ownership: VpnPlatformOwnershipRecord | null | undefined): TestOwnershipBinding {
  if (ownership === null || ownership === undefined) {
    return 'MISSING';
  }
  const bindingValue: Object | undefined = (ownership as Object as Record<string, Object>).binding;
  if (typeof bindingValue === 'string' && (bindingValue === 'PLATFORM_ID' || bindingValue === 'LEGACY_GLOBAL')) {
    return bindingValue;
  }
  return 'MISSING';
}

function createOwnership(
  phase: VpnPlatformOwnershipPhase,
  vpnId: string,
  binding: TestOwnershipBinding = 'LEGACY_GLOBAL'
): VpnPlatformOwnershipRecord {
  if (binding === 'MISSING') {
    throw new Error('Test ownership binding must be persisted as a concrete binding.');
  }
  return new OwnershipRecord(phase, vpnId, binding);
}

function buildExactCaptureConfig(): VpnCaptureConfig {
  return createVpnCaptureConfig({
    addresses: ['10.111.222.1/30', 'fd00:111:222::1/126'],
    routes: ['0.0.0.0/0', '::/0'],
    dnsServers: ['10.111.222.2', 'fd00:111:222::2'],
    mtu: 1500,
    ipv4: true,
    ipv6: true,
    isBlocking: false,
    blockedApplications: ['com.github.kr328.clash.harmony'],
    trustedApplications: []
  });
}

function createDriver(
  api: VpnConnectionApi,
  sessionId: string,
  store?: VpnPlatformOwnershipStorePort,
  reportStageLifecycle?: (stage: string) => void
): HarmonyVpnConnectionDriver {
  return new HarmonyVpnConnectionDriver(api, sessionId, store ?? new FakeOwnershipStore(), reportStageLifecycle);
}

async function expectRejects<T>(action: () => Promise<T>): Promise<Error> {
  try {
    await action();
    expect().assertFail();
  } catch (error) {
    return error as Error;
  }
  return new Error('expected rejection');
}

function expectPortErrorCode(error: Error, code: string): void {
  if (!(error instanceof VpnPlatformPortError)) {
    expect().assertFail();
  }
  expect((error as VpnPlatformPortError).code).assertEqual(code);
}

function assertExactConfig(config: PlatformVpnConfig): void {
  expect(config.vpnId === undefined).assertTrue();
  expect(config.addresses.length).assertEqual(2);
  expect(config.addresses[0].address.address).assertEqual('10.111.222.1');
  expect(config.addresses[0].address.family).assertEqual(1);
  expect(config.addresses[0].prefixLength).assertEqual(30);
  expect(config.addresses[1].address.address).assertEqual('fd00:111:222::1');
  expect(config.addresses[1].address.family).assertEqual(2);
  expect(config.addresses[1].prefixLength).assertEqual(126);
  expect(config.routes?.length ?? 0).assertEqual(2);
  expect(config.routes?.[0].destination.address.address ?? '').assertEqual('0.0.0.0');
  expect(config.routes?.[0].destination.address.family ?? 0).assertEqual(1);
  expect(config.routes?.[0].destination.prefixLength ?? 0).assertEqual(0);
  expect(config.routes?.[0].hasGateway ?? true).assertFalse();
  expect(config.routes?.[0].isDefaultRoute ?? false).assertTrue();
  expect(config.routes?.[1].destination.address.address ?? '').assertEqual('::');
  expect(config.routes?.[1].destination.address.family ?? 0).assertEqual(2);
  expect(config.routes?.[1].destination.prefixLength ?? 1).assertEqual(0);
  expect(config.routes?.[1].hasGateway ?? true).assertFalse();
  expect(config.routes?.[1].isDefaultRoute ?? false).assertTrue();
  expect(config.dnsAddresses?.join(',') ?? '').assertEqual('10.111.222.2,fd00:111:222::2');
  expect(config.mtu ?? 0).assertEqual(1500);
  expect(config.isIPv4Accepted ?? false).assertTrue();
  expect(config.isIPv6Accepted ?? false).assertTrue();
  expect(config.isBlocking ?? true).assertFalse();
  expect((config.trustedApplications?.length ?? 0) === 0).assertTrue();
  expect(config.blockedApplications?.join(',') ?? '').assertEqual('com.github.kr328.clash.harmony');
}

export default function harmonyVpnConnectionDriverTestsuite() {
  describe('HarmonyVpnConnectionDriverTest', () => {
    it('recoversStoredPlatformOwnerThenCreatesLegacyGlobalCaptureWithoutPlatformVpnId', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('ACTIVE', 'vpn-stale-1', 'PLATFORM_ID');
      const driver = createDriver(api, 'session-config', store);

      const handle = await driver.create(buildExactCaptureConfig());

      expect(handle.fd).assertEqual(41);
      expect(handle.vpnId).assertEqual('vpn-generated-1');
      expect(handle.sessionId).assertEqual('session-config');
      expect(handle.vpnId === handle.sessionId).assertFalse();
      expect(store.readValue?.phase ?? '').assertEqual('ACTIVE');
      expect(store.readValue?.vpnId ?? '').assertEqual('vpn-generated-1');
      expect(readOwnershipBinding(store.readValue)).assertEqual('LEGACY_GLOBAL');
      expect(store.log.join(',')).assertEqual(
        'read,write:RELEASED:vpn-stale-1:PLATFORM_ID,clearExpected:RELEASED:vpn-stale-1:PLATFORM_ID,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(api.connection.log.join(',')).assertEqual('destroyWithVpnId:vpn-stale-1,generateVpnId,create');
      assertExactConfig(api.connection.createConfigs[0]);
    });

    it('protectsTheProcessBeforeCreateOnApi22AndSkipsPerSocketProtectionAfterward', 0, async () => {
      const api = new FakeVpnConnectionApi(22);
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-api22', store);

      await driver.protectProcess();
      const handle = await driver.create(buildExactCaptureConfig());
      await driver.protectSocket(93);

      expect(handle.vpnId).assertEqual('vpn-generated-1');
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,protectProcessNet,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
    });

    it('usesPerSocketProtectionOnApi21AfterCreate', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-api21', store);

      await driver.create(buildExactCaptureConfig());
      await driver.protectSocket(61);

      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,protect:61');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
    });

    it('rejectsNonPositiveAndNonIntegerTunFileDescriptorsAndCleansUpThePersistedOwner', 0, async () => {
      const zeroApi = new FakeVpnConnectionApi(21);
      zeroApi.connection.createFd = 0;
      const zeroStore = new FakeOwnershipStore();
      const zeroDriver = createDriver(zeroApi, 'session-zero', zeroStore);

      const zeroError = await expectRejects(async (): Promise<void> => {
        await zeroDriver.create(buildExactCaptureConfig());
      });
      expect(zeroError.message.includes('Tun')).assertTrue();
      expect(zeroApi.connection.log.join(',')).assertEqual('generateVpnId,create,destroy');
      expect(zeroStore.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(zeroStore.readValue).assertNull();

      const fractionalApi = new FakeVpnConnectionApi(21);
      fractionalApi.connection.createFd = 7.5;
      const fractionalStore = new FakeOwnershipStore();
      const fractionalDriver = createDriver(fractionalApi, 'session-fractional', fractionalStore);

      const fractionalError = await expectRejects(async (): Promise<void> => {
        await fractionalDriver.create(buildExactCaptureConfig());
      });
      expect(fractionalError.message.includes('Tun')).assertTrue();
      expect(fractionalStore.readValue).assertNull();
    });

    it('destroysLiveLegacyGlobalSessionsWithoutPassingAPlatformVpnId', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-destroy', store);

      const handle = await driver.create(buildExactCaptureConfig());
      await driver.destroy(handle.vpnId);
      await driver.destroy(handle.vpnId);

      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,destroy');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('retainsDurableAndLiveOwnershipWhenDestroyFailsSoDestroyCanRetry', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-destroy', store);

      const handle = await driver.create(buildExactCaptureConfig());
      api.connection.destroyError = new Error('destroy failed');

      const destroyError = await expectRejects(async (): Promise<void> => {
        await driver.destroy(handle.vpnId);
      });
      expect(destroyError.message.includes('destroy')).assertTrue();
      expect(store.readValue?.phase ?? '').assertEqual('ACTIVE');
      expect(store.readValue?.vpnId ?? '').assertEqual('vpn-generated-1');
      expect(readOwnershipBinding(store.readValue)).assertEqual('LEGACY_GLOBAL');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );

      api.connection.destroyError = undefined;
      await driver.destroy(handle.vpnId);

      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,destroy,destroy');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('clearsThePreparedMarkerWhenCreateFailsBeforeThePlatformConnectionBecomesLive', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new Error('create failed');
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-create-fail', store);

      const createError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(createError.message.includes('create')).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('doesNotDestroyDuringPrepareWhenProtectProcessFailsAfterGenerateVpnId', 0, async () => {
      const api = new FakeVpnConnectionApi(22);
      api.connection.protectProcessError = new Error('protect failed');
      const store = new FakeOwnershipStore();
      const driver = createDriver(api, 'session-protect-fail', store);

      const protectError = await expectRejects(async (): Promise<void> => {
        await driver.protectProcess();
      });

      expect(protectError instanceof VpnPlatformPortError).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,protectProcessNet');
      expect(store.log.join(',')).assertEqual(
        'read,write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('doesNotDestroyDuringPrepareWhenPersistingPreparedOwnershipFails', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      store.failWritePhase = 'PREPARED';
      store.failWriteError = new Error('prepared write failed');
      const driver = createDriver(api, 'session-prepared-write-fail', store);

      const writeError = await expectRejects(async (): Promise<void> => {
        await driver.protectProcess();
      });

      expect(writeError.message.includes('prepared write failed')).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('generateVpnId');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('doesNotGrantLegacyGlobalReclaimAfterAPreLiveFailureWasCleanedUp', 0, async () => {
      const firstApi = new FakeVpnConnectionApi(21);
      firstApi.connection.createError = new Error('create failed');
      const sharedStore = new FakeOwnershipStore();
      const firstDriver = createDriver(firstApi, 'session-prelive-fail-a', sharedStore);

      const firstError = await expectRejects(async (): Promise<void> => {
        await firstDriver.create(buildExactCaptureConfig());
      });

      expect(firstError.message.includes('create failed')).assertTrue();
      expect(firstApi.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(sharedStore.readValue).assertNull();

      sharedStore.log.length = 0;

      const secondApi = new FakeVpnConnectionApi(21);
      secondApi.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      const secondDriver = createDriver(secondApi, 'session-prelive-fail-b', sharedStore);

      const secondError = await expectRejects(async (): Promise<void> => {
        await secondDriver.create(buildExactCaptureConfig());
      });

      expect(secondError instanceof VpnPlatformPortError).assertTrue();
      expect(secondApi.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(sharedStore.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(sharedStore.readValue).assertNull();
    });

    it('failsClosedWhenTheOwnershipStoreIsCorrupt', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const store = new FakeOwnershipStore();
      store.readError = new OwnershipStoreCorruptError();
      const driver = createDriver(api, 'session-corrupt', store);

      const error = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(error instanceof OwnershipStoreCorruptError).assertTrue();
      expect(api.connection.log.length).assertEqual(0);
      expect(store.log.join(',')).assertEqual('read');
    });

    it('doesNotParameterlessReclaimWithoutAPersistedLegacyGlobalOwnershipRecord', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      const store = new FakeOwnershipStore();
      const stages: string[] = [];
      const driver = createDriver(api, 'session-reclaim', store, (stage: string): void => {
        stages.push(stage);
      });

      const reclaimError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(reclaimError instanceof VpnPlatformPortError).assertTrue();
      expect(api.createConnectionCalls).assertEqual(1);
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(stages.join(',')).assertEqual(
        'platform.config.begin,platform.config.ok,platform.connection.begin,platform.connection.active,' +
        'platform.connection.failed'
      );
      assertExactConfig(api.connection.createConfigs[0]);
    });

    it('mapsBusinessErrorsToAllowlistedPortCodesWithoutLeakingRawSystemMessages', 0, async () => {
      const consentApi = new FakeVpnConnectionApi(21);
      consentApi.connection.createError = new FakeBusinessError(2203001, 'raw consent secret 42');
      const consentDriver = createDriver(consentApi, 'session-consent', new FakeOwnershipStore());

      const consentError = await expectRejects(async (): Promise<void> => {
        await consentDriver.create(buildExactCaptureConfig());
      });
      expectPortErrorCode(consentError, 'CONSENT_DENIED');
      expect(consentError.message.includes('raw consent secret 42')).assertFalse();

      const createApi = new FakeVpnConnectionApi(21);
      createApi.connection.createError = new FakeBusinessError(2203999, 'raw create secret 77');
      const createDriverPort = createDriver(createApi, 'session-create-error', new FakeOwnershipStore());

      const createError = await expectRejects(async (): Promise<void> => {
        await createDriverPort.create(buildExactCaptureConfig());
      });
      expectPortErrorCode(createError, 'PLATFORM_CREATE_FAILED');
      expect(createError.message.includes('raw create secret 77')).assertFalse();

      const processApi = new FakeVpnConnectionApi(22);
      processApi.connection.protectProcessError = new FakeBusinessError(2204999, 'raw process secret 99');
      const processDriver = createDriver(processApi, 'session-process-error', new FakeOwnershipStore());

      const processError = await expectRejects(async (): Promise<void> => {
        await processDriver.protectProcess();
      });
      expectPortErrorCode(processError, 'PROCESS_PROTECT_FAILED');
      expect(processError.message.includes('raw process secret 99')).assertFalse();

      const socketApi = new FakeVpnConnectionApi(21);
      const socketDriver = createDriver(socketApi, 'session-socket-error', new FakeOwnershipStore());
      await socketDriver.create(buildExactCaptureConfig());
      socketApi.connection.protectError = new FakeBusinessError(2205999, 'raw socket secret 101');

      const socketError = await expectRejects(async (): Promise<void> => {
        await socketDriver.protectSocket(88);
      });
      expectPortErrorCode(socketError, 'PROTECT_SOCKET_FAILED');
      expect(socketError.message.includes('raw socket secret 101')).assertFalse();
    });

    it('allowsOneLegacyGlobalReclaimOnlyWhenThePersistedOwnerIsActiveAndBoundToLegacyGlobal', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      api.replacementConnection = new FakePlatformVpnConnection();
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('ACTIVE', 'vpn-active-legacy-1', 'LEGACY_GLOBAL');
      const driver = createDriver(api, 'session-active-fallback', store);

      const handle = await driver.create(buildExactCaptureConfig());

      expect(handle.vpnId).assertEqual('vpn-generated-1');
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,destroy');
      expect(api.replacementConnection?.log.join(',') ?? '').assertEqual('create');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
      assertExactConfig(api.replacementConnection?.createConfigs[0] ?? api.connection.createConfigs[0]);
    });

    it('doesNotGrantLegacyGlobalReclaimWhenThePersistedOwnerIsPrepared', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('PREPARED', 'vpn-prepared-legacy-1', 'LEGACY_GLOBAL');
      const driver = createDriver(api, 'session-prepared-no-reclaim', store);

      const createError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(createError instanceof VpnPlatformPortError).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:RELEASED:vpn-prepared-legacy-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-prepared-legacy-1:LEGACY_GLOBAL,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('doesNotGrantLegacyGlobalReclaimWhenThePersistedOwnerIsReleased', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('RELEASED', 'vpn-released-legacy-1', 'LEGACY_GLOBAL');
      const driver = createDriver(api, 'session-released-no-reclaim', store);

      const createError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(createError instanceof VpnPlatformPortError).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,clearExpected:RELEASED:vpn-released-legacy-1:LEGACY_GLOBAL,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('failsAfterOneLegacyGlobalReclaimWhenRetryStillReturns2203002WithoutASecondParameterlessDestroy', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      api.replacementConnection = new FakePlatformVpnConnection();
      api.replacementConnection.createError = new FakeBusinessError(2203002, 'still active after reclaim');
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('ACTIVE', 'vpn-active-legacy-2', 'LEGACY_GLOBAL');
      const driver = createDriver(api, 'session-reclaim-twice', store);

      const createError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(createError instanceof VpnPlatformPortError).assertTrue();
      expect(api.createConnectionCalls).assertEqual(2);
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,destroy');
      expect(api.replacementConnection?.log.join(',') ?? '').assertEqual('create');
      expect(store.log.join(',')).assertEqual(
        'read,write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('destroysTheReplacementConnectionWhenRetryCreateSucceededButPersistingActiveOwnershipFails', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      api.replacementConnection = new FakePlatformVpnConnection();
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('ACTIVE', 'vpn-active-legacy-3', 'LEGACY_GLOBAL');
      store.failWritePhase = 'ACTIVE';
      store.failWriteError = new Error('active write failed');
      const driver = createDriver(api, 'session-active-write-fail-after-reclaim', store);

      const createError = await expectRejects(async (): Promise<void> => {
        await driver.create(buildExactCaptureConfig());
      });

      expect(createError.message.includes('active write failed')).assertTrue();
      expect(api.createConnectionCalls).assertEqual(2);
      expect(api.connection.log.join(',')).assertEqual('generateVpnId,create,destroy');
      expect(api.replacementConnection?.log.join(',') ?? '').assertEqual('create,destroy');
      expect(store.log.join(',')).assertEqual(
        'read,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL,' +
        'write:RELEASED:vpn-generated-1:LEGACY_GLOBAL,clearExpected:RELEASED:vpn-generated-1:LEGACY_GLOBAL'
      );
      expect(store.readValue).assertNull();
    });

    it('treatsPreparedDestroyAlreadyReleasedAsReleasedAndContinuesStart', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.destroyWithVpnIdError = new FakeBusinessError(19900001, 'already released');
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('PREPARED', 'vpn-prepared-1', 'PLATFORM_ID');
      const driver = createDriver(api, 'session-prepared-recover', store);

      const handle = await driver.create(buildExactCaptureConfig());

      expect(handle.vpnId).assertEqual('vpn-generated-1');
      expect(api.connection.log.join(',')).assertEqual('destroyWithVpnId:vpn-prepared-1,generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:RELEASED:vpn-prepared-1:PLATFORM_ID,clearExpected:RELEASED:vpn-prepared-1:PLATFORM_ID,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
    });

    it('treatsActiveDestroyAlreadyReleasedAsReleasedAndContinuesStart', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.destroyWithVpnIdError = new FakeBusinessError(19900001, 'already released');
      const store = new FakeOwnershipStore();
      store.readValue = createOwnership('ACTIVE', 'vpn-active-1', 'PLATFORM_ID');
      const driver = createDriver(api, 'session-active-recover', store);

      const handle = await driver.create(buildExactCaptureConfig());

      expect(handle.vpnId).assertEqual('vpn-generated-1');
      expect(api.connection.log.join(',')).assertEqual('destroyWithVpnId:vpn-active-1,generateVpnId,create');
      expect(store.log.join(',')).assertEqual(
        'read,write:RELEASED:vpn-active-1:PLATFORM_ID,clearExpected:RELEASED:vpn-active-1:PLATFORM_ID,' +
        'write:PREPARED:vpn-generated-1:LEGACY_GLOBAL,write:ACTIVE:vpn-generated-1:LEGACY_GLOBAL'
      );
    });
  });
}
