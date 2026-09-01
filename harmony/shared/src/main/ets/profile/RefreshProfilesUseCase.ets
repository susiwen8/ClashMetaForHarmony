import { normalizeCanonicalUtcIsoTimestamp } from './AppErrors';
import type { Profile } from './ProfileModels';
import type { Clock, ProfileRepository } from './ProfilePorts';
import type { RefreshProfileCommand, RefreshProfileResult } from './RefreshProfileUseCase';

export type RefreshProfilesMode = 'ALL' | 'DUE';
export type RefreshProfilesItemStatus =
  'SUCCESS' |
  'FAILED_USING_CURRENT' |
  'FAILED' |
  'SKIPPED_HTTP' |
  'SKIPPED_NOT_DUE' |
  'BUSY';

export interface RefreshProfilesCommand {
  mode: RefreshProfilesMode;
  deadlineMs?: number;
  isCancelled?: () => boolean;
}

export interface RefreshProfilesItemResult {
  profileId: string;
  status: RefreshProfilesItemStatus;
}

export interface RefreshProfilesResult {
  items: RefreshProfilesItemResult[];
  deadlineReached: boolean;
  cancelled: boolean;
  remainingCount: number;
}

export interface ProfileRefreshExecutorPort {
  execute(command: RefreshProfileCommand): Promise<RefreshProfileResult>;
}

export interface RefreshProfilesTimestampParser {
  parseUtcMillis(timestamp: string, label: string): number;
}

export interface RefreshProfilesUseCaseDependencies {
  repository: ProfileRepository;
  executor: ProfileRefreshExecutorPort;
  clock: Clock;
  parser?: RefreshProfilesTimestampParser;
}

interface RefreshCandidate {
  profile: Profile;
  dueSortGroup: number;
  nextDueMs: number;
  due: boolean;
}

const REFRESH_PROFILES_INVALID_INPUT_CODE: string = 'REFRESH_PROFILES_INVALID_INPUT';
const REFRESH_PROFILES_LIST_FAILED_CODE: string = 'REFRESH_PROFILES_LIST_FAILED';
const REFRESH_PROFILES_INVALID_INPUT_MESSAGE: string = 'Refresh profiles input is invalid.';
const REFRESH_PROFILES_LIST_FAILED_MESSAGE: string = 'Refresh profiles list failed.';
const PROFILE_REFRESH_BUSY_CODE: string = 'PROFILE_REFRESH_BUSY';
const MAX_SAFE_MILLIS: number = Number.MAX_SAFE_INTEGER;

class DefaultRefreshProfilesTimestampParser implements RefreshProfilesTimestampParser {
  parseUtcMillis(timestamp: string, label: string): number {
    const normalizedTimestamp: string = normalizeCanonicalUtcIsoTimestamp(timestamp, label);
    const parsed: number = Date.parse(normalizedTimestamp);
    if (!Number.isFinite(parsed)) {
      throw new Error(`${label} must be canonical ISO-8601 UTC.`);
    }
    return parsed;
  }
}

export class RefreshProfilesUseCaseError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'RefreshProfilesUseCaseError';
    this.code = code;
  }
}

export class RefreshProfilesUseCase {
  private readonly repository: ProfileRepository;
  private readonly executor: ProfileRefreshExecutorPort;
  private readonly clock: Clock;
  private readonly parser: RefreshProfilesTimestampParser;

  constructor(dependencies: RefreshProfilesUseCaseDependencies) {
    this.repository = dependencies.repository;
    this.executor = dependencies.executor;
    this.clock = dependencies.clock;
    this.parser = dependencies.parser ?? new DefaultRefreshProfilesTimestampParser();
  }

  async execute(command: RefreshProfilesCommand): Promise<RefreshProfilesResult> {
    if (command.mode !== 'ALL' && command.mode !== 'DUE') {
      throw new RefreshProfilesUseCaseError(
        REFRESH_PROFILES_INVALID_INPUT_CODE,
        REFRESH_PROFILES_INVALID_INPUT_MESSAGE
      );
    }
    const deadlineMs: number | undefined = this.normalizeDeadlineMs(command.deadlineMs);
    const nowMs: number = this.readNowMs();
    const candidates: RefreshCandidate[] = await this.listCandidates(command.mode, nowMs);
    const items: RefreshProfilesItemResult[] = [];

    for (let index = 0; index < candidates.length; index += 1) {
      if (command.isCancelled?.() === true) {
        return this.buildResult(items, false, true, candidates.length - index);
      }

      if (deadlineMs !== undefined && this.readNowMs() >= deadlineMs) {
        return this.buildResult(items, true, false, candidates.length - index);
      }

      const candidate: RefreshCandidate = candidates[index];
      if (command.mode === 'DUE' && !candidate.due) {
        items.push({
          profileId: candidate.profile.id,
          status: 'SKIPPED_NOT_DUE'
        });
        continue;
      }

      if (isPlainHttpSource(candidate.profile.sourceDisplay)) {
        items.push({
          profileId: candidate.profile.id,
          status: 'SKIPPED_HTTP'
        });
        continue;
      }

      items.push({
        profileId: candidate.profile.id,
        status: await this.refreshSingle(candidate.profile.id)
      });
    }

    return this.buildResult(items, false, false, 0);
  }

