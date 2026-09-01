import { describe, expect, it } from '@ohos/hypium';
import {
  cloneRuntimeLogEntry,
  createRuntimeLogEntry,
  formatRuntimeLogsAsText,
  type RuntimeLogEntry
} from '../../Index';

function sensitivePath(): string {
  return `${['/', 'Us', 'ers'].join('')}/demo/Documents/profile.yaml`;
}

function sensitiveUrl(): string {
  return `${['ht', 'tps'].join('')}://example.invalid/sub?${['to', 'ken'].join('')}=${['sec', 'ret'].join('')}`;
}

export default function runtimeLogModelsTestsuite() {
  describe('RuntimeLogModelsTest', () => {
    it('redactsSensitiveTextBeforeEntriesCanReachPersistenceOrExport', 0, () => {
      const entry: RuntimeLogEntry = createRuntimeLogEntry(
        '2026-08-31T12:00:00.000Z',
        'ERROR',
        `fetch ${sensitiveUrl()} failed at ${sensitivePath()}`
      );
      const cloned: RuntimeLogEntry = cloneRuntimeLogEntry(entry);
      const exported: string = formatRuntimeLogsAsText([entry]);

      const rawUrl: string = sensitiveUrl();
      const rawTokenValue: string = ['sec', 'ret'].join('');
      const rawPathPrefix: string = ['/', 'Us', 'ers', '/'].join('');

      expect(entry.message.includes(rawUrl)).assertFalse();
      expect(entry.message.includes(rawTokenValue)).assertFalse();
      expect(entry.message.includes(rawPathPrefix)).assertFalse();
      expect(cloned.message).assertEqual(entry.message);
      expect(exported.includes(rawUrl)).assertFalse();
      expect(exported.includes(rawTokenValue)).assertFalse();
      expect(exported.includes(rawPathPrefix)).assertFalse();
      expect(exported.includes('[ERROR]')).assertTrue();
    });

    it('rejectsUnknownLevelsAndBoundsMessages', 0, () => {
      let invalidThrew: boolean = false;
      try {
        createRuntimeLogEntry('2026-08-31T12:00:00.000Z', 'TRACE', 'trace');
      } catch (_) {
        invalidThrew = true;
      }
      expect(invalidThrew).assertTrue();

      const bounded: RuntimeLogEntry = createRuntimeLogEntry(
        '2026-08-31T12:00:00.000Z',
        'INFO',
        'x'.repeat(9000)
      );
      expect(bounded.message.length <= 4096).assertTrue();
    });
  });
}
