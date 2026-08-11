import {
  createAppError,
  redactUrl,
  type AppError,
  type Clock,
  type IdGenerator,
  type RemoteAcquireCommand,
  type RemoteProfileAcquisition,
  type RemoteProfileAcquisitionFailure,
  type RemoteProfileAcquisitionSuccess,
  type StagedSource
} from '@cmfa/shared';
import type { FileDriver, FileToken } from '../files/FileDriver';
import {
  FILE_OPEN_MODE_CREATE,
  FILE_OPEN_MODE_TRUNC,
  FILE_OPEN_MODE_WRITE_ONLY
} from '../files/FileDriver';
import {
  isHttpTransportFailure,
  type HttpTransport,
  type HttpTransportFailure,
  type HttpTransportResponse
} from './HttpTransport';

const DOWNLOAD_TIMEOUT_MS: number = 30 * 1000;
const MAX_BODY_BYTES: number = 16 * 1024 * 1024;
const MAX_REDIRECTS: number = 5;
const STAGING_SUFFIX: string = '.yaml';
const REDIRECT_STATUS_CODES: number[] = [301, 302, 303, 307, 308];
const SAFE_STAGE_ID_PATTERN: RegExp = /^[A-Za-z0-9._-]+$/u;

class AcquiredRemoteProfileValue implements RemoteProfileAcquisitionSuccess {
  readonly kind: 'ACQUIRED' = 'ACQUIRED';
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly staged: StagedSource;

  constructor(profileName: string, sourceDisplay: string, staged: StagedSource) {
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
    this.staged = staged;
  }
}

class FailedRemoteProfileValue implements RemoteProfileAcquisitionFailure {
  readonly kind: 'FAILED' = 'FAILED';
  readonly error: AppError;
  readonly profileName: string;
  readonly sourceDisplay: string;
  readonly shouldPersistInvalidProfile: boolean = false;

  constructor(error: AppError, profileName: string, sourceDisplay: string) {
    this.error = error;
    this.profileName = profileName;
    this.sourceDisplay = sourceDisplay;
  }
}

class NormalizedRemoteUrl {
  readonly scheme: 'http' | 'https';
  readonly authority: string;
  readonly path: string;
  readonly query: string;
  readonly requestUrl: string;
  readonly loopKey: string;

  constructor(
    scheme: 'http' | 'https',
    authority: string,
    path: string,
    query: string,
    requestUrl: string,
    loopKey: string
  ) {
    this.scheme = scheme;
    this.authority = authority;
    this.path = path;
    this.query = query;
    this.requestUrl = requestUrl;
    this.loopKey = loopKey;
  }
}

export interface SubscriptionDownloaderDependencies {
  sdkApiVersion: number;
  networkKitTransport: HttpTransport;
  requestAgentTransport: HttpTransport;
  fileDriver: FileDriver;
  filesDir: string;
  clock: Clock;
  idGenerator: IdGenerator;
}

export class SubscriptionDownloader {
  private readonly sdkApiVersion: number;
  private readonly networkKitTransport: HttpTransport;
  private readonly requestAgentTransport: HttpTransport;
  private readonly fileDriver: FileDriver;
  private readonly filesDir: string;
  private readonly clock: Clock;
  private readonly idGenerator: IdGenerator;

  constructor(dependencies: SubscriptionDownloaderDependencies) {
    this.sdkApiVersion = dependencies.sdkApiVersion;
    this.networkKitTransport = dependencies.networkKitTransport;
    this.requestAgentTransport = dependencies.requestAgentTransport;
    this.fileDriver = dependencies.fileDriver;
    this.filesDir = normalizeAbsoluteSandboxRoot(dependencies.filesDir);
    this.clock = dependencies.clock;
    this.idGenerator = dependencies.idGenerator;
  }

