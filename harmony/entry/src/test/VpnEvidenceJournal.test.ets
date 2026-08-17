import { describe, expect, it } from '@ohos/hypium';
import {
  VpnEvidenceJournal,
  type VpnEvidenceObservationRecord,
  type VpnEvidenceCounters,
  type VpnEvidenceJournalDocument,
  type VpnEvidenceJournalStorage,
  type VpnEvidenceJournalClock
} from '../main/ets/vpn/VpnEvidenceJournal';

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

      journal.rotateSession('session-secret-1');
      journal.recordLifecycleFact('running', 'https://device.example.invalid/path?token=1 192.168.1.7 profile-content');
      journal.recordTunCounters(counters);
      const snapshot = journal.snapshot();

      expect(snapshot.sequence > 0).assertTrue();
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

      journal.rotateSession('session-secret-2');
      journal.recordLifecycleFact('stopping', 'vpnId=abc123 secret token password');
      const snapshot = journal.snapshot();

      expect(snapshot.writeFailureCount > 0).assertTrue();
      expect(snapshot.lifecycle.state).assertEqual('stopping');
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

      journal.rotateSession('session-live');
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

      journal.rotateSession('session-next');
      const nextSnapshot = journal.snapshot();
      expect(nextSnapshot.records.length).assertEqual(0);
      expect(nextSnapshot.sessionAlias === liveSnapshot.sessionAlias).assertFalse();
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

      journal.rotateSession(sessionId);
      journal.recordObservationAdapter(record);
      const snapshot = journal.snapshot();
      const persisted = JSON.parse(storage.writes[storage.writes.length - 1]) as VpnEvidenceJournalDocument;

      expect(snapshot.sessionAlias).assertEqual(`session-${expectedHash}`);
      expect(snapshot.records[0].sessionIdHash).assertEqual(expectedHash);
      expect(persisted.records[0].sessionIdHash).assertEqual(expectedHash);
    });
  });
}
