const FIXED_ERROR_CODE = 'EXTERNAL_ORIGIN_CONFIG_INVALID';
const FIXED_ERROR_MESSAGE = 'Phase 4 external origin configuration was invalid.';
const FIXED_ERROR_DETAIL = 'Phase 4 external origin must use canonical public IPv4 endpoints and exact integer ports.';

const DEFAULT_PROVIDER_ALIAS = 'public-echo-v1';
const DEFAULT_ORIGIN = Object.freeze({
  hostIpv4: '52.43.121.77',
  tcpHostIpv4: '223.5.5.5',
  tcpPort: 80,
  udpPort: 10001,
  dnsPort: 10001
});

const EXACT_KEYS = Object.freeze(['hostIpv4', 'tcpHostIpv4', 'tcpPort', 'udpPort', 'dnsPort']);

function createInvalidExternalOriginError() {
  const error = new Error(FIXED_ERROR_MESSAGE);
  error.code = FIXED_ERROR_CODE;
  error.detail = FIXED_ERROR_DETAIL;
  return error;
}

function isObjectRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasExactKeys(value) {
  if (!isObjectRecord(value)) {
    return false;
  }
  const keys = Object.keys(value);
  if (keys.length !== EXACT_KEYS.length) {
    return false;
  }
  for (const key of EXACT_KEYS) {
    if (!keys.includes(key)) {
      return false;
    }
  }
  return true;
}

function isCanonicalNumericIpv4(value) {
  if (typeof value !== 'string' || value.trim() !== value || value.length === 0) {
    return false;
  }
  const parts = value.split('.');
  if (parts.length !== 4) {
    return false;
  }
  const octets = [];
  for (const part of parts) {
    if (!/^[0-9]+$/u.test(part)) {
      return false;
    }
    if (part.length > 1 && part.startsWith('0')) {
      return false;
    }
    const numeric = Number(part);
    if (!Number.isInteger(numeric) || numeric < 0 || numeric > 255 || `${numeric}` !== part) {
      return false;
    }
    octets.push(numeric);
  }
  if (octets[0] === 0 || octets[0] === 127 || octets[0] >= 224) {
    return false;
  }
  if (octets[0] === 10) {
    return false;
  }
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) {
    return false;
  }
  if (octets[0] === 192 && octets[1] === 168) {
    return false;
  }
  if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) {
    return false;
  }
  if (octets[0] === 169 && octets[1] === 254) {
    return false;
  }
  if (octets[0] === 192 && octets[1] === 0 && octets[2] === 2) {
    return false;
  }
  if (octets[0] === 198 && octets[1] === 51 && octets[2] === 100) {
    return false;
  }
  if (octets[0] === 203 && octets[1] === 0 && octets[2] === 113) {
    return false;
  }
  if (octets[0] === 198 && (octets[1] === 18 || octets[1] === 19)) {
    return false;
  }
  return true;
}

function isExactPort(value) {
  return Number.isInteger(value) && value >= 1 && value <= 65535;
}

export function normalizePhase4ExternalOrigin(input) {
  if (!hasExactKeys(input)) {
    throw createInvalidExternalOriginError();
  }
  if (!isCanonicalNumericIpv4(input.hostIpv4) || !isCanonicalNumericIpv4(input.tcpHostIpv4)) {
    throw createInvalidExternalOriginError();
  }
  if (!isExactPort(input.tcpPort) || !isExactPort(input.udpPort) || !isExactPort(input.dnsPort)) {
    throw createInvalidExternalOriginError();
  }
  return Object.freeze({
    hostIpv4: input.hostIpv4,
    tcpHostIpv4: input.tcpHostIpv4,
    tcpPort: input.tcpPort,
    udpPort: input.udpPort,
    dnsPort: input.dnsPort
  });
}

export function createDefaultPhase4ExternalOrigin() {
  return normalizePhase4ExternalOrigin(DEFAULT_ORIGIN);
}

export function describePhase4ExternalOrigin(_input) {
  return Object.freeze({
    provider: DEFAULT_PROVIDER_ALIAS,
    kind: 'external-echo-origin'
  });
}
