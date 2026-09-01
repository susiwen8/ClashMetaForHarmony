import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../../..', import.meta.url));
const HARMONY_ROOT = path.join(REPO_ROOT, 'harmony');
const SHARED_ROOT = path.join(HARMONY_ROOT, 'shared', 'src', 'main', 'ets');
const ENTRY_ROOT = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets');
const DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'proxy-one-click-vpn.md');
const DEVICE_PROOF_DOC_PATH = path.join(REPO_ROOT, 'docs', 'harmony', 'proxy-one-click-vpn-device-proof.md');
const RUNNER_MODULE_PATH = new URL('../bin/run-proxy-one-click-vpn-device-proof.mjs', import.meta.url);
const RUNNER_PATH = fileURLToPath(RUNNER_MODULE_PATH);
const SCHEMA_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-one-click-vpn-device-proof.schema.json');
const EXAMPLE_PATH = path.join(HARMONY_ROOT, 'tests', 'fixtures', 'proxy-one-click-vpn-device-proof.example.json');

const PROFILE_APPLICATION_PATH = path.join(SHARED_ROOT, 'profile', 'ProfileApplication.ets');
const ONE_CLICK_MODELS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyOneClickVpnModels.ets');
const PROXY_PORTS_PATH = path.join(SHARED_ROOT, 'proxy', 'ProxyPorts.ets');
const INDEX_PATH = path.join(ENTRY_ROOT, 'pages', 'Index.ets');
const PROXY_VIEW_MODEL_PATH = path.join(ENTRY_ROOT, 'presentation', 'ProxyViewModel.ets');
const PROXIES_PAGE_PATH = path.join(ENTRY_ROOT, 'pages', 'ProxiesPage.ets');
const PROXY_PRESENTATION_MODELS_PATH = path.join(ENTRY_ROOT, 'presentation', 'ProxyPresentationModels.ets');
const PUBLIC_INTERFACE_SOURCES = Object.freeze([
  ONE_CLICK_MODELS_PATH,
  PROXY_PRESENTATION_MODELS_PATH,
  PROFILE_APPLICATION_PATH
]);

const PUBLIC_SOURCE_BUCKETS = Object.freeze({
  shared: [ONE_CLICK_MODELS_PATH, PROXY_PORTS_PATH, PROFILE_APPLICATION_PATH],
  entry: [INDEX_PATH, PROXY_VIEW_MODEL_PATH, PROXIES_PAGE_PATH, PROXY_PRESENTATION_MODELS_PATH]
});

const FORBIDDEN_PUBLIC_FIELDS = Object.freeze([
  'groupName',
  'memberName',
  'nodeName',
  'label',
  'labelHash',
  'endpoint',
  'url',
  'uri',
  'credential',
  'password',
  'token',
  'secret',
  'sessionId',
  'profileId',
  'versionId',
  'failureCode',
  'appError',
  'vpnFailure',
  'platformDetail',
  'rawDetail'
]);

const SYNTHETIC_FORBIDDEN_SCHEMA_KEYS = Object.freeze([
  'label',
  'labelHash',
  'endpoint',
  'url',
  'credential',
  'sessionId',
  'profileId',
  'versionId',
  'failureCode',
  'rawDetail'
]);

async function readUtf8(filePath) {
  return await fs.readFile(filePath, 'utf8');
}

function assertOrdered(source, labelsAndNeedles) {
  let previousIndex = -1;
  for (const [label, needle] of labelsAndNeedles) {
    const currentIndex = source.indexOf(needle);
    assert.notEqual(currentIndex, -1, `missing ${label}`);
    assert.ok(currentIndex > previousIndex, `${label} must preserve the required source order`);
    previousIndex = currentIndex;
  }
}

function sliceBetween(source, startNeedle, endNeedle) {
  const startIndex = source.indexOf(startNeedle);
  assert.notEqual(startIndex, -1, `missing start needle ${startNeedle}`);
  const endIndex = source.indexOf(endNeedle, startIndex);
  assert.notEqual(endIndex, -1, `missing end needle ${endNeedle}`);
  return source.slice(startIndex, endIndex);
}

function collectForbiddenSchemaKeys(document, forbiddenKeys, trail = []) {
  const violations = [];
  if (Array.isArray(document)) {
    for (let index = 0; index < document.length; index += 1) {
      const value = document[index];
      if (typeof value === 'string' && forbiddenKeys.includes(value) && trail.at(-1) === 'required') {
        violations.push(`${trail.join('.')}[${index}]=${value}`);
      } else {
        violations.push(...collectForbiddenSchemaKeys(value, forbiddenKeys, [...trail, String(index)]));
      }
    }
    return violations;
  }
  if (document === null || typeof document !== 'object') {
    return violations;
  }
  for (const [key, value] of Object.entries(document)) {
    if (trail.at(-1) === 'properties' && forbiddenKeys.includes(key)) {
      violations.push(`${trail.join('.')} -> ${key}`);
    }
    violations.push(...collectForbiddenSchemaKeys(value, forbiddenKeys, [...trail, key]));
  }
  return violations;
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

function extractBalancedSegment(source, openIndex, openChar, closeChar) {
  let current = openIndex;
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
    if (source[current] === openChar) {
      depth += 1;
    } else if (source[current] === closeChar) {
      depth -= 1;
      if (depth === 0) {
        return source.slice(openIndex, current + 1);
      }
    }
    current += 1;
  }
  throw new Error(`Unbalanced ${openChar}${closeChar} segment.`);
}

function readCallExpression(source, startIndex, openParenIndex) {
  return source.slice(startIndex, openParenIndex) + extractBalancedSegment(source, openParenIndex, '(', ')');
}

function collectCallExpressions(source) {
  const calls = [];
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

    if (source.startsWith('console.', current) && isIdentifierBoundaryChar(source[current - 1])) {
      const openParenIndex = source.indexOf('(', current);
      calls.push(readCallExpression(source, current, openParenIndex));
      current = openParenIndex + 1;
      continue;
    }
    if (source.startsWith('hilog.', current) && isIdentifierBoundaryChar(source[current - 1])) {
      const openParenIndex = source.indexOf('(', current);
      calls.push(readCallExpression(source, current, openParenIndex));
      current = openParenIndex + 1;
      continue;
    }
    if (source.startsWith('JSON.stringify', current) && isIdentifierBoundaryChar(source[current - 1])) {
      const openParenIndex = skipTrivia(source, current + 'JSON.stringify'.length);
      calls.push(readCallExpression(source, current, openParenIndex));
      current = openParenIndex + 1;
      continue;
    }
    if (source.startsWith('new Error', current) && isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 'new Error'.length])) {
      const openParenIndex = skipTrivia(source, current + 'new Error'.length);
      calls.push(readCallExpression(source, current, openParenIndex));
      current = openParenIndex + 1;
      continue;
    }
    current += 1;
  }
  return calls;
}

function collectPublicSinkMatches(source) {
  const sensitiveExpr = String.raw`(?:groupName|memberName|nodeName|row\.name|group\.name|node\.name|record\.(?:groupName|selectedNodeName)|labelHash|endpoint|subscriptionUrl|sourceUrl|url|uri|credential|password|token|secret|sessionId|appError|vpnFailure|platformDetail|rawDetail)`;
  const sensitivePattern = new RegExp(sensitiveExpr, 'u');
  const rawErrorPattern = /\b(?:error|failure|appError|vpnFailure)\s*\.\s*(?:message|stack|technicalDetail|detail)\b/u;
  const matches = [];

  for (const call of collectCallExpressions(source)) {
    if (call.startsWith('JSON.stringify')) {
      matches.push(call);
      continue;
    }
    if (call.startsWith('console.') || call.startsWith('hilog.') || call.startsWith('new Error')) {
      if (sensitivePattern.test(call) || rawErrorPattern.test(call)) {
        matches.push(call);
      }
    }
  }
  return matches;
}

function collectForbiddenPublicFixtureFields(source) {
  const sensitiveExpr = String.raw`(?:label|labelHash|endpoint|url|credential|sessionId|rawDetail)`;
  const pattern = new RegExp(String.raw`\b(?:${sensitiveExpr})\b\s*:`, 'gu');
  return [...source.matchAll(pattern)].map((match) => match[0]);
}

function extractExportInterfaceBlocks(source) {
  const blocks = [];
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
    if (source.startsWith('export', current) && isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 'export'.length])) {
      let next = skipTrivia(source, current + 'export'.length);
      if (source.startsWith('interface', next) && isIdentifierBoundaryChar(source[next - 1]) &&
        isIdentifierBoundaryChar(source[next + 'interface'.length])) {
        const start = current;
        next = source.indexOf('{', next + 'interface'.length);
        const body = extractBalancedSegment(source, next, '{', '}');
        blocks.push(source.slice(start, next) + body);
        current = next + body.length;
        continue;
      }
    }
    current += 1;
  }
  return blocks;
}

