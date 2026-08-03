const FILE_URL_PATTERN = /\bfile:\/\/[^\s"'<>]+/giu;
const URL_USERINFO_PATTERN = /\b([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^/\s:@]+):([^/\s@]+)@/gu;
const POSIX_PATH_PATTERN = /(^|[\s"'(=\[])(\/(?!\/)[^\s"'<>]+)(?=$|[\s"'<>)}\]])/gu;
const WINDOWS_PATH_PATTERN = /(^|[\s"'(=\[])([A-Za-z]:\\[^\s"'<>]+)(?=$|[\s"'<>)}\]])/gu;

export function createRedactionReplacements({ repoRoot, env = {}, homeDirectory = process.env.HOME ?? process.env.USERPROFILE ?? null }) {
  const replacements = new Map();
  if (repoRoot) {
    replacements.set(repoRoot, '<repo>');
  }
  for (const value of [env.DEVECO_SDK_HOME, env.HARMONY_SDK_HOME, env.OHOS_SDK_HOME, env.HOS_SDK_HOME]) {
    if (value) {
      replacements.set(value, '<sdk-root>');
    }
  }
  for (const value of [env.HOME, homeDirectory]) {
    if (value) {
      replacements.set(value, '<home>');
    }
  }
  return replacements;
}

export function sanitizeText(raw, replacements = new Map()) {
  let sanitized = String(raw ?? '');
  for (const [value, replacement] of replacements.entries()) {
    sanitized = sanitized.split(value).join(replacement);
  }

  sanitized = sanitized.replace(FILE_URL_PATTERN, 'file://<redacted>');
  sanitized = sanitized.replace(URL_USERINFO_PATTERN, (_, prefix) => `${prefix}<redacted-userinfo>@`);
  sanitized = sanitized.replace(POSIX_PATH_PATTERN, (_, prefix, token) => {
    if (token.startsWith('/<')) {
      return `${prefix}${token}`;
    }
    return `${prefix}<path>`;
  });
  sanitized = sanitized.replace(WINDOWS_PATH_PATTERN, (_, prefix) => `${prefix}<path>`);
  return sanitized;
}

export function sanitizeForPersistence(value, replacements = new Map()) {
  if (typeof value === 'string') {
    return sanitizeText(value, replacements);
  }
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeForPersistence(entry, replacements));
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, sanitizeForPersistence(entry, replacements)]));
  }
  return value;
}
