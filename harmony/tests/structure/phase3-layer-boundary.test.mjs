import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const SHARED_ETS_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const MODULE_TEST_ROOTS = [
  ['shared', path.join(HARMONY_ROOT, 'shared', 'src', 'test')],
  ['platform', path.join(HARMONY_ROOT, 'platform', 'src', 'test')],
  ['entry', path.join(HARMONY_ROOT, 'entry', 'src', 'test')]
];
const HARMONY_DRIVER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'rdb', 'HarmonyRdbDriver.ets');
const SUBSCRIPTION_DOWNLOADER_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'source', 'SubscriptionDownloader.ets');
const HTTP_TRANSPORT_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'source', 'HttpTransport.ets');
const NETWORK_KIT_TRANSPORT_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'source', 'NetworkKitHttpTransport.ets');
const REQUEST_AGENT_TRANSPORT_PATH = path.join(HARMONY_ROOT, 'platform', 'src', 'main', 'ets', 'source', 'RequestAgentRedirectTransport.ets');

async function readJson(relativePath) {
  return JSON.parse(await fs.readFile(path.join(HARMONY_ROOT, relativePath), 'utf8'));
}

async function collectFiles(rootDir) {
  const entries = await fs.readdir(rootDir, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const absolutePath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      return await collectFiles(absolutePath);
    }
    if (entry.isFile()) {
      return [absolutePath];
    }
    return [];
  }));
  return files.flat().sort();
}

function isIdentifierBoundaryChar(character) {
  return !/[A-Za-z0-9_$]/u.test(character ?? '');
}

function skipWhitespace(source, index) {
  let current = index;
  while (current < source.length && /\s/u.test(source[current])) {
    current += 1;
  }
  return current;
}

function skipTrivia(source, index) {
  let current = index;
  while (current < source.length) {
    const next = skipWhitespace(source, current);
    if (next !== current) {
      current = next;
      continue;
    }
    if (source[current] === '/' && source[current + 1] === '/') {
      current = skipLineComment(source, current);
      continue;
    }
    if (source[current] === '/' && source[current + 1] === '*') {
      current = skipBlockComment(source, current);
      continue;
    }
    break;
  }
  return current;
}

function skipLineComment(source, index) {
  let current = index + 2;
  while (current < source.length && source[current] !== '\n') {
    current += 1;
  }
  return current;
}

function skipBlockComment(source, index) {
  let current = index + 2;
  while (current < source.length - 1) {
    if (source[current] === '*' && source[current + 1] === '/') {
      return current + 2;
    }
    current += 1;
  }
  return source.length;
}

function skipQuotedLiteral(source, index) {
  const quote = source[index];
  let current = index + 1;
  while (current < source.length) {
    const character = source[current];
    if (character === '\\') {
      current += 2;
      continue;
    }
    if (quote === '`' && character === '$' && source[current + 1] === '{') {
      current += 2;
      let depth = 1;
      while (current < source.length && depth > 0) {
        if (source[current] === '/' && source[current + 1] === '/') {
          current = skipLineComment(source, current);
          continue;
        }
        if (source[current] === '/' && source[current + 1] === '*') {
          current = skipBlockComment(source, current);
          continue;
        }
        if (source[current] === '\'' || source[current] === '"' || source[current] === '`') {
          current = skipQuotedLiteral(source, current);
          continue;
        }
        if (source[current] === '{') {
          depth += 1;
        } else if (source[current] === '}') {
          depth -= 1;
        }
        current += 1;
      }
      continue;
    }
    if (character === quote) {
      return current + 1;
    }
    current += 1;
  }
  return source.length;
}

function readQuotedSpecifier(source, index) {
  const quote = source[index];
  if (quote !== '\'' && quote !== '"') {
    return null;
  }
  let current = index + 1;
  let specifier = '';
  while (current < source.length) {
    const character = source[current];
    if (character === '\\') {
      specifier += source.slice(current, current + 2);
      current += 2;
      continue;
    }
    if (character === quote) {
      return {
        specifier,
        end: current + 1
      };
    }
    specifier += character;
    current += 1;
  }
  return null;
}