  async acquire(command: RemoteAcquireCommand): Promise<RemoteProfileAcquisition> {
    const initialUrl: NormalizedRemoteUrl | undefined = tryParseAbsoluteRemoteUrl(command.sourceUrl);
    if (initialUrl === undefined) {
      return this.fail(
        command,
        'Remote profile URL must use http or https.',
        'CMFA_DOWNLOAD_INVALID_URL',
        false
      );
    }

    if (initialUrl.scheme === 'http' && !command.allowPlainHttp) {
      return this.fail(
        command,
        'Remote profile download requires explicit plain HTTP confirmation.',
        'CMFA_DOWNLOAD_PLAIN_HTTP_DISABLED',
        false
      );
    }

    const visited: Set<string> = new Set<string>();
    visited.add(initialUrl.loopKey);
    let current: NormalizedRemoteUrl = initialUrl;
    let redirectsFollowed: number = 0;
    const transport: HttpTransport = this.sdkApiVersion >= 23
      ? this.networkKitTransport
      : this.requestAgentTransport;

    while (true) {
      let response: HttpTransportResponse;
      try {
        response = await transport.fetch({
          url: current.requestUrl,
          timeoutMs: DOWNLOAD_TIMEOUT_MS,
          maxResponseBytes: MAX_BODY_BYTES
        });
      } catch (error) {
        const mapped: TransportFailureMapping = mapTransportFailure(error as Object | undefined, current.requestUrl);
        return this.fail(command, mapped.detail, mapped.code, mapped.retryable);
      }

      if (isRedirectStatus(response.statusCode)) {
        redirectsFollowed += 1;
        if (redirectsFollowed > MAX_REDIRECTS) {
          return this.fail(
            command,
            `Subscription download exceeded ${MAX_REDIRECTS} redirects for ${redactUrl(current.requestUrl)}.`,
            'CMFA_DOWNLOAD_REDIRECT',
            false
          );
        }

        const location: string | undefined = readHeaderValue(response.headers, 'location');
        if (location === undefined || location.trim().length === 0) {
          return this.fail(
            command,
            `Subscription download redirect was missing a Location header for ${redactUrl(current.requestUrl)}.`,
            'CMFA_DOWNLOAD_REDIRECT',
            false
          );
        }

        const redirected: NormalizedRemoteUrl | undefined = resolveRedirectUrl(current, location);
        if (redirected === undefined) {
          return this.fail(
            command,
            `Subscription download redirect target was invalid for ${redactUrl(current.requestUrl)}.`,
            'CMFA_DOWNLOAD_REDIRECT',
            false
          );
        }
        if (redirected.scheme === 'http' && !command.allowPlainHttp) {
          return this.fail(
            command,
            'Remote profile download requires explicit plain HTTP confirmation.',
            'CMFA_DOWNLOAD_PLAIN_HTTP_DISABLED',
            false
          );
        }
        if (visited.has(redirected.loopKey)) {
          return this.fail(
            command,
            `Subscription download redirect loop was detected for ${redactUrl(current.requestUrl)}.`,
            'CMFA_DOWNLOAD_REDIRECT',
            false
          );
        }
        visited.add(redirected.loopKey);
        current = redirected;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return this.fail(
          command,
          `Subscription download returned HTTP ${response.statusCode} from ${redactUrl(current.requestUrl)}.`,
          'CMFA_DOWNLOAD_HTTP_STATUS',
          response.statusCode >= 500
        );
      }
      if (response.statusCode === 204) {
        return this.fail(
          command,
          `Subscription download returned an empty response from ${redactUrl(current.requestUrl)}.`,
          'CMFA_DOWNLOAD_EMPTY_BODY',
          false
        );
      }

      const byteLength: number = response.body.byteLength;
      if (byteLength === 0) {
        return this.fail(
          command,
          `Subscription download returned an empty response from ${redactUrl(current.requestUrl)}.`,
          'CMFA_DOWNLOAD_EMPTY_BODY',
          false
        );
      }
      if (byteLength > MAX_BODY_BYTES) {
        return this.fail(
          command,
          `Subscription download exceeded 16 MiB at ${redactUrl(current.requestUrl)}.`,
          'CMFA_DOWNLOAD_OVERSIZE',
          false
        );
      }

      try {
        const staged: StagedSource = await this.writeStage(response.body);
        return new AcquiredRemoteProfileValue(command.profileName, command.sourceDisplay, staged);
      } catch (_) {
        return this.fail(
          command,
          'Subscription download could not be staged into the app sandbox.',
          'CMFA_DOWNLOAD_STAGE_FAILED',
          true
        );
      }
    }
  }

  private async writeStage(body: ArrayBuffer): Promise<StagedSource> {
    const stageId: string = this.idGenerator.nextId();
    if (!SAFE_STAGE_ID_PATTERN.test(stageId)) {
      throw new Error('Stage id was unsafe.');
    }
    const stageDirectory: string = `${this.filesDir}/tmp`;
    const stagePath: string = `${stageDirectory}/${stageId}${STAGING_SUFFIX}`;
    let handle: FileToken | undefined = undefined;
    let closeFailure: Error | undefined = undefined;
    try {
      await this.fileDriver.mkdir(stageDirectory, true);
      handle = await this.fileDriver.open(stagePath, FILE_OPEN_MODE_WRITE_ONLY | FILE_OPEN_MODE_CREATE | FILE_OPEN_MODE_TRUNC);
      await writeFully(this.fileDriver, handle.fd, body);
      closeFailure = await this.tryCloseHandle(handle);
      handle = undefined;
      if (closeFailure !== undefined) {
        throw closeFailure;
      }
      const digest: string = await this.fileDriver.hash(stagePath, 'sha256');
      return {
        stagingId: stageId,
        validationPath: stagePath,
        sha256Digest: digest.toLowerCase(),
        byteLength: body.byteLength,
        validatedAt: this.clock.now()
      };
    } catch (error) {
      if (handle !== undefined) {
        closeFailure = await this.tryCloseHandle(handle);
      }
      await this.cleanupStage(stagePath);
      throw (error as Error) ?? closeFailure ?? new Error('Subscription stage failed.');
    }
  }

