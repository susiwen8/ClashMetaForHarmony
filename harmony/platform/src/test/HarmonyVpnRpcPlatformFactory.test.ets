import { describe, expect, it } from '@ohos/hypium';
import type {
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSocketConnectionPort,
  VpnRpcSocketClientFactoryPort,
  VpnRpcSocketServerPort
} from '@cmfa/shared';
import { HarmonyVpnRpcPlatformFactory } from '../../Index';
import { HarmonyVpnLoopbackSocketClient, HarmonyVpnLoopbackSocketServer } from '../main/ets/vpn/HarmonyVpnLoopbackSocket';
import { HarmonyVpnLocalSocketClient } from '../main/ets/vpn/HarmonyVpnLocalSocketClient';
import { HarmonyVpnLocalSocketServer } from '../main/ets/vpn/HarmonyVpnLocalSocketServer';
import {
  HarmonyVpnRpcCryptoFrameworkRandomPort,
  type HarmonyVpnCryptoFrameworkRandomDriver,
  type HarmonyVpnRpcPlatformBundle,
  type HarmonyVpnRpcPlatformDependencies
} from '../main/ets/vpn/HarmonyVpnRpcPlatformFactory';

class RecordingCryptoPort implements VpnRpcCryptoPort {
  prepareCalls: number = 0;

  async prepare(): Promise<void> {
    this.prepareCalls += 1;
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    return input.slice();
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    return new Uint8Array(key.length + input.length);
  }
}

class RecordingSocketClientFactory implements VpnRpcSocketClientFactoryPort {
  async connect(_: string, __: number): Promise<VpnRpcSocketConnectionPort> {
    return new RecordingSocketConnectionPort();
  }
}

class RecordingSocketServerPort implements VpnRpcSocketServerPort {
  async listen(_: string, __: (connection: VpnRpcSocketConnectionPort) => void): Promise<void> {
  }

  async close(): Promise<void> {
  }
}

class RecordingSocketConnectionPort implements VpnRpcSocketConnectionPort {
  async send(_: Uint8Array): Promise<void> {
  }

  subscribeData(_: (bytes: Uint8Array) => void): number {
    return 1;
  }

  unsubscribeData(_: number): void {
  }

  subscribeClose(_: () => void): number {
    return 2;
  }

  unsubscribeClose(_: number): void {
  }

  subscribeError(_: () => void): number {
    return 3;
  }

  unsubscribeError(_: number): void {
  }

  async close(): Promise<void> {
  }
}

class RecordingRandomDriver implements HarmonyVpnCryptoFrameworkRandomDriver {
  readonly seeded: Uint8Array[];
  throwOnGenerate: boolean = false;
  wrongLength: boolean = false;

  constructor(seeded: Uint8Array[]) {
    this.seeded = seeded;
  }

  generateRandomSync(length: number): Uint8Array {
    if (this.throwOnGenerate) {
      throw new Error('raw random failure');
    }
    const next: Uint8Array = this.seeded.length > 0 ? this.seeded.shift() ?? new Uint8Array(length) : new Uint8Array(length);
    if (this.wrongLength) {
      return next.slice(0, Math.max(0, next.length - 1));
    }
    return next.slice();
  }
}

class HarmonyVpnRpcPlatformDependenciesRecord implements HarmonyVpnRpcPlatformDependencies {
  readonly crypto?: VpnRpcCryptoPort;
  readonly random?: VpnRpcRandomPort;
  readonly clientFactoryCreator: () => VpnRpcSocketClientFactoryPort;
  readonly serverCreator: () => VpnRpcSocketServerPort;

  constructor(
    crypto: VpnRpcCryptoPort,
    random: VpnRpcRandomPort,
    clientFactoryCreator: () => VpnRpcSocketClientFactoryPort,
    serverCreator: () => VpnRpcSocketServerPort
  ) {
    this.crypto = crypto;
    this.random = random;
    this.clientFactoryCreator = clientFactoryCreator;
    this.serverCreator = serverCreator;
  }

  createClientFactory(): VpnRpcSocketClientFactoryPort {
    return this.clientFactoryCreator();
  }

  createServer(): VpnRpcSocketServerPort {
    return this.serverCreator();
  }
}

function bytesToCsv(bytes: Uint8Array): string {
  const values: string[] = [];
  for (let index: number = 0; index < bytes.length; index += 1) {
    values.push(`${bytes[index]}`);
  }
  return values.join(',');
}

