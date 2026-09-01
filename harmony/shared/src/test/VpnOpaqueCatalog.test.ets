import { describe, expect, it } from '@ohos/hypium';
import {
  buildVpnOpaqueCatalog,
  type VpnCatalogGroupInput,
  type VpnCatalogGroupMemberInput,
  type VpnCatalogMemberInput,
  type VpnCatalogTerminalMemberInput,
  type VpnOpaqueCatalog,
  type VpnOpaqueCatalogEntry,
  type VpnOpaqueCatalogWireEntry,
  VpnOpaqueCatalogError,
  type VpnRpcCryptoPort
} from '../../Index';

const ROOT_KEY_HEX: string = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const PROFILE_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const REVISION_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const APPENDIX_A_CATALOG_SALT: string = '6ed74afc4b4442d50cb34e3d7d3dcf194f08eefcfe362d55d2d896572c9101ab';
const APPENDIX_A_GROUP_ID: string = 'f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a1';
const APPENDIX_A_NODE_ID: string = 'b0a8d82ab2b6e1ad9a5e2eccc169707e55492a94a5f346435864b66a78284757';
const APPENDIX_A_CATALOG_DIGEST: string = '439490f7d5c249e4568e736a9e7a0f45c674f6fb355adf8d61d82a1d0276f219';
const ROOT_PARENT_HEX: string =
  '0000000000000000000000000000000000000000000000000000000000000000';
const CATALOG_MISMATCH_CODE: string = 'CATALOG_MISMATCH';
const CATALOG_MISMATCH_RETRYABLE: boolean = false;
const APPENDIX_A_GROUP_NAME: string = 'Proxy';
const APPENDIX_A_NODE_NAME: string = 'HK';
const APPENDIX_A_CATALOG_SALT_INPUT_HEX: string =
  '434d46412d56504e2d5250432f434154414c4f472d53414c542f763100aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const APPENDIX_A_GROUP_ID_INPUT_HEX: string =
  '434d46412d56504e2d5250432f47524f55502d49442f7631000000000000000000000000000000000000000000000000000000000000000000000000000000000550726f7879000a';
const APPENDIX_A_NODE_ID_INPUT_HEX: string =
  '434d46412d56504e2d5250432f4e4f44452d49442f763100f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a10000000000000002484b0013';
const APPENDIX_A_DIGEST_INPUT_HEX: string =
  '434d46412d56504e2d5250432f434154414c4f472d4449474553542f763100000000020001000a0000000000000000000000000000000000000000000000000000000000000000000000000000f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a1000100020013000100000000f7a7aa5db9ab84e06fb3574ed2f710fc00aead954d247956fd0d482e90dec1a1b0a8d82ab2b6e1ad9a5e2eccc169707e55492a94a5f346435864b66a782847570001';

class FixtureCatalogGroup implements VpnCatalogGroupInput {
  name: string;
  type: string;
  members: VpnCatalogMemberInput[];

  constructor(name: string, type: string, members: VpnCatalogMemberInput[] = []) {
    this.name = name;
    this.type = type;
    this.members = members.slice();
  }

  replaceMembers(members: VpnCatalogMemberInput[]): FixtureCatalogGroup {
    this.members = members.slice();
    return this;
  }
}

class ThrowingCatalogGroupName implements VpnCatalogGroupInput {
  type: string;
  members: VpnCatalogMemberInput[];

  constructor(type: string, members: VpnCatalogMemberInput[]) {
    this.type = type;
    this.members = members.slice();
  }

  get name(): string {
    throw new Error('leak hostile-group-name');
  }
}

class ThrowingCatalogGroupType implements VpnCatalogGroupInput {
  name: string;
  members: VpnCatalogMemberInput[];

  constructor(name: string, members: VpnCatalogMemberInput[]) {
    this.name = name;
    this.members = members.slice();
  }

  get type(): string {
    throw new Error('leak hostile-group-type');
  }
}

class ThrowingCatalogGroupMembers implements VpnCatalogGroupInput {
  name: string;
  type: string;

  constructor(name: string, type: string) {
    this.name = name;
    this.type = type;
  }

  get members(): VpnCatalogMemberInput[] {
    throw new Error('leak hostile-group-members');
  }
}

class FixtureCatalogTerminalMember implements VpnCatalogTerminalMemberInput {
  readonly kind: 'TERMINAL' = 'TERMINAL';
  name: string;
  type: string;

  constructor(name: string, type: string) {
    this.name = name;
    this.type = type;
  }
}

class ThrowingCatalogMemberKind implements VpnCatalogGroupMemberInput {
  group: VpnCatalogGroupInput;

  constructor(group: VpnCatalogGroupInput) {
    this.group = group;
  }

  get kind(): 'GROUP' {
    throw new Error('leak hostile-member-kind');
  }
}

class FixtureCatalogGroupMember implements VpnCatalogGroupMemberInput {
  readonly kind: 'GROUP' = 'GROUP';
  group: VpnCatalogGroupInput;

  constructor(group: VpnCatalogGroupInput) {
    this.group = group;
  }
}

class ThrowingCatalogMemberGroup implements VpnCatalogGroupMemberInput {
  readonly kind: 'GROUP' = 'GROUP';

  get group(): VpnCatalogGroupInput {
    throw new Error('leak hostile-member-group');
  }
}

