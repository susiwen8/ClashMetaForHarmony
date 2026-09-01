import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HARMONY_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const REPO_ROOT = path.resolve(HARMONY_ROOT, '..');
const INCLUDE_DIR = path.join(HARMONY_ROOT, 'core', 'abi', 'include');
const ENTRY_INCLUDE_DIR = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'include');
const ENTRY_SOURCE_DIR = path.join(HARMONY_ROOT, 'entry', 'src', 'main', 'cpp', 'src');
const RUNNER_PATH = path.join(HARMONY_ROOT, 'tools', 'test-native-host.mjs');
const CONTRACT_SOURCE_PATH = path.join(HARMONY_ROOT, 'core', 'abi', 'src', 'cmfa_contract.cpp');
const GO_MAIN_PATH = path.join(HARMONY_ROOT, 'core', 'go', 'cmd', 'cmfa_core', 'main.go');
const PHASE4_PROOF_RUNNER_PATH = path.join(HARMONY_ROOT, 'tests', 'bin', 'run-phase4-device-proof.mjs');

function extractFunctionBody(body, functionName) {
  const signature = `${functionName}(`;
  const start = body.indexOf(signature);
  assert.notEqual(start, -1, `Expected to find ${functionName}`);
  const braceStart = body.indexOf('{', start);
  assert.notEqual(braceStart, -1, `Expected ${functionName} to have a body`);
  let depth = 0;
  for (let index = braceStart; index < body.length; index += 1) {
    const char = body[index];
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return body.slice(start, index + 1);
      }
    }
  }
  throw new Error(`Unbalanced braces in ${functionName}`);
}

