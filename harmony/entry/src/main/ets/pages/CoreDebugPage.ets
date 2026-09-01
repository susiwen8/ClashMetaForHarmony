import { fileIo } from '@kit.CoreFileKit';
import { process } from '@kit.ArkTS';

import {
  getBridgeVersion,
  getCoreService,
  getSelfTestCoreService,
  getPhase1LaunchContext,
  subscribePhase1LaunchContext,
  unsubscribePhase1LaunchContext
} from '../bootstrap/CoreComposition';
import type {
  Phase1LaunchContext,
  Phase2SelfTestProbeRequest,
  Phase2SelfTestProbeResult
} from '../bootstrap/CoreComposition';
import type { CoreError, CoreErrorContext } from '@cmfa/shared';
import type {
  Phase1Check,
  Phase1CheckId,
  Phase1Timestamps,
  Phase1CoreErrorEvidence,
  Phase1Failure,
  Phase1SelfTestProof
} from '@cmfa/shared';

const PROOF_FILE_NAME: string = 'phase1-device-proof.json';
const PHASE2_PROOF_FILE_NAME: string = 'phase2-device-proof.json';
const PHASE2_CONFIG_FILE_NAME: string = 'phase2-match-direct.yaml';
const PHASE2_CONFIG_SOURCE: string = 'mode: rule\nmixed-port: 0\nrules:\n  - MATCH,DIRECT\n';
const PHASE2_SELF_TEST_BUILD_FLAG: string = 'CMFA_ENABLE_PHASE2_SELFTEST';
const INVALID_SELF_TEST_PATH: string = '';
const PHASE2_MIXED_PORT: number = 17890;

type ProbeProtocol = 'HTTP_CONNECT' | 'SOCKS5';
type Phase2ProbeRequest = Phase2SelfTestProbeRequest;
type Phase2ProbeResult = Phase2SelfTestProbeResult;

interface Phase2ProbeFailure {
  code: string;
  detail: string;
  stage: string;
}

interface Phase2ProbeEntry {
  protocol: ProbeProtocol;
  status: 'pass' | 'fail' | 'incomplete';
  detail: string;
  probe: Phase2ProbeResult;
  probeRunId: string | null;
  requestId: string | null;
  originRequestId: string | null;
  appProbeId: string | null;
  coreEventId: string | null;
  originEventRunId: string | null;
  appEventRunId: string | null;
  coreEventRunId: string | null;
  originId: string | null;
  coreConnectionId: string | null;
  clientSourcePort: number | null;
  destination: string | null;
  upstreamInboundType: string | null;
  listenerAddress: string | null;
  tlsPeerSha256: string | null;
  httpStatus: number | null;
  responseBytes: number | null;
  responseSha256: string | null;
  startedAt: string | null;
  completedAt: string | null;
  error: Phase2ProbeFailure | null;
}

interface Phase2ProbeTimestamps {
  startedAt: string;
  proofAt: string;
}

interface Phase2ProbeCollection {
  http: Phase2ProbeEntry | null;
  socks: Phase2ProbeEntry | null;
}

interface Phase2StopEvidence {
  result: string;
}

interface Phase2SelfTestProof {
  schemaVersion: '1.0.0';
  phase: 2;
  result: 'pass' | 'fail' | 'incomplete';
  runId: string;
  timestamps: Phase2ProbeTimestamps;
  bridgeVersion: string;
  coreVersion: string;
  selfTestBuildEnabled: boolean;
  buildFlag: string;
  appProcessId: number | null;
  originRunId: string;
  fixturePath: string;
  fixtureSha256: string;
  fixtureOriginUrl: string;
  fixtureExpectedBodySha256: string;
  httpListenerAddress: string;
  socksListenerAddress: string;
  probes: Phase2ProbeCollection;
  stop: Phase2StopEvidence;
  failures: Phase2ProbeFailure[];
}

function wait(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
}

function parseSourcePort(address: string): number | null {
  const separator: number = address.lastIndexOf(':');
  if (separator < 0 || separator === address.length - 1) {
    return null;
  }
  const value: number = Number.parseInt(address.slice(separator + 1), 10);
  return Number.isInteger(value) && value > 0 ? value : null;
}

function failedCheck(id: Phase1CheckId, detail: string): Phase1Check {
  return { id, result: 'fail', detail };
}

function passedCheck(id: Phase1CheckId, detail: string): Phase1Check {
  return { id, result: 'pass', detail };
}