class ThrowingCatalogTerminalName implements VpnCatalogTerminalMemberInput {
  readonly kind: 'TERMINAL' = 'TERMINAL';
  type: string;

  constructor(type: string) {
    this.type = type;
  }

  get name(): string {
    throw new Error('leak hostile-terminal-name');
  }
}

class ThrowingCatalogTerminalType implements VpnCatalogTerminalMemberInput {
  readonly kind: 'TERMINAL' = 'TERMINAL';
  name: string;

  constructor(name: string) {
    this.name = name;
  }

  get type(): string {
    throw new Error('leak hostile-terminal-type');
  }
}

class FixtureCatalogCryptoMapping {
  readonly mode: 'root' | 'derived';
  readonly keyHex: string | null;
  readonly inputHex: string;
  readonly outputHex: string;

  constructor(mode: 'root' | 'derived', keyHex: string | null, inputHex: string, outputHex: string) {
    this.mode = mode;
    this.keyHex = keyHex;
    this.inputHex = inputHex;
    this.outputHex = outputHex;
  }
}

class FixtureDeferredDerivedCall {
  private readonly keyHex: string;
  private readonly inputHex: string;
  private readonly result: Uint8Array;
  private readonly promise: Promise<Uint8Array>;
  private resolver?: (value: Uint8Array) => void;

  constructor(keyHex: string, inputHex: string, result: Uint8Array) {
    this.keyHex = keyHex;
    this.inputHex = inputHex;
    this.result = result;
    this.promise = new Promise<Uint8Array>((resolve: (value: Uint8Array) => void) => {
      this.resolver = resolve;
    });
  }

  wait(): Promise<Uint8Array> {
    return this.promise;
  }

  release(): void {
    if (this.resolver === undefined) {
      throw new Error('Deferred derived call already released.');
    }
    const resolver: (value: Uint8Array) => void = this.resolver;
    this.resolver = undefined;
    resolver(this.result);
  }

  expectKeyHex(): string {
    return this.keyHex;
  }

  expectInputHex(): string {
    return this.inputHex;
  }
}

class FixtureCatalogCryptoPort implements VpnRpcCryptoPort {
  readonly prepareCalls: string[] = [];
  readonly rootInputsHex: string[] = [];
  readonly derivedCallHexes: string[] = [];
  readonly derivedInputsHex: string[] = [];
  readonly derivedKeyHexes: string[] = [];
  readonly derivedKeyRefs: Uint8Array[] = [];
  readonly deferredDerivedCalls: FixtureDeferredDerivedCall[] = [];
  readonly rootMappings: FixtureCatalogCryptoMapping[];
  readonly derivedMappings: FixtureCatalogCryptoMapping[];
  readonly deterministicTag: string;
  prepareError?: Error;
  rootHmacError?: Error;
  derivedHmacError?: Error;
  rootOutputLengthOverride?: number;
  derivedOutputLengthOverride?: number;
  deferredDerivedCallBudget: number = 0;

  constructor(
    rootMappings: FixtureCatalogCryptoMapping[] = [],
    derivedMappings: FixtureCatalogCryptoMapping[] = [],
    deterministicTag: string = 'fixture-root-key'
  ) {
    this.rootMappings = rootMappings.slice();
    this.derivedMappings = derivedMappings.slice();
    this.deterministicTag = deterministicTag;
  }

  async prepare(): Promise<void> {
    this.prepareCalls.push('prepare');
    if (this.prepareError !== undefined) {
      throw this.prepareError;
    }
  }

  async rootHmac(input: Uint8Array): Promise<Uint8Array> {
    const inputHex: string = bytesToHex(input);
    this.rootInputsHex.push(inputHex);
    if (this.rootHmacError !== undefined) {
      throw this.rootHmacError;
    }
    const mapping: FixtureCatalogCryptoMapping | undefined = this.findRootMapping(inputHex);
    const baseResult: Uint8Array = mapping === undefined
      ? createDeterministicDigest(joinBytes([asciiBytes(this.deterministicTag), input]))
      : hexToBytes(mapping.outputHex);
    return this.applyLengthOverride(baseResult, this.rootOutputLengthOverride);
  }

  async derivedHmac(key: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    const keyHex: string = bytesToHex(key);
    const inputHex: string = bytesToHex(input);
    this.derivedInputsHex.push(inputHex);
    this.derivedKeyHexes.push(keyHex);
    this.derivedKeyRefs.push(key);
    this.derivedCallHexes.push(`${keyHex}:${inputHex}`);
    if (this.derivedHmacError !== undefined) {
      throw this.derivedHmacError;
    }
    const mapping: FixtureCatalogCryptoMapping | undefined = this.findDerivedMapping(keyHex, inputHex);
    const baseResult: Uint8Array = mapping === undefined
      ? createDeterministicDigest(joinBytes([asciiBytes(this.deterministicTag), key, input]))
      : hexToBytes(mapping.outputHex);
    const returned: Uint8Array = this.applyLengthOverride(baseResult, this.derivedOutputLengthOverride);
    if (this.deferredDerivedCallBudget > 0) {
      this.deferredDerivedCallBudget -= 1;
      const deferredCall: FixtureDeferredDerivedCall = new FixtureDeferredDerivedCall(keyHex, inputHex, returned);
      this.deferredDerivedCalls.push(deferredCall);
      return deferredCall.wait();
    }
    return returned;
  }

