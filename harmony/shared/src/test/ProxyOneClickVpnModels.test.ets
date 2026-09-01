import { describe, expect, it } from '@ohos/hypium';
import {
  cloneOneClickVpnOperationSnapshot,
  cloneSelectNodeAndEnsureVpnResult,
  createOneClickVpnFailureResult,
  createOneClickVpnOperationSnapshot,
  createSelectNodeAndEnsureVpnSuccessResult,
  listOneClickVpnErrorResourceIds,
  listOneClickVpnFailureCodes,
  listOneClickVpnFailureStages,
  listOneClickVpnOperationOutcomes,
  listOneClickVpnProgressStages,
  listSelectNodeAndEnsureVpnSuccessKinds,
  type OneClickVpnErrorResourceId,
  type OneClickVpnFailureCode,
  type OneClickVpnFailureStage,
  type OneClickVpnOperationSnapshot,
  type SelectNodeAndEnsureVpnFailedResult,
  type SelectNodeAndEnsureVpnResult,
  type SelectNodeAndEnsureVpnSucceededResult
} from '../../Index';
import { expectThrowsMessage } from './fakes/ProfileFakes';

interface FailureMappingExpectation {
  code: OneClickVpnFailureCode;
  stage: OneClickVpnFailureStage;
  resourceId: OneClickVpnErrorResourceId;
  retryableOptions: boolean[];
  savedForNextStartOptions: boolean[];
}

interface LeakyFailedResult extends SelectNodeAndEnsureVpnFailedResult {
  sessionId: string;
}

interface LeakySucceededResult extends SelectNodeAndEnsureVpnSucceededResult {
  label: string;
}

interface LeakyOperationSnapshot extends OneClickVpnOperationSnapshot {
  detail: string;
}

function exactKeysOf(record: Object): string {
  return Object.keys(record).sort().join(',');
}