  private async listCandidates(mode: RefreshProfilesMode, nowMs: number): Promise<RefreshCandidate[]> {
    let profiles: Profile[];
    try {
      profiles = await this.repository.list();
    } catch (_) {
      throw new RefreshProfilesUseCaseError(
        REFRESH_PROFILES_LIST_FAILED_CODE,
        REFRESH_PROFILES_LIST_FAILED_MESSAGE
      );
    }

    const remoteProfiles: Profile[] = profiles.filter((profile: Profile): boolean => profile.sourceKind === 'REMOTE_URL');
    if (mode === 'ALL') {
      const sorted: Profile[] = remoteProfiles.slice().sort(compareProfilesById);
      return sorted.map((profile: Profile): RefreshCandidate => ({
        profile,
        dueSortGroup: 0,
        nextDueMs: 0,
        due: true
      }));
    }

    const dueCandidates: RefreshCandidate[] = remoteProfiles.map((profile: Profile): RefreshCandidate =>
      this.toDueCandidate(profile, nowMs)
    );
    dueCandidates.sort(compareDueCandidates);
    return dueCandidates;
  }

  private toDueCandidate(profile: Profile, nowMs: number): RefreshCandidate {
    const intervalMs: number = normalizeSafeNonNegativeInteger(profile.autoUpdateIntervalMs);
    if (intervalMs <= 0) {
      return {
        profile,
        dueSortGroup: 2,
        nextDueMs: Number.POSITIVE_INFINITY,
        due: false
      };
    }

    if (profile.lastSuccessfulUpdateAt === null) {
      return {
        profile,
        dueSortGroup: 0,
        nextDueMs: 0,
        due: true
      };
    }

    const lastSuccessfulUpdateMs: number = this.parseTimestamp(profile.lastSuccessfulUpdateAt, 'Profile timestamp');
    if (lastSuccessfulUpdateMs > MAX_SAFE_MILLIS - intervalMs) {
      throw new RefreshProfilesUseCaseError(
        REFRESH_PROFILES_INVALID_INPUT_CODE,
        REFRESH_PROFILES_INVALID_INPUT_MESSAGE
      );
    }
    const nextDueMs: number = lastSuccessfulUpdateMs + intervalMs;

    return {
      profile,
      dueSortGroup: 1,
      nextDueMs,
      due: nextDueMs <= nowMs
    };
  }

  private async refreshSingle(profileId: string): Promise<RefreshProfilesItemStatus> {
    try {
      const result: RefreshProfileResult = await this.executor.execute({
        profileId,
        allowPlainHttp: false
      });
      return classifyRefreshResult(result);
    } catch (_) {
      return 'FAILED';
    }
  }

  private buildResult(
    items: RefreshProfilesItemResult[],
    deadlineReached: boolean,
    cancelled: boolean,
    remainingCount: number
  ): RefreshProfilesResult {
    return {
      items,
      deadlineReached,
      cancelled,
      remainingCount
    };
  }

  private readNowMs(): number {
    return this.parseTimestamp(this.clock.now(), 'Clock timestamp');
  }

  private parseTimestamp(timestamp: string, label: string): number {
    try {
      return normalizeSafeNonNegativeInteger(this.parser.parseUtcMillis(timestamp, label));
    } catch (_) {
      throw new RefreshProfilesUseCaseError(
        REFRESH_PROFILES_INVALID_INPUT_CODE,
        REFRESH_PROFILES_INVALID_INPUT_MESSAGE
      );
    }
  }

  private normalizeDeadlineMs(deadlineMs: number | undefined): number | undefined {
    if (deadlineMs === undefined) {
      return undefined;
    }
    if (!Number.isSafeInteger(deadlineMs) || deadlineMs < 0) {
      throw new RefreshProfilesUseCaseError(
        REFRESH_PROFILES_INVALID_INPUT_CODE,
        REFRESH_PROFILES_INVALID_INPUT_MESSAGE
      );
    }
    return deadlineMs;
  }
}

function compareProfilesById(left: Profile, right: Profile): number {
  if (left.id < right.id) {
    return -1;
  }
  if (left.id > right.id) {
    return 1;
  }
  return 0;
}

function compareDueCandidates(left: RefreshCandidate, right: RefreshCandidate): number {
  if (left.dueSortGroup !== right.dueSortGroup) {
    return left.dueSortGroup - right.dueSortGroup;
  }
  if (left.nextDueMs < right.nextDueMs) {
    return -1;
  }
  if (left.nextDueMs > right.nextDueMs) {
    return 1;
  }
  return compareProfilesById(left.profile, right.profile);
}

function isPlainHttpSource(sourceDisplay: string): boolean {
  return sourceDisplay.startsWith('http://');
}

function classifyRefreshResult(result: RefreshProfileResult): RefreshProfilesItemStatus {
  switch (result.kind) {
    case 'FAILED':
      return result.error.code === PROFILE_REFRESH_BUSY_CODE ? 'BUSY' : 'FAILED';
    case 'CANCELLED':
      return 'FAILED';
    case 'UPDATED':
      if (result.profile.availability === 'VALID' && result.profile.lastError === null) {
        return 'SUCCESS';
      }
      if (result.profile.availability === 'UPDATE_FAILED_USING_VALID') {
        return 'FAILED_USING_CURRENT';
      }
      if (hasUsableCurrent(result.profile) && result.profile.lastError !== null) {
        return 'FAILED_USING_CURRENT';
      }
      return 'FAILED';
    default:
      return 'FAILED';
  }
}

function hasUsableCurrent(profile: Profile): boolean {
  return profile.currentRevision !== null &&
    (profile.availability === 'VALID' || profile.availability === 'UPDATE_FAILED_USING_VALID');
}

function normalizeSafeNonNegativeInteger(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error('Value must be a safe non-negative integer.');
  }
  return value;
}
