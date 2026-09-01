import { describe, expect, it } from '@ohos/hypium';
import {
  VpnEvidenceJournal,
  type VpnEvidenceObservationRecord,
  type VpnEvidenceCounters,
  type VpnEvidenceJournalDocument,
  type VpnEvidenceJournalStorage,
  type VpnEvidenceJournalClock
} from '../main/ets/vpn/VpnEvidenceJournal';
import {
  createVpnRuntimeEvent,
  createVpnRuntimeSnapshot,
  createTunRuntimeSnapshot,
  createVpnCounters,
  createVpnIngressTrace,
  type TunRuntimeEvent
} from '@cmfa/shared';

const DESTINATION_HASH: string = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const OUTBOUND_TERMINAL_HASH: string = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const OUTBOUND_CHAIN_HASH: string = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class RecordingStorage implements VpnEvidenceJournalStorage {
  writes: string[] = [];

  writeAtomic(_targetPath: string, content: string): void {
    this.writes.push(content);
  }
}

class ThrowingStorage implements VpnEvidenceJournalStorage {
  writeAtomic(_targetPath: string, _content: string): void {
    throw new Error('write failed');
  }
}

class FixedJournalClock implements VpnEvidenceJournalClock {
  isoNow(): string {
    return '2026-08-17T08:00:00.000Z';
  }
}