function setCheck(checks: Phase1Check[], check: Phase1Check): void {
  const index: number = checks.findIndex((entry: Phase1Check) => entry.id === check.id);
  if (index >= 0) {
    checks[index] = check;
    return;
  }
  checks.push(check);
}

function createCoreErrorContext(operation: string, status: number): CoreErrorContext {
  return { operation, status };
}

function createProofTimestamps(startedAt: string, proofAt: string): Phase1Timestamps {
  return { startedAt, proofAt };
}

function unknownCoreError(operation: string): Phase1CoreErrorEvidence {
  const context: CoreErrorContext = createCoreErrorContext(operation, -1);
  return {
    name: 'CoreError',
    code: 'CORE_ERROR_SHAPE_INVALID',
    category: 'CoreError',
    message: 'Native rejection did not match the declared CoreError shape.',
    detail: 'The expected test-only invalid call rejected without complete typed metadata.',
    retryable: false,
    action: 'Inspect the Node-API error mapping.',
    context
  };
}

function copyCoreError(error: CoreError): Phase1CoreErrorEvidence {
  const context: CoreErrorContext = createCoreErrorContext(
    error.context?.operation ?? 'unknown',
    error.context?.status ?? -1
  );
  return {
    name: 'CoreError',
    code: error.code,
    category: error.category,
    message: error.message,
    detail: error.detail,
    retryable: error.retryable,
    action: error.action,
    context
  };
}

function isTypedCoreError(error: CoreError): boolean {
  return error.name === 'CoreError' && error.code.length > 0 && error.message.length > 0 &&
    error.detail.length > 0 && error.action.length > 0 && error.context !== undefined;
}

@Entry
@Component
struct CoreDebugPage {
  private readonly coreService = getCoreService();
  private launchContextSubscriptionId: number = 0;
  private selfTestInFlight: boolean = false;
  private activeRunId: string = '';

  @State private bridgeVersion: string = getBridgeVersion();
  @State private coreVersion: string = 'not loaded';
  @State private lastError: Phase1CoreErrorEvidence | null = null;
  @State private eventCount: number = 0;
  @State private proofStatus: string = 'idle';

  aboutToAppear(): void {
    if (this.launchContextSubscriptionId === 0) {
      this.launchContextSubscriptionId = subscribePhase1LaunchContext((context: Phase1LaunchContext) => {
        this.handlePhase1LaunchContext(context);
      });
    }
    this.handlePhase1LaunchContext(getPhase1LaunchContext());
  }

  aboutToDisappear(): void {
    if (this.launchContextSubscriptionId !== 0) {
      unsubscribePhase1LaunchContext(this.launchContextSubscriptionId);
      this.launchContextSubscriptionId = 0;
    }
  }

  private handlePhase1LaunchContext(context: Phase1LaunchContext): void {
    if (!context.selfTest || context.runId.length === 0 || context.filesDir.length === 0) {
      if (!this.selfTestInFlight && this.activeRunId.length === 0) {
        this.loadCoreVersion();
      }
      return;
    }
    if (this.selfTestInFlight || this.activeRunId === context.runId) {
      return;
    }
    this.selfTestInFlight = true;
    this.activeRunId = context.runId;
    this.runAutomaticSelfTest(context).then(() => {
      this.finishAutomaticSelfTest();
    }).catch(() => {
      this.proofStatus = 'fail';
      this.finishAutomaticSelfTest();
    });
  }

  private finishAutomaticSelfTest(): void {
    this.selfTestInFlight = false;
    const latestContext: Phase1LaunchContext = getPhase1LaunchContext();
    if (latestContext.runId !== this.activeRunId) {
      this.handlePhase1LaunchContext(latestContext);
    }
  }

  private loadCoreVersion(): void {
    this.coreService.coreVersion().then((version: string) => {
      this.coreVersion = version;
    }).catch((error: CoreError) => {
      this.lastError = copyCoreError(error);
    });
  }