  private async tryCloseHandle(handle?: FileToken): Promise<Error | undefined> {
    if (handle === undefined) {
      return undefined;
    }
    try {
      await this.fileDriver.close(handle);
      return undefined;
    } catch (_) {
      return new Error('Staged file close failed.');
    }
  }

  private async cleanupStage(stagePath: string): Promise<void> {
    try {
      await this.fileDriver.unlink(stagePath);
    } catch (_) {
    }
  }

  private fail(
    command: RemoteAcquireCommand,
    detail: string,
    code: string,
    retryable: boolean
  ): RemoteProfileAcquisitionFailure {
    return new FailedRemoteProfileValue(
      createAppError('DOWNLOAD', detail, {
        code,
        retryable,
        timestamp: this.clock.now()
      }),
      command.profileName,
      command.sourceDisplay
    );
  }
}

interface TransportFailureMapping {
  detail: string;
  code: string;
  retryable: boolean;
}

function mapTransportFailure(error: Object | undefined, requestUrl: string): TransportFailureMapping {
  if (isHttpTransportFailure(error)) {
    const failure: HttpTransportFailure = error as HttpTransportFailure;
    switch (failure.kind) {
      case 'TIMEOUT':
        return {
          detail: `Subscription download timed out after ${DOWNLOAD_TIMEOUT_MS} ms for ${redactUrl(requestUrl)}.`,
          code: 'CMFA_DOWNLOAD_TIMEOUT',
          retryable: true
        };
      case 'TLS':
        return {
          detail: `Subscription download TLS validation failed for ${redactUrl(requestUrl)}.`,
          code: 'CMFA_DOWNLOAD_TLS',
          retryable: false
        };
      case 'REDIRECT':
        return {
          detail: `Subscription download redirect failed for ${redactUrl(requestUrl)}.`,
          code: 'CMFA_DOWNLOAD_REDIRECT',
          retryable: false
        };
      case 'OVERSIZE':
        return {
          detail: `Subscription download exceeded 16 MiB at ${redactUrl(requestUrl)}.`,
          code: 'CMFA_DOWNLOAD_OVERSIZE',
          retryable: false
        };
      case 'NETWORK':
      default:
        return {
          detail: `Subscription download failed for ${redactUrl(requestUrl)}.`,
          code: 'CMFA_DOWNLOAD_FAILED',
          retryable: true
        };
    }
  }

  return {
    detail: `Subscription download failed for ${redactUrl(requestUrl)}.`,
    code: 'CMFA_DOWNLOAD_FAILED',
    retryable: true
  };
}

function isRedirectStatus(statusCode: number): boolean {
  for (let index = 0; index < REDIRECT_STATUS_CODES.length; index += 1) {
    if (REDIRECT_STATUS_CODES[index] === statusCode) {
      return true;
    }
  }
  return false;
}

function readHeaderValue(headers: Map<string, Array<string>>, name: string): string | undefined {
  const loweredName: string = name.toLowerCase();
  for (const entry of headers.entries()) {
    if (entry[0].toLowerCase() !== loweredName) {
      continue;
    }
    if (entry[1].length === 0) {
      return undefined;
    }
    return entry[1][0];
  }
  return undefined;
}