function extractExportTypeObjectBlocks(source) {
  const blocks = [];
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
    if (source.startsWith('export', current) && isIdentifierBoundaryChar(source[current - 1]) &&
      isIdentifierBoundaryChar(source[current + 'export'.length])) {
      let next = skipTrivia(source, current + 'export'.length);
      if (source.startsWith('type', next) && isIdentifierBoundaryChar(source[next - 1]) &&
        isIdentifierBoundaryChar(source[next + 'type'.length])) {
        const declarationStart = current;
        let declarationEnd = next + 'type'.length;
        let depthParen = 0;
        let depthBracket = 0;
        let depthBrace = 0;
        let depthAngle = 0;
        while (declarationEnd < source.length) {
          if (source[declarationEnd] === '/' && source[declarationEnd + 1] === '/') {
            declarationEnd = skipLineComment(source, declarationEnd);
            continue;
          }
          if (source[declarationEnd] === '/' && source[declarationEnd + 1] === '*') {
            declarationEnd = skipBlockComment(source, declarationEnd);
            continue;
          }
          if (source[declarationEnd] === '\'' || source[declarationEnd] === '"' || source[declarationEnd] === '`') {
            declarationEnd = skipQuotedLiteral(source, declarationEnd);
            continue;
          }
          if (source[declarationEnd] === '(') {
            depthParen += 1;
          } else if (source[declarationEnd] === ')') {
            depthParen = Math.max(0, depthParen - 1);
          } else if (source[declarationEnd] === '[') {
            depthBracket += 1;
          } else if (source[declarationEnd] === ']') {
            depthBracket = Math.max(0, depthBracket - 1);
          } else if (source[declarationEnd] === '{') {
            depthBrace += 1;
          } else if (source[declarationEnd] === '}') {
            depthBrace = Math.max(0, depthBrace - 1);
          } else if (source[declarationEnd] === '<') {
            depthAngle += 1;
          } else if (source[declarationEnd] === '>') {
            depthAngle = Math.max(0, depthAngle - 1);
          } else if (source[declarationEnd] === ';' &&
            depthParen === 0 &&
            depthBracket === 0 &&
            depthBrace === 0 &&
            depthAngle === 0) {
            declarationEnd += 1;
            break;
          }
          declarationEnd += 1;
        }
        const declaration = source.slice(declarationStart, declarationEnd);
        let blockCursor = 0;
        while (blockCursor < declaration.length) {
          if (declaration[blockCursor] === '/' && declaration[blockCursor + 1] === '/') {
            blockCursor = skipLineComment(declaration, blockCursor);
            continue;
          }
          if (declaration[blockCursor] === '/' && declaration[blockCursor + 1] === '*') {
            blockCursor = skipBlockComment(declaration, blockCursor);
            continue;
          }
          if (declaration[blockCursor] === '\'' || declaration[blockCursor] === '"' || declaration[blockCursor] === '`') {
            blockCursor = skipQuotedLiteral(declaration, blockCursor);
            continue;
          }
          if (declaration[blockCursor] === '{') {
            const block = extractBalancedSegment(declaration, blockCursor, '{', '}');
            blocks.push(block);
            blockCursor += block.length;
            continue;
          }
          blockCursor += 1;
        }
        current = declarationEnd;
        continue;
      }
    }
    current += 1;
  }
  return blocks;
}

function collectForbiddenExportInterfaceFieldMatches(source) {
  const forbiddenPattern = /\b(?:label|labelHash|endpoint|url|credential|sessionId|rawDetail)\??\s*:/gu;
  const matches = [];
  for (const block of extractExportInterfaceBlocks(source)) {
    matches.push(...[...block.matchAll(forbiddenPattern)].map((match) => match[0]));
  }
  for (const block of extractExportTypeObjectBlocks(source)) {
    matches.push(...[...block.matchAll(forbiddenPattern)].map((match) => match[0]));
  }
  return matches;
}

function createProofNode(id, text = '', children = []) {
  const attributes = { id };
  if (text.length > 0) {
    attributes.text = text;
  }
  return {
    attributes,
    bounds: { left: 0, top: 0, right: 320, bottom: 60 },
    children
  };
}

function createActionableProofNode(id, text = '', children = []) {
  const node = createProofNode(id, text, children);
  node.attributes.clickable = 'true';
  node.attributes.enabled = 'true';
  return node;
}

function createProxyRow(index, {
  runtimeSelected = false,
  savedIntent = false,
  nestedGroup = false,
  activation = false
} = {}) {
  const baseId = `proxies.node.${index}`;
  const children = [];
  if (runtimeSelected) {
    children.push(createProofNode(`${baseId}.runtime-selected`, '当前生效'));
  }
  if (savedIntent) {
    children.push(createProofNode(`${baseId}.saved-intent`, '下次启动生效'));
  }
  if (nestedGroup) {
    children.push(createProofNode(`${baseId}.nested-group`, '分组'));
  }
  if (activation) {
    children.push(createProofNode(`${baseId}.activation`, '连接中'));
  }
  return createActionableProofNode(baseId, '', children);
}

function createProxyLayout(rows, extras = []) {
  return {
    root: createProofNode('root', '', extras.concat(rows))
  };
}

function createHomeLayout({
  vpnText = 'Stop VPN global capture',
  includeVpn = true
} = {}) {
  const children = [];
  if (includeVpn) {
    children.push(createActionableProofNode('home.vpn.action', vpnText));
  }
  return {
    root: createProofNode('root', '', children)
  };
}

function createPassingDeviceProof(packageSha256 = 'a'.repeat(64)) {
  return {
    schemaVersion: '2.0.0',
    result: 'pass',
    packageSha256,
    stoppedToVpnState: 'RUNNING_SELECTED',
    runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
    recreationState: 'RESTORED_RUNNING_SELECTED',
    cleanupState: 'CLEAN'
  };
}

function createIncompleteDeviceProof() {
  return {
    schemaVersion: '2.0.0',
    result: 'incomplete',
    packageSha256: '0'.repeat(64),
    stoppedToVpnState: 'NOT_PROVEN',
    runningSwitchState: 'NOT_PROVEN',
    recreationState: 'NOT_PROVEN',
    cleanupState: 'NOT_PROVEN'
  };
}

