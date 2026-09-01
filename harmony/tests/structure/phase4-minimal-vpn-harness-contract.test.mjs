import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import test from 'node:test';

const HARNESS_PATH = new URL('../../../.omx/run-minimal-vpn-harness.mjs', import.meta.url);
const EVIDENCE_INSPECTOR_PATH = new URL('../../../.omx/inspect-phase4-device-evidence.mjs', import.meta.url);

test('minimal VPN harness isolates authorization and restores the traffic probe package', async () => {
  const source = await fs.readFile(HARNESS_PATH, 'utf8');

  assert.match(source, /fs\.cp\(SOURCE_PROJECT, temporaryProject/u,
    'the harness must build from an isolated temporary project');
  assert.match(source, /abilityName: 'HarnessVpnExtensionAbility'/u);
  assert.match(source, /\.id\('harness\.vpn\.action'\)/u);
  assert.match(source, /startVpnExtensionAbility\(HARNESS_WANT\)/u);
  assert.doesNotMatch(source, /createVpnConnection|\.create\(config\)|protect\(/u,
    'the harness must stop at system authorization and avoid creating a TUN');
  assert.match(source, /restoreProbePackage/u,
    'the harness must restore the real traffic-probe HAP after the differential');
  assert.match(source, /--main-identity/u,
    'the same minimal harness must support a main-bundle signing differential');
  assert.match(source, /applyMainSigningIdentity/u,
    'main identity mode must copy signing identity in memory without exposing its fields');
  assert.match(source, /buildHarnessPageSource\(harnessBundle\)/u,
    'the minimal Want bundle must follow the selected signed identity');
  assert.match(source, /buildVpnAbilitySource\(markerToken\)/u,
    'each harness build must embed a fresh non-secret onCreate marker');
  assert.match(source, /vpnExtensionOnCreateObserved/u,
    'the harness must distinguish an already-authorized direct Extension start from a missing dialog');
  assert.match(source, /'file', 'recv', '-b', harnessBundle/u,
    'the onCreate marker must be read through bundle-scoped HDC access');
  assert.match(source, /--session-parameters/u,
    'the harness must isolate the three production session parameters');
  assert.match(source, /--runner-parameter/u,
    'the proof runId parameter must be a separate differential');
  assert.match(source, /sessionParametersObserved/u,
    'the Extension marker must prove whether all session parameters survived the NAPI boundary');
  assert.match(source, /runnerParameterObserved/u,
    'the Extension marker must independently prove the dotted runner parameter');
  assert.match(source, /fs\.rm\(temporaryRoot, \{ recursive: true, force: true \}\)/u,
    'temporary copied signing configuration must be deleted after the run');
});

test('phase4 private evidence inspector exposes only allowlisted startup stages', async () => {
  const source = await fs.readFile(EVIDENCE_INSPECTOR_PATH, 'utf8');

  assert.match(source, /STARTUP_STAGE_PATTERN/u);
  assert.match(source, /platform-connection-\(\?:begin\|ok\|consent\|active\|parameter\|invalid\|service\|internal\|failed\)/u);
  assert.match(source, /startupStages:\s*collectStartupStages\(runtimeRecords\)/u);
  assert.match(source, /STARTUP_STAGE_PATTERN\.test\(detail\)/u);
  assert.match(source, /stages\.push\(detail\.split\('-'\)\.join\('\.'\)\)/u,
    'allowlisted on-disk stage encoding must be restored only after validation');
  assert.doesNotMatch(source, /detail:\s*entry\.detail/u,
    'the inspector must never pass arbitrary runtime detail through to stdout');
});