  blockNextDerivedCalls(count: number): void {
    this.deferredDerivedCallBudget += count;
  }

  private applyLengthOverride(bytes: Uint8Array, expectedLength: number | undefined): Uint8Array {
    const copied: Uint8Array = bytes.slice();
    return expectedLength === undefined ? copied : copied.slice(0, expectedLength);
  }

  private findRootMapping(inputHex: string): FixtureCatalogCryptoMapping | undefined {
    for (let index: number = 0; index < this.rootMappings.length; index += 1) {
      const mapping: FixtureCatalogCryptoMapping = this.rootMappings[index];
      if (mapping.inputHex === inputHex) {
        return mapping;
      }
    }
    return undefined;
  }

  private findDerivedMapping(keyHex: string, inputHex: string): FixtureCatalogCryptoMapping | undefined {
    for (let index: number = 0; index < this.derivedMappings.length; index += 1) {
      const mapping: FixtureCatalogCryptoMapping = this.derivedMappings[index];
      if (mapping.keyHex === keyHex && mapping.inputHex === inputHex) {
        return mapping;
      }
    }
    return undefined;
  }
}

function asciiBytes(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let index: number = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index);
  }
  return bytes;
}

function joinBytes(parts: Uint8Array[]): Uint8Array {
  let totalLength: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    totalLength += parts[index].length;
  }
  const result: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  for (let index: number = 0; index < parts.length; index += 1) {
    result.set(parts[index], offset);
    offset += parts[index].length;
  }
  return result;
}

function bytesToHex(bytes: Uint8Array): string {
  const alphabet: string = '0123456789abcdef';
  let result: string = '';
  for (let index: number = 0; index < bytes.length; index += 1) {
    result += alphabet[(bytes[index] >>> 4) & 0x0f];
    result += alphabet[bytes[index] & 0x0f];
  }
  return result;
}

function decodeHexNibble(charCode: number): number {
  if (charCode >= 0x30 && charCode <= 0x39) {
    return charCode - 0x30;
  }
  if (charCode >= 0x61 && charCode <= 0x66) {
    return charCode - 0x61 + 10;
  }
  throw new Error('Invalid lowercase hex fixture.');
}

function hexToBytes(rawHex: string): Uint8Array {
  if ((rawHex.length & 1) !== 0) {
    throw new Error('Invalid lowercase hex fixture.');
  }
  const bytes: Uint8Array = new Uint8Array(rawHex.length / 2);
  for (let index: number = 0; index < rawHex.length; index += 2) {
    const high: number = decodeHexNibble(rawHex.charCodeAt(index));
    const low: number = decodeHexNibble(rawHex.charCodeAt(index + 1));
    bytes[index / 2] = (high << 4) | low;
  }
  return bytes;
}

function expectBytesZeroed(bytes: Uint8Array): void {
  for (let index: number = 0; index < bytes.length; index += 1) {
    if (bytes[index] !== 0) {
      throw new Error('Expected zeroized bytes.');
    }
  }
}

async function flushMicrotasks(turns: number = 4): Promise<void> {
  for (let index: number = 0; index < turns; index += 1) {
    await Promise.resolve();
  }
}

function createDeterministicDigest(seed: Uint8Array): Uint8Array {
  const result: Uint8Array = new Uint8Array(32);
  for (let index: number = 0; index < result.length; index += 1) {
    result[index] = ((index * 29) + 17) & 0xff;
  }
  for (let index: number = 0; index < seed.length; index += 1) {
    const cursor: number = index & 31;
    const mixed: number = (result[cursor] ^ seed[index] ^ ((index * 13) & 0xff)) & 0xff;
    result[cursor] = ((mixed + result[(cursor + 7) & 31] + cursor) & 0xff);
    result[(cursor + 11) & 31] = (result[(cursor + 11) & 31] ^ ((seed[index] + cursor + 19) & 0xff)) & 0xff;
  }
  return result;
}

function createAppendixACatalogFixture(): FixtureCatalogGroup {
  return new FixtureCatalogGroup(
    APPENDIX_A_GROUP_NAME,
    'Selector',
    [new FixtureCatalogTerminalMember(APPENDIX_A_NODE_NAME, 'Vmess')]
  );
}

function createAppendixACryptoPort(): FixtureCatalogCryptoPort {
  return new FixtureCatalogCryptoPort(
    [new FixtureCatalogCryptoMapping('root', null, APPENDIX_A_CATALOG_SALT_INPUT_HEX, APPENDIX_A_CATALOG_SALT)],
    [
      new FixtureCatalogCryptoMapping('derived', APPENDIX_A_CATALOG_SALT, APPENDIX_A_GROUP_ID_INPUT_HEX, APPENDIX_A_GROUP_ID),
      new FixtureCatalogCryptoMapping('derived', APPENDIX_A_CATALOG_SALT, APPENDIX_A_NODE_ID_INPUT_HEX, APPENDIX_A_NODE_ID),
      new FixtureCatalogCryptoMapping('derived', APPENDIX_A_CATALOG_SALT, APPENDIX_A_DIGEST_INPUT_HEX, APPENDIX_A_CATALOG_DIGEST)
    ],
    ROOT_KEY_HEX
  );
}

