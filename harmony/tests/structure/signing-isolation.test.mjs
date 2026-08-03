import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const harmonyRoot = resolvePathFromImportMetaUrl(import.meta.url);
const repoRoot = path.resolve(harmonyRoot, '..');
const sensitiveExtensions = ['p12', 'cer', 'p7b', 'pem', 'pfx'];
const passwordFragments = ['pass', 'word'];
const passphraseFragments = ['pass', 'phrase'];
const secretFragments = ['sec', 'ret'];
const privateKeyFragments = ['private', 'Key'];
const certificateFragments = ['cert', 'ificate'];
const keystoreFragments = ['key', 'store'];
const signingFragments = ['sign', 'ing'];
const macHomePrefix = ['/Us', 'ers/'];
const windowsHomePrefix = [':\\\\Us', 'ers\\\\'];
const binaryExtensions = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.so', '.jar', '.zip']);
const escapedWindowsSourceSeparator = joinFragments(['\\', '\\']);
const pathFixtureLiteralReplacements = new Map([
  [
    'tests/structure/toolchain-discovery.test.mjs',
    [
      buildWindowsSourcePath([joinFragments(['Us', 'ers']), 'name', 'Sdk']),
      buildWindowsLocalPropertiesValue([joinFragments(['Us', 'ers']), 'name', 'Sdk']),
      `file://${joinFragments(['/Us', 'ers/test/My%20Repo'])}/harmony/tools/preflight.mjs`,
      joinFragments(['/Us', 'ers/test/My Repo']),
      `file:///C:/${joinFragments(['Us', 'ers/name/My%20Repo'])}/harmony/tools/preflight.mjs`,
      buildWindowsSourcePath([joinFragments(['Us', 'ers']), 'name', 'My Repo'])
    ]
  ]
]);

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function joinFragments(fragments) {
  return fragments.join('');
}

function buildWindowsSourcePath(segments) {
  return `C:${escapedWindowsSourceSeparator}${segments.join(escapedWindowsSourceSeparator)}`;
}

function buildWindowsLocalPropertiesValue(segments) {
  return `sdk.dir=C\\:${escapedWindowsSourceSeparator}${segments.join(escapedWindowsSourceSeparator)}\\n`;
}

function resolvePathFromImportMetaUrl(importMetaUrl, relativePath = '../..') {
  return path.resolve(fileURLToPath(new URL(relativePath, importMetaUrl)));
}