function readStaticImportSpecifier(source, index) {
  let current = skipTrivia(source, index);
  if (source[current] === '(') {
    return { specifier: null, end: current + 1 };
  }
  const directSpecifier = readQuotedSpecifier(source, current);
  if (directSpecifier) {
    return directSpecifier;
  }

  let depth = 0;
  while (current < source.length) {
    if (source[current] === '/' && source[current + 1] === '/') {
      current = skipLineComment(source, current);
      continue;
    }
    if (source[current] === '/' && source[current + 1] === '*') {
      current = skipBlockComment(source, current);
      continue;
    }
    if (source[current] === '\'' || source[current] === '"' || source[current] === '`') {
      current = skipQuotedLiteral(source, current);
      continue;
    }
    if (source[current] === '{' || source[current] === '[' || source[current] === '(') {
      depth += 1;
      current += 1;
      continue;
    }
    if (source[current] === '}' || source[current] === ']' || source[current] === ')') {
      depth = Math.max(0, depth - 1);
      current += 1;
      continue;
    }
    if (
      depth === 0 &&
      source.slice(current, current + 4) === 'from' &&
      isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 4])
    ) {
      current = skipTrivia(source, current + 4);
      return readQuotedSpecifier(source, current) ?? { specifier: null, end: current };
    }
    if (depth === 0 && source[current] === ';') {
      break;
    }
    current += 1;
  }
  return { specifier: null, end: current };
}

function readStaticExportSpecifier(source, index) {
  let current = skipTrivia(source, index);
  if (source[current] !== '*' && source[current] !== '{') {
    return { specifier: null, end: current + 1 };
  }

  let depth = 0;
  while (current < source.length) {
    if (source[current] === '/' && source[current + 1] === '/') {
      current = skipLineComment(source, current);
      continue;
    }
    if (source[current] === '/' && source[current + 1] === '*') {
      current = skipBlockComment(source, current);
      continue;
    }
    if (source[current] === '\'' || source[current] === '"' || source[current] === '`') {
      current = skipQuotedLiteral(source, current);
      continue;
    }
    if (source[current] === '{' || source[current] === '[' || source[current] === '(') {
      depth += 1;
      current += 1;
      continue;
    }
    if (source[current] === '}' || source[current] === ']' || source[current] === ')') {
      depth = Math.max(0, depth - 1);
      current += 1;
      continue;
    }
    if (
      depth === 0 &&
      source.slice(current, current + 4) === 'from' &&
      isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 4])
    ) {
      current = skipTrivia(source, current + 4);
      return readQuotedSpecifier(source, current) ?? { specifier: null, end: current };
    }
    if (depth === 0 && source[current] === ';') {
      break;
    }
    current += 1;
  }
  return { specifier: null, end: current };
}

function extractStaticModuleSpecifiers(source) {
  const specifiers = [];
  let current = 0;

  while (current < source.length) {
    if (source[current] === '/' && source[current + 1] === '/') {
      current = skipLineComment(source, current);
      continue;
    }
    if (source[current] === '/' && source[current + 1] === '*') {
      current = skipBlockComment(source, current);
      continue;
    }
    if (source[current] === '\'' || source[current] === '"' || source[current] === '`') {
      current = skipQuotedLiteral(source, current);
      continue;
    }

    if (
      source.slice(current, current + 6) === 'import' &&
      isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 6])
    ) {
      const { specifier, end } = readStaticImportSpecifier(source, skipTrivia(source, current + 6));
      if (specifier) {
        specifiers.push(specifier);
      }
      current = Math.max(end, current + 6);
      continue;
    }

    if (
      source.slice(current, current + 6) === 'export' &&
      isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 6])
    ) {
      const { specifier, end } = readStaticExportSpecifier(source, skipTrivia(source, current + 6));
      if (specifier) {
        specifiers.push(specifier);
      }
      current = Math.max(end, current + 6);
      continue;
    }

    current += 1;
  }

  return specifiers;
}

