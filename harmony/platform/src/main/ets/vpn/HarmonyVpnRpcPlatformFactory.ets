import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import type {
  VpnRpcCryptoPort,
  VpnRpcRandomPort,
  VpnRpcSocketClientFactoryPort,
  VpnRpcSocketServerPort
} from '@cmfa/shared';
import { HarmonyVpnLocalSocketClient } from './HarmonyVpnLocalSocketClient';
import { HarmonyVpnLocalSocketServer } from './HarmonyVpnLocalSocketServer';
import { HarmonyVpnRpcKeyProvider } from './HarmonyVpnRpcKeyProvider';

const RANDOM_FAILURE_MESSAGE: string = 'VPN RPC random generation failed.';

export interface HarmonyVpnCryptoFrameworkRandomDriver {
  generateRandomSync(length: number): Uint8Array;
}

export interface HarmonyVpnRpcPlatformBundle {
  readonly crypto: VpnRpcCryptoPort;
  readonly clientFactory: VpnRpcSocketClientFactoryPort;
  readonly server: VpnRpcSocketServerPort;
  readonly random: VpnRpcRandomPort;
}

export interface HarmonyVpnRpcPlatformDependencies {
  readonly crypto?: VpnRpcCryptoPort;
  readonly random?: VpnRpcRandomPort;
  createClientFactory?(): VpnRpcSocketClientFactoryPort;
  createServer?(): VpnRpcSocketServerPort;
}

export class HarmonyVpnRpcCryptoFrameworkRandomPort implements VpnRpcRandomPort {
  private readonly driver: HarmonyVpnCryptoFrameworkRandomDriver;

  constructor(driver?: HarmonyVpnCryptoFrameworkRandomDriver) {
    this.driver = driver ?? new HarmonyVpnCryptoFrameworkRandomDriverValue();
  }

  bytes(length: number): Uint8Array {
    if (!Number.isSafeInteger(length) || length <= 0) {
      throw new Error(RANDOM_FAILURE_MESSAGE);
    }
    try {
      const rawBytes: Uint8Array = this.driver.generateRandomSync(length);
      if (rawBytes.length !== length) {
        throw new Error(RANDOM_FAILURE_MESSAGE);
      }
      return copyBytes(rawBytes);
    } catch (_) {
      throw new Error(RANDOM_FAILURE_MESSAGE);
    }
  }
}

export class HarmonyVpnRpcPlatformFactory {
  private readonly crypto: VpnRpcCryptoPort;
  private readonly random: VpnRpcRandomPort;
  private readonly socketRootDir: string;
  private readonly dependencies: HarmonyVpnRpcPlatformDependencies;

  constructor(dependencies?: HarmonyVpnRpcPlatformDependencies, socketRootDir: string = '') {
    this.socketRootDir = socketRootDir;
    this.dependencies = dependencies ?? new HarmonyVpnRpcPlatformDependenciesRecord();
    this.crypto = this.dependencies.crypto ?? new HarmonyVpnRpcKeyProvider();
    this.random = this.dependencies.random ?? new HarmonyVpnRpcCryptoFrameworkRandomPort();
  }

  create(): HarmonyVpnRpcPlatformBundle {
    return new HarmonyVpnRpcPlatformBundleRecord(
      this.crypto,
      this.dependencies.createClientFactory?.() ?? new HarmonyVpnLocalSocketClient(undefined, this.socketRootDir),
      this.dependencies.createServer?.() ?? new HarmonyVpnLocalSocketServer(undefined, this.socketRootDir),
      this.random
    );
  }
}

class HarmonyVpnRpcPlatformBundleRecord implements HarmonyVpnRpcPlatformBundle {
  readonly crypto: VpnRpcCryptoPort;
  readonly clientFactory: VpnRpcSocketClientFactoryPort;
  readonly server: VpnRpcSocketServerPort;
  readonly random: VpnRpcRandomPort;

  constructor(
    crypto: VpnRpcCryptoPort,
    clientFactory: VpnRpcSocketClientFactoryPort,
    server: VpnRpcSocketServerPort,
    random: VpnRpcRandomPort
  ) {
    this.crypto = crypto;
    this.clientFactory = clientFactory;
    this.server = server;
    this.random = random;
  }
}

class HarmonyVpnCryptoFrameworkRandomDriverValue implements HarmonyVpnCryptoFrameworkRandomDriver {
  generateRandomSync(length: number): Uint8Array {
    try {
      return copyBytes(cryptoFramework.createRandom().generateRandomSync(length).data);
    } catch (_) {
      throw new Error(RANDOM_FAILURE_MESSAGE);
    }
  }
}

class HarmonyVpnRpcPlatformDependenciesRecord implements HarmonyVpnRpcPlatformDependencies {
  readonly crypto?: VpnRpcCryptoPort;
  readonly random?: VpnRpcRandomPort;
}

function copyBytes(bytes: Uint8Array): Uint8Array {
  const copy = new Uint8Array(bytes.length);
  for (let index: number = 0; index < bytes.length; index += 1) {
    copy[index] = bytes[index];
  }
  return copy;
}
