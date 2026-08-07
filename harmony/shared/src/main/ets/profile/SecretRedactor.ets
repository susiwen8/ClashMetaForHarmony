const URL_PATTERN: RegExp = /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s"'<>]+/g;
const POSIX_PATH_PATTERN: RegExp = /(^|[\s"'(=\[])(\/(?!\/)[^\s"'<>]+)(?=$|[\s"'<>)}\]])/g;
const INLINE_ASSIGNMENT_PATTERN: RegExp =
  /(token|password|secret|api-key|api_key|apikey|auth|authorization|passwd)(\s*=\s*)([^\s"'<>]+)/gi;
const INLINE_COLON_PATTERN: RegExp =
  /(token|password|secret|api-key|api_key|apikey|passwd)(\s*:\s*)([^\s"'<>]+)/gi;
const REDACTABLE_KEYS: string[] = [
  'token',
  'password',
  'secret',
  'api-key',
  'api_key',
  'apikey',
  'auth',
  'authorization',
  'passwd'
];
const REPOSITORY_HINT_SEGMENTS: string[] = ['harmony', '.git', '.worktrees'];
const HOME_HINT_SEGMENTS: string[] = ['.config', 'Downloads', 'Desktop', 'Documents', 'Library'];

interface ParsedSecretLine {
  indent: number;
  isBlockScalar: boolean;
  keyLiteral: string;
  normalizedKey: string;
  prefix: string;
  value: string;
}

function isAllowedSchemeCharacter(character: string): boolean {
  const code: number = character.charCodeAt(0);
  return (code >= 97 && code <= 122) ||
    (code >= 65 && code <= 90) ||
    (code >= 48 && code <= 57) ||
    character === '+' ||
    character === '.' ||
    character === '-';
}

function indexOfAny(value: string, characters: string[]): number {
  let smallest: number = -1;
  for (let index = 0; index < characters.length; index += 1) {
    const characterIndex: number = value.indexOf(characters[index]);
    if (characterIndex >= 0 && (smallest === -1 || characterIndex < smallest)) {
      smallest = characterIndex;
    }
  }
  return smallest;
}

function isRedactableKey(value: string): boolean {
  const normalizedValue: string = value.toLowerCase();
  for (let index = 0; index < REDACTABLE_KEYS.length; index += 1) {
    if (REDACTABLE_KEYS[index] === normalizedValue) {
      return true;
    }
  }
  return false;
}

function countIndent(line: string): number {
  let index: number = 0;
  while (index < line.length && (line[index] === ' ' || line[index] === '\t')) {
    index += 1;
  }
  return index;
}

function stripMatchingQuotes(value: string): string {
  if (value.length >= 2 && (
    (value[0] === '"' && value[value.length - 1] === '"') ||
    (value[0] === '\'' && value[value.length - 1] === '\'')
  )) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

function parseSecretLine(line: string): ParsedSecretLine | null {
  const indent: number = countIndent(line);
  let cursor: number = indent;
  if (line.substring(cursor, cursor + 2) === '- ') {
    cursor += 2;
  }

  if (cursor >= line.length) {
    return null;
  }

  let keyLiteral: string = '';
  let separatorIndex: number = -1;
  if (line[cursor] === '"' || line[cursor] === '\'') {
    const quote: string = line[cursor];
    let endQuoteIndex: number = cursor + 1;
    while (endQuoteIndex < line.length && line[endQuoteIndex] !== quote) {
      endQuoteIndex += 1;
    }
    if (endQuoteIndex >= line.length) {
      return null;
    }
    keyLiteral = line.substring(cursor, endQuoteIndex + 1);
    separatorIndex = line.indexOf(':', endQuoteIndex + 1);
    if (separatorIndex < 0) {
      return null;
    }
  } else {
    const colonIndex: number = line.indexOf(':', cursor);
    const equalsIndex: number = line.indexOf('=', cursor);
    if (colonIndex < 0 && equalsIndex < 0) {
      return null;
    }
    if (colonIndex >= 0 && (equalsIndex < 0 || colonIndex < equalsIndex)) {
      separatorIndex = colonIndex;
    } else {
      separatorIndex = equalsIndex;
    }
    keyLiteral = line.substring(cursor, separatorIndex).trim();
  }

  const normalizedKey: string = stripMatchingQuotes(keyLiteral).trim().toLowerCase();
  if (!isRedactableKey(normalizedKey)) {
    return null;
  }

  let valueStart: number = separatorIndex + 1;
  while (valueStart < line.length && (line[valueStart] === ' ' || line[valueStart] === '\t')) {
    valueStart += 1;
  }
  const value: string = line.substring(valueStart);
  if (separatorIndex === line.indexOf('=') && value.indexOf(' ') >= 0) {
    return null;
  }
  const isBlockScalar: boolean = value.length > 0 && (value[0] === '|' || value[0] === '>');
  return {
    indent,
    isBlockScalar,
    keyLiteral,
    normalizedKey,
    prefix: line.substring(0, valueStart),
    value
  };
}

function redactInlineSecretValue(value: string): string {
  if (value.length >= 2 && value[0] === '"' && value[value.length - 1] === '"') {
    return '"<redacted>"';
  }
  if (value.length >= 2 && value[0] === '\'' && value[value.length - 1] === '\'') {
    return '\'<redacted>\'';
  }
  return '<redacted>';
}

function redactStructuredSecrets(raw: string): string {
  const lines: string[] = raw.split('\n');
  let activeBlockIndent: number = -1;
  for (let index: number = 0; index < lines.length; index += 1) {
    const currentLine: string = lines[index];
    const trimmedLine: string = currentLine.trim();
    const currentIndent: number = countIndent(currentLine);

    if (activeBlockIndent >= 0) {
      if (trimmedLine.length === 0) {
        continue;
      }
      if (currentIndent > activeBlockIndent) {
        lines[index] = `${currentLine.substring(0, currentIndent)}<redacted>`;
        continue;
      }
      activeBlockIndent = -1;
    }

    const parsedLine: ParsedSecretLine | null = parseSecretLine(currentLine);
    if (parsedLine === null) {
      continue;
    }
    if (parsedLine.isBlockScalar) {
      activeBlockIndent = parsedLine.indent;
      continue;
    }
    lines[index] = `${parsedLine.prefix}${redactInlineSecretValue(parsedLine.value)}`;
  }
  return lines.join('\n');
}

function isAsciiLetter(character: string): boolean {
  const code: number = character.charCodeAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isPathBoundary(character: string): boolean {
  return character === ' ' ||
    character === '\t' ||
    character === '\n' ||
    character === '\r' ||
    character === '"' ||
    character === '\'' ||
    character === '<' ||
    character === '>' ||
    character === ')' ||
    character === '}' ||
    character === ']';
}

function isScannerBoundary(text: string, index: number): boolean {
  if (index === 0) {
    return true;
  }
  return isPathBoundary(text[index - 1]) ||
    text[index - 1] === '(' ||
    text[index - 1] === '[' ||
    text[index - 1] === '=';
}

function consumeWindowsPath(text: string, startIndex: number): number {
  const quoteBoundary: string = startIndex > 0 && (text[startIndex - 1] === '"' || text[startIndex - 1] === '\'')
    ? text[startIndex - 1]
    : '';
  let index: number = startIndex;
  while (index < text.length) {
    if (quoteBoundary.length > 0) {
      if (text[index] === quoteBoundary) {
        return index;
      }
      index += 1;
      continue;
    }
    if (isPathBoundary(text[index])) {
      return index;
    }
    index += 1;
  }
  return text.length;
}

function redactWindowsAbsolutePaths(rawText: string): string {
  let sanitized: string = '';
  let index: number = 0;
  while (index < rawText.length) {
    const hasDrivePath: boolean = isScannerBoundary(rawText, index) &&
      index + 2 < rawText.length &&
      isAsciiLetter(rawText[index]) &&
      rawText[index + 1] === ':' &&
      (rawText[index + 2] === '\\' || rawText[index + 2] === '/');
    const hasUncPath: boolean = isScannerBoundary(rawText, index) &&
      index + 1 < rawText.length &&
      rawText[index] === '\\' &&
      rawText[index + 1] === '\\';

    if (!hasDrivePath && !hasUncPath) {
      sanitized += rawText[index];
      index += 1;
      continue;
    }

    const endIndex: number = consumeWindowsPath(rawText, index);
    sanitized += classifyAbsolutePath(rawText.substring(index, endIndex));
    index = endIndex;
  }
  return sanitized;
}

function classifyAbsolutePath(pathToken: string): string {
  const normalizedPathToken: string = pathToken.replace(/\\/g, '/');
  const segments: string[] = normalizedPathToken.split('/');
  for (let index = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    for (let hintIndex = 0; hintIndex < REPOSITORY_HINT_SEGMENTS.length; hintIndex += 1) {
      if (segment === REPOSITORY_HINT_SEGMENTS[hintIndex]) {
        return '<repo>';
      }
    }
  }

  for (let index = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    for (let hintIndex = 0; hintIndex < HOME_HINT_SEGMENTS.length; hintIndex += 1) {
      if (segment === HOME_HINT_SEGMENTS[hintIndex]) {
        return '<home>';
      }
    }
  }
  return '<path>';
}

export function redactUrl(rawUrl: string): string {
  const separatorIndex: number = rawUrl.indexOf('://');
  if (separatorIndex <= 0) {
    return '<redacted-url>';
  }

  for (let index = 0; index < separatorIndex; index += 1) {
    if (!isAllowedSchemeCharacter(rawUrl[index])) {
      return '<redacted-url>';
    }
  }

  const scheme: string = rawUrl.substring(0, separatorIndex);
  const authorityStart: number = separatorIndex + 3;
  const remainder: string = rawUrl.substring(authorityStart);
  const authorityEndOffset: number = indexOfAny(remainder, ['/', '?', '#']);
  const authority: string = authorityEndOffset >= 0
    ? remainder.substring(0, authorityEndOffset)
    : remainder;
  if (authority.length === 0) {
    return `${scheme}://<redacted-host>`;
  }

  const atIndex: number = authority.lastIndexOf('@');
  const host: string = atIndex >= 0 ? authority.substring(atIndex + 1) : authority;
  if (host.length === 0) {
    return `${scheme}://<redacted-host>`;
  }
  return `${scheme}://${host}`;
}

export function redactSensitiveText(rawText: string): string {
  let sanitized: string = rawText;
  sanitized = sanitized.replace(URL_PATTERN, (match: string): string => {
    return redactUrl(match);
  });
  sanitized = redactStructuredSecrets(sanitized);
  sanitized = sanitized.replace(
    INLINE_ASSIGNMENT_PATTERN,
    (_match: string, key: string, separator: string): string => {
      return `${key}${separator}<redacted>`;
    }
  );
  sanitized = sanitized.replace(
    INLINE_COLON_PATTERN,
    (_match: string, key: string, separator: string): string => {
      return `${key}${separator}<redacted>`;
    }
  );
  sanitized = sanitized.replace(
    POSIX_PATH_PATTERN,
    (_match: string, prefix: string, token: string): string => {
      return `${prefix}${classifyAbsolutePath(token)}`;
    }
  );
  sanitized = redactWindowsAbsolutePaths(sanitized);
  return sanitized;
}

export function redactCoreEventMessage(_rawMessage: string): string {
  return 'Core event received.';
}