function createSharedPathFixture(): FixtureCatalogGroup[] {
  const sharedLeaf: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Shared',
    'Selector',
    [new FixtureCatalogTerminalMember('Tokyo', 'Trojan')]
  );
  const firstRoot: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Gateway',
    'Selector',
    [
      new FixtureCatalogGroupMember(sharedLeaf),
      new FixtureCatalogTerminalMember('Dup', 'Direct'),
      new FixtureCatalogTerminalMember('Dup', 'Reject')
    ]
  );
  const secondRoot: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Mirror',
    'Fallback',
    [new FixtureCatalogGroupMember(sharedLeaf)]
  );
  const thirdRoot: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Stable',
    'URLTest',
    [
      new FixtureCatalogTerminalMember('A', 'Vmess'),
      new FixtureCatalogTerminalMember('B', 'Trojan')
    ]
  );
  return [firstRoot, secondRoot, thirdRoot];
}

function createCycleFixture(): FixtureCatalogGroup[] {
  const root: FixtureCatalogGroup = new FixtureCatalogGroup('Cycle-A', 'Selector');
  const child: FixtureCatalogGroup = new FixtureCatalogGroup('Cycle-B', 'Fallback');
  root.replaceMembers([new FixtureCatalogGroupMember(child)]);
  child.replaceMembers([new FixtureCatalogGroupMember(root)]);
  return [root, child];
}

function createDepthChain(maxDepth: number): FixtureCatalogGroup[] {
  let current: FixtureCatalogGroup = new FixtureCatalogGroup(`Depth-${maxDepth}`, 'Selector', [
    new FixtureCatalogTerminalMember('Leaf', 'Direct')
  ]);
  for (let depth: number = maxDepth - 1; depth >= 0; depth -= 1) {
    current = new FixtureCatalogGroup(`Depth-${depth}`, 'Selector', [new FixtureCatalogGroupMember(current)]);
  }
  return [current];
}

function createEntryLimitFixture(entryCount: number): FixtureCatalogGroup[] {
  const members: VpnCatalogMemberInput[] = [];
  for (let index: number = 0; index < entryCount - 1; index += 1) {
    members.push(new FixtureCatalogTerminalMember(`Node-${index}`, 'Direct'));
  }
  return [new FixtureCatalogGroup('Many', 'Selector', members)];
}

function createToctouFixture(): FixtureCatalogGroup[] {
  const originalNested: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Original-Nested',
    'Selector',
    [new FixtureCatalogTerminalMember('Original-Leaf', 'Trojan')]
  );
  const replacementNested: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Replacement-Nested',
    'Fallback',
    [new FixtureCatalogTerminalMember('Replacement-Leaf', 'Direct')]
  );
  const root: FixtureCatalogGroup = new FixtureCatalogGroup(
    'Mutable-Root',
    'Selector',
    [
      new FixtureCatalogGroupMember(originalNested),
      new FixtureCatalogTerminalMember('Stable-Leaf', 'Vmess')
    ]
  );
  return [root, originalNested, replacementNested];
}

async function expectCatalogMismatch(
  runner: () => Promise<VpnOpaqueCatalog>,
  forbiddenFragments: string[] = []
): Promise<void> {
  let failure: VpnOpaqueCatalogError | undefined = undefined;
  try {
    await runner();
  } catch (error) {
    if (error instanceof VpnOpaqueCatalogError) {
      failure = error;
    } else {
      throw new Error('Expected a VpnOpaqueCatalogError instance.');
    }
  }
  if (failure === undefined) {
    throw new Error('Expected VpnOpaqueCatalogError.');
  }
  expect(failure.code).assertEqual(CATALOG_MISMATCH_CODE);
  expect(failure.retryable).assertEqual(CATALOG_MISMATCH_RETRYABLE);
  for (let index: number = 0; index < forbiddenFragments.length; index += 1) {
    expect(String(failure).includes(forbiddenFragments[index])).assertFalse();
    expect((failure.message).includes(forbiddenFragments[index])).assertFalse();
  }
}

async function buildCatalog(
  crypto: VpnRpcCryptoPort,
  groups: VpnCatalogGroupInput[],
  profileHash: string = PROFILE_HASH,
  revisionHash: string = REVISION_HASH
): Promise<VpnOpaqueCatalog> {
  return buildVpnOpaqueCatalog(crypto, profileHash, revisionHash, groups);
}

function requireEntry(catalog: VpnOpaqueCatalog, id: string): VpnOpaqueCatalogEntry {
  const entry: VpnOpaqueCatalogEntry | undefined = catalog.resolveEntry(id);
  if (entry === undefined) {
    throw new Error('Expected catalog entry.');
  }
  return entry;
}

function requireTopLevelEntry(catalog: VpnOpaqueCatalog, index: number): VpnOpaqueCatalogEntry {
  const ids: string[] = catalog.topLevelGroupIds();
  const id: string | undefined = ids[index];
  if (id === undefined) {
    throw new Error('Missing top level entry.');
  }
  return requireEntry(catalog, id);
}