function listTrackedAndCandidateHarmonyFiles() {
  const output = execFileSync(
    'git',
    ['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'harmony'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  return output
    .split('\u0000')
    .filter(Boolean)
    .map((filePath) => path.posix.relative('harmony', filePath))
    .sort();
}

function isBinaryPath(relativePath) {
  return binaryExtensions.has(path.posix.extname(relativePath).toLowerCase());
}

function buildSensitiveFilePattern() {
  return new RegExp(
    String.raw`(?:^|[\s"'=:(\[])[^\s"'=:(\[]*\.(?:${sensitiveExtensions.map(escapeRegex).join('|')})(?=$|[\s"'=,)\]}])`,
    'iu'
  );
}

function buildCredentialAssignmentPattern() {
  const keywords = [
    String.raw`[\w.-]*${joinFragments(passwordFragments)}\b`,
    String.raw`[\w.-]*${joinFragments(passphraseFragments)}\b`,
    String.raw`[\w.-]*${joinFragments(secretFragments)}\b`,
    String.raw`${joinFragments(['key', 'Alias'])}\b`,
    String.raw`${joinFragments(['cert', 'Path'])}\b`,
    String.raw`${joinFragments(['store', 'File'])}\b`,
    String.raw`${joinFragments(privateKeyFragments)}(?:File|Path)?\b`,
    String.raw`${joinFragments(certificateFragments)}(?:File|Path)?\b`,
    String.raw`${joinFragments(keystoreFragments)}(?:File|Path)?\b`,
    String.raw`${joinFragments(signingFragments)}\b(?!["']?\s*:\s*\{)`,
    String.raw`${joinFragments(['store', 'Password'])}\b`,
    String.raw`${joinFragments(['key', 'Password'])}\b`
  ];

  return new RegExp(
    String.raw`(?:^|[\s{,])["']?(?:${keywords.join('|')})["']?\s*[:=]`,
    'iu'
  );
}

function buildMachineSpecificPathPattern() {
  return new RegExp(
    `${escapeRegex(joinFragments(macHomePrefix))}|${String.raw`[A-Za-z]:(?:(?:\\)+|/)${joinFragments(['Us', 'ers'])}(?:(?:\\)+|/)`}`,
    'u'
  );
}

function sanitizeAllowedLiterals(relativePath, raw) {
  const literals = pathFixtureLiteralReplacements.get(relativePath);
  if (!literals) {
    return raw;
  }

  let sanitized = raw;
  for (const literal of literals) {
    sanitized = sanitized.split(literal).join('__ALLOWED_PATH_FIXTURE__');
  }
  return sanitized;
}

const bannedPathPattern = new RegExp(
  String.raw`(^|[\\/])[^\\/]*\.(?:${sensitiveExtensions.map(escapeRegex).join('|')})$`,
  'iu'
);
const bannedContentPatterns = [
  buildSensitiveFilePattern(),
  buildCredentialAssignmentPattern(),
  buildMachineSpecificPathPattern()
];

test('signing isolation matchers reject bare extensions, signing credential fields, and machine-specific homes without banning signingConfig names', () => {
  const sensitiveFilePattern = buildSensitiveFilePattern();
  const credentialAssignmentPattern = buildCredentialAssignmentPattern();
  const machineSpecificPathPattern = buildMachineSpecificPathPattern();
  const bareExtensionToken = `.${sensitiveExtensions[0]}`;
  const pfxExtensionToken = `.${joinFragments(['p', 'fx'])}`;
  const fileToken = `${joinFragments(['sign', 'ing'])} ${joinFragments(['file'])} ${bareExtensionToken}`;
  const certPathField = `${joinFragments(certificateFragments)}${joinFragments(['Path'])}: './${joinFragments(['cert'])}.${sensitiveExtensions[1]}'`;
  const storeFileField = `${joinFragments(['store', 'File'])} = '${joinFragments(['release'])}.${sensitiveExtensions[0]}'`;
  const keyAliasField = `${joinFragments(['key', 'Alias'])}: '${joinFragments(['release'])}'`;
  const signingAssignmentField = `${joinFragments(signingFragments)}: '${joinFragments(['release'])}'`;
  const signingStatusField = `${joinFragments(signingFragments)}: { result: '${joinFragments(['incomplete'])}' }`;
  const signingConfigName = `${joinFragments(signingFragments)}Config: "${joinFragments(['default'])}"`;
  const macHomePath = `${joinFragments(macHomePrefix)}${joinFragments(['alice/keys'])}`;
  const windowsHomePath = String.raw`${joinFragments(['C'])}:${joinFragments(['\\', '\\'])}${joinFragments(['Us', 'ers'])}${joinFragments(['\\', '\\'])}${joinFragments(['alice'])}${joinFragments(['\\', '\\'])}${joinFragments(['keys'])}`;
  const windowsForwardSlashHomePath = `${joinFragments(['C'])}:/${joinFragments(['Us', 'ers'])}/${joinFragments(['alice/keys'])}`;
  const hiddenSigningPath = `${joinFragments(['keys'])}/${bareExtensionToken}`;

  assert.match(bareExtensionToken, sensitiveFilePattern);
  assert.match(pfxExtensionToken, sensitiveFilePattern);
  assert.match(fileToken, sensitiveFilePattern);
  assert.match(certPathField, sensitiveFilePattern);
  assert.match(certPathField, credentialAssignmentPattern);
  assert.match(storeFileField, credentialAssignmentPattern);
  assert.match(keyAliasField, credentialAssignmentPattern);
  assert.match(signingAssignmentField, credentialAssignmentPattern);
  assert.doesNotMatch(signingStatusField, credentialAssignmentPattern);
  assert.doesNotMatch(signingConfigName, credentialAssignmentPattern);
  assert.match(macHomePath, machineSpecificPathPattern);
  assert.match(windowsHomePath, machineSpecificPathPattern);
  assert.match(windowsForwardSlashHomePath, machineSpecificPathPattern);
  assert.match(hiddenSigningPath, bannedPathPattern);
  assert.match(`${joinFragments(['keys'])}/${pfxExtensionToken}`, bannedPathPattern);
});

test('signing isolation path resolution decodes encoded spaces from import.meta URLs', () => {
  const spacedRoot = resolvePathFromImportMetaUrl('file:///tmp/Space%20Folder/harmony/tests/structure/signing-isolation.test.mjs');
  assert.equal(spacedRoot, '/tmp/Space Folder/harmony');
});

test('tracked and candidate harmony files stay free of embedded signing material and machine-specific paths', async () => {
  const scopedFiles = listTrackedAndCandidateHarmonyFiles();
  assert.ok(scopedFiles.length > 0, 'git ls-files should enumerate tracked and candidate harmony files');

  for (const relativePath of scopedFiles) {
    assert.doesNotMatch(relativePath, bannedPathPattern, `${relativePath} must not be a tracked or candidate signing artifact`);

    if (isBinaryPath(relativePath)) {
      continue;
    }

    const raw = sanitizeAllowedLiterals(relativePath, await fs.readFile(path.join(harmonyRoot, relativePath), 'utf8'));
    for (const pattern of bannedContentPatterns) {
      assert.doesNotMatch(raw, pattern, `${relativePath} embeds signing material or machine-specific paths`);
    }
  }
});