function createTrackingFs(baseFs = fs, options = {}) {
  const createdRoots = [];
  const removedRoots = [];
  const tempFiles = [];
  const rmFailures = new Set(options.failRmPaths ?? []);
  return {
    ...baseFs,
    createdRoots,
    removedRoots,
    tempFiles,
    async mkdtemp(prefix, ...rest) {
      const result = await baseFs.mkdtemp(prefix, ...rest);
      createdRoots.push(result);
      return result;
    },
    async writeFile(filePath, data, encoding) {
      if (String(filePath).includes('.tmp')) {
        tempFiles.push(String(filePath));
      }
      if (typeof options.writeFileImpl === 'function') {
        return await options.writeFileImpl(filePath, data, encoding, baseFs);
      }
      return await baseFs.writeFile(filePath, data, encoding);
    },
    async rename(fromPath, toPath) {
      if (typeof options.renameImpl === 'function') {
        return await options.renameImpl(fromPath, toPath, baseFs);
      }
      return await baseFs.rename(fromPath, toPath);
    },
    async rm(targetPath, rmOptions) {
      const normalized = String(targetPath);
      if (rmFailures.has(normalized)) {
        throw Object.assign(new Error('synthetic rm failure'), { code: 'RM_FAILED' });
      }
      removedRoots.push(normalized);
      return await baseFs.rm(targetPath, rmOptions);
    }
  };
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

test('one-click vpn contract keeps vpn and one-click mutation ownership in ProfileApplication', async () => {
  const [applicationSource, indexSource, viewModelSource] = await Promise.all([
    readUtf8(PROFILE_APPLICATION_PATH),
    readUtf8(INDEX_PATH),
    readUtf8(PROXY_VIEW_MODEL_PATH)
  ]);

  assert.match(applicationSource, /async startVpnGlobalCapture\(\): Promise<VpnControllerStartResult>[\s\S]*tryAcquireRuntimeMutationOwner\('VPN'\)/u);
  assert.match(applicationSource, /async stopVpnGlobalCapture\(\): Promise<VpnControllerStopResult>[\s\S]*tryAcquireRuntimeMutationOwner\('VPN'\)/u);
  assert.match(applicationSource, /async selectNodeAndEnsureVpn\([\s\S]*tryAcquireRuntimeMutationOwner\('ONE_CLICK'\)[\s\S]*result = await this\.selectNodeAndEnsureVpnInsideLease\(groupName,\s*memberName,\s*snapshotGeneration,\s*groupPath\)[\s\S]*this\.finishOneClickVpnOperation\(result\)/u);

  assert.doesNotMatch(indexSource, /\.(?:startVpnGlobalCapture|stopVpnGlobalCapture)\(/u,
    'Index must not orchestrate VPN mutations directly'
  );
  assert.doesNotMatch(viewModelSource, /\.(?:startVpnGlobalCapture|stopVpnGlobalCapture)\(/u,
    'ProxyViewModel must not orchestrate VPN mutations directly'
  );
  assert.match(viewModelSource, /await this\.application\.selectNodeAndEnsureVpn\(\s*groupName,\s*row\.name,\s*generation,\s*this\.cloneDisplayedGroupPath\(\)\s*\)/u,
    'terminal node activation must stay inside the application-owned one-click use case'
  );
});

test('one-click vpn contract pins stopped and running-vpn source ordering', async () => {
  const source = await readUtf8(PROFILE_APPLICATION_PATH);
  const leaseSource = sliceBetween(
    source,
    'private async selectNodeAndEnsureVpnInsideLease(',
    'private async applySelectionToRunningVpn('
  );
  const hotSwitchSource = sliceBetween(
    source,
    'private async applySelectionToRunningVpn(',
    'private async selectAndStartVpn('
  );
  const stoppedSource = sliceBetween(
    source,
    'private async selectAndStartVpn(',
    'private async startVpnAfterSelection('
  );
  const startSource = sliceBetween(
    source,
    'private async startVpnAfterSelection(',
    'private async finishVpnConfirmation('
  );
  const finishSource = sliceBetween(
    source,
    'private async finishVpnConfirmation(',
    'private tryAcquireRuntimeMutationOwner('
  );

  assertOrdered(leaseSource, [
    ['busy state guard', "if (this.snapshot.runtime.state === 'STARTING'"],
    ['running vpn hot switch branch', "if (vpnSnapshot.state === 'RUNNING')"],
    ['stopped branch', 'return await this.selectAndStartVpn(groupName, memberName, snapshotGeneration, groupPath);']
  ]);

  assertOrdered(stoppedSource, [
    ['publish saving selection', "createOneClickVpnOperationSnapshot('SAVING_SELECTION', true, 'NONE')"],
    ['persist selection', 'await this.proxyService.select(groupName, memberName, snapshotGeneration, groupPath)'],
    ['start vpn after persistence', 'return await this.startVpnAfterSelection(groupName, memberName, true, groupPath);']
  ]);

  assertOrdered(startSource, [
    ['arm confirmation first', 'confirmationHandle = this.oneClickVpnConfirmation.arm(sessionId, ONE_CLICK_VPN_CONFIRMATION_TIMEOUT_MS)'],
    ['publish starting vpn', "createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'NONE')"],
    ['controller start', 'await controller.start(target.profileId, target.versionId, sessionId)'],
    ['publish confirming selection', "createOneClickVpnOperationSnapshot('CONFIRMING_SELECTION', true, 'NONE')"],
    ['mark accepted', 'confirmationHandle.markStartAccepted()'],
    ['wait running confirmation', 'confirmationResult = await confirmationHandle.wait()'],
    ['finish confirmation only after running proof', 'return await this.finishVpnConfirmation(']
  ]);
  assert.doesNotMatch(startSource, /return createSelectNodeAndEnsureVpnSuccessResult\('VPN_STARTED'\)/u,
    'STARTED alone must never be treated as a public success'
  );
  assert.match(finishSource, /if \(confirmationResult\.kind === 'RUNNING'\)[\s\S]*await this\.proxyService\.queryGroup\(groupName,\s*groupPath\)[\s\S]*selectedNode\.selected[\s\S]*return createSelectNodeAndEnsureVpnSuccessResult\('VPN_STARTED'\)/u,
    'VPN_STARTED must require RUNNING plus same-group runtime selection confirmation'
  );

  assert.match(hotSwitchSource, /await this\.proxyService\.queryGroup\(groupName,\s*groupPath\)[\s\S]*createOneClickVpnOperationSnapshot\('SWITCHING_VPN', true, 'NONE'\)[\s\S]*await this\.proxyService\.select\(groupName,\s*memberName,\s*snapshotGeneration,\s*groupPath\)/u);
  assert.doesNotMatch(hotSwitchSource, /controller\.(?:start|stop)\(|createFreshVpnSessionId|oneClickVpnConfirmation\.arm/u,
    'running VPN hot-switch must not restart or replace the VPN session'
  );
});

test('one-click vpn privacy scanner catches synthetic leaks while allowing safe text and equality checks', () => {
  const safePositive = `
    Text(row.name);
    return queryResult.snapshot.identity.sessionId !== sessionId;
    return createOneClickVpnFailureResult('VPN_CONFIRMATION', 'VPN_SESSION_CHANGED', true, 'proxies_error_session_changed', true);
  `;
  const safeMultilineLog = `
    console.info(
      'one-click-stage',
      stageName
    );
  `;
  const safeFixedLogs = [
    `console.info('one-click-stage');`,
    `hilog.info(0, 'OneClick', '%{public}s', 'one-click-stage');`,
    `throw new Error('one-click-stage');`
  ];
  assert.deepEqual(
    [...collectPublicSinkMatches(safePositive), ...collectForbiddenPublicFixtureFields(safePositive)],
    [],
    'safe text and in-memory equality checks must stay allowed'
  );
  assert.deepEqual(collectPublicSinkMatches(safeMultilineLog), [], 'safe multiline fixed-stage log must stay allowed');
  for (const safeLog of safeFixedLogs) {
    assert.deepEqual(collectPublicSinkMatches(safeLog), [], 'safe fixed-stage console/hilog/new Error logs must stay allowed');
  }
  const fieldFixtures = [
    ['label', `return { label: row.name };`],
    ['labelHash', `return { labelHash: hashedLabel };`],
    ['endpoint', `return { endpoint: server.endpoint };`],
    ['url', `return { url: subscriptionUrl };`],
    ['credential', `return { credential: authMaterial };`],
    ['sessionId', `return { sessionId: active.sessionId };`],
    ['rawDetail', `return { rawDetail: error.message };`]
  ];
  for (const [fieldName, fixture] of fieldFixtures) {
    assert.deepEqual(collectPublicSinkMatches(fixture), [], `${fieldName} field fixture must fail through the field scanner only`);
    assert.notDeepEqual(collectForbiddenPublicFixtureFields(fixture), [], `${fieldName} field fixture must trip the field scanner`);
  }

  const schemaFixtures = [
    ['label', { properties: { label: { type: 'string' } }, required: ['label'] }],
    ['labelHash', { properties: { labelHash: { type: 'string' } }, required: ['labelHash'] }],
    ['endpoint', { properties: { endpoint: { type: 'string' } }, required: ['endpoint'] }],
    ['url', { properties: { url: { type: 'string' } }, required: ['url'] }],
    ['credential', { properties: { credential: { type: 'string' } }, required: ['credential'] }],
    ['sessionId', { properties: { sessionId: { type: 'string' } }, required: ['sessionId'] }],
    ['rawDetail', { properties: { rawDetail: { type: 'string' } }, required: ['rawDetail'] }]
  ];
  for (const [fieldName, schemaFixture] of schemaFixtures) {
    assert.notDeepEqual(
      collectForbiddenSchemaKeys(schemaFixture, SYNTHETIC_FORBIDDEN_SCHEMA_KEYS),
      [],
      `${fieldName} schema fixture must reject the forbidden public key`
    );
  }

  const sinkFixtures = [
    ['log template', `console.info(\`node ${'${row.name}'}\`);`],
    ['log concat left', `console.info('url=' + subscriptionUrl);`],
    ['log concat right', `console.info(subscriptionUrl + ' selected');`],
    ['console direct endpoint', `console.info(endpoint);`],
    ['console raw error message', `console.info(error.message);`],
    ['hilog public arg', `hilog.info(0, 'OneClick', '%{public}s', endpoint);`],
    ['hilog direct sensitive arg', `hilog.info(0, 'OneClick', endpoint);`],
    ['error interpolation', `throw new Error(\`credential ${'${credential}'}\`);`],
    ['error concat', `throw new Error('session=' + sessionId);`],
    ['new Error endpoint', `throw new Error(endpoint);`],
    ['new Error raw error message', `throw new Error(error.message);`],
    ['json stringify sink', `JSON.stringify(result);`],
    ['json stringify object literal', `JSON.stringify({ endpoint });`],
    ['json stringify identifier', `JSON.stringify(sensitiveObject);`]
  ];
  for (const [label, fixture] of sinkFixtures) {
    assert.notDeepEqual(collectPublicSinkMatches(fixture), [], `${label} fixture must trip the public sink scanner`);
  }

  const multilineSinkFixtures = [
    ['multiline console concat', `console.info(\n  'url=' +\n  subscriptionUrl\n);`],
    ['multiline console direct endpoint', `console.info(\n  endpoint\n);`],
    ['multiline console raw error message', `console.info(\n  error.message\n);`],
    ['multiline hilog public arg', `hilog.info(\n  0,\n  'OneClick',\n  '%{public}s',\n  endpoint\n);`],
    ['multiline hilog direct sensitive arg', `hilog.info(\n  0,\n  'OneClick',\n  endpoint\n);`],
    ['multiline new Error interpolation', `throw new Error(\n  \`credential ${'${credential}'}\`\n);`],
    ['multiline new Error concat', `throw new Error(\n  'session=' +\n  sessionId\n);`],
    ['multiline new Error endpoint', `throw new Error(\n  endpoint\n);`],
    ['multiline new Error raw error message', `throw new Error(\n  error.message\n);`],
    ['multiline JSON.stringify', `JSON.stringify(\n  result\n);`],
    ['multiline JSON.stringify object literal', `JSON.stringify(\n  { endpoint }\n);`],
    ['multiline JSON.stringify identifier', `JSON.stringify(\n  sensitiveObject\n);`]
  ];
  for (const [label, fixture] of multilineSinkFixtures) {
    assert.notDeepEqual(collectPublicSinkMatches(fixture), [], `${label} fixture must trip the multiline sink scanner`);
  }

  const exportInterfaceFixtures = [
    ['label', `export interface LeakyLabel { label?: string; }`],
    ['labelHash', `export interface LeakyLabelHash { labelHash?: string; }`],
    ['endpoint', `export interface LeakyEndpoint { endpoint?: string; }`],
    ['url', `export interface LeakyUrl { url?: string; }`],
    ['credential', `export interface LeakyCredential { credential?: string; }`],
    ['sessionId', `export interface LeakySession { sessionId?: string; }`],
    ['rawDetail', `export interface LeakyRawDetail { rawDetail?: string; }`]
  ];
  for (const [label, fixture] of exportInterfaceFixtures) {
    assert.notDeepEqual(
      collectForbiddenExportInterfaceFieldMatches(fixture),
      [],
      `${label} exported interface fixture must trip the public field scanner`
    );
  }

  const privateInterfaceSafe = `
    interface PrivateIdentity {
      sessionId?: string;
    }
  `;
  const exportTypeFixtures = [
    ['label export type object', `export type LeakyLabel = { label?: string; };`],
    ['endpoint export type readonly', `export type LeakyReadonly = Readonly<{ endpoint?: string; }>;`],
    ['sessionId export type union', `export type LeakyUnion = { sessionId?: string; } | { ok: boolean; };`],
    ['rawDetail export type union right branch', `export type LeakyUnionRight = { ok: boolean; } | { rawDetail?: string; };`]
  ];
  for (const [label, fixture] of exportTypeFixtures) {
    assert.notDeepEqual(
      collectForbiddenExportInterfaceFieldMatches(fixture),
      [],
      `${label} fixture must trip the public field scanner`
    );
  }
  const privateTypeSafe = `
    type PrivateIdentity = {
      sessionId?: string;
    };
  `;
  assert.deepEqual(
    collectForbiddenExportInterfaceFieldMatches(privateInterfaceSafe),
    [],
    'non-exported private interfaces must stay outside the public field scanner'
  );
  assert.deepEqual(
    collectForbiddenExportInterfaceFieldMatches(privateTypeSafe),
    [],
    'non-exported private types must stay outside the public field scanner'
  );
});

test('one-click vpn public surfaces stay redacted and documentation stays package-neutral', async () => {
  const bucketEntries = await Promise.all(
    Object.entries(PUBLIC_SOURCE_BUCKETS).map(async ([bucketName, filePaths]) => ({
      bucketName,
      source: (await Promise.all(filePaths.map(readUtf8))).join('\n')
    }))
  );
  const [docSource, modelSource] = await Promise.all([
    readUtf8(DOC_PATH),
    readUtf8(ONE_CLICK_MODELS_PATH)
  ]);

  for (const { bucketName, source } of bucketEntries) {
    assert.deepEqual(
      collectPublicSinkMatches(source),
      [],
      `${bucketName} public bucket must stay free of label endpoint credential session and raw-detail leaks`
    );
  }
  for (const publicInterfaceSourcePath of PUBLIC_INTERFACE_SOURCES) {
    const publicInterfaceSource = await readUtf8(publicInterfaceSourcePath);
    assert.deepEqual(
      collectForbiddenExportInterfaceFieldMatches(publicInterfaceSource),
      [],
      `${path.basename(publicInterfaceSourcePath)} exported public interfaces must stay free of forbidden output fields`
    );
  }

  for (const required of [
    '# Harmony One-Click VPN Contract',
    'Public success enums:',
    'Public failure stages:',
    'Public failure codes:',
    'Progress stages:',
    'Ownership and ordering:',
    'Safe error resource IDs:',
    'Focused verification command:',
    'Full structure suite command:',
    'Privacy guarantee:'
  ]) {
    assert.equal(docSource.includes(required), true, `missing doc contract: ${required}`);
  }
  for (const required of [
    '- `ADMISSION`',
    '- `SELECTION`',
    '- `VPN_START`',
    '- `VPN_CONFIRMATION`',
    'The stopped path persists selection before requesting VPN start and publishes success only after confirmation reaches `RUNNING` with same-group runtime selection.',
    'The running-VPN path hot-switches through proxy selection only and preserves the active VPN session.',
    'Shared runtime `STARTING` and `STOPPING` states fail closed as busy admission results.',
    'Retained diagnostic and TUN internals are implementation detail, not public API.'
  ]) {
    assert.equal(docSource.includes(required), true, `missing vpn-only doc contract: ${required}`);
  }
  assert.doesNotMatch(docSource, /\bLOCAL_STOP\b/u,
    'doc must not publish LOCAL_STOP as a public failure stage'
  );
  assert.doesNotMatch(docSource, /\bLOCAL_STOP_FAILED\b/u,
    'doc must not publish LOCAL_STOP_FAILED as a public failure code'
  );
  assert.doesNotMatch(docSource, /\bSTOPPING_LOCAL\b/u,
    'doc must not publish STOPPING_LOCAL as a public progress stage'
  );
  assert.doesNotMatch(docSource, /\bproxies_one_click_local_stop_failed\b/u,
    'doc must not publish the local-stop resource id'
  );
  assert.doesNotMatch(docSource, /The local-running path drains delay work, stops local runtime, re-queries the displayed group, persists the refreshed generation, then starts VPN\./u,
    'doc must not describe the removed local-stop ordering'
  );
  assert.doesNotMatch(docSource, /\b(?:groupName|memberName|nodeName|label|endpoint|sessionId|deviceId)\b/u,
    'doc must not leak live labels identities or device data'
  );
  assert.doesNotMatch(docSource, /(?:https?:\/\/|content:\/\/|token=|password|credential|secret|\.hap\b|signing|keystore|\.p12\b|\.cer\b|\.pem\b)/iu,
    'doc must not leak URLs credentials or signing material'
  );
});

test('one-click vpn device proof schema, example, and writer enforce exact aggregate pass or canonical incomplete shapes', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const schema = JSON.parse(await readUtf8(SCHEMA_PATH));
  const example = JSON.parse(await readUtf8(EXAMPLE_PATH));
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-proof-writer-'));
  const outputPath = path.join(tempRoot, 'proxy-one-click-vpn-device-proof.json');

  assert.equal(typeof runner.validateProxyOneClickVpnProofDocument, 'function');
  assert.equal(typeof runner.writeValidatedProxyOneClickVpnProof, 'function');

  assert.equal((await runner.validateProxyOneClickVpnProofDocument(createPassingDeviceProof(), schema)).valid, true);
  assert.equal((await runner.validateProxyOneClickVpnProofDocument(createIncompleteDeviceProof(), schema)).valid, true);
  assert.equal((await runner.validateProxyOneClickVpnProofDocument(example, schema)).valid, true);

  const partialPass = {
    ...createPassingDeviceProof(),
    runningSwitchState: 'NOT_PROVEN'
  };
  assert.equal(
    (await runner.validateProxyOneClickVpnProofDocument(partialPass, schema)).valid,
    false,
    'result=pass must prove every aggregate state'
  );

  const recreationNotProven = {
    ...createPassingDeviceProof(),
    recreationState: 'NOT_PROVEN'
  };
  assert.equal(
    (await runner.validateProxyOneClickVpnProofDocument(recreationNotProven, schema)).valid,
    false,
    'result=pass must reject recreation NOT_PROVEN'
  );

  const unknownRecreationState = {
    ...createIncompleteDeviceProof(),
    recreationState: 'RESTORED_BUT_PRIVATE'
  };
  assert.equal(
    (await runner.validateProxyOneClickVpnProofDocument(unknownRecreationState, schema)).valid,
    false,
    'recreationState must stay inside the fixed closed enum'
  );

  const legacyBranchKey = `localTo${'VpnState'}`;
  assert.equal(
    (await runner.validateProxyOneClickVpnProofDocument({
      ...createPassingDeviceProof(),
      [legacyBranchKey]: 'legacy'
    }, schema)).valid,
    false,
    'legacy local-to-vpn state must be rejected by the v2 schema'
  );

  for (const forbiddenKey of [
    'label',
    'labelHash',
    'endpoint',
    'url',
    'credential',
    'timestamp',
    'sessionId',
    'profileId',
    'versionId',
    'failureCode',
    'deviceId',
    'layout',
    'journal',
    'rawDetail',
    'unknownKey'
  ]) {
    assert.equal(
      (await runner.validateProxyOneClickVpnProofDocument({
        ...createPassingDeviceProof(),
        [forbiddenKey]: 'private'
      }, schema)).valid,
      false,
      `${forbiddenKey} must be rejected from the persisted proof`
    );
  }

  assert.equal(
    (await runner.validateProxyOneClickVpnProofDocument({
      ...createPassingDeviceProof(),
      packageSha256: 'A'.repeat(64)
    }, schema)).valid,
    false,
    'packageSha256 must stay lower-hex only'
  );

  const persisted = await runner.writeValidatedProxyOneClickVpnProof({
    ...createPassingDeviceProof(),
    packageSha256: 'oops'
  }, outputPath);
  assert.deepEqual(
    persisted,
    createIncompleteDeviceProof(),
    'writer must canonicalize invalid pass proofs to the fixed incomplete shape'
  );
});

test('one-click vpn device proof CLI stays strict and invalid args still write a canonical incomplete proof to a safe --out path', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-cli-'));
  const safeOutputPath = path.join(tempRoot, 'proxy-one-click-vpn-device-proof.json');

  assert.equal(typeof runner.parseCliArguments, 'function');
  assert.deepEqual(
    runner.parseCliArguments([], REPO_ROOT),
    {
      productionHapPath: path.join(HARMONY_ROOT, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap'),
      outputPath: path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-vpn-device-proof.json')
    }
  );
  assert.throws(() => runner.parseCliArguments(['--wat'], REPO_ROOT), /Unknown argument/u);
  assert.throws(() => runner.parseCliArguments(['--out'], REPO_ROOT), /requires a value|Missing value/u);

  const spawned = spawnSync(
    process.execPath,
    [RUNNER_PATH, '--wat', 'boom', '--out', safeOutputPath],
    { cwd: REPO_ROOT, encoding: 'utf8' }
  );

  assert.notEqual(spawned.status, 0);
  assert.deepEqual(
    JSON.parse(await readUtf8(safeOutputPath)),
    createIncompleteDeviceProof(),
    'CLI parse failure must still persist the fixed incomplete document to a safe output path'
  );

  const externalRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-external-'));
  const symlinkRoot = path.join(tempRoot, 'symlink-out');
  await fs.symlink(externalRoot, symlinkRoot);
  await assert.rejects(
    async () => await runner.writeValidatedProxyOneClickVpnProof(
      createIncompleteDeviceProof(),
      path.join(symlinkRoot, 'proof.json')
    ),
    /repository without symlink hops/u
  );
});

test('one-click vpn device proof runner persists pass from injected orchestration plus cleanup and removes local temp roots', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-runner-pass-'));
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const outputPath = path.join(tempRoot, 'proxy-one-click-vpn-device-proof.json');
  const trackingFs = createTrackingFs();
  let orchestrationCalls = 0;
  let cleanupCalls = 0;
  await fs.writeFile(productionHapPath, 'signed-hap', 'utf8');

  const proof = await runner.runProxyOneClickVpnDeviceProof({
    productionHapPath,
    outputPath,
    repoRoot: REPO_ROOT,
    fsApi: trackingFs,
    hashFileImpl: async () => ({ sha256: 'b'.repeat(64), sizeBytes: 10 }),
    orchestrationImpl: async () => {
      orchestrationCalls += 1;
      return {
        stoppedToVpnState: 'RUNNING_SELECTED',
        runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
        recreationState: 'RESTORED_RUNNING_SELECTED'
      };
    },
    cleanupImpl: async () => {
      cleanupCalls += 1;
      return 'CLEAN';
    }
  });

  assert.equal(orchestrationCalls, 1);
  assert.equal(cleanupCalls, 1);
  assert.deepEqual(proof, createPassingDeviceProof('b'.repeat(64)));
  assert.equal(trackingFs.createdRoots.length, 2);
  assert.deepEqual(
    trackingFs.createdRoots.slice().sort(),
    trackingFs.removedRoots.filter((value) => !value.includes('.tmp')).slice().sort(),
    'runner must remove both local layout/runtime temp roots after success'
  );
});

test('one-click vpn device proof runner still cleans up once after orchestration failure and downgrades cleanup or rm failures to exact incomplete', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-runner-fail-'));
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const outputPath = path.join(tempRoot, 'proxy-one-click-vpn-device-proof.json');
  await fs.writeFile(productionHapPath, 'signed-hap', 'utf8');

  let cleanupCalls = 0;
  const orchestrateFailure = await runner.runProxyOneClickVpnDeviceProof({
    productionHapPath,
    outputPath,
    repoRoot: REPO_ROOT,
    hashFileImpl: async () => ({ sha256: 'c'.repeat(64), sizeBytes: 10 }),
    orchestrationImpl: async () => {
      throw Object.assign(new Error('boom'), { code: 'PROXY_ONE_CLICK_TEST_FAILURE' });
    },
    cleanupImpl: async () => {
      cleanupCalls += 1;
      return 'CLEAN';
    }
  });
  assert.equal(cleanupCalls, 1);
  assert.deepEqual(orchestrateFailure, {
    ...createIncompleteDeviceProof(),
    packageSha256: 'c'.repeat(64)
  });

  let cleanupThrowCalls = 0;
  const cleanupFailure = await runner.runProxyOneClickVpnDeviceProof({
    productionHapPath,
    outputPath,
    repoRoot: REPO_ROOT,
    hashFileImpl: async () => ({ sha256: 'd'.repeat(64), sizeBytes: 10 }),
    orchestrationImpl: async () => ({
      stoppedToVpnState: 'RUNNING_SELECTED',
      runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
      recreationState: 'RESTORED_RUNNING_SELECTED'
    }),
    cleanupImpl: async () => {
      cleanupThrowCalls += 1;
      throw Object.assign(new Error('cleanup boom'), { code: 'PROXY_ONE_CLICK_CLEANUP_FAILED' });
    }
  });
  assert.equal(cleanupThrowCalls, 1);
  assert.deepEqual(cleanupFailure, {
    ...createIncompleteDeviceProof(),
    packageSha256: 'd'.repeat(64)
  });

  const rmTrackingFs = createTrackingFs(fs);
  const rmProbePath = await fs.mkdtemp(path.join(os.tmpdir(), 'proxy-one-click-rm-probe-'));
  rmTrackingFs.rm = async (targetPath, rmOptions) => {
    const normalized = String(targetPath);
    rmTrackingFs.removedRoots.push(normalized);
    if (normalized.includes('proxy-one-click-vpn-runtime-')) {
      throw Object.assign(new Error('synthetic rm failure'), { code: 'RM_FAILED' });
    }
    return await fs.rm(targetPath, rmOptions);
  };
  await fs.rm(rmProbePath, { recursive: true, force: true });
  const rmFailure = await runner.runProxyOneClickVpnDeviceProof({
    productionHapPath,
    outputPath,
    repoRoot: REPO_ROOT,
    fsApi: rmTrackingFs,
    hashFileImpl: async () => ({ sha256: 'e'.repeat(64), sizeBytes: 10 }),
    orchestrationImpl: async () => ({
      stoppedToVpnState: 'RUNNING_SELECTED',
      runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
      recreationState: 'RESTORED_RUNNING_SELECTED'
    }),
    cleanupImpl: async () => 'CLEAN'
  });
  assert.deepEqual(rmFailure, {
    ...createIncompleteDeviceProof(),
    packageSha256: 'e'.repeat(64)
  });
});

test('one-click vpn cleanup helper attempts each seam once and the bundle runtime delete helper proves rm plus absence', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const seamCalls = [];

  await runner.performProxyOneClickVpnCleanup({
    targetContext: {
      target: 'device-1',
      hdcCommand: 'hdc-bin',
      execImpl: async () => {
        throw new Error('unexpected direct exec');
      },
      cwd: REPO_ROOT
    },
    ensureVpnStoppedImpl: async () => { seamCalls.push('vpn'); },
    deleteProxyOneClickVpnRuntimeJournalImpl: async () => { seamCalls.push('journal'); },
    forceStopProductionAppImpl: async () => { seamCalls.push('prod'); },
    forceStopProbeAppImpl: async () => { seamCalls.push('probe'); }
  });
  assert.deepEqual(seamCalls, ['vpn', 'journal', 'prod', 'probe']);

  const throwingCalls = [];
  await assert.rejects(
    async () => await runner.performProxyOneClickVpnCleanup({
      targetContext: {
        target: 'device-1',
        hdcCommand: 'hdc-bin',
        execImpl: async () => {
          throw new Error('unexpected direct exec');
        },
        cwd: REPO_ROOT
      },
      ensureVpnStoppedImpl: async () => { throwingCalls.push('vpn'); },
      deleteProxyOneClickVpnRuntimeJournalImpl: async () => {
        throwingCalls.push('journal');
        throw Object.assign(new Error('journal-failed'), { code: 'PROXY_ONE_CLICK_CLEANUP_FAILED' });
      },
      forceStopProductionAppImpl: async () => {
        throwingCalls.push('prod');
      },
      forceStopProbeAppImpl: async () => { throwingCalls.push('probe'); },
    }),
    /PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );
  assert.deepEqual(throwingCalls, ['vpn', 'journal', 'prod', 'probe']);

  const execCalls = [];
  await runner.deleteProxyOneClickVpnRuntimeJournal({
    target: 'device-1',
    hdcCommand: 'hdc-bin',
    cwd: REPO_ROOT,
    execImpl: async (command, args) => {
      execCalls.push({ command, args });
      return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
    }
  });
  assert.equal(execCalls.length, 2);
  assert.match(execCalls[0].args.join(' '), /rm -f/u);
  assert.match(execCalls[1].args.join(' '), /test ! -e/u);
});

test('one-click vpn mission dump analyzer is tri-state and waitForUiGone fail-closes on unrecognized mission output', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  assert.equal(typeof runner.analyzeEntryAbilityMissionDump, 'function');
  assert.equal(typeof runner.waitForUiGone, 'function');

  const presentDump = `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.github.kr328.clash.harmony:entry:EntryAbility]
    app name [com.github.kr328.clash.harmony]
    bundle name [com.github.kr328.clash.harmony]
    main name [EntryAbility]
}
`;
  assert.equal(runner.analyzeEntryAbilityMissionDump(presentDump), 'PRESENT');

  const absentDump = `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.example.other:entry:OtherAbility]
    app name [com.example.other]
    bundle name [com.example.other]
    main name [OtherAbility]
}
`;
  assert.equal(runner.analyzeEntryAbilityMissionDump(absentDump), 'ABSENT');

  const emptyActualDump = `
User ID #100
current mission lists:{
}
`;
  assert.equal(runner.analyzeEntryAbilityMissionDump(emptyActualDump), 'ABSENT');
  assert.equal(runner.analyzeEntryAbilityMissionDump('Mission List: []\n'), 'ABSENT');
  assert.equal(runner.analyzeEntryAbilityMissionDump('mission records: none\n'), 'ABSENT');

  for (const dump of [
    `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.example.other:entry:OtherAbility]
    app name [com.example.other]
    bundle name [com.example.other]
    main name [OtherAbility]
`,
    `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.example.other:entry:OtherAbility]
    bundle name [com.example.other]
    main name [OtherAbility]
}}
`,
    '',
    'User #100 current mission lists:{\n}\n',
    'bundle name [com.github.kr328.clash.harmony]\n',
    'mission name #[#com.github.kr328.clash.harmony:entry:EntryAbility]\n',
    'bundle name [com.github.kr328.clash.harmony]\nmain name [EntryAbility]\n',
    `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.github.kr328.clash.harmony:entry:EntryAbility]
    bundle name [com.github.kr328.clash.harmony]
`,
    `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.example.other:entry:OtherAbility]
    bundle name [com.example.other]
    main name [OtherAbility]
}
User ID #101
bundle name [com.github.kr328.clash.harmony]
main name [EntryAbility]
`,
    'totally changed formatting without mission grammar\n'
  ]) {
    assert.equal(runner.analyzeEntryAbilityMissionDump(dump), 'UNRECOGNIZED');
  }

  let reads = 0;
  let launches = 0;
  await assert.rejects(
    async () => await runner.waitForUiGone(
      {
        target: 'device-1',
        hdcCommand: 'hdc-bin',
        execImpl: async () => {
          throw new Error('unexpected direct exec');
        },
        cwd: REPO_ROOT
      },
      {
        attempts: 3,
        delayImpl: async () => {},
        readAbilityMissionDumpImpl: async () => {
          reads += 1;
          return `
User ID #100
current mission lists:{
  Mission record #1
    mission name #[#com.example.other:entry:OtherAbility]
    app name [com.example.other]
    bundle name [com.example.other]
    main name [OtherAbility]
`;
        },
        launchProductionAppImpl: async () => {
          launches += 1;
        }
      }
    ),
    /PROXY_ONE_CLICK_UI_EXIT_NOT_PROVEN/u
  );
  assert.equal(reads, 3, 'waitForUiGone must stay bounded while mission output remains unrecognized');
  assert.equal(launches, 0, 'waitForUiGone must not relaunch or advance after unrecognized mission output');
});

