import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const MONITOR_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'ets', 'vpn', 'VpnTrafficMonitor.ets');
const MONITOR_TEST_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'test', 'VpnTrafficMonitor.test.ets');
const TEST_LIST_PATH = path.join(HARMONY_ROOT, 'entry', 'src', 'test', 'List.test.ets');

async function readUtf8(targetPath) {
  return await fs.readFile(targetPath, 'utf8');
}

test('vpn traffic monitor contract exposes the dedicated monitor API and hides session identifiers from snapshots', async () => {
  const monitorSource = await readUtf8(MONITOR_PATH);

  assert.match(monitorSource, /export interface VpnTrafficMonitorSnapshot \{[\s\S]*available: boolean;[\s\S]*txBytes: number;[\s\S]*rxBytes: number;[\s\S]*uploadBytesPerSecond: number;[\s\S]*downloadBytesPerSecond: number;[\s\S]*\}/u);
  assert.doesNotMatch(monitorSource, /interface VpnTrafficMonitorSnapshot[\s\S]*sessionId/u);
  assert.match(monitorSource, /export interface VpnTrafficMonitorReadPort \{[\s\S]*snapshot\(\): VpnTrafficMonitorSnapshot;[\s\S]*subscribe\(listener: VpnTrafficMonitorListener\): number;[\s\S]*unsubscribe\(id: number\): void;[\s\S]*\}/u);
  assert.match(monitorSource, /export interface VpnTrafficMonitorLifecyclePort \{[\s\S]*start\(sessionId: string\): void;[\s\S]*markRecovering\(sessionId: string\): void;[\s\S]*stop\(sessionId\?: string\): void;[\s\S]*dispose\(\): void;[\s\S]*\}/u);
  assert.match(monitorSource, /export class VpnTrafficRateTracker/u);
  assert.match(monitorSource, /export class VpnTrafficMonitor implements VpnTrafficMonitorReadPort, VpnTrafficMonitorLifecyclePort/u);
  assert.match(monitorSource, /refreshTrafficCounters\(\)/u);
  assert.match(monitorSource, /this\.tracker\.reset\(\);/u);
});

test('vpn traffic monitor contract keeps the new suite registered in the entry test list', async () => {
  const [monitorTestSource, testListSource] = await Promise.all([
    readUtf8(MONITOR_TEST_PATH),
    readUtf8(TEST_LIST_PATH)
  ]);

  assert.match(monitorTestSource, /describe\('VpnTrafficMonitorTest'/u);
  assert.match(testListSource, /import vpnTrafficMonitorTestsuite from '\.\/VpnTrafficMonitor\.test';/u);
  assert.match(testListSource, /vpnTrafficMonitorTestsuite\(\);/u);
});