export default function proxyOneClickVpnModelsTestsuite() {
  describe('ProxyOneClickVpnModelsTest', () => {
    it('exposesClosedOneClickVpnAllowlists', 0, () => {
      const successKinds: string[] = listSelectNodeAndEnsureVpnSuccessKinds();
      const failureStages: string[] = listOneClickVpnFailureStages();
      const failureCodes: string[] = listOneClickVpnFailureCodes();
      const resourceIds: string[] = listOneClickVpnErrorResourceIds();
      const progressStages: string[] = listOneClickVpnProgressStages();
      const outcomes: string[] = listOneClickVpnOperationOutcomes();

      successKinds[0] = 'mutated';
      failureStages[0] = 'mutated';
      failureCodes[0] = 'mutated';
      resourceIds[0] = 'mutated';
      progressStages[0] = 'mutated';
      outcomes[0] = 'mutated';

      expect(listSelectNodeAndEnsureVpnSuccessKinds().join(',')).assertEqual(
        'ALREADY_ACTIVE,APPLIED_TO_RUNNING_VPN,APPLIED_TO_RUNNING_VPN_NOT_PERSISTED,VPN_STARTED,SAVED_VPN_START_FAILED'
      );
      expect(listOneClickVpnFailureStages().join(',')).assertEqual(
        'ADMISSION,SELECTION,VPN_START,VPN_CONFIRMATION'
      );
      expect(listOneClickVpnFailureCodes().join(',')).assertEqual(
        'OPERATION_BUSY,PROXY_SELECTION_STALE,PROXY_SELECTION_FAILED,PROXY_PERSISTENCE_FAILED,VPN_PROFILE_UNAVAILABLE,VPN_PERMISSION_DENIED,VPN_START_FAILED,VPN_STOPPED_BEFORE_RUNNING,VPN_CONFIRMATION_TIMEOUT,VPN_SESSION_CHANGED'
      );
      expect(listOneClickVpnErrorResourceIds().join(',')).assertEqual(
        'proxies_one_click_busy,proxies_error_selection_stale,proxies_error_selection_failed,proxies_error_persistence_failed,error_vpn_profile_unavailable,error_vpn_permission_denied,error_vpn_start_failed,proxies_one_click_confirmation_timeout,proxies_error_session_changed'
      );
      expect(listOneClickVpnProgressStages().join(',')).assertEqual(
        'IDLE,SAVING_SELECTION,STARTING_VPN,SWITCHING_VPN,CONFIRMING_SELECTION'
      );
      expect(listOneClickVpnOperationOutcomes().join(',')).assertEqual('NONE,SUCCEEDED,FAILED');
    });

    it('createsExactSuccessResultsAndClonesWithoutPrivateFields', 0, () => {
      const success: SelectNodeAndEnsureVpnResult = createSelectNodeAndEnsureVpnSuccessResult('VPN_STARTED');
      const cloned: SelectNodeAndEnsureVpnResult = cloneSelectNodeAndEnsureVpnResult(success);

      expect(success.kind).assertEqual('VPN_STARTED');
      expect(exactKeysOf(success as Object)).assertEqual('kind');
      expect(success === cloned).assertFalse();
      expect(cloned.kind).assertEqual('VPN_STARTED');
      expect(JSON.stringify(cloned).includes('label')).assertFalse();
      expect(JSON.stringify(cloned).includes('endpoint')).assertFalse();
      expect(JSON.stringify(cloned).includes('sessionId')).assertFalse();
      expect(JSON.stringify(cloned).includes('detail')).assertFalse();
    });

    it('mapsEveryFailureCodeToItsExactClosedContract', 0, () => {
      const expectations: FailureMappingExpectation[] = [
        {
          code: 'OPERATION_BUSY',
          stage: 'ADMISSION',
          resourceId: 'proxies_one_click_busy',
          retryableOptions: [true],
          savedForNextStartOptions: [false, true]
        },
        {
          code: 'PROXY_SELECTION_STALE',
          stage: 'SELECTION',
          resourceId: 'proxies_error_selection_stale',
          retryableOptions: [true],
          savedForNextStartOptions: [false]
        },
        {
          code: 'PROXY_SELECTION_FAILED',
          stage: 'SELECTION',
          resourceId: 'proxies_error_selection_failed',
          retryableOptions: [true],
          savedForNextStartOptions: [false]
        },
        {
          code: 'PROXY_PERSISTENCE_FAILED',
          stage: 'SELECTION',
          resourceId: 'proxies_error_persistence_failed',
          retryableOptions: [false, true],
          savedForNextStartOptions: [false]
        },
        {
          code: 'VPN_PROFILE_UNAVAILABLE',
          stage: 'VPN_START',
          resourceId: 'error_vpn_profile_unavailable',
          retryableOptions: [false],
          savedForNextStartOptions: [true]
        },
        {
          code: 'VPN_PERMISSION_DENIED',
          stage: 'VPN_START',
          resourceId: 'error_vpn_permission_denied',
          retryableOptions: [true],
          savedForNextStartOptions: [true]
        },
        {
          code: 'VPN_START_FAILED',
          stage: 'VPN_START',
          resourceId: 'error_vpn_start_failed',
          retryableOptions: [true],
          savedForNextStartOptions: [true]
        },
        {
          code: 'VPN_STOPPED_BEFORE_RUNNING',
          stage: 'VPN_START',
          resourceId: 'error_vpn_start_failed',
          retryableOptions: [true],
          savedForNextStartOptions: [true]
        },
        {
          code: 'VPN_CONFIRMATION_TIMEOUT',
          stage: 'VPN_CONFIRMATION',
          resourceId: 'proxies_one_click_confirmation_timeout',
          retryableOptions: [true],
          savedForNextStartOptions: [true]
        },
        {
          code: 'VPN_SESSION_CHANGED',
          stage: 'VPN_CONFIRMATION',
          resourceId: 'proxies_error_session_changed',
          retryableOptions: [true],
          savedForNextStartOptions: [true]
        }
      ];

      for (let index: number = 0; index < expectations.length; index += 1) {
        const expected: FailureMappingExpectation = expectations[index];
        for (let retryIndex: number = 0; retryIndex < expected.retryableOptions.length; retryIndex += 1) {
          for (let savedIndex: number = 0; savedIndex < expected.savedForNextStartOptions.length; savedIndex += 1) {
            const result: SelectNodeAndEnsureVpnResult = createOneClickVpnFailureResult(
              expected.stage,
              expected.code,
              expected.retryableOptions[retryIndex],
              expected.resourceId,
              expected.savedForNextStartOptions[savedIndex]
            );

            expect(result.kind).assertEqual('FAILED');
            if (result.kind !== 'FAILED') {
              throw new Error('Expected FAILED result.');
            }
            expect(result.stage).assertEqual(expected.stage);
            expect(result.code).assertEqual(expected.code);
            expect(result.retryable).assertEqual(expected.retryableOptions[retryIndex]);
            expect(result.resourceId).assertEqual(expected.resourceId);
            expect(result.savedForNextStart).assertEqual(expected.savedForNextStartOptions[savedIndex]);
            expect(exactKeysOf(result as Object)).assertEqual('code,kind,resourceId,retryable,savedForNextStart,stage');
          }
        }
      }
    });

    it('rejectsInvalidFailureMappingsAndPrivateLeakFields', 0, () => {
      expectThrowsMessage(() => {
        createOneClickVpnFailureResult(
          'SELECTION',
          'PROXY_SELECTION_FAILED',
          true,
          'proxies_error_selection_stale',
          false
        );
      }, 'mapping');
      expectThrowsMessage(() => {
        createOneClickVpnFailureResult(
          'VPN_START',
          'VPN_PROFILE_UNAVAILABLE',
          true,
          'error_vpn_profile_unavailable',
          true
        );
      }, 'mapping');
      expectThrowsMessage(() => {
        const leakedFailed: LeakyFailedResult = {
          kind: 'FAILED',
          stage: 'VPN_CONFIRMATION',
          code: 'VPN_SESSION_CHANGED',
          retryable: true,
          resourceId: 'proxies_error_session_changed',
          savedForNextStart: true,
          sessionId: 'vpn-session-1'
        };
        cloneSelectNodeAndEnsureVpnResult(leakedFailed);
      }, 'exact keys');
      expectThrowsMessage(() => {
        const leakedSucceeded: LeakySucceededResult = {
          kind: 'VPN_STARTED',
          label: 'secret-node'
        };
        cloneSelectNodeAndEnsureVpnResult(leakedSucceeded);
      }, 'exact keys');
    });

    it('enforcesBalancedProgressSnapshotInvariantsAndDeepClones', 0, () => {
      const switching: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('SWITCHING_VPN', true, 'NONE');
      const switched: OneClickVpnOperationSnapshot = cloneOneClickVpnOperationSnapshot(switching);
      const failedIdle: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'FAILED');
      const succeededIdle: OneClickVpnOperationSnapshot = createOneClickVpnOperationSnapshot('IDLE', false, 'SUCCEEDED');

      expect(switching.stage).assertEqual('SWITCHING_VPN');
      expect(switched === switching).assertFalse();
      expect(switched.outcome).assertEqual('NONE');
      expect(exactKeysOf(switched as Object)).assertEqual('busy,outcome,stage');
      expect(failedIdle.outcome).assertEqual('FAILED');
      expect(succeededIdle.outcome).assertEqual('SUCCEEDED');

      expectThrowsMessage(() => {
        createOneClickVpnOperationSnapshot('SAVING_SELECTION', false, 'NONE');
      }, 'busy');
      expectThrowsMessage(() => {
        createOneClickVpnOperationSnapshot('STARTING_VPN', true, 'SUCCEEDED');
      }, 'outcome');
      expectThrowsMessage(() => {
        createOneClickVpnOperationSnapshot('IDLE', true, 'NONE');
      }, 'IDLE');
      expectThrowsMessage(() => {
        const leakedSnapshot: LeakyOperationSnapshot = {
          stage: 'IDLE',
          busy: false,
          outcome: 'FAILED',
          detail: 'vpn-session-1'
        };
        cloneOneClickVpnOperationSnapshot(leakedSnapshot);
      }, 'exact keys');
    });
  });
}