test('one-click vpn recreation helper requires ability-only exit, vanished old UI, relaunch, hydrated marker restore, and a post-recreation hot switch', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  assert.equal(typeof runner.verifyProxyOneClickVpnRecreation, 'function');

  const orchestrationSteps = [];
  let clickCount = 0;
  let selectedPollCount = 0;
  let visibleSelectionCount = 0;

  const restoredLayout = createProxyLayout([
    createProxyRow(0, { runtimeSelected: true }),
    createProxyRow(1),
    createProxyRow(2)
  ]);
  restoredLayout.root.attributes.scrollable = 'true';
  restoredLayout.root.bounds = { left: 0, top: 0, right: 360, bottom: 720 };

  const recreated = await runner.verifyProxyOneClickVpnRecreation({
    targetContext: {
      target: 'device-1',
      hdcCommand: 'hdc-bin',
      execImpl: async () => {
        throw new Error('unexpected direct exec');
      },
      cwd: REPO_ROOT
    },
    selectedIndex: 0,
    navigateToVpnCleanupHomeImpl: async () => {
      orchestrationSteps.push('home');
      return createHomeLayout({ vpnText: 'Stop VPN global capture', localText: 'Start Local proxy' });
    },
    exitUiAbilityOnlyImpl: async () => {
      orchestrationSteps.push('exit-ui-only');
    },
    waitForUiGoneImpl: async () => {
      orchestrationSteps.push('ui-gone');
      return true;
    },
    verifyRuntimeStillRunningWithoutUiImpl: async () => {
      orchestrationSteps.push('runtime-still-running');
      return true;
    },
    launchProductionAppImpl: async () => {
      orchestrationSteps.push('relaunch');
    },
    openProxyPageImpl: async () => {
      orchestrationSteps.push('reopen-proxies');
    },
    waitForExpectedRuntimeSelectedIndexImpl: async (_context, expectedIndex) => {
      selectedPollCount += 1;
      orchestrationSteps.push(selectedPollCount === 1 ? 'hydrated-marker' : 'post-recreation-hot-switch');
      assert.equal(expectedIndex, selectedPollCount === 1 ? 0 : 1);
      return restoredLayout;
    },
    waitForVisibleTerminalSelectionImpl: async (_context, excludedIndexes) => {
      visibleSelectionCount += 1;
      orchestrationSteps.push('find-next-terminal');
      assert.deepEqual(excludedIndexes, [0]);
      return {
        layout: restoredLayout,
        index: 1,
        selection: {
          node: createActionableProofNode('proxies.node.1'),
          bounds: { left: 0, top: 0, right: 320, bottom: 60 },
          centerX: 160,
          centerY: 30
        }
      };
    },
    clickLayoutNodeImpl: async (selection) => {
      clickCount += 1;
      orchestrationSteps.push(clickCount === 1 ? 'tap-after-recreation' : `unexpected-click:${selection.node.attributes.id}`);
      assert.equal(selection.node.attributes.id, 'proxies.node.1');
    }
  });

  assert.equal(recreated, 'RESTORED_RUNNING_SELECTED');
  assert.deepEqual(orchestrationSteps, [
    'home',
    'exit-ui-only',
    'ui-gone',
    'runtime-still-running',
    'relaunch',
    'reopen-proxies',
    'hydrated-marker',
    'find-next-terminal',
    'tap-after-recreation',
    'post-recreation-hot-switch'
  ]);
  assert.equal(clickCount, 1);
  assert.equal(selectedPollCount, 2);
  assert.equal(visibleSelectionCount, 1);
});

