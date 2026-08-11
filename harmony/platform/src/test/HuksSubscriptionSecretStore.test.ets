import { describe, expect, it } from '@ohos/hypium';
import { isSubscriptionSecretError } from '@cmfa/shared';
import { HarmonyHuksDriver } from '../main/ets/secrets/HarmonyHuksDriver';
import {
  type HuksOperations,
  type HuksOptionsContract,
  type HuksParamContract,
  type HuksRandomSource,
  type HuksReturnResultContract
} from '../main/ets/secrets/HuksDriver';
import { HuksSubscriptionSecretStore } from '../main/ets/secrets/HuksSubscriptionSecretStore';
import {
  DeterministicHuksDriver,
  FakeFileDriver,
  SequenceIdGenerator,
  assertNoLeak,
  replaceEnvelopeCiphertextByte,
  replaceEnvelopeNumberField,
  replaceEnvelopeTagByte,
  utf8Bytes
} from './fakes/PlatformFakes';

const FILES_DIR = '/sandbox/app/files';
const SECRETS_DIR = `${FILES_DIR}/profile-secrets`;
const PLAINTEXT_URL = 'https://用户:密钥@example.com/subscription?token=秘密#片段';

class RecordedUpdateCall {
  readonly handle: number;
  readonly inDataLength: number;
  readonly tokenLength: number;

  constructor(handle: number, inDataLength: number, tokenLength: number) {
    this.handle = handle;
    this.inDataLength = inDataLength;
    this.tokenLength = tokenLength;
  }
}

class RecordedInitCall {
  readonly handle: number;
  readonly purpose: number;
  readonly nonceLength: number;
  readonly tagLength: number;

  constructor(handle: number, purpose: number, nonceLength: number, tagLength: number) {
    this.handle = handle;
    this.purpose = purpose;
    this.nonceLength = nonceLength;
    this.tagLength = tagLength;
  }
}

class SessionHandleRecord {
  readonly handle: number;
  readonly challenge?: Uint8Array;

  constructor(handle: number, challenge?: Uint8Array) {
    this.handle = handle;
    this.challenge = challenge;
  }
}

class ParamRecord implements HuksParamContract {
  readonly tag: number;
  readonly value: boolean | number | bigint | Uint8Array;

  constructor(tag: number, value: boolean | number | bigint | Uint8Array) {
    this.tag = tag;
    this.value = value;
  }
}

class ReturnResultRecord implements HuksReturnResultContract {
  readonly outData?: Uint8Array;
  readonly properties?: Array<HuksParamContract>;

  constructor(outData?: Uint8Array, properties?: Array<HuksParamContract>) {
    this.outData = outData;
    this.properties = properties;
  }
}

class ScriptedSessionOperations implements HuksOperations {
  readonly initCalls: RecordedInitCall[] = [];
  readonly updateCalls: RecordedUpdateCall[] = [];
  isKeyItemExistCallCount: number = 0;
  generateKeyItemCallCount: number = 0;
  abortSessionCallCount: number = 0;

  async isKeyItemExist(_: string, __: HuksOptionsContract): Promise<boolean> {
    this.isKeyItemExistCallCount += 1;
    return false;
  }

  async generateKeyItem(_: string, __: HuksOptionsContract): Promise<void> {
    this.generateKeyItemCallCount += 1;
  }

  async initSession(_: string, options: HuksOptionsContract): Promise<SessionHandleRecord> {
    const purpose: number = readNumberParam(options.properties, 536870916);
    const nonceLength: number = readBytesParamLength(options.properties, 1342177280 + 9);
    const tagLength: number = readBytesParamLength(options.properties, 1342177280 + 10009);
    this.initCalls.push(new RecordedInitCall(41, purpose, nonceLength, tagLength));
    return new SessionHandleRecord(41);
  }

  async updateSession(handle: number, options: HuksOptionsContract, token?: Uint8Array): Promise<ReturnResultRecord> {
    this.updateCalls.push(new RecordedUpdateCall(
      handle,
      options.inData?.length ?? 0,
      token?.length ?? 0
    ));
    if (this.updateCalls.length === 1) {
      return new ReturnResultRecord(new Uint8Array(0));
    }
    return new ReturnResultRecord(options.inData);
  }

  async finishSession(_: number, options: HuksOptionsContract): Promise<ReturnResultRecord> {
    if ((options.properties?.length ?? 0) > 0) {
      return new ReturnResultRecord(new Uint8Array(0));
    }
    if (this.updateCalls.length >= 2) {
      return new ReturnResultRecord(new Uint8Array(0));
    }
    const ciphertext = utf8Bytes('cipher');
    const tag = utf8Bytes('tag-16-byte-long');
    const merged = new Uint8Array(ciphertext.length + tag.length);
    for (let index = 0; index < ciphertext.length; index += 1) {
      merged[index] = ciphertext[index];
    }
    for (let index = 0; index < tag.length; index += 1) {
      merged[ciphertext.length + index] = tag[index];
    }
    return new ReturnResultRecord(merged);
  }