export default function vpnOpaqueCatalogTestsuite() {
  describe('VpnOpaqueCatalogTest', () => {
    it('pinsAppendixAGoldenVectorsAndHidesRawNamesFromWireAndDigestViews', 0, async () => {
      const crypto: FixtureCatalogCryptoPort = createAppendixACryptoPort();

      const catalog: VpnOpaqueCatalog = await buildCatalog(crypto, [createAppendixACatalogFixture()]);
      const wireEntries: VpnOpaqueCatalogWireEntry[] = catalog.wireEntries();
      const firstTopLevelId: string = catalog.topLevelGroupIds()[0];
      const topLevelEntry: VpnOpaqueCatalogEntry = requireEntry(catalog, firstTopLevelId);
      const childEntry: VpnOpaqueCatalogEntry = requireEntry(catalog, topLevelEntry.childIds[0]);
      const wireJson: string = JSON.stringify(wireEntries);
      const digestInputHex: string = crypto.derivedInputsHex[crypto.derivedInputsHex.length - 1];

      expect(crypto.prepareCalls.length).assertEqual(1);
      expect(crypto.rootInputsHex[0]).assertEqual(APPENDIX_A_CATALOG_SALT_INPUT_HEX);
      expect(crypto.derivedCallHexes[0]).assertEqual(`${APPENDIX_A_CATALOG_SALT}:${APPENDIX_A_GROUP_ID_INPUT_HEX}`);
      expect(crypto.derivedCallHexes[1]).assertEqual(`${APPENDIX_A_CATALOG_SALT}:${APPENDIX_A_NODE_ID_INPUT_HEX}`);
      expect(crypto.derivedCallHexes[2]).assertEqual(`${APPENDIX_A_CATALOG_SALT}:${APPENDIX_A_DIGEST_INPUT_HEX}`);
      expect(catalog.catalogDigest).assertEqual(APPENDIX_A_CATALOG_DIGEST);
      expect(catalog.entryCount).assertEqual(2);
      expect(firstTopLevelId).assertEqual(APPENDIX_A_GROUP_ID);
      expect(topLevelEntry.parentId).assertEqual(ROOT_PARENT_HEX);
      expect(topLevelEntry.kind).assertEqual('GROUP');
      expect(topLevelEntry.type).assertEqual('Selector');
      expect(catalog.resolveLocalName(APPENDIX_A_GROUP_ID)).assertEqual(APPENDIX_A_GROUP_NAME);
      expect(childEntry.id).assertEqual(APPENDIX_A_NODE_ID);
      expect(childEntry.parentId).assertEqual(APPENDIX_A_GROUP_ID);
      expect(childEntry.kind).assertEqual('TERMINAL');
      expect(childEntry.type).assertEqual('Vmess');
      expect(catalog.resolveLocalName(APPENDIX_A_NODE_ID)).assertEqual(APPENDIX_A_NODE_NAME);
      expect(wireEntries.length).assertEqual(2);
      expect(wireEntries[0].id).assertEqual(APPENDIX_A_GROUP_ID);
      expect(wireEntries[1].id).assertEqual(APPENDIX_A_NODE_ID);
      expect(wireJson.includes(APPENDIX_A_GROUP_NAME)).assertFalse();
      expect(wireJson.includes(APPENDIX_A_NODE_NAME)).assertFalse();
      expect(digestInputHex).assertEqual(APPENDIX_A_DIGEST_INPUT_HEX);
      expect(digestInputHex.includes('50726f7879')).assertFalse();
      expect(digestInputHex.includes('484b')).assertFalse();
      expect(crypto.derivedKeyRefs.length).assertEqual(3);
      for (let index: number = 0; index < crypto.derivedKeyRefs.length; index += 1) {
        expectBytesZeroed(crypto.derivedKeyRefs[index]);
      }
    });

    it('retainsValidatedProfileAndRevisionHashesAsReadonlyMetadata', 0, async () => {
      const catalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), [createAppendixACatalogFixture()]);
      const snapshotProfileHash: string = catalog.profileHash;
      const snapshotRevisionHash: string = catalog.revisionHash;
      const wireEntries: VpnOpaqueCatalogWireEntry[] = catalog.wireEntries();

      wireEntries[0].id = PROFILE_HASH.replace(/1/g, '9');

      expect(catalog.profileHash).assertEqual(snapshotProfileHash);
      expect(catalog.revisionHash).assertEqual(snapshotRevisionHash);
      expect(catalog.profileHash).assertEqual(PROFILE_HASH);
      expect(catalog.revisionHash).assertEqual(REVISION_HASH);
      expect(JSON.stringify(catalog.wireEntries()).includes(PROFILE_HASH)).assertFalse();
      expect(JSON.stringify(catalog.wireEntries()).includes(REVISION_HASH)).assertFalse();
    });

    it('assignsPathAwareIdsKeepsStableDepthFirstOrderAndReturnsCopiedLookupViews', 0, async () => {
      const crypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();
      const catalog: VpnOpaqueCatalog = await buildCatalog(crypto, createSharedPathFixture());
      const topLevelIdsA: string[] = catalog.topLevelGroupIds();
      const topLevelIdsB: string[] = catalog.topLevelGroupIds();
      const firstRoot: VpnOpaqueCatalogEntry = requireEntry(catalog, topLevelIdsA[0]);
      const secondRoot: VpnOpaqueCatalogEntry = requireEntry(catalog, topLevelIdsA[1]);
      const thirdRoot: VpnOpaqueCatalogEntry = requireEntry(catalog, topLevelIdsA[2]);
      const sharedFromFirst: VpnOpaqueCatalogEntry = requireEntry(catalog, firstRoot.childIds[0]);
      const sharedFromSecond: VpnOpaqueCatalogEntry = requireEntry(catalog, secondRoot.childIds[0]);
      const duplicateFirst: VpnOpaqueCatalogEntry = requireEntry(catalog, firstRoot.childIds[1]);
      const duplicateSecond: VpnOpaqueCatalogEntry = requireEntry(catalog, firstRoot.childIds[2]);
      const firstWire: VpnOpaqueCatalogWireEntry[] = catalog.wireEntries();
      const secondWire: VpnOpaqueCatalogWireEntry[] = catalog.wireEntries();
      const sharedFirstAgain: VpnOpaqueCatalogEntry = requireEntry(catalog, sharedFromFirst.id);
      const sharedSecondAgain: VpnOpaqueCatalogEntry = requireEntry(catalog, sharedFromSecond.id);

      expect(topLevelIdsA.length).assertEqual(3);
      expect((topLevelIdsA === topLevelIdsB)).assertFalse();
      expect(firstRoot.depth).assertEqual(0);
      expect(secondRoot.depth).assertEqual(0);
      expect(thirdRoot.depth).assertEqual(0);
      expect(catalog.resolveLocalName(firstRoot.id)).assertEqual('Gateway');
      expect(catalog.resolveLocalName(secondRoot.id)).assertEqual('Mirror');
      expect(catalog.resolveLocalName(thirdRoot.id)).assertEqual('Stable');
      expect(sharedFromFirst.id === sharedFromSecond.id).assertFalse();
      expect(catalog.resolveLocalName(sharedFromFirst.id)).assertEqual('Shared');
      expect(catalog.resolveLocalName(sharedFromSecond.id)).assertEqual('Shared');
      expect(sharedFromFirst.childIds.length).assertEqual(1);
      expect(sharedFromSecond.childIds.length).assertEqual(1);
      expect(catalog.resolveLocalName(sharedFromFirst.childIds[0])).assertEqual('Tokyo');
      expect(catalog.resolveLocalName(sharedFromSecond.childIds[0])).assertEqual('Tokyo');
      expect(duplicateFirst.id === duplicateSecond.id).assertFalse();
      expect(duplicateFirst.memberIndex).assertEqual(1);
      expect(duplicateSecond.memberIndex).assertEqual(2);
      expect(catalog.resolveLocalName(duplicateFirst.id)).assertEqual('Dup');
      expect(catalog.resolveLocalName(duplicateSecond.id)).assertEqual('Dup');
      expect(firstWire.length).assertEqual(catalog.entryCount);
      expect(firstWire[0].id).assertEqual(firstRoot.id);
      expect(firstWire[1].id).assertEqual(sharedFromFirst.id);
      expect(firstWire[2].id).assertEqual(sharedFromFirst.childIds[0]);
      expect(firstWire[3].id).assertEqual(duplicateFirst.id);
      expect(firstWire[4].id).assertEqual(duplicateSecond.id);
      expect(firstWire[5].id).assertEqual(secondRoot.id);
      expect(firstWire[6].id).assertEqual(sharedFromSecond.id);
      expect(firstWire[7].id).assertEqual(sharedFromSecond.childIds[0]);
      expect(firstWire[8].id).assertEqual(thirdRoot.id);
      expect((firstWire === secondWire)).assertFalse();
      expect((firstWire[0] === secondWire[0])).assertFalse();
      expect((sharedFromFirst === sharedFirstAgain)).assertFalse();
      expect((sharedFromFirst.childIds === sharedFirstAgain.childIds)).assertFalse();
      expect((sharedFromSecond === sharedSecondAgain)).assertFalse();
      expect(JSON.stringify(firstWire).includes('Gateway')).assertFalse();
      expect(JSON.stringify(firstWire).includes('Shared')).assertFalse();
      expect(JSON.stringify(firstWire).includes('Tokyo')).assertFalse();
    });

    it('changesIdsAndDigestAcrossRootKeyRevisionProfileNameTypeParentAndMemberIndex', 0, async () => {
      const baseGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Proxy', 'Selector', [
        new FixtureCatalogTerminalMember('Node', 'Vmess')
      ])];
      const renamedGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Proxy-2', 'Selector', [
        new FixtureCatalogTerminalMember('Node', 'Vmess')
      ])];
      const retypedGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Proxy', 'Fallback', [
        new FixtureCatalogTerminalMember('Node', 'Vmess')
      ])];
      const cryptoA: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort([], [], 'root-key-A');
      const cryptoB: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort([], [], 'root-key-B');
      const baseCatalog: VpnOpaqueCatalog = await buildCatalog(cryptoA, baseGroups);
      const otherKeyCatalog: VpnOpaqueCatalog = await buildCatalog(cryptoB, baseGroups);
      const otherProfileCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), baseGroups, PROFILE_HASH.replace(/a/g, 'c'), REVISION_HASH);
      const otherRevisionCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), baseGroups, PROFILE_HASH, REVISION_HASH.replace(/b/g, 'd'));
      const renamedCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), renamedGroups);
      const retypedCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), retypedGroups);
      const pathCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), createSharedPathFixture());
      const firstRoot: VpnOpaqueCatalogEntry = requireTopLevelEntry(pathCatalog, 0);
      const secondRoot: VpnOpaqueCatalogEntry = requireTopLevelEntry(pathCatalog, 1);
      const firstShared: VpnOpaqueCatalogEntry = requireEntry(pathCatalog, firstRoot.childIds[0]);
      const secondShared: VpnOpaqueCatalogEntry = requireEntry(pathCatalog, secondRoot.childIds[0]);
      const duplicateFirst: VpnOpaqueCatalogEntry = requireEntry(pathCatalog, firstRoot.childIds[1]);
      const duplicateSecond: VpnOpaqueCatalogEntry = requireEntry(pathCatalog, firstRoot.childIds[2]);

      expect(baseCatalog.topLevelGroupIds()[0] === otherKeyCatalog.topLevelGroupIds()[0]).assertFalse();
      expect(baseCatalog.catalogDigest === otherKeyCatalog.catalogDigest).assertFalse();
      expect(baseCatalog.catalogDigest === otherProfileCatalog.catalogDigest).assertFalse();
      expect(baseCatalog.catalogDigest === otherRevisionCatalog.catalogDigest).assertFalse();
      expect(baseCatalog.topLevelGroupIds()[0] === renamedCatalog.topLevelGroupIds()[0]).assertFalse();
      expect(baseCatalog.topLevelGroupIds()[0] === retypedCatalog.topLevelGroupIds()[0]).assertFalse();
      expect(firstShared.id === secondShared.id).assertFalse();
      expect(duplicateFirst.id === duplicateSecond.id).assertFalse();
    });

    it('enforcesDepthAndEntryCountBoundsWithoutReturningPartialCatalogs', 0, async () => {
      const depth16Catalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), createDepthChain(15));
      const largeCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), createEntryLimitFixture(4096));

      expect(depth16Catalog.entryCount).assertEqual(17);
      expect(largeCatalog.entryCount).assertEqual(4096);
      expect(largeCatalog.wireEntries().length).assertEqual(4096);

      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), createDepthChain(16)));
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), createEntryLimitFixture(4097)));
    });

    it('emitsCycleEdgesAsUnsupportedTerminalNodesAndDoesNotMisclassifySharedSiblings', 0, async () => {
      const cycleRoot: FixtureCatalogGroup = new FixtureCatalogGroup('Cycle-A', 'Selector');
      const cycleChild: FixtureCatalogGroup = new FixtureCatalogGroup('Cycle-B', 'Fallback');
      cycleRoot.replaceMembers([new FixtureCatalogGroupMember(cycleChild)]);
      cycleChild.replaceMembers([new FixtureCatalogGroupMember(cycleRoot)]);

      const catalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), [cycleRoot]);
      const topLevel: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const child: VpnOpaqueCatalogEntry = requireEntry(catalog, topLevel.childIds[0]);
      const cycleEdge: VpnOpaqueCatalogEntry = requireEntry(catalog, child.childIds[0]);
      const wireCycle: VpnOpaqueCatalogWireEntry = catalog.wireEntries()[2];
      const sharedCatalog: VpnOpaqueCatalog = await buildCatalog(new FixtureCatalogCryptoPort(), createSharedPathFixture());
      const sharedFirst: VpnOpaqueCatalogEntry = requireEntry(sharedCatalog, requireTopLevelEntry(sharedCatalog, 0).childIds[0]);
      const sharedSecond: VpnOpaqueCatalogEntry = requireEntry(sharedCatalog, requireTopLevelEntry(sharedCatalog, 1).childIds[0]);

      expect(catalog.entryCount).assertEqual(3);
      expect(cycleEdge.kind).assertEqual('TERMINAL');
      expect(cycleEdge.edgeState).assertEqual('CYCLE_UNSUPPORTED');
      expect(cycleEdge.depth).assertEqual(2);
      expect(cycleEdge.type).assertEqual('Selector');
      expect(cycleEdge.childIds.length).assertEqual(0);
      expect(catalog.resolveLocalName(cycleEdge.id)).assertEqual('Cycle-A');
      expect(wireCycle.kind).assertEqual('TERMINAL');
      expect(wireCycle.edgeState).assertEqual('CYCLE_UNSUPPORTED');
      expect(sharedFirst.edgeState).assertEqual('NORMAL');
      expect(sharedSecond.edgeState).assertEqual('NORMAL');
    });

    it('failsClosedForUnknownTypesBadHashesBadLabelsAndHmacProblemsWithoutLeakingInputs', 0, async () => {
      const rawLeakName: string = 'Leak\x00Name';
      const longName: string = `${'x'.repeat(300)}-too-long`;
      const unknownTypeGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Proxy', 'UnknownType', [])];
      const badHashGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Proxy', 'Selector', [])];
      const badTrimmedGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('   ', 'Selector', [])];
      const nulGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup(rawLeakName, 'Selector', [])];
      const controlGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup('Bad\u0007Name', 'Selector', [])];
      const longGroups: VpnCatalogGroupInput[] = [new FixtureCatalogGroup(longName, 'Selector', [])];
      const wrongRootLengthCrypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();
      const wrongDerivedLengthCrypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();
      const throwingRootCrypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();
      const throwingDerivedCrypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();

      wrongRootLengthCrypto.rootOutputLengthOverride = 31;
      wrongDerivedLengthCrypto.derivedOutputLengthOverride = 31;
      throwingRootCrypto.rootHmacError = new Error(`root leak ${PROFILE_HASH}`);
      throwingDerivedCrypto.derivedHmacError = new Error(`derived leak ${REVISION_HASH}`);

      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), unknownTypeGroups));
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), badHashGroups, 'ABCDEF', REVISION_HASH), ['ABCDEF']);
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), badTrimmedGroups), ['   ']);
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), nulGroups), [rawLeakName]);
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), controlGroups), ['Bad\u0007Name']);
      await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), longGroups), [longName]);
      await expectCatalogMismatch(() => buildCatalog(wrongRootLengthCrypto, [createAppendixACatalogFixture()]), [PROFILE_HASH, REVISION_HASH]);
      await expectCatalogMismatch(() => buildCatalog(wrongDerivedLengthCrypto, [createAppendixACatalogFixture()]), [PROFILE_HASH, REVISION_HASH]);
      await expectCatalogMismatch(() => buildCatalog(throwingRootCrypto, [createAppendixACatalogFixture()]), [PROFILE_HASH, REVISION_HASH]);
      await expectCatalogMismatch(() => buildCatalog(throwingDerivedCrypto, [createAppendixACatalogFixture()]), [PROFILE_HASH, REVISION_HASH]);
    });

    it('failsClosedForHostileGettersWithoutLeakingRawMessagesAcrossGroupAndMemberFields', 0, async () => {
      const cases: VpnCatalogGroupInput[][] = [
        [new ThrowingCatalogGroupName('Selector', [])],
        [new ThrowingCatalogGroupType('Proxy', [])],
        [new ThrowingCatalogGroupMembers('Proxy', 'Selector')],
        [new FixtureCatalogGroup('Proxy', 'Selector', [new ThrowingCatalogMemberKind(createAppendixACatalogFixture())])],
        [new FixtureCatalogGroup('Proxy', 'Selector', [new ThrowingCatalogMemberGroup()])],
        [new FixtureCatalogGroup('Proxy', 'Selector', [new ThrowingCatalogTerminalName('Vmess')])],
        [new FixtureCatalogGroup('Proxy', 'Selector', [new ThrowingCatalogTerminalType('HK')])]
      ];
      const forbiddenFragments: string[] = [
        'leak hostile-group-name',
        'leak hostile-group-type',
        'leak hostile-group-members',
        'leak hostile-member-kind',
        'leak hostile-member-group',
        'leak hostile-terminal-name',
        'leak hostile-terminal-type'
      ];

      for (let index: number = 0; index < cases.length; index += 1) {
        await expectCatalogMismatch(() => buildCatalog(new FixtureCatalogCryptoPort(), cases[index]), forbiddenFragments);
      }
    });

    it('snapshotsTheExternalGraphBeforeAnyAwaitSoDeferredCryptoDoesNotObserveLaterMutations', 0, async () => {
      const fixture: FixtureCatalogGroup[] = createToctouFixture();
      const root: FixtureCatalogGroup = fixture[0];
      const originalNested: FixtureCatalogGroup = fixture[1];
      const replacementNested: FixtureCatalogGroup = fixture[2];
      const crypto: FixtureCatalogCryptoPort = new FixtureCatalogCryptoPort();
      crypto.blockNextDerivedCalls(1);

      const buildPromise: Promise<VpnOpaqueCatalog> = buildCatalog(crypto, [root]);
      await flushMicrotasks();

      expect(crypto.deferredDerivedCalls.length).assertEqual(1);
      root.replaceMembers([
        new FixtureCatalogGroupMember(replacementNested),
        new FixtureCatalogTerminalMember('Mutated-Leaf', 'Reject'),
        new FixtureCatalogTerminalMember('Late-Leaf', 'Direct')
      ]);
      originalNested.replaceMembers([new FixtureCatalogTerminalMember('Mutated-Nested-Leaf', 'Http')]);
      crypto.deferredDerivedCalls[0].release();

      const catalog: VpnOpaqueCatalog = await buildPromise;
      const rootEntry: VpnOpaqueCatalogEntry = requireTopLevelEntry(catalog, 0);
      const nestedEntry: VpnOpaqueCatalogEntry = requireEntry(catalog, rootEntry.childIds[0]);
      const nestedLeafEntry: VpnOpaqueCatalogEntry = requireEntry(catalog, nestedEntry.childIds[0]);
      const stableLeafEntry: VpnOpaqueCatalogEntry = requireEntry(catalog, rootEntry.childIds[1]);
      const wireJson: string = JSON.stringify(catalog.wireEntries());

      expect(rootEntry.childIds.length).assertEqual(2);
      expect(catalog.resolveLocalName(nestedEntry.id)).assertEqual('Original-Nested');
      expect(catalog.resolveLocalName(nestedLeafEntry.id)).assertEqual('Original-Leaf');
      expect(nestedLeafEntry.type).assertEqual('Trojan');
      expect(catalog.resolveLocalName(stableLeafEntry.id)).assertEqual('Stable-Leaf');
      expect(wireJson.includes('Mutated-Leaf')).assertFalse();
      expect(wireJson.includes('Late-Leaf')).assertFalse();
      expect(wireJson.includes('Replacement-Nested')).assertFalse();
      expect(wireJson.includes('Mutated-Nested-Leaf')).assertFalse();
      expect(catalog.resolveLocalName(rootEntry.childIds[0])).assertEqual('Original-Nested');
      expect(catalog.resolveLocalName(rootEntry.childIds[1])).assertEqual('Stable-Leaf');
    });
  });
}