export default function harmonyVpnRpcPlatformFactoryTestsuite() {
  describe('HarmonyVpnRpcPlatformFactoryTest', () => {
    it('keepsApi20Through25OnLocalSocketAndUsesLoopbackOn26AndLater', 0, () => {
      for (const api of [20, 21, 22, 24, 25]) {
        const bundle = new HarmonyVpnRpcPlatformFactory(undefined, '/sandbox/files', api).create();
        expect(bundle.transport).assertEqual('LOCAL_SOCKET');
        expect(bundle.clientFactory instanceof HarmonyVpnLocalSocketClient).assertTrue();
        expect(bundle.server instanceof HarmonyVpnLocalSocketServer).assertTrue();
      }
      for (const api of [26, 27]) {
        const bundle = new HarmonyVpnRpcPlatformFactory(undefined, '/sandbox/files', api).create();
        expect(bundle.transport).assertEqual('LOOPBACK_TCP');
        expect(bundle.clientFactory instanceof HarmonyVpnLoopbackSocketClient).assertTrue();
        expect(bundle.server instanceof HarmonyVpnLoopbackSocketServer).assertTrue();
      }
    });

    it('exportsPlatformAssemblyFromIndexAndReusesCryptoWhileCreatingFreshSocketOwners', 0, () => {
      const sharedCrypto: RecordingCryptoPort = new RecordingCryptoPort();
      const sharedRandomSeed: Uint8Array[] = [new Uint8Array([1, 2, 3, 4]), new Uint8Array([5, 6, 7, 8])];
      const sharedRandom: VpnRpcRandomPort = new HarmonyVpnRpcCryptoFrameworkRandomPort(new RecordingRandomDriver(sharedRandomSeed));
      let clientFactoryCount = 0;
      let serverCount = 0;
      const dependencies: HarmonyVpnRpcPlatformDependencies = new HarmonyVpnRpcPlatformDependenciesRecord(
        sharedCrypto,
        sharedRandom,
        (): VpnRpcSocketClientFactoryPort => {
          clientFactoryCount += 1;
          return new RecordingSocketClientFactory();
        },
        (): VpnRpcSocketServerPort => {
          serverCount += 1;
          return new RecordingSocketServerPort();
        }
      );

      const factory: HarmonyVpnRpcPlatformFactory = new HarmonyVpnRpcPlatformFactory(dependencies);
      const first: HarmonyVpnRpcPlatformBundle = factory.create();
      const second: HarmonyVpnRpcPlatformBundle = factory.create();

      expect(first.crypto === second.crypto).assertTrue();
      expect(first.random === second.random).assertTrue();
      expect(first.clientFactory === second.clientFactory).assertFalse();
      expect(first.server === second.server).assertFalse();
      expect(clientFactoryCount).assertEqual(2);
      expect(serverCount).assertEqual(2);
    });

    it('returnsExactCopiedRandomBytesAndThrowsFixedFailureOnDriverIssues', 0, () => {
      const source = new Uint8Array([9, 8, 7, 6]);
      const sourceSeed: Uint8Array[] = [source];
      const port = new HarmonyVpnRpcCryptoFrameworkRandomPort(new RecordingRandomDriver(sourceSeed));
      const generated = port.bytes(4);
      generated[0] = 1;

      expect(bytesToCsv(generated)).assertEqual('1,8,7,6');
      expect(bytesToCsv(source)).assertEqual('9,8,7,6');

      const wrongLengthSeed: Uint8Array[] = [new Uint8Array([1, 2, 3, 4])];
      const wrongLengthDriver = new RecordingRandomDriver(wrongLengthSeed);
      wrongLengthDriver.wrongLength = true;
      const wrongLengthPort = new HarmonyVpnRpcCryptoFrameworkRandomPort(wrongLengthDriver);
      try {
        wrongLengthPort.bytes(4);
        expect(false).assertTrue();
      } catch (error) {
        expect(String(error)).assertContain('VPN RPC random generation failed.');
      }

      const throwingSeed: Uint8Array[] = [new Uint8Array([1, 2, 3, 4])];
      const throwingDriver = new RecordingRandomDriver(throwingSeed);
      throwingDriver.throwOnGenerate = true;
      const throwingPort = new HarmonyVpnRpcCryptoFrameworkRandomPort(throwingDriver);
      try {
        throwingPort.bytes(4);
        expect(false).assertTrue();
      } catch (error) {
        expect(String(error)).assertContain('VPN RPC random generation failed.');
      }
    });

  });
}