  async abortSession(_: number, __: HuksOptionsContract): Promise<void> {
    this.abortSessionCallCount += 1;
  }
}

class ScriptedNonceSource implements HuksRandomSource {
  private readonly nonce: Uint8Array;

  constructor(nonce: Uint8Array) {
    this.nonce = nonce;
  }

  nextNonce(_: number): Uint8Array {
    return this.nonce;
  }
}

function extractErrorDetail(error: Object | undefined): string {
  if (error === undefined) {
    return 'undefined';
  }
  if (typeof (error as Record<string, string>).detail === 'string') {
    return (error as Record<string, string>).detail;
  }
  if (typeof (error as Record<string, string>).message === 'string') {
    return (error as Record<string, string>).message;
  }
  return `${error}`;
}

async function expectSecretFailure(
  operation: () => Promise<void | string>,
  expectedCode: string,
  forbiddenFragments: string[]
): Promise<void> {
  try {
    await operation();
    expect(false).assertTrue();
  } catch (error) {
    expect(isSubscriptionSecretError(error as Object)).assertTrue();
    const record = error as Record<string, string>;
    expect(record.code).assertEqual(expectedCode);
    const detail: string = extractErrorDetail(error as Object);
    assertNoLeak(detail, forbiddenFragments);
  }
}