function getForbiddenImportReason(specifier) {
  const normalizedSpecifier = specifier.toLowerCase();
  if (normalizedSpecifier.startsWith('@kit.')) {
    return '@kit.';
  }
  if (normalizedSpecifier.startsWith('@ohos.')) {
    return '@ohos.';
  }
  if (normalizedSpecifier.startsWith('node-api:')) {
    return 'node-api:';
  }
  return null;
}

function collectForbiddenSharedImports(relativePath, source) {
  const forbiddenSharedImports = [];
  for (const specifier of extractStaticModuleSpecifiers(source)) {
    const reason = getForbiddenImportReason(specifier);
    if (reason) {
      forbiddenSharedImports.push({
        file: relativePath,
        specifier
      });
    }
  }
  return forbiddenSharedImports;
}

function normalizeRelativeTestSpecifier(specifier) {
  if (!specifier.startsWith('./') && !specifier.startsWith('../')) {
    return null;
  }

  let normalizedSpecifier = specifier;
  if (!normalizedSpecifier.endsWith('.ets')) {
    normalizedSpecifier = `${normalizedSpecifier}.ets`;
  }

  return path.posix.normalize(normalizedSpecifier);
}

function assertTask1RootTestingSurface(rootPkg, rootLock) {
  assert.deepEqual(rootPkg.devDependencies ?? {}, {
    '@ohos/hypium': '1.0.25'
  });
  assert.deepEqual(rootLock.specifiers ?? {}, {
    '@ohos/hypium@1.0.25': '@ohos/hypium@1.0.25'
  });
  assert.deepEqual(Object.keys(rootLock.packages ?? {}), ['@ohos/hypium@1.0.25']);
  assert.equal(rootLock.packages?.['@ohos/hypium@1.0.25']?.name, '@ohos/hypium');
  assert.equal(rootLock.packages?.['@ohos/hypium@1.0.25']?.version, '1.0.25');
}

function assertModuleTestEntrypoints(moduleTestFiles) {
  for (const [moduleName, files, listSource] of moduleTestFiles) {
    assert.ok(files.includes('List.test.ets'), `${moduleName} must keep List.test.ets as the cumulative entrypoint`);

    const listLikeEntrypoints = files.filter((fileName) => /^List.+\.test\.ets$/u.test(fileName));
    assert.deepEqual(listLikeEntrypoints, [], `${moduleName} must not add a second List-style entrypoint`);

    const siblingSuiteFiles = files.filter((fileName) => fileName !== 'List.test.ets' && fileName.endsWith('.test.ets'));
    const importedSuites = new Set(
      extractStaticModuleSpecifiers(listSource)
        .map((specifier) => normalizeRelativeTestSpecifier(specifier))
        .filter((specifier) => specifier !== null)
        .map((specifier) => path.posix.basename(specifier))
    );

    assert.deepEqual(
      siblingSuiteFiles.filter((fileName) => !importedSuites.has(fileName)),
      [],
      `${moduleName} List.test.ets must statically import every sibling suite`
    );
  }
}