test('one-click vpn recreation helper fails closed on the first ambiguous restored marker without retrying or force-stopping the bundle', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  assert.equal(typeof runner.verifyProxyOneClickVpnRecreation, 'function');

  let selectedPollCount = 0;
  let launchCount = 0;
  let bundleForceStops = 0;

  await assert.rejects(
    async () => await runner.verifyProxyOneClickVpnRecreation({
      targetContext: {
        target: 'device-1',
        hdcCommand: 'hdc-bin',
        execImpl: async () => {
          throw new Error('unexpected direct exec');
        },
        cwd: REPO_ROOT
      },
      selectedIndex: 0,
      navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ vpnText: 'Stop VPN global capture' }),
      exitUiAbilityOnlyImpl: async () => {},
      waitForUiGoneImpl: async () => true,
      verifyRuntimeStillRunningWithoutUiImpl: async () => true,
      launchProductionAppImpl: async () => {
        launchCount += 1;
      },
      openProxyPageImpl: async () => {},
      waitForExpectedRuntimeSelectedIndexImpl: async () => {
        selectedPollCount += 1;
        throw Object.assign(new Error('safe fixed error'), { code: 'PROXY_ONE_CLICK_RUNTIME_SELECTED_AMBIGUOUS' });
      },
      waitForVisibleTerminalSelectionImpl: async () => {
        throw new Error('must not search for a second row after ambiguity');
      },
      clickLayoutNodeImpl: async () => {
        throw new Error('must not click after ambiguity');
      },
      forceStopProductionAppImpl: async () => {
        bundleForceStops += 1;
      }
    }),
    (error) => error?.code === 'PROXY_ONE_CLICK_RUNTIME_SELECTED_AMBIGUOUS'
  );

  assert.equal(launchCount, 1, 'recreation still relaunches once before fail-closing on ambiguity');
  assert.equal(selectedPollCount, 1, 'ambiguous restored marker must fail on the first hydrated-marker poll');
  assert.equal(bundleForceStops, 0, 'ability-only recreation must not bundle-force-stop before final cleanup');
});