export default function huksSubscriptionSecretStoreTestsuite() {
  describe('HarmonyHuksDriverTest', () => {
    it('passesBusinessBytesViaInDataInsteadOfTheTokenArgument', 0, async () => {
      const operations = new ScriptedSessionOperations();
      const driver = new HarmonyHuksDriver(operations, new ScriptedNonceSource(utf8Bytes('nonce-value1')));

      const encrypted = await driver.encrypt(utf8Bytes('hello'));
      const decrypted = await driver.decrypt(encrypted);

      expect(operations.initCalls.length).assertEqual(2);
      expect(operations.initCalls[0].nonceLength).assertEqual(12);
      expect(operations.initCalls[0].tagLength).assertEqual(0);
      expect(operations.initCalls[1].tagLength).assertEqual(16);
      expect(operations.updateCalls.length).assertEqual(2);
      expect(operations.updateCalls[0].handle).assertEqual(41);
      expect(operations.updateCalls[0].inDataLength).assertEqual(5);
      expect(operations.updateCalls[0].tokenLength).assertEqual(0);
      expect(operations.updateCalls[1].inDataLength).assertEqual(encrypted.ciphertext.length);
      expect(operations.updateCalls[1].tokenLength).assertEqual(0);
      expect(decrypted.length).assertEqual(encrypted.ciphertext.length);
    });
  });

  describe('HuksSubscriptionSecretStoreTest', () => {
    it('encryptsIntoVersionedOpaqueEnvelopeWithFreshNonceAndUtf8RoundTrip', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      driver.seedNonce(utf8Bytes('nonce-value2'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      const idGenerator = new SequenceIdGenerator(['secret-alpha', 'tmp-a', 'secret-beta', 'tmp-b']);
      const store = new HuksSubscriptionSecretStore(driver, fileDriver, FILES_DIR, idGenerator);

      const firstRef = await store.encrypt(PLAINTEXT_URL);
      const secondRef = await store.encrypt('https://example.com/二次?密码=值');
      const decrypted = await store.decrypt(firstRef);

      expect(firstRef).assertEqual('secret-alpha');
      expect(secondRef).assertEqual('secret-beta');
      expect(decrypted).assertEqual(PLAINTEXT_URL);
      expect(driver.ensureKeyCallCount).assertEqual(3);
      expect(driver.generateKeyCallCount).assertEqual(1);
      expect(driver.encryptCalls.length).assertEqual(2);
      expect(driver.encryptCalls[0].nonceHex === driver.encryptCalls[1].nonceHex).assertFalse();

      const serialized = fileDriver.readFileText(`${SECRETS_DIR}/${firstRef}.json`);
      expect(serialized.includes('"version":1')).assertTrue();
      expect(serialized.includes('"nonce"')).assertTrue();
      expect(serialized.includes('"ciphertext"')).assertTrue();
      expect(serialized.includes('"tag"')).assertTrue();
      expect(serialized.includes('"keyAliasVersion":1')).assertTrue();
      assertNoLeak(serialized, [PLAINTEXT_URL, 'subscription', 'example.com/token']);
    });

    it('rejectsMissingTamperedAndUnsupportedEnvelopesWithoutLeakingSecrets', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp-a'])
      );

      const ref = await store.encrypt(PLAINTEXT_URL);
      const originalEnvelopeText: string = fileDriver.readFileText(`${SECRETS_DIR}/${ref}.json`);
      fileDriver.writeTextFile(`${SECRETS_DIR}/${ref}.json`, replaceEnvelopeNumberField(originalEnvelopeText, 'version', 2));
      await expectSecretFailure(
        async () => {
          await store.decrypt(ref);
        },
        'SOURCE_SECRET_VERSION_UNSUPPORTED',
        [ref, PLAINTEXT_URL]
      );

      fileDriver.writeTextFile(`${SECRETS_DIR}/${ref}.json`, replaceEnvelopeNumberField(originalEnvelopeText, 'keyAliasVersion', 2));
      await expectSecretFailure(
        async () => {
          await store.decrypt(ref);
        },
        'SOURCE_SECRET_VERSION_UNSUPPORTED',
        [ref, PLAINTEXT_URL]
      );

      fileDriver.writeTextFile(`${SECRETS_DIR}/${ref}.json`, replaceEnvelopeCiphertextByte(originalEnvelopeText));
      await expectSecretFailure(
        async () => {
          await store.decrypt(ref);
        },
        'SOURCE_DECRYPT_FAILED',
        [ref, PLAINTEXT_URL]
      );

      fileDriver.writeTextFile(`${SECRETS_DIR}/${ref}.json`, replaceEnvelopeTagByte(originalEnvelopeText));
      await expectSecretFailure(
        async () => {
          await store.decrypt(ref);
        },
        'SOURCE_DECRYPT_FAILED',
        [ref, PLAINTEXT_URL]
      );

      await expectSecretFailure(
        async () => {
          await store.decrypt('missing-secret');
        },
        'SOURCE_SECRET_MISSING',
        ['missing-secret', PLAINTEXT_URL]
      );
    });

    it('removeIsIdempotentAndReconcileCleansManagedTempsAndUnreferencedEnvelopesOnly', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      const idGenerator = new SequenceIdGenerator(['secret-alpha', 'tmp-a']);
      const store = new HuksSubscriptionSecretStore(driver, fileDriver, FILES_DIR, idGenerator);

      const ref = await store.encrypt(PLAINTEXT_URL);
      fileDriver.seedTextFile(`${SECRETS_DIR}/orphan.json`, '{"version":1,"nonce":"bm9uY2UtdmFsdWUtMDE=","ciphertext":"YQ==","tag":"YmJiYmJiYmJiYmJiYmJiYg==","keyAliasVersion":1}');
      fileDriver.seedTextFile(`${SECRETS_DIR}/corrupt.json`, '{');
      fileDriver.seedTextFile(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`, 'temp-envelope');
      fileDriver.seedTextFile(`${SECRETS_DIR}/keep.txt`, 'note');

      await store.remove('absent-secret');
      await store.remove(ref);
      await store.remove(ref);
      await store.reconcile([ref]);

      expect(fileDriver.fileExists(`${SECRETS_DIR}/${ref}.json`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/orphan.json`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/corrupt.json`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/keep.txt`)).assertTrue();
      expect(driver.deleteKeyCallCount).assertEqual(0);
    });

    it('rejectsInvalidRefsBeforeDeletionAndPreservesCorruptReferencedEnvelopeForLaterDecryptFailure', 0, async () => {
      const driver = new DeterministicHuksDriver();
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedTextFile(`${SECRETS_DIR}/referenced.json`, '{');
      fileDriver.seedTextFile(`${SECRETS_DIR}/stale.json`, '{"version":1,"nonce":"bm9uY2UtdmFsdWUtMDE=","ciphertext":"YQ==","tag":"YmJiYmJiYmJiYmJiYmJiYg==","keyAliasVersion":1}');
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp-a'])
      );

      await expectSecretFailure(
        async () => {
          await store.reconcile(['../escape']);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        ['../escape', 'referenced.json', 'stale.json']
      );
      expect(fileDriver.fileExists(`${SECRETS_DIR}/referenced.json`)).assertTrue();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/stale.json`)).assertTrue();

      await store.reconcile(['referenced']);
      expect(fileDriver.fileExists(`${SECRETS_DIR}/referenced.json`)).assertTrue();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/stale.json`)).assertFalse();

      await expectSecretFailure(
        async () => {
          await store.decrypt('referenced');
        },
        'SOURCE_DECRYPT_FAILED',
        ['referenced', PLAINTEXT_URL]
      );
    });

    it('doesNotOverwriteAnExistingOpaqueTargetAndCleansTheRealTemporaryEnvelope', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.seedTextFile(`${SECRETS_DIR}/secret-alpha.json`, '{"version":1,"nonce":"bm9uY2UtdmFsdWUtMDE=","ciphertext":"YQ==","tag":"YmJiYmJiYmJiYmJiYmJiYg==","keyAliasVersion":1}');
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp-a'])
      );

      await expectSecretFailure(
        async () => {
          await store.encrypt(PLAINTEXT_URL);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        ['secret-alpha', PLAINTEXT_URL]
      );

      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`)).assertFalse();
      expect(fileDriver.readFileText(`${SECRETS_DIR}/secret-alpha.json`).includes('"version":1')).assertTrue();
    });

    it('cleansTheActualUniqueTemporaryEnvelopeAfterAnInjectedWriteFailure', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.injectFailure('write', `${SECRETS_DIR}/secret-beta.tmp-b.tmp`, new Error('write failed /private/secret'));
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-beta', 'tmp-b'])
      );

      await expectSecretFailure(
        async () => {
          await store.encrypt(PLAINTEXT_URL);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        ['/private/secret', 'secret-beta', 'tmp-b', PLAINTEXT_URL]
      );

      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-beta.tmp-b.tmp`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-beta.json`)).assertFalse();
    });

    it('mapsInvalidGeneratedOpaqueAndTemporaryIdsToWriteFailuresWithoutLeakingTheRawIds', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);

      const invalidOpaqueStore = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['bad/id', 'tmp-a'])
      );
      await expectSecretFailure(
        async () => {
          await invalidOpaqueStore.encrypt(PLAINTEXT_URL);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        ['bad/id', PLAINTEXT_URL]
      );

      const invalidTempStore = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp/a'])
      );
      await expectSecretFailure(
        async () => {
          await invalidTempStore.encrypt(PLAINTEXT_URL);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        ['tmp/a', PLAINTEXT_URL]
      );
    });

    it('retriesPositiveShortWritesUntilTheEnvelopeIsFullyPersisted', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.scriptWriteCounts(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`, [5, 7]);
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp-a'])
      );

      const ref = await store.encrypt(PLAINTEXT_URL);
      const envelopeText = fileDriver.readFileText(`${SECRETS_DIR}/${ref}.json`);

      expect(ref).assertEqual('secret-alpha');
      expect(envelopeText.includes('"ciphertext"')).assertTrue();
    });

    it('failsClosedWhenAWriteReportsMoreBytesThanRequestedAndCleansTheTemporaryEnvelope', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      fileDriver.scriptWriteCounts(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`, [4096]);
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['secret-alpha', 'tmp-a'])
      );

      await expectSecretFailure(
        async () => {
          await store.encrypt(PLAINTEXT_URL);
        },
        'SOURCE_SECRET_WRITE_FAILED',
        [PLAINTEXT_URL, 'secret-alpha', 'tmp-a']
      );
      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-alpha.tmp-a.tmp`)).assertFalse();
      expect(fileDriver.fileExists(`${SECRETS_DIR}/secret-alpha.json`)).assertFalse();
    });

    it('keepsRepositoryFacingRefsPathsAndErrorsOpaqueFromPlaintextUrl', 0, async () => {
      const driver = new DeterministicHuksDriver();
      driver.seedNonce(utf8Bytes('nonce-value1'));
      const fileDriver = new FakeFileDriver();
      fileDriver.seedDirectory(FILES_DIR);
      const store = new HuksSubscriptionSecretStore(
        driver,
        fileDriver,
        FILES_DIR,
        new SequenceIdGenerator(['opaque-secret', 'tmp-a'])
      );

      const ref = await store.encrypt(PLAINTEXT_URL);
      const serialized = fileDriver.readFileText(`${SECRETS_DIR}/${ref}.json`);
      const allDriverCalls = driver.operationLog.join('\n');
      const allDriverMetadata = JSON.stringify(driver.encryptCalls);
      const allPaths = fileDriver.operationLog.join('\n');

      expect(ref).assertEqual('opaque-secret');
      assertNoLeak(ref, [PLAINTEXT_URL, 'example.com', 'subscription', 'token']);
      assertNoLeak(serialized, [PLAINTEXT_URL]);
      assertNoLeak(allPaths, [PLAINTEXT_URL]);
      assertNoLeak(allDriverCalls, [PLAINTEXT_URL]);
      assertNoLeak(allDriverMetadata, [PLAINTEXT_URL, '用户', '密钥', '秘密']);
    });
  });
}

function readNumberParam(properties: Array<HuksParamContract> | undefined, tag: number): number {
  if (properties === undefined) {
    return 0;
  }
  for (let index = 0; index < properties.length; index += 1) {
    const property = properties[index];
    if (property.tag === tag && typeof property.value === 'number') {
      return property.value;
    }
  }
  return 0;
}

function readBytesParamLength(properties: Array<HuksParamContract> | undefined, tag: number): number {
  if (properties === undefined) {
    return 0;
  }
  for (let index = 0; index < properties.length; index += 1) {
    const property = properties[index];
    if (property.tag === tag && property.value instanceof Uint8Array) {
      return property.value.length;
    }
  }
  return 0;
}