test('Task 1 registers the platform HAR and keeps shared ArkTS free of platform imports', async () => {
  const [projectBuildProfile, rootPkg, rootLock, platformPkg, entryPkg, sharedFiles, moduleTestFiles] = await Promise.all([
    readJson('build-profile.json5'),
    readJson('oh-package.json5'),
    readJson('oh-package-lock.json5'),
    readJson('platform/oh-package.json5'),
    readJson('entry/oh-package.json5'),
    collectFiles(SHARED_ETS_ROOT),
    Promise.all(MODULE_TEST_ROOTS.map(async ([moduleName, rootDir]) => {
      const files = await collectFiles(rootDir);
      const listFilePath = files.find((filePath) => path.basename(filePath) === 'List.test.ets');
      return [
        moduleName,
        files.map((filePath) => path.basename(filePath)),
        listFilePath ? await fs.readFile(listFilePath, 'utf8') : ''
      ];
    }))
  ]);

  const registeredModuleNames = projectBuildProfile.modules.map((entry) => entry.name).sort();
  assert.deepEqual(registeredModuleNames, ['core', 'entry', 'platform', 'shared']);

  assert.equal(platformPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
  assert.equal(entryPkg.dependencies?.['@cmfa/platform'], 'file:../platform');
  assert.equal(entryPkg.dependencies?.['@cmfa/shared'], 'file:../shared');
  assert.equal(entryPkg.dependencies?.['@cmfa/core'], 'file:../core');

  assertTask1RootTestingSurface(rootPkg, rootLock);
  assertModuleTestEntrypoints(moduleTestFiles);

  const forbiddenSharedImports = [];
  for (const filePath of sharedFiles) {
    const body = await fs.readFile(filePath, 'utf8');
    forbiddenSharedImports.push(
      ...collectForbiddenSharedImports(
        path.relative(HARMONY_ROOT, filePath).split(path.sep).join('/'),
        body
      )
    );
  }

  assert.equal(forbiddenSharedImports.length, 0);
});

test('Task 1 shared import guard ignores comments and strings while still catching forbidden import specifiers', () => {
  const source = `
    const sample = "@ohos.security.huks";
    // @kit.ArkUI should stay ignored inside comments
    /* RDB in comments must not count */
    import {
      pickerFeature as feature
    } from "@ohos.file.picker";
    import {
      localThing
    } from "./local/okay";
    export {
      createUi
    } from '@kit.ArkUI';
    import bridge from "node-api:bridge";
  `;

  assert.deepEqual(
    collectForbiddenSharedImports('synthetic/SharedImports.ets', source),
    [
      { file: 'synthetic/SharedImports.ets', specifier: '@ohos.file.picker' },
      { file: 'synthetic/SharedImports.ets', specifier: '@kit.ArkUI' },
      { file: 'synthetic/SharedImports.ets', specifier: 'node-api:bridge' }
    ]
  );
});

test('Task 1 shared import guard accepts trivia after import and export keywords before forbidden specifiers', () => {
  const source = `
    import /*keep*/ "@ohos.file.picker";
    export /*keep*/ { x } from "@kit.ArkUI";
  `;

  assert.deepEqual(
    collectForbiddenSharedImports('synthetic/SharedImportTrivia.ets', source),
    [
      { file: 'synthetic/SharedImportTrivia.ets', specifier: '@ohos.file.picker' },
      { file: 'synthetic/SharedImportTrivia.ets', specifier: '@kit.ArkUI' }
    ]
  );
});

test('Task 1 shared import guard ignores relative specifiers even when their names mention platform concepts', () => {
  const source = `
    import pickerUtils from "./picker-utils";
    import rdbModel from "../rdb-model";
    export { seal } from "./huks-envelope";
    export * from "./arkui-names";
    import localBridge from "./node-api-helper";
  `;

  assert.deepEqual(
    collectForbiddenSharedImports('synthetic/SharedRelativeImports.ets', source),
    []
  );
});

test('Task 1 root test surface guard rejects dependency and lockfile drift', () => {
  const invalidRootPkg = {
    devDependencies: {
      '@ohos/hypium': '1.0.25',
      '@ohos/hamock': '1.0.0'
    }
  };
  const invalidRootLock = {
    specifiers: {
      '@ohos/hypium@1.0.24': '@ohos/hypium@1.0.24'
    },
    packages: {
      '@ohos/hypium@1.0.24': {
        name: '@ohos/hypium',
        version: '1.0.24'
      }
    }
  };

  assert.throws(
    () => assertTask1RootTestingSurface(invalidRootPkg, invalidRootLock),
    /1\.0\.25|hypium/u
  );
});

test('Task 1 module test entrypoint guard rejects unexpected suite files', () => {
  const invalidModuleTestFiles = [
    ['shared', ['List.test.ets', 'Extra.test.ets'], ''],
    ['platform', ['List.test.ets'], ''],
    ['entry', ['List.test.ets'], '']
  ];

  assert.throws(
    () => assertModuleTestEntrypoints(invalidModuleTestFiles),
    /import|suite/u
  );
});

test('Task 1 module test entrypoint guard allows sibling suites when List.test.ets imports them', () => {
  const validModuleTestFiles = [
    ['shared', ['List.test.ets', 'ProfileDomain.test.ets'], `import './ProfileDomain.test';`],
    ['platform', ['List.test.ets'], ''],
    ['entry', ['List.test.ets'], '']
  ];

  assert.doesNotThrow(() => assertModuleTestEntrypoints(validModuleTestFiles));
});

test('Task 1 module test entrypoint guard rejects missing List.test.ets, unimported suites, and second List-style entrypoints', () => {
  assert.throws(
    () => assertModuleTestEntrypoints([
      ['shared', ['ProfileDomain.test.ets'], `import './ProfileDomain.test';`]
    ]),
    /List\.test\.ets/u
  );

  assert.throws(
    () => assertModuleTestEntrypoints([
      ['shared', ['List.test.ets', 'ProfileDomain.test.ets'], ''],
      ['platform', ['List.test.ets'], ''],
      ['entry', ['List.test.ets'], '']
    ]),
    /statically import every sibling suite/u
  );

  assert.throws(
    () => assertModuleTestEntrypoints([
      ['shared', ['List.test.ets', 'List2.test.ets'], `import './List2.test';`],
      ['platform', ['List.test.ets'], ''],
      ['entry', ['List.test.ets'], '']
    ]),
    /List-style entrypoint/u
  );
});

test('Task 5 Harmony driver source contract keeps durable schema version and public ordering aligned', async () => {
  const source = await fs.readFile(HARMONY_DRIVER_PATH, 'utf8');

  assert.match(source, /schema_version\s+INTEGER\s+NOT\s+NULL/u);
  assert.match(source, /PROFILE_COLUMNS\s*=\s*[\s\S]*schema_version/u);
  assert.match(source, /schemaVersion:\s*require[A-Za-z]+Value\(bucket\.schema_version/u);
  assert.match(source, /row\.schemaVersion/u);
  assert.match(source, /SELECT \$\{PROFILE_COLUMNS\} FROM profiles ORDER BY updated_at DESC, id ASC/u);
});

test('Task 5 Harmony driver source contract recreates app_state and memoizes in-flight store initialization', async () => {
  const source = await fs.readFile(HARMONY_DRIVER_PATH, 'utf8');

  assert.match(source, /INSERT OR REPLACE INTO app_state \(id, active_profile_id\) VALUES \((1, \?|\?, \?)\)/u);
  assert.match(source, /private storePromise\?: Promise<relationalStore\.RdbStore>/u);
  assert.match(source, /private initializePromise\?: Promise<void>/u);
  assert.equal((source.match(/APP_STATE_SEED_SQL/g) ?? []).length, 2, 'driver should declare and execute APP_STATE_SEED_SQL exactly once');
});

test('Task 5 Harmony driver lifecycle source contract waits for pending acquisition and blocks reactivation after close', async () => {
  const source = await fs.readFile(HARMONY_DRIVER_PATH, 'utf8');

  assert.match(source, /private closePromise\?: Promise<void>/u);
  assert.match(source, /private closing:\s*boolean/u);
  assert.match(source, /private closed:\s*boolean/u);
  assert.match(source, /if \(this\.closePromise !== undefined\)/u);
  assert.match(source, /await this\.storePromise/u);
  assert.match(source, /await this\.initializePromise/u);
  assert.match(source, /if \(this\.closing \|\| this\.closed\)/u);
  assert.match(source, /if \(this\.closed\)/u);
});

test('Task 8 platform source contract keeps transport selection and manual redirect ownership inside the platform HAR', async () => {
  const [downloaderSource, httpTransportSource, networkKitSource, requestAgentSource, entryModule] = await Promise.all([
    fs.readFile(SUBSCRIPTION_DOWNLOADER_PATH, 'utf8'),
    fs.readFile(HTTP_TRANSPORT_PATH, 'utf8'),
    fs.readFile(NETWORK_KIT_TRANSPORT_PATH, 'utf8'),
    fs.readFile(REQUEST_AGENT_TRANSPORT_PATH, 'utf8'),
    readJson('entry/src/main/module.json5')
  ]);

  assert.match(downloaderSource, /type RemoteAcquireCommand/u);
  assert.match(downloaderSource, /type RemoteProfileAcquisition/u);
  assert.match(downloaderSource, /sdkApiVersion/u);
  assert.match(downloaderSource, /sdkApiVersion\s*>=\s*23/u);
  assert.match(downloaderSource, /networkKitTransport/u);
  assert.match(downloaderSource, /requestAgentTransport/u);
  assert.match(downloaderSource, /30 \* 1000/u);
  assert.match(downloaderSource, /16 \* 1024 \* 1024/u);
  assert.match(downloaderSource, /301|302|303|307|308/u);
  assert.match(downloaderSource, /response\.statusCode === 204/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_HTTP_STATUS/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_EMPTY_BODY/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_OVERSIZE/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_STAGE_FAILED/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_TIMEOUT/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_REDIRECT/u);
  assert.match(downloaderSource, /CMFA_DOWNLOAD_TLS/u);
  assert.match(httpTransportSource, /interface HttpTransport/u);
  assert.match(httpTransportSource, /createHttpTransportFailure/u);
  assert.match(networkKitSource, /from '@kit\.NetworkKit'/u);
  assert.match(networkKitSource, /maxRedirects:\s*0/u);
  assert.match(networkKitSource, /maxLimit:\s*16 \* 1024 \* 1024/u);
  assert.match(networkKitSource, /connectTimeout:\s*30 \* 1000/u);
  assert.match(networkKitSource, /readTimeout:\s*30 \* 1000/u);
  assert.match(networkKitSource, /usingCache:\s*false/u);
  assert.match(networkKitSource, /2300063/u);
  assert.doesNotMatch(networkKitSource, /requestUrl|request\.url.*createHttpTransportFailure|\$\{request\.url\}/u);
  assert.match(requestAgentSource, /from '@kit\.BasicServicesKit'/u);
  assert.match(requestAgentSource, /request\.agent\.create/u);
  assert.match(requestAgentSource, /redirect:\s*false|redirect\s*=\s*false/u);
  assert.match(requestAgentSource, /isRedirectStatus\(responseStatusCode\)/u);
  assert.match(requestAgentSource, /new ArrayBuffer\(0\)/u);
  assert.match(requestAgentSource, /createHttpTransportFailure\('OVERSIZE'/u);
  assert.match(requestAgentSource, /task\.on\('progress'/u);
  assert.match(requestAgentSource, /task\.on\('response'/u);
  assert.match(requestAgentSource, /task\.on\('faultOccur'/u);
  assert.match(requestAgentSource, /requestAgent\.remove\(task\.tid\)|request\.agent\.remove\(task\.tid\)/u);
  assert.doesNotMatch(requestAgentSource, /requestSpec\.url.*createHttpTransportFailure|\$\{requestSpec\.url\}/u);
  assert.deepEqual(entryModule.module.requestPermissions, [{ name: 'ohos.permission.INTERNET' }]);
});
