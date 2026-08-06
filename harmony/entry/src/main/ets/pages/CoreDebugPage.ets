import { fileIo } from '@kit.CoreFileKit';

import {
  getBridgeVersion,
  getCoreService,
  getPhase1LaunchContext,
  subscribePhase1LaunchContext,
  unsubscribePhase1LaunchContext
} from '../bootstrap/CoreComposition';
import type { Phase1LaunchContext } from '../bootstrap/CoreComposition';
import type { CoreError, CoreErrorContext } from '@cmfa/shared';
import type {
  ProbeProtocol,
  ProbeRequest,
  ProbeResult,
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
const INVALID_SELF_TEST_PATH: string = '';
const PHASE2_MIXED_PORT: number = 17890;

interface Phase2ProbeFailure {
  code: string;
  detail: string;
  stage: string;
}

interface Phase2ProbeEntry {
  protocol: ProbeProtocol;
  result: 'pass' | 'fail';
  detail: string;
  probe: ProbeResult;
}

interface Phase2ProbeTimestamps {
  startedAt: string;
  proofAt: string;
}

interface Phase2SelfTestProof {
  schemaVersion: '1.0.0';
  phase: 2;
  result: 'pass' | 'fail' | 'incomplete';
  runId: string;
  timestamps: Phase2ProbeTimestamps;
  bridgeVersion: string;
  coreVersion: string;
  httpAddress: string;
  socksAddress: string;
  probes: Phase2ProbeEntry[];
  failures: Phase2ProbeFailure[];
}

function wait(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, milliseconds);
  });
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
    const probes: Phase2ProbeEntry[] = [];
    const failures: Phase2ProbeFailure[] = [];
    let httpAddress: string = '';
    let socksAddress: string = '';

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
        const request: ProbeRequest = {
          probeRunId: `${context.runId}-${protocol.toLowerCase()}`,
          protocol,
          listenerAddress,
          originUrl: context.probeOriginUrl,
          caPem: context.probeCaPem,
          expectedBodySha256: context.probeExpectedBodySha256
        };
        const probe = await this.coreService.probeHttps(request);
        const passed: boolean = probe.ok && probe.httpStatus === 200 && probe.error.code.length === 0;
        probes.push({
          protocol,
          result: passed ? 'pass' : 'fail',
          detail: passed ? probe.tracker.connectionId : `${probe.error.code}:${probe.error.detail}`,
          probe
        });
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
      } catch (error) {
        failures.push({
          code: 'PHASE2_STOP_FAILED',
          detail: (error as Error).message ?? 'failed to stop local proxy after phase2 probe',
          stage: 'cleanup'
        });
      }
    }

    const phase2Timestamps: Phase2ProbeTimestamps = {
      startedAt,
      proofAt: new Date().toISOString()
    };
    const phase2Proof: Phase2SelfTestProof = {
      schemaVersion: '1.0.0',
      phase: 2,
      result: failures.length === 0 && probes.length === 2 ? 'pass' : 'fail',
      runId: context.runId,
      timestamps: phase2Timestamps,
      bridgeVersion: this.bridgeVersion,
      coreVersion: this.coreVersion,
      httpAddress,
      socksAddress,
      probes,
      failures
    };
    this.writeTextFile(`${context.filesDir}/${PHASE2_PROOF_FILE_NAME}`, `${JSON.stringify(phase2Proof)}\n`);
  }

  private writeProof(proof: Phase1SelfTestProof, filesDir: string): void {
    const filePath: string = `${filesDir}/${PROOF_FILE_NAME}`;
    this.writeTextFile(filePath, `${JSON.stringify(proof)}\n`);
  }

  private writeTextFile(filePath: string, content: string): void {
    const file: fileIo.File = fileIo.openSync(
      filePath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file.fd);
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