  private async runAutomaticSelfTest(context: Phase1LaunchContext): Promise<void> {
    this.proofStatus = 'running';
    const startedAt: string = new Date().toISOString();
    const checks: Phase1Check[] = [];
    const failures: Phase1Failure[] = [];
    let subscriptionId: number = 0;

    try {
      const helloValue: string = this.coreService.hello();
      if (helloValue === 'cmfa-native-ready') {
        setCheck(checks, passedCheck('nativeHello', helloValue));
      } else {
        setCheck(checks, failedCheck('nativeHello', `Unexpected hello value: ${helloValue}`));
      }
    } catch (error) {
      setCheck(checks, failedCheck('nativeHello', 'hello() threw before returning the native sentinel.'));
    }

    try {
      const versionPromise: Promise<string> = this.coreService.coreVersion();
      this.coreVersion = await versionPromise;
      setCheck(checks, this.coreVersion.length > 0
        ? passedCheck('coreVersion', this.coreVersion)
        : failedCheck('coreVersion', 'coreVersion() resolved to an empty string.'));
      setCheck(checks, passedCheck('promiseResolution', 'coreVersion() Promise resolved.'));
    } catch (error) {
      setCheck(checks, failedCheck('coreVersion', 'coreVersion() did not return a usable real-core version.'));
      setCheck(checks, failedCheck('promiseResolution', 'coreVersion() Promise rejected.'));
    }

    try {
      await this.coreService.validateConfiguration(INVALID_SELF_TEST_PATH);
      setCheck(checks, failedCheck('typedRejection', 'The invalid call unexpectedly resolved.'));
    } catch (error) {
      const coreError: CoreError = error as CoreError;
      const typed: boolean = isTypedCoreError(coreError);
      this.lastError = typed ? copyCoreError(coreError) : unknownCoreError('validateConfiguration');
      setCheck(checks, typed
        ? passedCheck('typedRejection', coreError.code)
        : failedCheck('typedRejection', 'The invalid call rejected without the declared CoreError shape.'));
    }

    try {
      const beforeSubscribe: number = this.eventCount;
      subscriptionId = this.coreService.subscribe(() => {
        this.eventCount += 1;
      });
      const eventDeadline: number = Date.now() + 1500;
      while (this.eventCount === beforeSubscribe && Date.now() < eventDeadline) {
        await wait(25);
      }
      setCheck(checks, this.eventCount > beforeSubscribe
        ? passedCheck('eventDelivery', `Observed ${this.eventCount - beforeSubscribe} event.`)
        : failedCheck('eventDelivery', 'No event arrived before the self-test deadline.'));

      this.coreService.unsubscribe(subscriptionId);
      subscriptionId = 0;
      const afterUnsubscribe: number = this.eventCount;
      await wait(250);
      setCheck(checks, this.eventCount === afterUnsubscribe
        ? passedCheck('unsubscribeSilence', 'No event arrived after unsubscribe.')
        : failedCheck('unsubscribeSilence', 'An event arrived after unsubscribe.'));
    } catch (error) {
      setCheck(checks, failedCheck('eventDelivery', 'Event subscription failed.'));
      setCheck(checks, failedCheck('unsubscribeSilence', 'Unsubscribe silence could not be proved.'));
    } finally {
      if (subscriptionId !== 0) {
        try {
          this.coreService.unsubscribe(subscriptionId);
        } catch (error) {
          setCheck(checks, failedCheck('unsubscribeSilence', 'Unsubscribe threw during self-test cleanup.'));
        }
      }
    }

    const allPassed: boolean = checks.length === 6 && checks.every((check: Phase1Check) => check.result === 'pass');
    if (!allPassed) {
      const failure: Phase1Failure = {
        code: 'PHASE1_SELF_TEST_FAILED',
        detail: 'One or more real native bridge checks failed.',
        stage: 'self-test'
      };
      failures.push(failure);
    }
    const timestamps: Phase1Timestamps = createProofTimestamps(startedAt, new Date().toISOString());
    const proof: Phase1SelfTestProof = {
      schemaVersion: '1.0.0',
      phase: 1,
      result: allPassed ? 'pass' : 'fail',
      runId: context.runId,
      timestamps,
      bridgeVersion: this.bridgeVersion,
      coreVersion: this.coreVersion,
      eventCount: this.eventCount,
      lastError: this.lastError,
      checks,
      failures
    };

    try {
      this.writeProof(proof, context.filesDir);
      if (context.probeOriginUrl.length > 0 && context.probeCaPem.length > 0 &&
        context.probeExpectedBodySha256.length > 0) {
        await this.runPhase2ProbeSelfTest(context);
      }
      this.proofStatus = allPassed ? 'pass' : 'fail';
    } catch (error) {
      this.proofStatus = 'write-failed';
    }
  }

