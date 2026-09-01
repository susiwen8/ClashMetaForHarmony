import { describe, expect, it } from '@ohos/hypium';
import { createVpnCaptureConfig, type VpnCaptureConfig } from '@cmfa/shared';
import { HarmonyVpnConnectionDriver } from '../main/ets/vpn/HarmonyVpnConnectionDriver';
import { VpnPlatformPortError } from '@cmfa/shared';
import type {
  PlatformVpnConfig,
  PlatformVpnConnection,
  VpnConnectionApi
} from '../main/ets/vpn/VpnConnectionApi';

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
  alreadyActiveCreateFailuresRemaining: number = 0;
  useDeferredCreate: boolean = false;
  useDeferredDestroy: boolean = false;
  createError?: Error | FakeBusinessError;
  generateVpnIdError?: Error | FakeBusinessError;
  protectProcessError?: Error | FakeBusinessError;
  protectError?: Error | FakeBusinessError;
  destroyError?: Error | FakeBusinessError;
  destroyWithVpnIdError?: Error | FakeBusinessError;
  private createDeferredResolve?: (value: number) => void;
  private readonly createDeferredPromise: Promise<number>;
  private destroyDeferredResolve?: () => void;
  private readonly destroyDeferredPromise: Promise<void>;

  constructor() {
    this.createDeferredPromise = new Promise<number>((resolve) => {
      this.createDeferredResolve = resolve;
    });
    this.destroyDeferredPromise = new Promise<void>((resolve) => {
      this.destroyDeferredResolve = resolve;
    });
  }

  async create(config: PlatformVpnConfig): Promise<number> {
    this.log.push('create');
    this.createConfigs.push(config);
    if (this.alreadyActiveCreateFailuresRemaining > 0) {
      this.alreadyActiveCreateFailuresRemaining -= 1;
      throw new FakeBusinessError(2203002, 'existing vpn session');
    }
    if (this.createError !== undefined) {
      throw requireFakeError(this.createError);
    }
    if (this.useDeferredCreate) {
      return await this.createDeferredPromise;
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
    if (this.useDeferredDestroy) {
      await this.destroyDeferredPromise;
    }
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

  releaseDeferredCreate(fd?: number): void {
    this.createDeferredResolve?.(fd ?? this.createFd);
  }

  releaseDeferredDestroy(): void {
    this.destroyDeferredResolve?.();
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

function createDriver(api: VpnConnectionApi, sessionId: string): HarmonyVpnConnectionDriver {
  return new HarmonyVpnConnectionDriver(api, sessionId);
}

async function expectRejects(action: () => Promise<void>): Promise<Error> {
  try {
    await action();
    expect().assertFail();
  } catch (error) {
    return error as Error;
  }
  return new Error('expected rejection');
}

async function waitForCondition(predicate: () => boolean, maxTurns: number = 12): Promise<void> {
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  expect().assertFail();
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
    it('usesLegacySingleVpnConfigSoTheSelfBlocklistCapturesEveryOtherApplication', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const driver = createDriver(api, 'session-config');

      await driver.protectProcess();
      const handle = await driver.create(buildExactCaptureConfig());

      expect(api.createConnectionCalls).assertEqual(1);
      expect(api.connection.log.join(',')).assertEqual('create');
      expect(handle.fd).assertEqual(41);
      expect(handle.vpnId).assertEqual('session-config');
      expect(handle.sessionId).assertEqual('session-config');
      assertExactConfig(api.connection.createConfigs[0]);
    });

    it('rejectsNonPositiveAndNonIntegerTunFileDescriptors', 0, async () => {
      const zeroApi = new FakeVpnConnectionApi(21);
      zeroApi.connection.createFd = 0;
      const zeroDriver = createDriver(zeroApi, 'session-zero');

      const zeroError = await expectRejects(async () => {
        await zeroDriver.create(buildExactCaptureConfig());
      });
      expect(zeroError.message.includes('Tun')).assertTrue();

      const fractionalApi = new FakeVpnConnectionApi(21);
      fractionalApi.connection.createFd = 7.5;
      const fractionalDriver = createDriver(fractionalApi, 'session-fractional');

      const fractionalError = await expectRejects(async () => {
        await fractionalDriver.create(buildExactCaptureConfig());
      });
      expect(fractionalError.message.includes('Tun')).assertTrue();

      const unsafeApi = new FakeVpnConnectionApi(21);
      unsafeApi.connection.createFd = Number.MAX_SAFE_INTEGER + 1;
      const unsafeDriver = createDriver(unsafeApi, 'session-unsafe');

      const unsafeError = await expectRejects(async () => {
        await unsafeDriver.create(buildExactCaptureConfig());
      });
      expect(unsafeError.message.includes('Tun')).assertTrue();
    });

    it('protectsTheProcessBeforeCreateOnApi22AndAwaitProtectSocketOnApi21', 0, async () => {
      const api22 = new FakeVpnConnectionApi(22);
      const driver22 = createDriver(api22, 'session-api22');

      await driver22.protectProcess();
      await driver22.create(buildExactCaptureConfig());

      expect(api22.connection.log.join(',')).assertEqual('protectProcessNet,create');

      const api21 = new FakeVpnConnectionApi(21);
      const driver21 = createDriver(api21, 'session-api21');

      await driver21.protectProcess();
      await driver21.create(buildExactCaptureConfig());
      await driver21.protectSocket(93);

      expect(api21.connection.log.join(',')).assertEqual('create,protect:93');
    });

    it('reusesThePreparedOwnerAcrossRepeatedProtectProcessCallsWithoutCreatingASecondConnection', 0, async () => {
      const api22 = new FakeVpnConnectionApi(22);
      const driver22 = createDriver(api22, 'session-owner-22');

      await driver22.protectProcess();
      await driver22.protectProcess();
      await driver22.create(buildExactCaptureConfig());

      expect(api22.createConnectionCalls).assertEqual(1);
      expect(api22.connection.log.join(',')).assertEqual('protectProcessNet,create');

      const api20 = new FakeVpnConnectionApi(20);
      const driver20 = createDriver(api20, 'session-owner-20');

      await driver20.protectProcess();
      await driver20.protectProcess();
      await driver20.create(buildExactCaptureConfig());
      await driver20.protectSocket(73);

      expect(api20.createConnectionCalls).assertEqual(1);
      expect(api20.connection.log.join(',')).assertEqual('create,protect:73');
    });

    it('skipsPerSocketProtectionAfterTheProcessPathWasProtectedOnApi22', 0, async () => {
      const api = new FakeVpnConnectionApi(22);
      const driver = createDriver(api, 'session-api22-socket');

      await driver.create(buildExactCaptureConfig());
      await driver.protectSocket(61);

      expect(api.createConnectionCalls).assertEqual(1);
      expect(api.connection.log.join(',')).assertEqual('protectProcessNet,create');
    });

    it('stopsBeforeCreateWhenProcessProtectionFailsAndCleansUp', 0, async () => {
      const api = new FakeVpnConnectionApi(22);
      api.connection.protectProcessError = new Error('process protect failed');
      const driver = createDriver(api, 'session-stop');

      const error = await expectRejects(async () => {
        await driver.protectProcess();
      });

      expect(error.message.includes('protect')).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('protectProcessNet,destroy');
    });

    it('rejectsDuplicateCreateAndOnlyDestroysTheLiveLegacyOwner', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const driver = createDriver(api, 'session-live');

      await driver.protectProcess();
      await driver.create(buildExactCaptureConfig());

      const duplicateError = await expectRejects(async () => {
        await driver.create(buildExactCaptureConfig());
      });
      expect(duplicateError.message.includes('already')).assertTrue();

      const mismatchError = await expectRejects(async () => {
        await driver.destroy('vpn-other');
      });
      expect(mismatchError.message.includes('vpn')).assertTrue();

      await driver.destroy('session-live');
      await driver.destroy('session-live');

      expect(api.connection.log.join(',')).assertEqual('create,destroy');
    });

    it('rejectsConcurrentCreateWhileThePendingOwnerIsStillCreating', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.useDeferredCreate = true;
      const driver = createDriver(api, 'session-pending');

      await driver.protectProcess();
      const pendingCreate = driver.create(buildExactCaptureConfig());

      const duplicateError = await expectRejects(async () => {
        await driver.create(buildExactCaptureConfig());
      });
      expect(duplicateError.message.includes('creating')).assertTrue();

      api.connection.releaseDeferredCreate();
      const handle = await pendingCreate;
      expect(handle.sessionId).assertEqual('session-pending');
    });

    it('cleansUpCreateFailuresThroughTheLegacySingleVpnOwner', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new Error('create failed');
      const driver = createDriver(api, 'session-create-fail');

      const createError = await expectRejects(async () => {
        await driver.protectProcess();
        await driver.create(buildExactCaptureConfig());
      });
      expect(createError.message.includes('create')).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('create,destroy');
    });

    it('keepsTheOwnerBusyUntilLegacyCleanupFinishes', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new Error('create failed');
      api.connection.useDeferredDestroy = true;
      const driver = createDriver(api, 'session-cleanup-race');

      let primaryError: Error | undefined = undefined;
      const pendingCreate = driver.create(buildExactCaptureConfig()).catch((error: Error) => {
        primaryError = error;
      });

      await waitForCondition(() => api.connection.log.includes('destroy'));
      api.connection.createError = undefined;

      await driver.protectProcess();
      expect(api.createConnectionCalls).assertEqual(1);

      const duplicateError = await expectRejects(async () => {
        await driver.create(buildExactCaptureConfig());
      });
      expect(duplicateError.message.includes('creating')).assertTrue();
      expect(api.createConnectionCalls).assertEqual(1);

      api.connection.releaseDeferredDestroy();
      await pendingCreate;

      expect(primaryError !== undefined).assertTrue();
      const finalPrimaryError: Error = primaryError ?? new Error('missing primary create error');
      expect(finalPrimaryError.message.includes('create')).assertTrue();
      expect(api.connection.log.join(',')).assertEqual('create,destroy');
    });

    it('rejectsInvalidProtectSocketFileDescriptors', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      const driver = createDriver(api, 'session-protect');

      await driver.create(buildExactCaptureConfig());

      const zeroError = await expectRejects(async () => {
        await driver.protectSocket(0);
      });
      expect(zeroError.message.includes('socket')).assertTrue();

      const fractionalError = await expectRejects(async () => {
        await driver.protectSocket(7.5);
      });
      expect(fractionalError.message.includes('socket')).assertTrue();

      const unsafeError = await expectRejects(async () => {
        await driver.protectSocket(Number.MAX_SAFE_INTEGER + 1);
      });
      expect(unsafeError.message.includes('socket')).assertTrue();

      expect(api.connection.log.join(',')).assertEqual('create');
    });

    it('retainsLiveOwnershipWhenDestroyFailsSoDestroyCanRetry', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.destroyError = new Error('destroy failed');
      const driver = createDriver(api, 'session-destroy');

      await driver.create(buildExactCaptureConfig());

      const destroyError = await expectRejects(async () => {
        await driver.destroy('session-destroy');
      });
      expect(destroyError.message.includes('destroy')).assertTrue();

      api.connection.destroyError = undefined;
      await driver.destroy('session-destroy');

      expect(api.connection.log.join(',')).assertEqual('create,destroy,destroy');
    });

    it('mapsBusinessErrorsToAllowlistedPortCodesWithoutLeakingRawSystemMessages', 0, async () => {
      const consentApi = new FakeVpnConnectionApi(21);
      consentApi.connection.createError = new FakeBusinessError(2203001, 'raw consent secret 42');
      const consentDriver = createDriver(consentApi, 'session-consent');

      const consentError = await expectRejects(async () => {
        await consentDriver.create(buildExactCaptureConfig());
      });
      expectPortErrorCode(consentError, 'CONSENT_DENIED');
      expect(consentError.message.includes('raw consent secret 42')).assertFalse();

      const createApi = new FakeVpnConnectionApi(21);
      createApi.connection.createError = new FakeBusinessError(2203999, 'raw create secret 77');
      const createDriverPort = createDriver(createApi, 'session-create-error');

      const createError = await expectRejects(async () => {
        await createDriverPort.create(buildExactCaptureConfig());
      });
      expectPortErrorCode(createError, 'PLATFORM_CREATE_FAILED');
      expect(createError.message.includes('raw create secret 77')).assertFalse();

      const activeApi = new FakeVpnConnectionApi(21);
      activeApi.connection.createError = new FakeBusinessError(2203002, 'raw active secret 66');
      const activeStages: string[] = [];
      const activeDriver = new HarmonyVpnConnectionDriver(activeApi, 'session-already-active', (stage: string): void => {
        activeStages.push(stage);
      });

      const activeError = await expectRejects(async () => {
        await activeDriver.create(buildExactCaptureConfig());
      });
      expectPortErrorCode(activeError, 'ALREADY_ACTIVE');
      expect(activeError.message.includes('raw active secret 66')).assertFalse();
      expect(activeStages.includes('platform.connection.retry.active')).assertTrue();

      const processApi = new FakeVpnConnectionApi(22);
      processApi.connection.protectProcessError = new FakeBusinessError(2204999, 'raw process secret 99');
      const processDriver = createDriver(processApi, 'session-process-error');

      const processError = await expectRejects(async () => {
        await processDriver.protectProcess();
      });
      expectPortErrorCode(processError, 'PROCESS_PROTECT_FAILED');
      expect(processError.message.includes('raw process secret 99')).assertFalse();

      const socketApi = new FakeVpnConnectionApi(21);
      socketApi.connection.protectError = new FakeBusinessError(2205999, 'raw socket secret 101');
      const socketDriver = createDriver(socketApi, 'session-socket-error');
      await socketDriver.create(buildExactCaptureConfig());

      const socketError = await expectRejects(async () => {
        await socketDriver.protectSocket(88);
      });
      expectPortErrorCode(socketError, 'PROTECT_SOCKET_FAILED');
      expect(socketError.message.includes('raw socket secret 101')).assertFalse();
    });

    it('reclaimsOneLegacySystemVpnAndRetriesCreateOnce', 0, async () => {
      const api = new FakeVpnConnectionApi(21);
      api.connection.createError = new FakeBusinessError(2203002, 'existing vpn session');
      api.replacementConnection = new FakePlatformVpnConnection();
      const stages: string[] = [];
      const driver = new HarmonyVpnConnectionDriver(api, 'session-reclaim', (stage: string): void => {
        stages.push(stage);
      });

      const handle = await driver.create(buildExactCaptureConfig());

      expect(handle.fd).assertEqual(41);
      expect(handle.sessionId).assertEqual('session-reclaim');
      expect(api.createConnectionCalls).assertEqual(2);
      expect(api.connection.log.join(',')).assertEqual('create,destroy');
      expect(api.replacementConnection?.log.join(',') ?? '').assertEqual('create');
      expect(stages.join(',')).assertEqual(
        'platform.config.begin,platform.config.ok,platform.connection.begin,' +
        'platform.connection.active,platform.connection.reclaim.begin,platform.connection.reclaim.ok,' +
        'platform.connection.retry.begin,platform.connection.retry.ok,platform.fd.ok'
      );
    });

  });
}