test('one-click vpn cleanup navigation scrolls backward once then leaves detail and profiles before returning Home', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let reads = 0;
  let backwardScrolls = 0;
  let clicks = 0;
  let delays = 0;

  const proxyLayoutWithoutBack = createProxyLayout([
    createProxyRow(88),
    createProxyRow(89)
  ]);
  proxyLayoutWithoutBack.root.attributes.scrollable = 'true';
  proxyLayoutWithoutBack.root.bounds = { left: 0, top: 120, right: 360, bottom: 720 };

  const detailLayoutWithBack = createProxyLayout([
    createProxyRow(88),
    createProxyRow(89)
  ], [
    createActionableProofNode('detail.back', 'Back')
  ]);
  detailLayoutWithBack.root.attributes.scrollable = 'true';
  detailLayoutWithBack.root.bounds = { left: 0, top: 120, right: 360, bottom: 720 };

  const profilesLayoutWithBack = createProxyLayout([], [
    createActionableProofNode('profiles.back', 'Back')
  ]);

  const homeLayout = createHomeLayout({ vpnText: 'Stop VPN global capture' });
  const layouts = [proxyLayoutWithoutBack, detailLayoutWithBack, profilesLayoutWithBack, homeLayout];

  const navigatedLayout = await runner.navigateToVpnCleanupHome({
    readLayoutImpl: async () => {
      const next = layouts[Math.min(reads, layouts.length - 1)];
      reads += 1;
      return next;
    },
    clickLayoutNodeImpl: async (selection) => {
      clicks += 1;
      assert.equal(['detail.back', 'profiles.back'].includes(selection.node.attributes.id), true);
    },
    scrollBackwardImpl: async (selection) => {
      backwardScrolls += 1;
      assert.equal(selection.node.attributes.id, 'root');
    },
    delayImpl: async () => {
      delays += 1;
    },
    attempts: 4
  });

  assert.equal(navigatedLayout, homeLayout);
  assert.equal(reads, 4, 'cleanup navigation should re-read after scroll and both hierarchy back clicks');
  assert.equal(backwardScrolls, 1, 'cleanup navigation should use exactly one backward scroll to reveal the back action');
  assert.equal(clicks, 2, 'cleanup navigation should click detail and profiles back exactly once');
  assert.equal(delays, 3, 'cleanup navigation should delay after scroll and each async back transition');
});

test('one-click vpn cleanup navigation immediately fails on duplicate Home vpn actions without clicking or scrolling', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let reads = 0;
  let backwardScrolls = 0;
  let clicks = 0;
  let delays = 0;

  const ambiguousHomeLayout = createHomeLayout({ includeVpn: false });
  ambiguousHomeLayout.root.children.push(createActionableProofNode('home.vpn.action', 'Stop VPN global capture'));
  ambiguousHomeLayout.root.children.push(createActionableProofNode('home.vpn.action', 'Stop VPN global capture'));

  await assert.rejects(
    async () => await runner.navigateToVpnCleanupHome({
      readLayoutImpl: async () => {
        reads += 1;
        return ambiguousHomeLayout;
      },
      clickLayoutNodeImpl: async () => {
        clicks += 1;
      },
      scrollBackwardImpl: async () => {
        backwardScrolls += 1;
      },
      delayImpl: async () => {
        delays += 1;
      },
      attempts: 4
    }),
    /PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );

  assert.equal(reads, 1, 'duplicate Home actions must fail on the first read');
  assert.equal(clicks, 0, 'duplicate Home actions must not trigger a click');
  assert.equal(backwardScrolls, 0, 'duplicate Home actions must not trigger scroll fallback');
  assert.equal(delays, 0, 'duplicate Home actions must not enter retry delay');
});

test('one-click vpn cleanup navigation immediately fails on duplicate back actions without clicking or scrolling', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let reads = 0;
  let backwardScrolls = 0;
  let clicks = 0;
  let delays = 0;

  const ambiguousBackLayout = createProxyLayout([
    createProxyRow(88),
    createProxyRow(89)
  ], [
    createActionableProofNode('detail.back', 'Back'),
    createActionableProofNode('detail.back', 'Back')
  ]);
  ambiguousBackLayout.root.attributes.scrollable = 'true';
  ambiguousBackLayout.root.bounds = { left: 0, top: 120, right: 360, bottom: 720 };

  await assert.rejects(
    async () => await runner.navigateToVpnCleanupHome({
      readLayoutImpl: async () => {
        reads += 1;
        return ambiguousBackLayout;
      },
      clickLayoutNodeImpl: async () => {
        clicks += 1;
      },
      scrollBackwardImpl: async () => {
        backwardScrolls += 1;
      },
      delayImpl: async () => {
        delays += 1;
      },
      attempts: 4
    }),
    /PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );

  assert.equal(reads, 1, 'duplicate back actions must fail on the first read');
  assert.equal(clicks, 0, 'duplicate back actions must not click any ambiguous action');
  assert.equal(backwardScrolls, 0, 'duplicate back actions must not degrade into scroll fallback');
  assert.equal(delays, 0, 'duplicate back actions must not enter retry delay');
});

test('one-click vpn cleanup navigation immediately fails when Home poll after back click becomes ambiguous', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let reads = 0;
  let backwardScrolls = 0;
  let clicks = 0;
  let delays = 0;

  const proxyLayoutWithBack = createProxyLayout([
    createProxyRow(88),
    createProxyRow(89)
  ], [
    createActionableProofNode('detail.back', 'Back')
  ]);
  proxyLayoutWithBack.root.attributes.scrollable = 'true';
  proxyLayoutWithBack.root.bounds = { left: 0, top: 120, right: 360, bottom: 720 };

  const ambiguousHomeLayout = createHomeLayout({ includeVpn: false });
  ambiguousHomeLayout.root.children.push(createActionableProofNode('home.vpn.action', 'Stop VPN global capture'));
  ambiguousHomeLayout.root.children.push(createActionableProofNode('home.vpn.action', 'Stop VPN global capture'));

  const layouts = [proxyLayoutWithBack, ambiguousHomeLayout];
  await assert.rejects(
    async () => await runner.navigateToVpnCleanupHome({
      readLayoutImpl: async () => {
        const next = layouts[Math.min(reads, layouts.length - 1)];
        reads += 1;
        return next;
      },
      clickLayoutNodeImpl: async (selection) => {
        clicks += 1;
        assert.equal(selection.node.attributes.id, 'detail.back');
      },
      scrollBackwardImpl: async () => {
        backwardScrolls += 1;
      },
      delayImpl: async () => {
        delays += 1;
      },
      attempts: 4
    }),
    /PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );

  assert.equal(reads, 2, 'ambiguous Home poll should fail on the first post-click read');
  assert.equal(clicks, 1, 'back path still clicks once before the ambiguous Home poll');
  assert.equal(backwardScrolls, 0, 'ambiguous Home poll must not trigger scroll fallback after back click');
  assert.equal(delays, 1, 'detail back transition delays once before the ambiguous Home read');
});

test('one-click vpn cleanup navigation fails closed after bounded unchanged proxy-layout backward scroll attempts', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  let reads = 0;
  let backwardScrolls = 0;
  let clicks = 0;
  let delays = 0;

  const stalledProxyLayout = createProxyLayout([
    createProxyRow(88),
    createProxyRow(89)
  ]);
  stalledProxyLayout.root.attributes.scrollable = 'true';
  stalledProxyLayout.root.bounds = { left: 0, top: 120, right: 360, bottom: 720 };

  await assert.rejects(
    async () => await runner.navigateToVpnCleanupHome({
      readLayoutImpl: async () => {
        reads += 1;
        return stalledProxyLayout;
      },
      clickLayoutNodeImpl: async () => {
        clicks += 1;
      },
      scrollBackwardImpl: async (selection) => {
        backwardScrolls += 1;
        assert.equal(selection.node.attributes.id, 'root');
      },
      delayImpl: async () => {
        delays += 1;
      },
      attempts: 3
    }),
    /PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );

  assert.equal(reads, 3, 'cleanup navigation must stop after the bounded number of unchanged proxy-layout reads');
  assert.equal(backwardScrolls, 2, 'cleanup navigation should only scroll while another read attempt remains');
  assert.equal(clicks, 0, 'cleanup navigation must not synthesize a back click when none is actionable');
  assert.equal(delays, 2, 'cleanup navigation should only delay between bounded retry attempts');
});

