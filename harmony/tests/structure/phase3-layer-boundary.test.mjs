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
  for (const [moduleName, files] of moduleTestFiles) {
    assert.deepEqual(files, ['List.test.ets'], `${moduleName} must keep exactly one suite entrypoint`);
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
    Promise.all(MODULE_TEST_ROOTS.map(async ([moduleName, rootDir]) => [
      moduleName,
      (await collectFiles(rootDir)).map((filePath) => path.basename(filePath))
    ]))
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
    ['shared', ['List.test.ets', 'Extra.test.ets']],
    ['platform', ['List.test.ets']],
    ['entry', ['List.test.ets']]
  ];

  assert.throws(
    () => assertModuleTestEntrypoints(invalidModuleTestFiles),
    /Extra|unique|only/u
  );
});