  private async runPhase2ProbeSelfTest(context: Phase1LaunchContext): Promise<void> {
    const startedAt: string = new Date().toISOString();
    const configPath: string = `${context.filesDir}/${PHASE2_CONFIG_FILE_NAME}`;
    let httpProbe: Phase2ProbeEntry | null = null;
    let socksProbe: Phase2ProbeEntry | null = null;
    const failures: Phase2ProbeFailure[] = [];
    const probeService = getSelfTestCoreService();
    const selfTestBuildEnabled: boolean = typeof probeService.probeHttpsForSelfTest === 'function';
    const appProcessId: number | null = this.readAppProcessId();
    let httpAddress: string = '';
    let socksAddress: string = '';
    let stopResult: string = 'not-run';

    if (!selfTestBuildEnabled) {
      const phase2Timestamps: Phase2ProbeTimestamps = {
        startedAt,
        proofAt: new Date().toISOString()
      };
      const phase2Probes: Phase2ProbeCollection = {
        http: httpProbe,
        socks: socksProbe
      };
      const phase2Stop: Phase2StopEvidence = {
        result: stopResult
      };
      const disabledFailure: Phase2ProbeFailure = {
        code: 'PHASE2_SELFTEST_DISABLED',
        detail: `${PHASE2_SELF_TEST_BUILD_FLAG} is disabled in the default lane.`,
        stage: 'phase2'
      };
      const phase2Proof: Phase2SelfTestProof = {
        schemaVersion: '1.0.0',
        phase: 2,
        result: 'incomplete',
        runId: context.runId,
        timestamps: phase2Timestamps,
        bridgeVersion: this.bridgeVersion,
        coreVersion: this.coreVersion,
        selfTestBuildEnabled,
        buildFlag: PHASE2_SELF_TEST_BUILD_FLAG,
        appProcessId,
        originRunId: context.probeOriginRunId.length > 0 ? context.probeOriginRunId : context.runId,
        fixturePath: context.probeFixturePath,
        fixtureSha256: context.probeFixtureSha256,
        fixtureOriginUrl: context.probeOriginUrl,
        fixtureExpectedBodySha256: context.probeExpectedBodySha256,
        httpListenerAddress: httpAddress,
        socksListenerAddress: socksAddress,
        probes: phase2Probes,
        stop: phase2Stop,
        failures: [disabledFailure]
      };
      this.writeAtomicTextFile(`${context.filesDir}/${PHASE2_PROOF_FILE_NAME}`, `${JSON.stringify(phase2Proof)}\n`);
      return;
    }

    try {
      this.writeTextFile(configPath, PHASE2_CONFIG_SOURCE);
      const snapshot = await this.coreService.startLocal({
        configPath,
        mixedPort: PHASE2_MIXED_PORT
      });
      httpAddress = snapshot.httpAddress;
      socksAddress = snapshot.socksAddress;

      for (const protocol of ['HTTP_CONNECT', 'SOCKS5'] as ProbeProtocol[]) {
        const listenerAddress: string = protocol === 'HTTP_CONNECT' ? httpAddress : socksAddress;
        const request: Phase2ProbeRequest = {
          probeRunId: `${context.runId}-${protocol.toLowerCase()}`,
          protocol,
          listenerAddress,
          originUrl: context.probeOriginUrl,
          caPem: context.probeCaPem,
          expectedBodySha256: context.probeExpectedBodySha256
        };
        const probe: Phase2ProbeResult = await probeService.probeHttpsForSelfTest(request);
        const passed: boolean = probe.ok && probe.httpStatus === 200 && probe.error.code.length === 0;
        const probeEntry: Phase2ProbeEntry = {
          protocol,
          status: passed ? 'pass' : 'fail',
          detail: passed ? probe.tracker.connectionId : `${probe.error.code}:${probe.error.detail}`,
          probe,
          probeRunId: probe.probeRunId,
          requestId: probe.requestIdEcho,
          originRequestId: probe.requestIdEcho,
          appProbeId: request.probeRunId,
          coreEventId: probe.tracker.connectionId,
          originEventRunId: context.probeOriginRunId.length > 0 ? context.probeOriginRunId : context.runId,
          appEventRunId: context.runId,
          coreEventRunId: context.runId,
          originId: probe.originId,
          coreConnectionId: probe.tracker.connectionId,
          clientSourcePort: parseSourcePort(probe.clientLocalAddress),
          destination: probe.tracker.destinationAddress,
          upstreamInboundType: probe.tracker.inboundType,
          listenerAddress,
          tlsPeerSha256: probe.tlsPeerSha256,
          httpStatus: probe.httpStatus,
          responseBytes: probe.bodyBytes,
          responseSha256: probe.responseSha256,
          startedAt: probe.startedAt,
          completedAt: probe.completedAt,
          error: probe.error.code.length > 0 ? {
            code: probe.error.code,
            detail: probe.error.detail,
            stage: probe.error.stage
          } : null
        };
        if (protocol === 'HTTP_CONNECT') {
          httpProbe = probeEntry;
        } else {
          socksProbe = probeEntry;
        }
        if (!passed) {
          failures.push({
            code: probe.error.code.length > 0 ? probe.error.code : 'PHASE2_PROBE_FAILED',
            detail: probe.error.detail.length > 0 ? probe.error.detail : `Probe ${protocol} did not pass.`,
            stage: protocol
          });
        }
      }
    } catch (error) {
      failures.push({
        code: 'PHASE2_PROBE_FATAL',
        detail: (error as Error).message ?? 'unknown phase2 probe error',
        stage: 'phase2'
      });
    } finally {
      try {
        await this.coreService.stopRuntime();
        stopResult = 'pass';
      } catch (error) {
        stopResult = 'fail';
        failures.push({
          code: 'PHASE2_STOP_FAILED',
          detail: (error as Error).message ?? 'failed to stop local runtime after phase2 probe',
          stage: 'cleanup'
        });
      }
    }
    if (appProcessId === null) {
      failures.push({
        code: 'APP_PROCESS_ID_UNAVAILABLE',
        detail: 'getProcessInfo() did not return a usable app process ID for the self-test lane.',
        stage: 'phase2'
      });
    }

    const phase2Timestamps: Phase2ProbeTimestamps = {
      startedAt,
      proofAt: new Date().toISOString()
    };
    const phase2Probes: Phase2ProbeCollection = {
      http: httpProbe,
      socks: socksProbe
    };
    const phase2Stop: Phase2StopEvidence = {
      result: stopResult
    };
    const phase2Proof: Phase2SelfTestProof = {
      schemaVersion: '1.0.0',
      phase: 2,
      result: failures.length === 0 && httpProbe !== null && socksProbe !== null && stopResult === 'pass' ? 'pass' : 'incomplete',
      runId: context.runId,
      timestamps: phase2Timestamps,
      bridgeVersion: this.bridgeVersion,
      coreVersion: this.coreVersion,
      selfTestBuildEnabled,
      buildFlag: PHASE2_SELF_TEST_BUILD_FLAG,
      appProcessId,
      originRunId: context.probeOriginRunId.length > 0 ? context.probeOriginRunId : context.runId,
      fixturePath: context.probeFixturePath,
      fixtureSha256: context.probeFixtureSha256,
      fixtureOriginUrl: context.probeOriginUrl,
      fixtureExpectedBodySha256: context.probeExpectedBodySha256,
      httpListenerAddress: httpAddress,
      socksListenerAddress: socksAddress,
      probes: phase2Probes,
      stop: phase2Stop,
      failures
    };
    this.writeAtomicTextFile(`${context.filesDir}/${PHASE2_PROOF_FILE_NAME}`, `${JSON.stringify(phase2Proof)}\n`);
  }

  private readAppProcessId(): number | null {
    try {
      const appProcessId: number = process.pid;
      return Number.isInteger(appProcessId) && appProcessId > 0 ? appProcessId : null;
    } catch (error) {
      return null;
    }
  }

  private writeProof(proof: Phase1SelfTestProof, filesDir: string): void {
    const filePath: string = `${filesDir}/${PROOF_FILE_NAME}`;
    this.writeAtomicTextFile(filePath, `${JSON.stringify(proof)}\n`);
  }

  private writeTextFile(targetPath: string, content: string): void {
    const file: fileIo.File = fileIo.openSync(
      targetPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file.fd);
    }
  }

  private writeAtomicTextFile(targetPath: string, content: string): void {
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
      throw new Error('Failed to atomically publish proof evidence.');
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('Native bridge debug proof')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
        this.factRow('Bridge version', this.bridgeVersion)
        this.factRow('Core version', this.coreVersion)
        this.factRow('Last structured error', this.lastError?.code ?? 'none')
        this.factRow('Event count', `${this.eventCount}`)
        this.factRow('Proof status', this.proofStatus)
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private factRow(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(14)
        .fontColor('#6B7280')
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
    }
    .alignItems(HorizontalAlign.Start)
  }
}
