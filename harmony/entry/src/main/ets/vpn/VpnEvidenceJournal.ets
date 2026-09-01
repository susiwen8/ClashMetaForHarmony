import { fileIo } from '@kit.CoreFileKit';
import type { TunRuntimeEvent, TunRuntimeSnapshot, VpnRuntimeEvent } from '@cmfa/shared';

const DEFAULT_EVIDENCE_PATH: string = '/data/storage/el2/base/haps/entry/files/phase4-runtime-evidence.json';
const MAX_EVIDENCE_BYTES: number = 1024 * 1024;
const MAX_RECORD_COUNT: number = 96;

export interface VpnEvidenceJournalStorage {
  writeAtomic(targetPath: string, content: string): void;
}

export interface VpnEvidenceJournalClock {
  isoNow(): string;
}

export interface VpnEvidenceLifecycleFact {
  state: string;
  detail: string;
  notificationActive: boolean;
  recoveryAttempt: number;
  stopped: boolean;
}

export interface VpnEvidenceCounters {
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

export type VpnEvidenceRecordKind = 'traffic' | 'lifecycle' | 'stop';
export type VpnEvidenceLinkageStatus = 'linked' | 'missing';

export interface VpnEvidenceObservationRecord {
  sequence: number;
  recordedAt: string;
  kind: VpnEvidenceRecordKind;
  sessionIdHash: string;
  ingress: string;
  traceAlias: string;
  coreAlias: string;
  flowIdHash: string;
  protocol: string;
  hashedTuple: string;
  correlationHash: string;
  destinationHash: string;
  outboundTerminalHash: string;
  outboundChainHash: string;
  outboundChainLength: number;
  counterDelta: number;
  linkageStatus: VpnEvidenceLinkageStatus;
  counterSnapshot: VpnEvidenceCounters;
  detail: string;
}

export interface VpnEvidenceJournalDocument {
  schemaVersion: '1.0.0';
  phase: 4;
  runId: string;
  sessionAlias: string;
  sequence: number;
  updatedAt: string;
  lifecycle: VpnEvidenceLifecycleFact;
  counters: VpnEvidenceCounters;
  records: VpnEvidenceObservationRecord[];
  writeFailureCount: number;
  sizeBytes: number;
}

class SystemJournalClock implements VpnEvidenceJournalClock {
  isoNow(): string {
    return new Date().toISOString();
  }
}

class FileJournalStorage implements VpnEvidenceJournalStorage {
  writeAtomic(targetPath: string, content: string): void {
    const tempPath: string = `${targetPath}.${Date.now()}.tmp`;
    const file: fileIo.File = fileIo.openSync(
      tempPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file.fd);
    }
    try {
      fileIo.renameSync(tempPath, targetPath);
    } catch (error) {
      try {
        fileIo.unlinkSync(tempPath);
      } catch (cleanupError) {
      }
      throw error as Error;
    }
  }
}