function tryParseAbsoluteRemoteUrl(rawUrl: string): NormalizedRemoteUrl | undefined {
  const trimmed: string = rawUrl.trim();
  const separatorIndex: number = trimmed.indexOf('://');
  if (separatorIndex <= 0) {
    return undefined;
  }
  const schemeCandidate: string = trimmed.substring(0, separatorIndex).toLowerCase();
  if (schemeCandidate !== 'http' && schemeCandidate !== 'https') {
    return undefined;
  }
  const authorityStart: number = separatorIndex + 3;
  if (authorityStart >= trimmed.length) {
    return undefined;
  }

  let authorityEnd: number = trimmed.length;
  for (let index = authorityStart; index < trimmed.length; index += 1) {
    const character: string = trimmed[index];
    if (character === '/' || character === '?' || character === '#') {
      authorityEnd = index;
      break;
    }
  }
  const authority: string = trimmed.substring(authorityStart, authorityEnd);
  if (authority.length === 0) {
    return undefined;
  }

  let path: string = '/';
  let query: string = '';
  if (authorityEnd < trimmed.length) {
    let pathEnd: number = trimmed.length;
    for (let index = authorityEnd; index < trimmed.length; index += 1) {
      const character: string = trimmed[index];
      if (character === '?' || character === '#') {
        pathEnd = index;
        break;
      }
    }
    const rawPath: string = trimmed[authorityEnd] === '/' ? trimmed.substring(authorityEnd, pathEnd) : '/';
    path = normalizePath(rawPath);
    if (pathEnd < trimmed.length && trimmed[pathEnd] === '?') {
      const fragmentIndex: number = trimmed.indexOf('#', pathEnd);
      query = fragmentIndex >= 0
        ? trimmed.substring(pathEnd, fragmentIndex)
        : trimmed.substring(pathEnd);
    }
  }

  const requestUrl: string = `${schemeCandidate}://${authority}${path}${query}`;
  return new NormalizedRemoteUrl(
    schemeCandidate as 'http' | 'https',
    authority,
    path,
    query,
    requestUrl,
    `${schemeCandidate}://${authority.toLowerCase()}${path}${query}`
  );
}

function resolveRedirectUrl(base: NormalizedRemoteUrl, location: string): NormalizedRemoteUrl | undefined {
  const trimmed: string = location.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  if (trimmed.indexOf('://') > 0) {
    return tryParseAbsoluteRemoteUrl(trimmed);
  }
  if (trimmed.startsWith('//')) {
    return tryParseAbsoluteRemoteUrl(`${base.scheme}:${trimmed}`);
  }

  const hashIndex: number = trimmed.indexOf('#');
  const withoutFragment: string = hashIndex >= 0 ? trimmed.substring(0, hashIndex) : trimmed;
  const queryIndex: number = withoutFragment.indexOf('?');
  const pathPart: string = queryIndex >= 0 ? withoutFragment.substring(0, queryIndex) : withoutFragment;
  const queryPart: string = queryIndex >= 0 ? withoutFragment.substring(queryIndex) : '';

  if (pathPart.startsWith('/')) {
    return buildResolvedUrl(base.scheme, base.authority, normalizePath(pathPart), queryPart);
  }
  if (pathPart.startsWith('?') || pathPart.length === 0 && queryPart.length > 0) {
    return buildResolvedUrl(base.scheme, base.authority, base.path, pathPart.length > 0 ? pathPart : queryPart);
  }

  const baseDirectory: string = base.path.endsWith('/')
    ? base.path
    : base.path.substring(0, base.path.lastIndexOf('/') + 1);
  return buildResolvedUrl(
    base.scheme,
    base.authority,
    normalizePath(`${baseDirectory}${pathPart}`),
    queryPart
  );
}

function buildResolvedUrl(
  scheme: 'http' | 'https',
  authority: string,
  path: string,
  query: string
): NormalizedRemoteUrl {
  const requestUrl: string = `${scheme}://${authority}${path}${query}`;
  return new NormalizedRemoteUrl(
    scheme,
    authority,
    path,
    query,
    requestUrl,
    `${scheme}://${authority.toLowerCase()}${path}${query}`
  );
}

function normalizePath(rawPath: string): string {
  const segments: string[] = rawPath.split('/');
  const resolved: string[] = [];
  for (let index = 0; index < segments.length; index += 1) {
    const segment: string = segments[index];
    if (segment.length === 0 || segment === '.') {
      continue;
    }
    if (segment === '..') {
      if (resolved.length > 0) {
        resolved.pop();
      }
      continue;
    }
    resolved.push(segment);
  }
  return `/${resolved.join('/')}`;
}

function normalizeAbsoluteSandboxRoot(rawPath: string): string {
  const normalized: string = rawPath.trim().replace(/\\/g, '/').replace(/\/+$/u, '');
  if (!normalized.startsWith('/')) {
    throw new Error('Sandbox root must be absolute.');
  }
  if (normalized.length === 0) {
    throw new Error('Sandbox root must be absolute.');
  }
  return normalized;
}

async function writeFully(fileDriver: FileDriver, fd: number, body: ArrayBuffer): Promise<void> {
  let totalWritten: number = 0;
  while (totalWritten < body.byteLength) {
    const slice: ArrayBuffer = totalWritten === 0
      ? body
      : body.slice(totalWritten, body.byteLength);
    const written: number = await fileDriver.write(fd, slice, {
      offset: 0,
      length: slice.byteLength
    });
    if (written <= 0 || written > slice.byteLength) {
      throw new Error('Subscription stage write failed.');
    }
    totalWritten += written;
  }
}
