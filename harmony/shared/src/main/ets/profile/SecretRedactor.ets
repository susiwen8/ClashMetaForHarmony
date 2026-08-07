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

function replaceCredentialLine(line: string): string {
  let start: number = 0;
  while (start < line.length && (line[start] === ' ' || line[start] === '\t' || line[start] === '-')) {
    start += 1;
  }

  let separatorIndex: number = line.indexOf(':', start);
  if (separatorIndex < 0) {
    return line;
  }

  const key: string = line.substring(start, separatorIndex).trim().toLowerCase();
  if (!isRedactableKey(key)) {
    return line;
  }

  return `${line.substring(0, separatorIndex + 1)} <redacted>`;
}

function redactCredentialLines(raw: string): string {
  const lines: string[] = raw.split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    lines[index] = replaceCredentialLine(lines[index]);
  }
  return lines.join('\n');
}

function classifyAbsolutePath(pathToken: string): string {
  const segments: string[] = pathToken.split('/');
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
  sanitized = redactCredentialLines(sanitized);
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
  return sanitized;
}

export function redactCoreEventMessage(_rawMessage: string): string {
  return 'Core event received.';
}