function hashOpaque(value: string): string {
  let hash: number = 2166136261;
  for (let index: number = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function aliasId(value: string): string {
  return `session-${hashOpaque(value)}`;
}

function sanitizeDetail(raw: string): string {
  let sanitized: string = raw;
  sanitized = sanitized.replace(/https?:\/\/\S+/giu, '<redacted-url>');
  sanitized = sanitized.replace(/\b\d{1,3}(?:\.\d{1,3}){3}\b/gu, '<redacted-ip>');
  sanitized = sanitized.replace(/\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b/giu, '<redacted-host>');
  sanitized = sanitized.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/giu, '<redacted-id>');
  sanitized = sanitized.replace(/\b(?:profile|config|signing|device|serial|token|secret|password)\b/giu, '<redacted>');
  return sanitized;
}

function cloneCounters(snapshot?: TunRuntimeSnapshot | null): VpnEvidenceCounters {
  return {
    txPackets: snapshot?.counters.txPackets ?? 0,
    txBytes: snapshot?.counters.txBytes ?? 0,
    rxPackets: snapshot?.counters.rxPackets ?? 0,
    rxBytes: snapshot?.counters.rxBytes ?? 0
  };
}

function createEmptyCounters(): VpnEvidenceCounters {
  return {
    txPackets: 0,
    txBytes: 0,
    rxPackets: 0,
    rxBytes: 0
  };
}

function positivePacketDelta(previous: VpnEvidenceCounters, current: VpnEvidenceCounters): number {
  const rxDelta: number = current.rxPackets - previous.rxPackets;
  const txDelta: number = current.txPackets - previous.txPackets;
  if (rxDelta < 0 || txDelta < 0) {
    return 0;
  }
  return rxDelta + txDelta;
}

function createEmptyDocument(clock: VpnEvidenceJournalClock): VpnEvidenceJournalDocument {
  return {
    schemaVersion: '1.0.0',
    phase: 4,
    runId: '',
    sessionAlias: 'session-00000000',
    sequence: 0,
    updatedAt: clock.isoNow(),
    lifecycle: {
      state: 'idle',
      detail: '',
      notificationActive: false,
      recoveryAttempt: 0,
      stopped: false
    },
    counters: createEmptyCounters(),
    records: [],
    writeFailureCount: 0,
    sizeBytes: 0
  };
}

export interface VpnEvidenceJournalPort {
  rotateSession(sessionId: string, runId: string): void;
  recordCoordinatorEvent(event: VpnRuntimeEvent): void;
  recordTunEvent(event: TunRuntimeEvent): void;
  recordDiagnosticStage(stage: string): void;
  recordLifecycleFact(state: string, detail: string): void;
  recordTunCounters(counters: VpnEvidenceCounters): void;
  recordObservationAdapter(record: VpnEvidenceObservationRecord): void;
  finalizeStop(event: VpnRuntimeEvent | null): void;
  finalizeStopWithDetail(sessionId: string, detail: string): void;
  createObservationRecordForTesting(
    sessionId: string,
    kind: VpnEvidenceRecordKind,
    ingress: string,
    traceAlias: string,
    coreAlias: string,
    flowId: string,
    linkageStatus: VpnEvidenceLinkageStatus
  ): VpnEvidenceObservationRecord;
  snapshot(): VpnEvidenceJournalDocument;
}

export class VpnEvidenceJournal implements VpnEvidenceJournalPort {
  private readonly storage: VpnEvidenceJournalStorage;
  private readonly clock: VpnEvidenceJournalClock;
  private readonly targetPath: string;
  private document: VpnEvidenceJournalDocument;
  private currentSessionHash: string = '00000000';
  private readonly seenTrafficTraceAliases: Set<string> = new Set();
  private lastTunCounters: VpnEvidenceCounters = createEmptyCounters();

  constructor(
    storage: VpnEvidenceJournalStorage = new FileJournalStorage(),
    clock: VpnEvidenceJournalClock = new SystemJournalClock(),
    targetPath: string = DEFAULT_EVIDENCE_PATH
  ) {
    this.storage = storage;
    this.clock = clock;
    this.targetPath = targetPath;
    this.document = createEmptyDocument(clock);
  }

  rotateSession(sessionId: string, runId: string): void {
    this.currentSessionHash = hashOpaque(sessionId);
    this.document = createEmptyDocument(this.clock);
    this.seenTrafficTraceAliases.clear();
    this.lastTunCounters = createEmptyCounters();
    this.document.runId = runId;
    this.document.sessionAlias = aliasId(sessionId);
    this.persist();
  }

  recordCoordinatorEvent(event: VpnRuntimeEvent): void {
    const sessionId: string = event.snapshot.activeRequest?.sessionId ?? event.snapshot.tunSnapshot?.sessionId ?? '';
    if (!this.acceptsSession(sessionId)) {
      return;
    }
    this.document.lifecycle.state = event.snapshot.state.toLowerCase();
    this.document.lifecycle.notificationActive = event.snapshot.notificationActive;
    this.document.lifecycle.recoveryAttempt = event.snapshot.recoveryAttempt;
    this.document.counters = cloneCounters(event.snapshot.tunSnapshot);
    this.document.lifecycle.detail = sanitizeDetail(event.snapshot.lastFailure?.detail ?? '');
    this.appendRecord({
      sequence: 0,
      recordedAt: this.clock.isoNow(),
      kind: 'lifecycle',
      sessionIdHash: this.currentSessionHash,
      ingress: 'lifecycle',
      traceAlias: `trace-${this.document.sequence + 1}`,
      coreAlias: '',
      flowIdHash: 'none',
      protocol: '',
      hashedTuple: '',
      correlationHash: '',
      destinationHash: '',
      outboundTerminalHash: '',
      outboundChainHash: '',
      outboundChainLength: 0,
      counterDelta: 0,
      linkageStatus: 'missing',
      counterSnapshot: this.document.counters,
      detail: sanitizeDetail(`${event.type}:${event.snapshot.state}`)
    });
  }

  recordTunEvent(event: TunRuntimeEvent): void {
    if (!this.acceptsSession(event.sessionId)) {
      return;
    }
    const currentCounters: VpnEvidenceCounters = cloneCounters(event.snapshot);
    const newTraceIndexes: number[] = [];
    for (let index: number = 0; index < event.snapshot.ingressTraces.length; index += 1) {
      const traceAlias: string = event.snapshot.ingressTraces[index].traceId;
      if (traceAlias.length > 0 && !this.seenTrafficTraceAliases.has(traceAlias)) {
        newTraceIndexes.push(index);
      }
    }
    const packetDelta: number = positivePacketDelta(this.lastTunCounters, currentCounters);
    const perTraceCounterDelta: number = newTraceIndexes.length > 0 && packetDelta >= newTraceIndexes.length ? 1 : 0;
    this.document.counters = currentCounters;
    for (let newIndex: number = 0; newIndex < newTraceIndexes.length; newIndex += 1) {
      const trace = event.snapshot.ingressTraces[newTraceIndexes[newIndex]];
      this.seenTrafficTraceAliases.add(trace.traceId);
      const hasOutboundProof: boolean = trace.destinationHash.length > 0 &&
        trace.outboundTerminalHash.length > 0 &&
        trace.outboundChainHash.length > 0 &&
        trace.outboundChainLength > 0;
      const linked: boolean = trace.traceId.length > 0 &&
        trace.correlationHash.length > 0 &&
        trace.protocol.length > 0 &&
        trace.ingress === 'tun' &&
        (trace.protocol !== 'tcp' || hasOutboundProof);
      this.appendRecord({
        sequence: 0,
        recordedAt: this.clock.isoNow(),
        kind: 'traffic',
        sessionIdHash: this.currentSessionHash,
        ingress: trace.ingress,
        traceAlias: trace.traceId,
        coreAlias: '',
        flowIdHash: trace.correlationHash,
        protocol: trace.protocol,
        hashedTuple: trace.hashedTuple,
        correlationHash: trace.correlationHash,
        destinationHash: trace.destinationHash,
        outboundTerminalHash: trace.outboundTerminalHash,
        outboundChainHash: trace.outboundChainHash,
        outboundChainLength: trace.outboundChainLength,
        counterDelta: perTraceCounterDelta,
        linkageStatus: linked ? 'linked' : 'missing',
        counterSnapshot: this.document.counters,
        detail: sanitizeDetail(trace.detail)
      });
    }
    this.lastTunCounters = currentCounters;
  }

  recordDiagnosticStage(stage: string): void {
    this.appendRecord({
      sequence: 0,
      recordedAt: this.clock.isoNow(),
      kind: 'lifecycle',
      sessionIdHash: this.currentSessionHash,
      ingress: 'lifecycle',
      traceAlias: `trace-${this.document.sequence + 1}`,
      coreAlias: '',
      flowIdHash: 'none',
      protocol: '',
      hashedTuple: '',
      correlationHash: '',
      destinationHash: '',
      outboundTerminalHash: '',
      outboundChainHash: '',
      outboundChainLength: 0,
      counterDelta: 0,
      linkageStatus: 'missing',
      counterSnapshot: this.document.counters,
      detail: sanitizeDetail(stage)
    });
  }

  recordLifecycleFact(state: string, detail: string): void {
    this.document.lifecycle.state = state;
    this.document.lifecycle.detail = sanitizeDetail(detail);
    this.appendRecord({
      sequence: 0,
      recordedAt: this.clock.isoNow(),
      kind: 'lifecycle',
      sessionIdHash: this.currentSessionHash,
      ingress: 'lifecycle',
      traceAlias: `trace-${this.document.sequence + 1}`,
      coreAlias: '',
      flowIdHash: 'none',
      protocol: '',
      hashedTuple: '',
      correlationHash: '',
      destinationHash: '',
      outboundTerminalHash: '',
      outboundChainHash: '',
      outboundChainLength: 0,
      counterDelta: 0,
      linkageStatus: 'missing',
      counterSnapshot: this.document.counters,
      detail: sanitizeDetail(detail)
    });
  }

  recordTunCounters(counters: VpnEvidenceCounters): void {
    this.document.counters = {
      txPackets: counters.txPackets,
      txBytes: counters.txBytes,
      rxPackets: counters.rxPackets,
      rxBytes: counters.rxBytes
    };
    this.persist();
  }

  recordObservationAdapter(record: VpnEvidenceObservationRecord): void {
    if (record.sessionIdHash !== this.currentSessionHash) {
      return;
    }
    this.appendRecord(record);
  }

  finalizeStop(event: VpnRuntimeEvent | null): void {
    if (this.document.lifecycle.stopped) {
      return;
    }
    if (event !== null) {
      this.recordCoordinatorEvent(event);
    }
    this.document.lifecycle.stopped = true;
    this.document.lifecycle.state = 'stopped';
    this.appendRecord({
      sequence: 0,
      recordedAt: this.clock.isoNow(),
      kind: 'stop',
      sessionIdHash: this.currentSessionHash,
      ingress: 'stop',
      traceAlias: `trace-${this.document.sequence + 1}`,
      coreAlias: '',
      flowIdHash: 'none',
      protocol: '',
      hashedTuple: '',
      correlationHash: '',
      destinationHash: '',
      outboundTerminalHash: '',
      outboundChainHash: '',
      outboundChainLength: 0,
      counterDelta: 0,
      linkageStatus: 'missing',
      counterSnapshot: this.document.counters,
      detail: sanitizeDetail(this.document.lifecycle.detail)
    });
  }

  finalizeStopWithDetail(sessionId: string, detail: string): void {
    if (!this.acceptsSession(sessionId)) {
      return;
    }
    if (this.document.lifecycle.stopped) {
      return;
    }
    this.document.lifecycle.detail = sanitizeDetail(detail);
    this.finalizeStop(null);
  }

  createObservationRecordForTesting(
    sessionId: string,
    kind: VpnEvidenceRecordKind,
    ingress: string,
    traceAlias: string,
    coreAlias: string,
    flowId: string,
    linkageStatus: VpnEvidenceLinkageStatus
  ): VpnEvidenceObservationRecord {
    return {
      sequence: 0,
      recordedAt: this.clock.isoNow(),
      kind,
      sessionIdHash: hashOpaque(sessionId),
      ingress,
      traceAlias,
      coreAlias,
      flowIdHash: hashOpaque(flowId),
      protocol: ingress === 'tun' ? 'tcp' : '',
      hashedTuple: '',
      correlationHash: hashOpaque(flowId),
      destinationHash: '',
      outboundTerminalHash: '',
      outboundChainHash: '',
      outboundChainLength: 0,
      counterDelta: 0,
      linkageStatus,
      counterSnapshot: this.document.counters,
      detail: kind
    };
  }

  snapshot(): VpnEvidenceJournalDocument {
    return JSON.parse(JSON.stringify(this.document)) as VpnEvidenceJournalDocument;
  }

  private acceptsSession(sessionId: string): boolean {
    return sessionId.trim().length > 0 && hashOpaque(sessionId) === this.currentSessionHash;
  }

  private appendRecord(record: VpnEvidenceObservationRecord): void {
    this.document.sequence += 1;
    const normalized: VpnEvidenceObservationRecord = {
      sequence: this.document.sequence,
      recordedAt: this.clock.isoNow(),
      kind: record.kind,
      sessionIdHash: record.sessionIdHash,
      ingress: sanitizeDetail(record.ingress),
      traceAlias: sanitizeDetail(record.traceAlias),
      coreAlias: sanitizeDetail(record.coreAlias),
      flowIdHash: sanitizeDetail(record.flowIdHash),
      protocol: sanitizeDetail(record.protocol),
      hashedTuple: sanitizeDetail(record.hashedTuple),
      correlationHash: sanitizeDetail(record.correlationHash),
      destinationHash: sanitizeDetail(record.destinationHash),
      outboundTerminalHash: sanitizeDetail(record.outboundTerminalHash),
      outboundChainHash: sanitizeDetail(record.outboundChainHash),
      outboundChainLength: record.outboundChainLength,
      counterDelta: record.counterDelta,
      linkageStatus: record.linkageStatus,
      counterSnapshot: {
        txPackets: record.counterSnapshot.txPackets,
        txBytes: record.counterSnapshot.txBytes,
        rxPackets: record.counterSnapshot.rxPackets,
        rxBytes: record.counterSnapshot.rxBytes
      },
      detail: sanitizeDetail(record.detail)
    };
    this.document.updatedAt = normalized.recordedAt;
    this.document.records.push(normalized);
    if (this.document.records.length > MAX_RECORD_COUNT) {
      this.document.records = this.document.records.slice(this.document.records.length - MAX_RECORD_COUNT);
    }
    this.persist();
  }

  private persist(): void {
    let persisted: VpnEvidenceJournalDocument = this.snapshot();
    let serialized: string = `${JSON.stringify(persisted)}\n`;
    while (serialized.length > MAX_EVIDENCE_BYTES && persisted.records.length > 0) {
      persisted.records = persisted.records.slice(1);
      serialized = `${JSON.stringify(persisted)}\n`;
    }
    if (serialized.length > MAX_EVIDENCE_BYTES) {
      const fallback: VpnEvidenceJournalDocument = createEmptyDocument(this.clock);
      fallback.runId = this.document.runId;
      fallback.sessionAlias = this.document.sessionAlias;
      fallback.sequence = this.document.sequence;
      fallback.updatedAt = this.document.updatedAt;
      fallback.lifecycle = {
        state: this.document.lifecycle.state,
        detail: 'fallback',
        notificationActive: this.document.lifecycle.notificationActive,
        recoveryAttempt: this.document.lifecycle.recoveryAttempt,
        stopped: this.document.lifecycle.stopped
      };
      fallback.counters = this.document.counters;
      fallback.records = [];
      fallback.writeFailureCount = this.document.writeFailureCount;
      persisted = fallback;
      serialized = `${JSON.stringify(persisted)}\n`;
    }
    persisted.sizeBytes = serialized.length;
    serialized = `${JSON.stringify(persisted)}\n`;
    this.document.sizeBytes = persisted.sizeBytes;
    try {
      this.storage.writeAtomic(this.targetPath, serialized);
    } catch (error) {
      this.document.writeFailureCount += 1;
    }
  }
}