function fnv1aUtf16Hex(value: string): string {
  let hash: number = 2166136261;
  for (let index: number = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

export default function vpnEvidenceJournalTestsuite() {
  describe('VpnEvidenceJournalTest', () => {
    it('rotates sessions, redacts sensitive details, and falls back under the hard cap', 0, () => {
      const storage: RecordingStorage = new RecordingStorage();
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(storage, new FixedJournalClock());
      const counters: VpnEvidenceCounters = {
        txPackets: 7,
        txBytes: 70,
        rxPackets: 8,
        rxBytes: 80
      };

      journal.rotateSession('session-secret-1', '123e4567-e89b-42d3-a456-426614174000');
      journal.recordLifecycleFact('running', 'https://device.example.invalid/path?token=1 192.168.1.7 profile-content');
      journal.recordTunCounters(counters);
      const snapshot = journal.snapshot();

      expect(snapshot.sequence > 0).assertTrue();
      expect(snapshot.runId).assertEqual('123e4567-e89b-42d3-a456-426614174000');
      expect(snapshot.sessionAlias.startsWith('session-')).assertTrue();
      expect(snapshot.lifecycle.state).assertEqual('running');
      expect(snapshot.lifecycle.detail.includes('https://')).assertFalse();
      expect(snapshot.lifecycle.detail.includes('192.168.1.7')).assertFalse();
      expect(storage.writes.length > 0).assertTrue();

      const giant: string = 'secret.example.com '.repeat(70_000);
      journal.recordLifecycleFact('running', giant);
      const capped = journal.snapshot();
      expect(capped.sizeBytes <= 1024 * 1024).assertTrue();
      expect(capped.writeFailureCount).assertEqual(0);
    });

    it('keeps write failures diagnostic-only', 0, () => {
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(new ThrowingStorage(), new FixedJournalClock());

      journal.rotateSession('session-secret-2', '');
      journal.recordLifecycleFact('stopping', 'vpnId=abc123 secret token password');
      const snapshot = journal.snapshot();

      expect(snapshot.writeFailureCount > 0).assertTrue();
      expect(snapshot.lifecycle.state).assertEqual('stopping');
    });

    it('records fixed packet diagnostic stages without regressing the lifecycle state', 0, () => {
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(new RecordingStorage(), new FixedJournalClock());

      journal.rotateSession('session-diagnostic', '');
      journal.recordLifecycleFact('running', 'running');
      journal.recordDiagnosticStage('tun-packet-read-loop-enter');
      const snapshot = journal.snapshot();

      expect(snapshot.lifecycle.state).assertEqual('running');
      expect(snapshot.records[snapshot.records.length - 1].kind).assertEqual('lifecycle');
      expect(snapshot.records[snapshot.records.length - 1].detail).assertEqual('tun-packet-read-loop-enter');
    });

    it('keeps bounded current-session records, rejects stale session observations, and finalizes after the last record', 0, () => {
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(new RecordingStorage(), new FixedJournalClock());
      const first: VpnEvidenceObservationRecord = journal.createObservationRecordForTesting(
        'session-live',
        'traffic',
        'tun',
        'trace-a',
        'core-a',
        'flow-a',
        'linked'
      );
      const stale: VpnEvidenceObservationRecord = journal.createObservationRecordForTesting(
        'session-stale',
        'traffic',
        'tun',
        'trace-b',
        'core-b',
        'flow-b',
        'linked'
      );

      journal.rotateSession('session-live', '');
      journal.recordObservationAdapter(first);
      journal.recordObservationAdapter(stale);
      journal.finalizeStopWithDetail('session-live', 'stopped cleanly');
      const liveSnapshot = journal.snapshot();

      expect(liveSnapshot.records.length).assertEqual(2);
      expect(liveSnapshot.records[0].sequence).assertEqual(1);
      expect(liveSnapshot.records[0].kind).assertEqual('traffic');
      expect(liveSnapshot.records[0].traceAlias).assertEqual('trace-a');
      expect(liveSnapshot.records[0].coreAlias).assertEqual('core-a');
      expect(liveSnapshot.records[1].kind).assertEqual('stop');
      expect(liveSnapshot.records[1].sequence > liveSnapshot.records[0].sequence).assertTrue();

      journal.rotateSession('session-next', '');
      const nextSnapshot = journal.snapshot();
      expect(nextSnapshot.records.length).assertEqual(0);
      expect(nextSnapshot.sessionAlias === liveSnapshot.sessionAlias).assertFalse();
    });

    it('finalizes stop idempotently across detail and destroy paths', 0, () => {
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(new RecordingStorage(), new FixedJournalClock());

      journal.rotateSession('session-live', '');
      journal.recordLifecycleFact('running', 'stopped cleanly');
      journal.finalizeStopWithDetail('session-live', 'stopped cleanly');
      journal.finalizeStop(createVpnRuntimeEvent('STOPPED', createVpnRuntimeSnapshot({
        state: 'STOPPED',
        activeRequest: null,
        activeHandle: null,
        captureConfig: null,
        tunSnapshot: null,
        notificationActive: false,
        recoveryAttempt: 0,
        scheduledRetryDelayMs: null,
        lastFailure: null
      })));

      const snapshot = journal.snapshot();
      expect(snapshot.lifecycle.state).assertEqual('stopped');
      expect(snapshot.lifecycle.stopped).assertTrue();
      expect(snapshot.records.filter((record) => record.kind === 'stop').length).assertEqual(1);
      expect(snapshot.records[snapshot.records.length - 1].kind).assertEqual('stop');
    });

    it('keeps the sessionIdHash contract aligned with the phase4 runner FNV-1a UTF-16 8hex helper', 0, () => {
      const storage: RecordingStorage = new RecordingStorage();
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(storage, new FixedJournalClock());
      const sessionId: string = '123e4567-e89b-12d3-a456-426614174000';
      const expectedHash: string = 'd02023ff';
      const record: VpnEvidenceObservationRecord = journal.createObservationRecordForTesting(
        sessionId,
        'traffic',
        'tun',
        'trace-contract',
        'core-contract',
        'flow-contract',
        'linked'
      );

      expect(fnv1aUtf16Hex(sessionId)).assertEqual(expectedHash);
      expect(record.sessionIdHash).assertEqual(expectedHash);

      journal.rotateSession(sessionId, '');
      journal.recordObservationAdapter(record);
      const snapshot = journal.snapshot();
      const persisted = JSON.parse(storage.writes[storage.writes.length - 1]) as VpnEvidenceJournalDocument;

      expect(snapshot.sessionAlias).assertEqual(`session-${expectedHash}`);
      expect(snapshot.records[0].sessionIdHash).assertEqual(expectedHash);
      expect(persisted.records[0].sessionIdHash).assertEqual(expectedHash);
    });

    it('persists outbound proof fields and only links tcp tun traces when destination and outbound hashes are complete', 0, () => {
      const storage: RecordingStorage = new RecordingStorage();
      const journal: VpnEvidenceJournal = new VpnEvidenceJournal(storage, new FixedJournalClock());

      journal.rotateSession('session-proof', '123e4567-e89b-42d3-a456-426614174999');
      const event: TunRuntimeEvent = {
        sessionId: 'session-proof',
        snapshot: createTunRuntimeSnapshot({
          sessionId: 'session-proof',
          state: 'READY',
          counters: createVpnCounters(1, 2, 3, 4),
          ingressTraces: [
            createVpnIngressTrace({
              sequence: 1,
              sessionId: 'session-proof',
              stage: 'tun/tcp',
              detail: 'linked',
              atMs: 1,
              traceId: 'trace-complete',
              ingress: 'tun',
              protocol: 'tcp',
              hashedTuple: 'hash-complete',
              correlationHash: 'corr-complete',
              destinationHash: DESTINATION_HASH,
              outboundTerminalHash: OUTBOUND_TERMINAL_HASH,
              outboundChainHash: OUTBOUND_CHAIN_HASH,
              outboundChainLength: 2
            }),
            createVpnIngressTrace({
              sequence: 2,
              sessionId: 'session-proof',
              stage: 'tun/tcp',
              detail: 'missing',
              atMs: 2,
              traceId: 'trace-missing',
              ingress: 'tun',
              protocol: 'tcp',
              hashedTuple: 'hash-missing',
              correlationHash: 'corr-missing'
            })
          ]
        })
      };

      journal.recordTunEvent(event);
      journal.recordTunEvent(event);
      const snapshot = journal.snapshot();

      expect(snapshot.records.length).assertEqual(2);
      expect(snapshot.records[0].linkageStatus).assertEqual('linked');
      expect(snapshot.records[0].destinationHash).assertEqual(DESTINATION_HASH);
      expect(snapshot.records[0].outboundTerminalHash).assertEqual(OUTBOUND_TERMINAL_HASH);
      expect(snapshot.records[0].outboundChainHash).assertEqual(OUTBOUND_CHAIN_HASH);
      expect(snapshot.records[0].outboundChainLength).assertEqual(2);
      expect(snapshot.records[0].counterDelta > 0).assertTrue();
      expect(snapshot.records[1].linkageStatus).assertEqual('missing');
      expect(snapshot.records[1].outboundChainLength).assertEqual(0);
      expect(snapshot.records[1].counterDelta > 0).assertTrue();
    });
  });
}