test('one-click vpn proof writer removes temporary residue when write or rename fails', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-writer-fail-'));
  const outputPath = path.join(tempRoot, 'proof.json');

  const writeFailFs = createTrackingFs(fs, {
    writeFileImpl: async (filePath) => {
      if (String(filePath).includes('.tmp')) {
        throw Object.assign(new Error('write failed'), { code: 'WRITE_FAILED' });
      }
      return await fs.writeFile(filePath, '', 'utf8');
    }
  });
  await assert.rejects(
    async () => await runner.writeValidatedProxyOneClickVpnProof(createPassingDeviceProof(), outputPath, writeFailFs, REPO_ROOT),
    /write failed/u
  );
  for (const tempPath of writeFailFs.tempFiles) {
    assert.equal(await fileExists(tempPath), false, 'temp file must not survive a write failure');
  }

  const renameFailFs = createTrackingFs(fs, {
    renameImpl: async () => {
      throw Object.assign(new Error('rename failed'), { code: 'RENAME_FAILED' });
    }
  });
  await assert.rejects(
    async () => await runner.writeValidatedProxyOneClickVpnProof(createPassingDeviceProof(), outputPath, renameFailFs, REPO_ROOT),
    /rename failed/u
  );
  for (const tempPath of renameFailFs.tempFiles) {
    assert.equal(await fileExists(tempPath), false, 'temp file must not survive a rename failure');
  }
});

test('one-click vpn runner accepts exactly one HarmonyOS 6 physical target and rejects missing ambiguous simulator non-arm64 or api-19 targets before install', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const tempRoot = await fs.mkdtemp(path.join(HARMONY_ROOT, 'artifacts', 'proxy-one-click-target-'));
  const productionHapPath = path.join(tempRoot, 'entry-default-signed.hap');
  const outputPath = path.join(tempRoot, 'proof.json');
  await fs.writeFile(productionHapPath, 'signed-hap', 'utf8');

  async function runTargetCase({ stdout, facts, expectPass }) {
    const execCalls = [];
    const proof = await runner.runProxyOneClickVpnDeviceProof({
      productionHapPath,
      outputPath,
      repoRoot: REPO_ROOT,
      hashFileImpl: async () => ({ sha256: 'f'.repeat(64), sizeBytes: 10 }),
      toolchainInspectorImpl: async () => ({
        report: { result: 'pass' },
        resolved: { paths: { hdc: 'hdc-bin' } }
      }),
      execImpl: async (_command, args) => {
        execCalls.push(args);
        const joined = args.join(' ');
        if (joined.includes('list targets -v')) {
          return { exitCode: 0, stdout, stderr: '', timedOut: false };
        }
        if (joined.includes('param get')) {
          if (joined.includes('const.product.software.version')) {
            return { exitCode: 0, stdout: `${facts.buildVersion}\n`, stderr: '', timedOut: false };
          }
          if (joined.includes('const.ohos.apiversion') || joined.includes('const.product.apiversion')) {
            return { exitCode: 0, stdout: `${facts.apiVersion}\n`, stderr: '', timedOut: false };
          }
          if (joined.includes('const.product.cpu.abilist')) {
            return { exitCode: 0, stdout: `${facts.abi}\n`, stderr: '', timedOut: false };
          }
          if (joined.includes('const.product.model')) {
            return { exitCode: 0, stdout: `${facts.model}\n`, stderr: '', timedOut: false };
          }
          if (joined.includes('const.product.name')) {
            return { exitCode: 0, stdout: `${facts.product}\n`, stderr: '', timedOut: false };
          }
        }
        if (joined.includes('install -r')) {
          return { exitCode: 0, stdout: 'success', stderr: '', timedOut: false };
        }
        if (joined.includes('aa start')) {
          return { exitCode: 0, stdout: 'ok', stderr: '', timedOut: false };
        }
        return { exitCode: 0, stdout: '', stderr: '', timedOut: false };
      },
      orchestrationImpl: async () => ({
        stoppedToVpnState: 'RUNNING_SELECTED',
        runningSwitchState: 'HOT_SWITCHED_SAME_SESSION',
        recreationState: 'RESTORED_RUNNING_SELECTED'
      }),
      cleanupImpl: async () => 'CLEAN',
      requiresDeviceSetup: true
    });
    const installCalls = execCalls.filter((args) => args.join(' ').includes('install -r')).length;
    if (expectPass) {
      assert.deepEqual(proof, createPassingDeviceProof('f'.repeat(64)));
      assert.equal(installCalls, 1);
    } else {
      assert.deepEqual(proof, {
        ...createIncompleteDeviceProof(),
        packageSha256: 'f'.repeat(64)
      });
      assert.equal(installCalls, 0);
    }
  }

  await runTargetCase({
    stdout: 'device-1\n',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '20', abi: 'arm64-v8a', model: 'Mate', product: 'HMA' },
    expectPass: true
  });
  await runTargetCase({
    stdout: '',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '20', abi: 'arm64-v8a', model: 'Mate', product: 'HMA' },
    expectPass: false
  });
  await runTargetCase({
    stdout: 'device-1\ndevice-2\n',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '20', abi: 'arm64-v8a', model: 'Mate', product: 'HMA' },
    expectPass: false
  });
  await runTargetCase({
    stdout: 'simulator-target\n',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '20', abi: 'arm64-v8a', model: 'simulator', product: 'emulator' },
    expectPass: false
  });
  await runTargetCase({
    stdout: 'device-1\n',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '20', abi: 'armeabi-v7a', model: 'Mate', product: 'HMA' },
    expectPass: false
  });
  await runTargetCase({
    stdout: 'device-1\n',
    facts: { buildVersion: 'HarmonyOS 6.0.1', apiVersion: '19', abi: 'arm64-v8a', model: 'Mate', product: 'HMA' },
    expectPass: false
  });
});

test('one-click vpn stopped flow must verify Home vpn stop-mode before reporting RUNNING_SELECTED and action parsing accepts fixed english/chinese copy', async () => {
  const runner = await import(RUNNER_MODULE_PATH);

  assert.equal(await runner.verifyVpnRunning({
    navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ vpnText: 'Stop VPN global capture' })
  }), true);
  assert.equal(await runner.verifyVpnRunning({
    navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ vpnText: '停止 VPN 全局流量接管' })
  }), true);

  await assert.rejects(
    async () => await runner.verifyVpnRunning({
      navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ vpnText: 'Start VPN global capture' })
    }),
    /PROXY_ONE_CLICK_VPN_NOT_RUNNING/u
  );
  await assert.rejects(
    async () => await runner.verifyVpnRunning({
      navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ vpnText: '处理中' })
    }),
    /PROXY_ONE_CLICK_VPN_NOT_RUNNING/u
  );
  await assert.rejects(
    async () => await runner.verifyVpnRunning({
      navigateToVpnCleanupHomeImpl: async () => createHomeLayout({ includeVpn: false })
    }),
    /PROXY_ONE_CLICK_VPN_NOT_RUNNING|PROXY_ONE_CLICK_CLEANUP_FAILED/u
  );
});