test('Task 3 public ABI appends tun and protection symbols without leaking Harmony types', async () => {
  const [typesHeader, hostHeader, coreHeader] = await Promise.all([
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_types.h'), 'utf8'),
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_host.h'), 'utf8'),
    fs.readFile(path.join(INCLUDE_DIR, 'cmfa_core.h'), 'utf8'),
  ]);

  assert.match(typesHeader, /CMFA_SOCKET_PROTECT_FAILED/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_options\b/u);
  assert.match(typesHeader, /\bconst char \*config_path\s*;/u);
  assert.match(typesHeader, /\buint32_t mixed_port\s*;/u);
  assert.match(typesHeader, /\buint32_t platform_api_level\s*;/u);
  assert.match(typesHeader, /\buint8_t process_protected\s*;/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_trace_ring\b/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_snapshot\b/u);
  assert.match(typesHeader, /\btypedef struct cmfa_tun_trace_collection\b/u);
  assert.match(hostHeader, /\bcmfa_socket_protect_fn\s+protect_socket\s*;/u);
  assert.match(hostHeader, /\bsession_id\s*;/u);
  assert.match(hostHeader, /\btrace_id\s*;/u);
  assert.match(hostHeader, /\bingress\s*;/u);
  assert.match(hostHeader, /\bprotocol\s*;/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_start\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_stop\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_runtime_state\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_copy_traces\(/u);
  assert.match(coreHeader, /\bcmfa_status cmfa_tun_copy_traces_ring\(/u);

  for (const header of [typesHeader, hostHeader, coreHeader]) {
    assert.doesNotMatch(header, /\bVpnConnection\b/u);
    assert.doesNotMatch(header, /\bArkTS\b/u);
    assert.doesNotMatch(header, /\bnapi_value\b/u);
    assert.doesNotMatch(header, /\bJNIEnv\b/u);
  }
});

test('Task 3 native host runner keeps documented cli stable while defaulting to tun coverage', async () => {
  const runnerSource = await fs.readFile(RUNNER_PATH, 'utf8');

  assert.match(runnerSource, /const TUN_CONTRACT_TEST_SOURCE = .*cmfa_tun_contract_test\.cpp/u);
  assert.match(runnerSource, /\['tun-contract',\s*\{/u);
  assert.match(runnerSource, /const defaultCaseNames = \['contract', 'tun-contract'\];/u);
  assert.doesNotMatch(runnerSource, /node harmony\/tools\/test-native-host\.mjs --case tun-contract/u);
});

test('Task 3 backend seam adds tun hooks and host protection trampoline', async () => {
  const [backendHeader, backendSource, goMainSource] = await Promise.all([
    fs.readFile(path.join(ENTRY_INCLUDE_DIR, 'cmfa_mihomo_backend.h'), 'utf8'),
    fs.readFile(path.join(ENTRY_SOURCE_DIR, 'cmfa_mihomo_backend.cpp'), 'utf8'),
    fs.readFile(GO_MAIN_PATH, 'utf8'),
  ]);

  assert.match(backendHeader, /register_mihomo_backend/u);
  assert.match(backendSource, /\bcmfa_mihomo_start_tun_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_stop_tun_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_tun_runtime_state_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_tun_copy_traces_v1\b/u);
  assert.match(backendSource, /\bcmfa_mihomo_tun_copy_traces_ring_v1\b/u);
  assert.match(backendSource, /\bhost_protect_socket\b/u);
  assert.match(backendHeader, /\bcmfa_host_protect_socket_bridge_v1\b/u);
  assert.match(backendHeader, /\bcmfa_host_emit_runtime_event_bridge_v1\b/u);
  assert.match(backendSource, /\bcmfa_host_protect_socket_bridge_v1\b/u);
  assert.match(backendSource, /\bcmfa_host_emit_runtime_event_bridge_v1\b/u);
  assert.match(goMainSource, /"cmfa_host_protect_socket_bridge_v1"/u);
  assert.match(goMainSource, /"cmfa_host_emit_runtime_event_bridge_v1"/u);
  assert.doesNotMatch(goMainSource, /__ZN4cmfa33protect_socket_for_mihomo_backend/u);
});

test('production profile validation and loading forward through the native backend into Go', async () => {
  const [backendSource, goMainSource] = await Promise.all([
    fs.readFile(path.join(ENTRY_SOURCE_DIR, 'cmfa_mihomo_backend.cpp'), 'utf8'),
    fs.readFile(GO_MAIN_PATH, 'utf8'),
  ]);

  const validateBody = extractFunctionBody(backendSource, 'validate_config');
  const loadBody = extractFunctionBody(backendSource, 'load_config');
  assert.match(backendSource, /extern "C" cmfa_status cmfa_mihomo_validate_config_v1\(/u);
  assert.match(backendSource, /extern "C" cmfa_status cmfa_mihomo_load_config_v1\(/u);
  assert.match(validateBody, /cmfa_mihomo_validate_config_v1\(/u);
  assert.match(loadBody, /cmfa_mihomo_load_config_v1\(/u);
  assert.doesNotMatch(validateBody, /CMFA_CORE_UNAVAILABLE/u);
  assert.doesNotMatch(loadBody, /CMFA_CORE_UNAVAILABLE/u);

  assert.match(goMainSource, /\/\/export cmfa_mihomo_validate_config_v1/u);
  assert.match(goMainSource, /\/\/export cmfa_mihomo_load_config_v1/u);
  assert.match(goMainSource, /validateManagedConfig\s*=\s*configpkg\.ValidateFile/u);
  assert.match(goMainSource, /func validateConfigForNative\(configPath string\) error \{[\s\S]*if managedConfigPath \{[\s\S]*return validateManagedConfig\(sandboxRoot,\s*candidate\)[\s\S]*\}/u);
  assert.match(goMainSource, /configpkg\.NewLoader\(/u);
  assert.match(goMainSource, /func cmfa_mihomo_validate_config_v1\([\s\S]*err := validateConfigForNative\(C\.GoString\(configPath\)\)/u);
  assert.match(goMainSource, /func cmfa_mihomo_load_config_v1\([\s\S]*executeAfterProxyDelayDrain\(nil,\s*func\(\) proxyMutationResult \{[\s\S]*loadConfigForLocalProxy\(C\.GoString\(configPath\)\)/u);
  const validateNativeBody = extractFunctionBody(goMainSource, 'cmfa_mihomo_validate_config_v1');
  assert.doesNotMatch(validateNativeBody, /executeAfterProxyDelayDrain/u);
});

test('TUN lifecycle diagnostics cross the Go/native boundary as fixed CMFAVpn stages only', async () => {
  const [backendHeader, backendSource, goMainSource] = await Promise.all([
    fs.readFile(path.join(ENTRY_INCLUDE_DIR, 'cmfa_mihomo_backend.h'), 'utf8'),
    fs.readFile(path.join(ENTRY_SOURCE_DIR, 'cmfa_mihomo_backend.cpp'), 'utf8'),
    fs.readFile(GO_MAIN_PATH, 'utf8'),
  ]);

  assert.match(backendSource, /const char \*kVpnStageLogTag = "CMFAVpn";/u);
  assert.match(backendSource, /"tun\.listener\.endpoint-enter"/u);
  assert.match(backendSource, /"tun\.stop\.listener\.begin"/u);
  assert.match(backendSource, /is_allowed_tun_lifecycle_stage\(stage\)/u);
  assert.match(backendSource, /OH_LOG_Print\(LOG_APP, LOG_INFO,[\s\S]*"%\{public\}s", stage\)/u);
  assert.doesNotMatch(backendHeader, /cmfa_host_report_tun_start_stage_bridge_v1/u);
  assert.doesNotMatch(goMainSource, /"cmfa_host_report_tun_start_stage_bridge_v1"/u);
  assert.match(goMainSource, /runtimeLogs\.Publish\(runtimepkg\.RuntimeLog\{[\s\S]*Category:\s+"runtime\.tun\.stage"[\s\S]*Message:\s+stage[\s\S]*\}\)/u);
  assert.match(goMainSource, /ReportStageLifecycle:\s+reportTunStartStage/u);
  const startTunBody = extractFunctionBody(backendSource, 'start_tun');
  assert.match(startTunBody, /cmfa_mihomo_start_tun_v1\([\s\S]*emit_runtime_logs\(options->session_id\)/u);
  assert.doesNotMatch(backendSource, /OH_LOG_Print\(LOG_APP, LOG_INFO,[^;]*(config|session|profile|error|message)/u);
});

test('TUN packet diagnostics bridge to CMFAVpn only for the fixed diagnostic allow-list while preserving host forwarding', async () => {
  const backendSource = await fs.readFile(path.join(ENTRY_SOURCE_DIR, 'cmfa_mihomo_backend.cpp'), 'utf8');

  const startTunBody = extractFunctionBody(backendSource, 'start_tun');
  const bridgeBody = extractFunctionBody(backendSource, 'cmfa_host_emit_runtime_event_bridge_v1');
  const runtimeStateBody = extractFunctionBody(backendSource, 'tun_runtime_state');
  const traceRingBody = extractFunctionBody(backendSource, 'tun_copy_traces_ring');
  assert.match(backendSource, /constexpr unsigned int kVpnStageLogDomain = 0x0D00CF4A;/u);
  assert.match(backendSource, /"tun\.packet\.read-loop-enter"/u);
  assert.match(backendSource, /"tun\.packet\.read-would-block"/u);
  assert.match(backendSource, /"tun\.packet\.read-failed"/u);
  assert.match(backendSource, /"tun\.packet\.raw-read"/u);
  assert.match(backendSource, /"tun\.packet\.gvisor-inject"/u);
  assert.match(backendSource, /std::strcmp\(event->ingress,\s*"diagnostic"\)\s*==\s*0/u);
  assert.match(backendSource, /std::strcmp\(stage,\s*allowed\)\s*==\s*0/u);
  assert.match(backendSource, /is_allowed_tun_packet_diagnostic_stage\(event->protocol\)/u);
  assert.match(backendSource, /OH_LOG_Print\(LOG_APP, LOG_INFO,\s*kVpnStageLogDomain,\s*kVpnStageLogTag,\s*"%\{public\}s",\s*event->protocol\)/u);
  assert.match(backendSource, /event\.message\s*=\s*stage;[\s\S]*event\.session_id\s*=\s*tun_session_id;[\s\S]*event\.ingress\s*=\s*"diagnostic";[\s\S]*event\.protocol\s*=\s*stage;/u);
  assert.match(backendSource, /std::string active_tun_session_id;/u);
  assert.match(startTunBody, /active_tun_session_id\s*=\s*options->session_id;/u);
  assert.match(startTunBody, /emit_runtime_logs\(options->session_id\)/u);
  assert.doesNotMatch(backendSource, /OH_LOG_Print\(LOG_APP, LOG_INFO,[^;]*event->(?:session_id|trace_id|message|code)/u);
  assert.match(bridgeBody, /return g_backend_state\.host\.host_emit_event\(g_backend_state\.host\.context,\s*event,\s*error\);/u);
  assert.doesNotMatch(bridgeBody, /\b(?:session_id|trace_id)\b/u);
  assert.match(runtimeStateBody, /cmfa_mihomo_tun_runtime_state_v1\([\s\S]*emit_runtime_logs\(\)/u);
  assert.match(traceRingBody, /cmfa_mihomo_tun_copy_traces_ring_v1\([\s\S]*emit_runtime_logs\(\)/u);
});

test('tracked phase4 proof runner keeps baseline capture intent and consent diagnostics inside repo-owned sources only', async () => {
  const scriptSource = await fs.readFile(PHASE4_PROOF_RUNNER_PATH, 'utf8');

  assert.match(scriptSource, /function buildProbeAbilityParameters\(originHandle, externalOrigin, runId, captureMode = 'baseline'\)/u);
  assert.match(scriptSource, /const parameters = buildProbeAbilityParameters\(origin, externalOrigin, runId, 'baseline'\);/u);
  assert.match(scriptSource, /const parameters = buildProbeAbilityParameters\(origin, externalOrigin, runId, 'vpn'\);/u);
  assert.match(scriptSource, /let consentLayoutDiagnostic = null;/u);
  assert.match(scriptSource, /consentLayoutDiagnostic = summary;/u);
  assert.match(scriptSource, /consentLayoutDiagnostic,/u);
  assert.match(scriptSource, /EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN/u);
  assert.match(scriptSource, /assessPhase4ProbeReachability\(normalized\)/u);
  assert.match(scriptSource, /stopVpnImpl = async \(options\) => await defaultStopVpn\(options\),/u);
  assert.doesNotMatch(scriptSource, /\.test\(raw\)/u);
});

test('Task 3 protect_socket_to_host stays a synchronous trampoline with no detached worker state', async () => {
  const contractSource = await fs.readFile(CONTRACT_SOURCE_PATH, 'utf8');
  const functionBody = extractFunctionBody(contractSource, 'protect_socket_to_host');

  assert.doesNotMatch(functionBody, /\bstd::thread\b/u);
  assert.doesNotMatch(functionBody, /\.detach\s*\(/u);
  assert.doesNotMatch(contractSource, /\bProtectSocketCallState\b/u);
});