test('one-click vpn semantic layout helpers stay label-free, exclude nested or active rows, and source-contract scroll exact rows only by semantic ids', async () => {
  const runner = await import(RUNNER_MODULE_PATH);
  const source = await readUtf8(RUNNER_PATH);

  const layout = createProxyLayout([
    createProxyRow(0, { runtimeSelected: true }),
    createProxyRow(1, { nestedGroup: true }),
    createProxyRow(2, { savedIntent: true }),
    createProxyRow(3)
  ]);
  const stableRuntimeLayout = createProxyLayout([
    createProxyRow(0, { runtimeSelected: true }),
    createProxyRow(1, { nestedGroup: true }),
    createProxyRow(2),
    createProxyRow(3)
  ]);
  const activationLayout = createProxyLayout([
    createProxyRow(0, { runtimeSelected: true }),
    createProxyRow(1, { activation: true }),
    createProxyRow(2)
  ]);
  const offsetLayout = createProxyLayout([
    createProxyRow(3, { runtimeSelected: true }),
    createProxyRow(4)
  ]);
  const selection = runner.selectNextTerminalSelection(layout);
  assert.equal(selection.index, 2, 'next terminal selection must skip the runtime-active row and nested group rows');
  assert.equal(runner.verifyRuntimeSelectedIndex(stableRuntimeLayout, 0), true);
  assert.equal(runner.selectNextTerminalSelection(activationLayout).index, 2, 'live activation rows must stay ineligible for selection');
  assert.equal(runner.selectNextTerminalSelection(offsetLayout).index, 4, 'visible offscreen slices may start from a non-zero semantic index');

  assert.throws(
    () => runner.analyzeProxyOneClickLayout(createProxyLayout([
      createProxyRow(0, { runtimeSelected: true }),
      createProxyRow(1, { runtimeSelected: true })
    ])),
    /PROXY_ONE_CLICK_RUNTIME_SELECTED_AMBIGUOUS/u
  );
  assert.throws(
    () => runner.selectNextTerminalSelection(createProxyLayout([
      createProxyRow(0, { runtimeSelected: true }),
      createProxyRow(1, { nestedGroup: true })
    ]), [0]),
    /PROXY_ONE_CLICK_TERMINAL_NOT_FOUND/u
  );
  assert.throws(
    () => runner.verifyRuntimeSelectedIndex(createProxyLayout([
      createProxyRow(0),
      createProxyRow(1, { savedIntent: true })
    ]), 1),
    /PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH/u
  );
  assert.throws(
    () => runner.analyzeProxyOneClickLayout(createProxyLayout([
      createProxyRow(0),
      createProxyRow(0)
    ])),
    /PROXY_ONE_CLICK_LAYOUT_ROW_AMBIGUOUS/u
  );

  let reads = 0;
  let scrolls = 0;
  await assert.rejects(
    async () => await runner.waitForExpectedRuntimeSelectedIndex({
      readLayoutImpl: async () => {
        reads += 1;
        const layout = createProxyLayout([
          createProxyRow(0, { runtimeSelected: true }),
          createProxyRow(1)
        ], [createProofNode('scroll-root', '', [])]);
        layout.root.attributes.scrollable = 'true';
        layout.root.bounds = { left: 0, top: 0, right: 360, bottom: 720 };
        return layout;
      },
      scrollForwardImpl: async () => {
        scrolls += 1;
      }
    }, 3, { attempts: 2 }),
    /PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH|PROXY_ONE_CLICK_TERMINAL_NOT_FOUND/u
  );
  assert.equal(reads, 2, 'expected-row polling must stay bounded');
  assert.equal(scrolls, 2, 'expected-row polling must attempt scrolling when the expected row is missing');

  let backwardScrolls = 0;
  await assert.rejects(
    async () => await runner.waitForExpectedRuntimeSelectedIndex({
      readLayoutImpl: async () => {
        const layout = createProxyLayout([
          createProxyRow(4),
          createProxyRow(5, { runtimeSelected: true }),
          createProxyRow(6)
        ]);
        layout.root.attributes.scrollable = 'true';
        layout.root.bounds = { left: 0, top: 400, right: 360, bottom: 720 };
        layout.root.children[0].bounds = { left: 0, top: 120, right: 360, bottom: 180 };
        layout.root.children[1].bounds = { left: 0, top: 220, right: 360, bottom: 280 };
        layout.root.children[2].bounds = { left: 0, top: 320, right: 360, bottom: 380 };
        return layout;
      },
      scrollForwardImpl: async () => {
        throw new Error('forward scroll should not be used for rows above the viewport');
      },
      scrollBackwardImpl: async () => {
        backwardScrolls += 1;
      }
    }, 4, { attempts: 2 }),
    /PROXY_ONE_CLICK_RUNTIME_SELECTED_MISMATCH|PROXY_ONE_CLICK_SCROLL_STALLED/u
  );
  assert.equal(backwardScrolls, 2, 'rows above the viewport must use backward scroll attempts');

  let stalledReads = 0;
  let stalledForward = 0;
  await assert.rejects(
    async () => await runner.waitForExpectedRuntimeSelectedIndex({
      readLayoutImpl: async () => {
        stalledReads += 1;
        const layout = createProxyLayout([
          createProxyRow(0, { runtimeSelected: true }),
          createProxyRow(1),
          createProxyRow(2)
        ]);
        layout.root.attributes.scrollable = 'true';
        layout.root.bounds = { left: 0, top: 0, right: 360, bottom: 720 };
        return layout;
      },
      scrollForwardImpl: async () => {
        stalledForward += 1;
      },
      scrollBackwardImpl: async () => {}
    }, 9, { attempts: 4 }),
    /PROXY_ONE_CLICK_SCROLL_STALLED/u
  );
  assert.equal(stalledReads >= 3, true, 'scroll stall guard must allow an initial unchanged frame before fail-closing');
  assert.equal(stalledForward >= 2, true, 'scroll stall guard should detect repeated no-progress scrolling');

  assert.match(source, /proxies\.node\.\(\?:\$\{index\}|\(\\d\+\)\)/u);
  assert.match(source, /runtime-selected/u);
  assert.match(source, /saved-intent/u);
  assert.match(source, /nested-group/u);
  assert.match(source, /activation/u);
  assert.match(source, /scrollLayoutNodeForward/u);
  assert.match(source, /scrollBackwardImpl/u);
  assert.match(source, /PROXY_ONE_CLICK_SCROLL_STALLED/u);
  assert.doesNotMatch(source, /readNodeVisibleLabel|hashSelectedTerminalLabel|selectedTerminalHash|analyzeProxySelectionLayout/u);
});

test('one-click vpn device proof source contract requires injected orchestration, click-then-poll proof order, exact cleanup, and probe force-stop ownership', async () => {
  const source = await readUtf8(RUNNER_PATH);

  assert.match(source, /const PROBE_BUNDLE = 'com\.cmfa\.phase4\.trafficprobe';/u);
  assert.match(source, /writeValidatedProofImpl/u);
  assert.match(source, /orchestrationImpl/u);
  assert.match(source, /cleanupImpl/u);
  assert.match(source, /buildProxyOneClickVpnRuntimeJournalDeleteArgs/u);
  assert.match(source, /deleteProxyOneClickVpnRuntimeJournal/u);
  assert.match(source, /performProxyOneClickVpnCleanup/u);
  assert.match(source, /navigateToVpnCleanupHome/u);
  assert.match(source, /ensureVpnStoppedImpl/u);
  assert.match(source, /forceStopBundle/u);
  assert.match(source, /phase4-runtime-evidence\.json/u);
  assert.match(source, /proxy-one-click-vpn-layout-/u);
  assert.match(source, /proxy-one-click-vpn-runtime-/u);
  assert.match(source, /shell', '-b', APP_BUNDLE, 'rm', '-f', RUNTIME_REMOTE_PATH/u);
  assert.match(source, /shell', '-b', APP_BUNDLE, 'test', '!', '-e', RUNTIME_REMOTE_PATH/u);
  assert.match(source, /force-stop', APP_BUNDLE/u);
  assert.match(source, /force-stop', PROBE_BUNDLE/u);
  assert.match(source, /proof\.result = 'pass';/u);
  assert.match(source, /proof\.result = 'incomplete';/u);
  assert.match(source, /proof\.recreationState = orchestration\.recreationState;/u);
  assert.match(source, /proof\.recreationState = 'NOT_PROVEN';/u);
  assert.match(source, /proof\.cleanupState = 'NOT_PROVEN';/u);
  assert.match(source, /maxAttempts:\s*8/u);
  assert.match(source, /try \{[\s\S]*finally \{/u);
  assert.match(source, /verifyProxyOneClickVpnRecreation/u);
  assert.match(source, /exitUiAbilityOnly/u);
  assert.match(source, /waitForUiGone/u);
  assert.match(source, /verifyRuntimeStillRunningWithoutUi/u);

  const orchestrationSource = sliceBetween(
    source,
    'export async function orchestrateProxyOneClickVpnDeviceProof(',
    'export async function performProxyOneClickVpnCleanup('
  );
  assertOrdered(orchestrationSource, [
    ['ensure runtimes stopped before first proof branch', 'await ensureVpnStoppedImpl('],
    ['open proxy page for stopped branch', 'await openProxyPage('],
    ['click terminal before consent detection', 'await clickLayoutNode(stoppedSelection.selection'],
    ['consent detection after click', 'await confirmConsentIfNeeded('],
    ['bounded runtime-selected poll after click', 'await waitForExpectedRuntimeSelectedIndex('],
    ['verify vpn running after marker success', 'await verifyVpnRunningImpl(targetContext)'],
    ['running branch captures private session before switching', 'const beforeSwitchSessionIdentity = await pullPrivateSessionIdentityImpl('],
    ['running branch clicks another terminal', 'await clickLayoutNode(runningSelection.selection'],
    ['running branch compares same private session after switch', 'const afterSwitchSessionIdentity = await pullPrivateSessionIdentityImpl('],
    ['recreation begins only after running hot switch stays alive', 'const recreationState = await verifyProxyOneClickVpnRecreation(']
  ]);

  const recreationBody = sliceBetween(
    source,
    '}) {\n  await navigateToVpnCleanupHomeImpl(targetContext);',
    'export async function orchestrateProxyOneClickVpnDeviceProof('
  );
  assertOrdered(recreationBody, [
    ['recreation exits UI ability only first', 'await exitUiAbilityOnlyImpl(targetContext);'],
    ['recreation proves the old UI disappears', 'await waitForUiGoneImpl(targetContext);'],
    ['recreation proves runtime stays running without UI', 'await verifyRuntimeStillRunningWithoutUiImpl(targetContext);'],
    ['recreation relaunches EntryAbility after UI disappearance', 'await launchProductionAppImpl({'],
    ['recreation reopens proxy page semantically', 'await openProxyPageImpl(targetContext);'],
    ['recreation proves hydrated runtime marker first', 'await waitForExpectedRuntimeSelectedIndexImpl(targetContext, selectedIndex, {'],
    ['recreation hot switches only after restored marker', 'const recreationSelection = await waitForVisibleTerminalSelectionImpl(targetContext, [selectedIndex],'],
    ['recreation returns the fixed success enum', "return 'RESTORED_RUNNING_SELECTED';"]
  ]);

  assert.doesNotMatch(source, /verifyRuntimeSelectedIndex\(stoppedLayout/u,
    'the stopped branch must not claim success before a real click and post-click poll'
  );
  assert.doesNotMatch(orchestrationSource, /forceStopProductionAppImpl|forceStopProductionApp\(/u,
    'ability-only recreation must not force-stop the bundle inside orchestration'
  );
  assert.doesNotMatch(recreationBody, /forceStopProductionAppImpl|forceStopProductionApp\(/u,
    'recreation body must not force-stop the bundle before final cleanup'
  );
  const runBody = sliceBetween(
    source,
    'export async function runProxyOneClickVpnDeviceProof(',
    'async function main('
  );
  assertOrdered(runBody, [
    ['orchestration resolves before cleanup', 'const orchestration = await orchestrationImpl('],
    ['cleanup runs after orchestration', 'proof.cleanupState = await cleanupImpl(']
  ]);
});

test('one-click vpn device proof documentation pins exact fields, command, controlled-failure boundary, and zero-private-data guarantee', async () => {
  const doc = await readUtf8(DEVICE_PROOF_DOC_PATH);

  for (const required of [
    '2.0.0',
    'schemaVersion',
    'result',
    'packageSha256',
    'stoppedToVpnState',
    'runningSwitchState',
    'recreationState',
    'cleanupState',
    'run-proxy-one-click-vpn-device-proof.mjs',
    'entry-default-signed.hap',
    'No Local-to-VPN scenario is part of schema v2.',
    'saved-marker/retryable-error failure path is proven through injectable shared/entry Hypium tests',
    'exit only the UIAbility',
    'bundle force-stop is forbidden until final cleanup',
    'RESTORED_RUNNING_SELECTED',
    'No node text, transport address, subscription location, auth material, private runtime identity, or raw platform detail',
    'zero private data'
  ]) {
    assert.equal(doc.includes(required), true, `missing device-proof doc contract: ${required}`);
  }
  assert.doesNotMatch(doc, /\b(?:groupName|memberName|nodeName|labelHash|sessionId|profileId|versionId|failureCode|deviceId|layout|journal)\b/u);
  assert.doesNotMatch(doc, /(?:https?:\/\/|content:\/\/|token=|password|credential|secret|signing|keystore|\.p12\b|\.cer\b|\.pem\b)/iu);
});
