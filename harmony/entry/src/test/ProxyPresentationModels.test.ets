import { describe, expect, it } from '@ohos/hypium';
import type { OneClickVpnErrorResourceId, ProxyRejectedErrorCode } from '@cmfa/shared';
import {
  cloneProxyViewState,
  type ProxyActivationStateOptions,
  createProxyActivationStateOptions,
  createProxyGroupTabState,
  createProxyNodeRowState,
  createProxyViewState,
  type ProxyActivationStage,
  type ProxyGroupTabState,
  type ProxyNodeRowState,
  type ProxyViewState,
  type ProxyViewStateOptions
} from '../main/ets/presentation/ProxyPresentationModels';

function buildGroups(): ProxyGroupTabState[] {
  return [
    createProxyGroupTabState(0, 'Group A', 'Selector', true),
    createProxyGroupTabState(1, 'Group B', 'Fallback', false)
  ];
}

function buildNodes(): ProxyNodeRowState[] {
  return [
    createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
      delayStatus: 'AVAILABLE',
      delayMs: 42,
      delayFastest: true
    }),
    createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, true, {
      delayStatus: 'WAITING'
    }),
    createProxyNodeRowState(2, 'Node C', 'Trojan', false, false, false, {
      delayStatus: 'TESTING'
    }),
    createProxyNodeRowState(3, 'Nested Group', 'Selector', true, false, false, {
      delayStatus: 'UNSUPPORTED'
    }),
    createProxyNodeRowState(4, 'Node D', 'Socks5', false, false, false, {
      delayStatus: 'FAILED'
    })
  ];
}

function buildTerminalNodes(): ProxyNodeRowState[] {
  return [
    createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
      delayStatus: 'AVAILABLE',
      delayMs: 8,
      delayFastest: true
    }),
    createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false, {
      delayStatus: 'TIMEOUT'
    }),
    createProxyNodeRowState(2, 'Node C', 'Trojan', false, false, true, {
      delayStatus: 'FAILED'
    }),
    createProxyNodeRowState(3, 'Node D', 'Http', false, false, false, {
      delayStatus: 'CANCELLED'
    }),
    createProxyNodeRowState(4, 'Nested Group', 'Selector', true, false, false, {
      delayStatus: 'UNSUPPORTED'
    })
  ];
}

function captureThrownMessage(callback: () => void): string {
  try {
    callback();
  } catch (error) {
    if (error instanceof Error) {
      return error.message;
    }
    return 'non-error';
  }
  return '';
}

function assertExactlyOneRuntimeSelected(state: ProxyViewState): void {
  let runtimeSelectedCount: number = 0;
  for (let index: number = 0; index < state.nodes.length; index += 1) {
    if (state.nodes[index].runtimeSelected) {
      runtimeSelectedCount += 1;
    }
  }
  expect(runtimeSelectedCount).assertEqual(1);
}

function buildCompletedDelayViewOptions(
  activation?: ProxyActivationStateOptions,
  selectionPending?: boolean
): ProxyViewStateOptions {
  return {
    selectionPending,
    activation,
    delayState: 'COMPLETED',
    totalDelayCount: 5,
    testableDelayCount: 4,
    completedDelayCount: 5,
    availableDelayCount: 1,
    timeoutDelayCount: 1,
    failedDelayCount: 1,
    cancelledDelayCount: 1,
    unsupportedDelayCount: 1,
    fastestDelayNodeIndex: 0
  };
}

export default function proxyPresentationModelsTestsuite(): void {
  describe('ProxyPresentationModelsTest', () => {
    it('createsDeeplyClonedReadyStateWithStableIndexOnlySemanticIdsAndRunningDelaySnapshot', 0, () => {
      const groups: ProxyGroupTabState[] = buildGroups();
      const nodes: ProxyNodeRowState[] = buildNodes();

      const state: ProxyViewState = createProxyViewState('READY', groups, nodes, {
        groupGeneration: 7,
        selectionPending: true,
        warning: 'SAVED_FOR_NEXT_START',
        delayState: 'RUNNING',
        totalDelayCount: 5,
        testableDelayCount: 4,
        completedDelayCount: 3,
        availableDelayCount: 1,
        timeoutDelayCount: 0,
        failedDelayCount: 1,
        cancelledDelayCount: 0,
        unsupportedDelayCount: 1,
        fastestDelayNodeIndex: 0
      });

      groups[0].name = 'Mutated Group';
      nodes[0].name = 'Mutated Node';
      nodes[0].delayMs = 512;
      nodes[3].delayStatus = 'FAILED';

      const clone: ProxyViewState = cloneProxyViewState(state);
      clone.groups[0].name = 'Clone Group';
      clone.nodes[0].runtimeSelected = false;
      clone.nodes[2].savedForNextStart = false;
      clone.nodes[0].delayMs = 99;
      clone.nodes[0].delayFastest = false;
      clone.nodes[1].delayStatus = 'TIMEOUT';

      expect(state.status).assertEqual('READY');
      expect(state.groupGeneration).assertEqual(7);
      expect(state.selectionPending).assertTrue();
      expect(state.warning).assertEqual('SAVED_FOR_NEXT_START');
      expect(state.delayState).assertEqual('RUNNING');
      expect(state.totalDelayCount).assertEqual(5);
      expect(state.testableDelayCount).assertEqual(4);
      expect(state.completedDelayCount).assertEqual(3);
      expect(state.availableDelayCount).assertEqual(1);
      expect(state.failedDelayCount).assertEqual(1);
      expect(state.unsupportedDelayCount).assertEqual(1);
      expect(state.fastestDelayNodeIndex).assertEqual(0);
      expect(state.groups.length).assertEqual(2);
      expect(state.groups[0].semanticId).assertEqual('proxies.group.0');
      expect(state.groups[1].semanticId).assertEqual('proxies.group.1');
      expect(state.groups[0].name).assertEqual('Group A');
      expect(state.groups[1].type).assertEqual('Fallback');
      expect(state.nodes.length).assertEqual(5);
      expect(state.nodes[0].semanticId).assertEqual('proxies.node.0');
      expect(state.nodes[1].semanticId).assertEqual('proxies.node.1');
      expect(state.nodes[4].semanticId).assertEqual('proxies.node.4');
      expect(state.nodes[0].name).assertEqual('Node A');
      expect(state.nodes[0].runtimeSelected).assertTrue();
      expect(state.nodes[0].delayStatus).assertEqual('AVAILABLE');
      expect(state.nodes[0].delayMs).assertEqual(42);
      expect(state.nodes[0].delayFastest).assertTrue();
      expect(state.nodes[1].savedForNextStart).assertTrue();
      expect(state.nodes[1].delayStatus).assertEqual('WAITING');
      expect(state.nodes[2].delayStatus).assertEqual('TESTING');
      expect(state.nodes[3].isGroup).assertTrue();
      expect(state.nodes[3].delayStatus).assertEqual('UNSUPPORTED');
      expect(state.nodes[4].delayStatus).assertEqual('FAILED');
      expect(state.nodes[4].delayFastest).assertFalse();
      expect(state.groups[0].name).assertEqual('Group A');
      expect(state.nodes[0].delayMs).assertEqual(42);
    });

    it('preservesBackwardCompatibleConstructorsAndIdleOrStartingDelayDefaults', 0, () => {
      const legacyRow: ProxyNodeRowState = createProxyNodeRowState(
        0,
        'Node AVAILABLE 99ms',
        'Direct',
        false,
        true,
        false
      );
      const idleState: ProxyViewState = createProxyViewState('IDLE', buildGroups(), [legacyRow], {
        warning: 'NONE'
      });
      const startingState: ProxyViewState = createProxyViewState('READY', buildGroups(), [
        createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false),
        createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false)
      ], {
        delayState: 'STARTING',
        totalDelayCount: 0,
        testableDelayCount: 0,
        completedDelayCount: 0,
        availableDelayCount: 0,
        timeoutDelayCount: 0,
        failedDelayCount: 0,
        cancelledDelayCount: 0,
        unsupportedDelayCount: 0
      });

      expect(legacyRow.semanticId).assertEqual('proxies.node.0');
      expect(legacyRow.delayStatus).assertEqual('NONE');
      expect(legacyRow.delayMs).assertEqual(undefined);
      expect(legacyRow.delayFastest).assertFalse();
      expect(idleState.delayState).assertEqual('IDLE');
      expect(idleState.totalDelayCount).assertEqual(0);
      expect(idleState.testableDelayCount).assertEqual(0);
      expect(idleState.completedDelayCount).assertEqual(0);
      expect(idleState.availableDelayCount).assertEqual(0);
      expect(idleState.timeoutDelayCount).assertEqual(0);
      expect(idleState.failedDelayCount).assertEqual(0);
      expect(idleState.cancelledDelayCount).assertEqual(0);
      expect(idleState.unsupportedDelayCount).assertEqual(0);
      expect(idleState.fastestDelayNodeIndex).assertEqual(undefined);
      expect(startingState.delayState).assertEqual('STARTING');
      expect(startingState.nodes[0].delayStatus).assertEqual('NONE');
      expect(startingState.nodes[1].delayStatus).assertEqual('NONE');
      expect(startingState.totalDelayCount).assertEqual(0);
      expect(startingState.completedDelayCount).assertEqual(0);
    });

    it('supportsTerminalDelaySnapshotsWithoutDisturbingSelectionOrSavedMarkers', 0, () => {
      const completedState: ProxyViewState = createProxyViewState('READY', buildGroups(), buildTerminalNodes(), {
        delayState: 'COMPLETED',
        totalDelayCount: 5,
        testableDelayCount: 4,
        completedDelayCount: 5,
        availableDelayCount: 1,
        timeoutDelayCount: 1,
        failedDelayCount: 1,
        cancelledDelayCount: 1,
        unsupportedDelayCount: 1,
        fastestDelayNodeIndex: 0
      });

      expect(completedState.delayState).assertEqual('COMPLETED');
      expect(completedState.nodes[0].runtimeSelected).assertTrue();
      expect(completedState.nodes[0].delayFastest).assertTrue();
      expect(completedState.nodes[1].delayStatus).assertEqual('TIMEOUT');
      expect(completedState.nodes[2].savedForNextStart).assertTrue();
      expect(completedState.nodes[2].delayStatus).assertEqual('FAILED');
      expect(completedState.nodes[3].delayStatus).assertEqual('CANCELLED');
      expect(completedState.nodes[4].isGroup).assertTrue();
      expect(completedState.nodes[4].delayStatus).assertEqual('UNSUPPORTED');
      expect(completedState.completedDelayCount).assertEqual(5);
      expect(completedState.unsupportedDelayCount).assertEqual(1);
      expect(completedState.fastestDelayNodeIndex).assertEqual(0);
    });

    it('supportsIdleEmptyAndErrorStatesWithoutLeakingNamesIntoIdsOrErrors', 0, () => {
      const emptyState: ProxyViewState = createProxyViewState('EMPTY', [], [], {
        warning: 'NONE'
      });
      const errorState: ProxyViewState = createProxyViewState('ERROR', buildGroups(), buildTerminalNodes(), {
        errorCode: 'PROXY_QUERY_FAILED',
        errorRetryable: true,
        warning: 'APPLIED_NOT_PERSISTED',
        delayState: 'FAILED',
        totalDelayCount: 5,
        testableDelayCount: 4,
        completedDelayCount: 5,
        availableDelayCount: 1,
        timeoutDelayCount: 1,
        failedDelayCount: 1,
        cancelledDelayCount: 1,
        unsupportedDelayCount: 1,
        fastestDelayNodeIndex: 0
      });

      const rejectedCode: ProxyRejectedErrorCode | undefined = errorState.errorCode;
      expect(emptyState.status).assertEqual('EMPTY');
      expect(emptyState.groups.length).assertEqual(0);
      expect(emptyState.nodes.length).assertEqual(0);
      expect(emptyState.warning).assertEqual('NONE');
      expect(emptyState.delayState).assertEqual('IDLE');
      expect(emptyState.errorRetryable).assertFalse();
      expect(rejectedCode).assertEqual('PROXY_QUERY_FAILED');
      expect(errorState.warning).assertEqual('APPLIED_NOT_PERSISTED');
      expect(errorState.delayState).assertEqual('FAILED');
      expect(errorState.errorRetryable).assertTrue();
      expect(errorState.groups[0].semanticId.includes('Group A')).assertFalse();
      expect(errorState.nodes[0].semanticId.includes('Node A')).assertFalse();
    });

    it('supportsIdleLiveAndFailedActivationStatesWithoutDisturbingExistingDelayOrSelectionMarkers', 0, () => {
      const idleState: ProxyViewState = createProxyViewState('READY', buildGroups(), buildTerminalNodes(), {
        delayState: 'COMPLETED',
        totalDelayCount: 5,
        testableDelayCount: 4,
        completedDelayCount: 5,
        availableDelayCount: 1,
        timeoutDelayCount: 1,
        failedDelayCount: 1,
        cancelledDelayCount: 1,
        unsupportedDelayCount: 1,
        fastestDelayNodeIndex: 0,
        activation: createProxyActivationStateOptions('IDLE')
      });

      const liveStages: ProxyActivationStage[] = [
        'SAVING_SELECTION',
        'STARTING_VPN',
        'SWITCHING_VPN',
        'CONFIRMING_SELECTION'
      ];
      const liveSnapshots: ProxyViewState[] = [];
      for (let index: number = 0; index < liveStages.length; index += 1) {
        liveSnapshots.push(createProxyViewState('READY', buildGroups(), buildTerminalNodes(), {
          delayState: 'COMPLETED',
          totalDelayCount: 5,
          testableDelayCount: 4,
          completedDelayCount: 5,
          availableDelayCount: 1,
          timeoutDelayCount: 1,
          failedDelayCount: 1,
          cancelledDelayCount: 1,
          unsupportedDelayCount: 1,
          fastestDelayNodeIndex: 0,
          activation: createProxyActivationStateOptions(liveStages[index], 2)
        }));
      }

      const failedState: ProxyViewState = createProxyViewState('READY', buildGroups(), buildTerminalNodes(), {
        delayState: 'COMPLETED',
        totalDelayCount: 5,
        testableDelayCount: 4,
        completedDelayCount: 5,
        availableDelayCount: 1,
        timeoutDelayCount: 1,
        failedDelayCount: 1,
        cancelledDelayCount: 1,
        unsupportedDelayCount: 1,
        fastestDelayNodeIndex: 0,
        activation: createProxyActivationStateOptions(
          'FAILED',
          2,
          'proxies_one_click_confirmation_timeout',
          true
        )
      });
      const failedClone: ProxyViewState = cloneProxyViewState(failedState);

      expect(idleState.selectionPending).assertFalse();
      expect(idleState.activationStage).assertEqual('IDLE');
      expect(idleState.activatingRowIndex).assertEqual(undefined);
      expect(idleState.activationErrorResourceId).assertEqual(undefined);
      expect(idleState.activationErrorRetryable).assertFalse();
      assertExactlyOneRuntimeSelected(idleState);

      for (let index: number = 0; index < liveSnapshots.length; index += 1) {
        const liveState: ProxyViewState = liveSnapshots[index];
        expect(liveState.selectionPending).assertTrue();
        expect(liveState.activationStage).assertEqual(liveStages[index]);
        expect(liveState.activatingRowIndex).assertEqual(2);
        expect(liveState.activationErrorResourceId).assertEqual(undefined);
        expect(liveState.activationErrorRetryable).assertFalse();
        expect(liveState.nodes[2].isGroup).assertFalse();
        expect(liveState.nodes[2].runtimeSelected).assertFalse();
        expect(liveState.nodes[2].savedForNextStart).assertTrue();
        expect(liveState.nodes[0].runtimeSelected).assertTrue();
        expect(liveState.nodes[0].delayFastest).assertTrue();
        expect(liveState.fastestDelayNodeIndex).assertEqual(0);
        assertExactlyOneRuntimeSelected(liveState);
      }

      expect(failedState.selectionPending).assertFalse();
      expect(failedState.activationStage).assertEqual('FAILED');
      expect(failedState.activatingRowIndex).assertEqual(2);
      expect(failedState.activationErrorResourceId).assertEqual('proxies_one_click_confirmation_timeout');
      expect(failedState.activationErrorRetryable).assertTrue();
      expect(failedState.errorCode).assertEqual(undefined);
      expect(failedState.errorRetryable).assertFalse();
      expect(failedState.nodes[0].runtimeSelected).assertTrue();
      expect(failedState.nodes[2].savedForNextStart).assertTrue();
      expect(failedState.nodes[2].runtimeSelected).assertFalse();
      expect(failedState.groups[0].semanticId).assertEqual('proxies.group.0');
      expect(failedState.nodes[2].semanticId).assertEqual('proxies.node.2');
      expect(failedState.nodes[2].semanticId.includes('Node C')).assertFalse();
      assertExactlyOneRuntimeSelected(failedState);

      failedClone.activationStage = 'IDLE';
      failedClone.activatingRowIndex = undefined;
      failedClone.activationErrorResourceId = undefined;
      failedClone.activationErrorRetryable = false;
      failedClone.nodes[0].runtimeSelected = false;
      expect(failedState.activationStage).assertEqual('FAILED');
      expect(failedState.activatingRowIndex).assertEqual(2);
      expect(failedState.activationErrorResourceId).assertEqual('proxies_one_click_confirmation_timeout');
      expect(failedState.activationErrorRetryable).assertTrue();
      expect(failedState.nodes[0].runtimeSelected).assertTrue();
    });

    it('rejectsInvalidActivationRowOrErrorShapesWithoutLeakingLabelsIntoActivationErrors', 0, () => {
      const secretResourceId = 'Node C endpoint should never escape';
      const liveWithoutRowMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(createProxyActivationStateOptions('STARTING_VPN'))
        );
      });
      const liveGroupRowMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(createProxyActivationStateOptions('SWITCHING_VPN', 4))
        );
      });
      const livePrematureRuntimeMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, false, false),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false),
          createProxyNodeRowState(2, 'Node C', 'Trojan', false, true, true)
        ], buildCompletedDelayViewOptions(createProxyActivationStateOptions('CONFIRMING_SELECTION', 2)));
      });
      const failedWithoutErrorMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(createProxyActivationStateOptions('FAILED', 2))
        );
      });
      const failedWithLeakyResourceMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(
            createProxyActivationStateOptions(
              'FAILED',
              2,
              secretResourceId as OneClickVpnErrorResourceId,
              true
            )
          )
        );
      });
      const idleWithErrorMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(
            createProxyActivationStateOptions(
              'IDLE',
              undefined,
              'proxies_one_click_confirmation_timeout',
              true
            )
          )
        );
      });
      const idleWithPendingMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(createProxyActivationStateOptions('IDLE'), true)
        );
      });
      const liveWithFalsePendingMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(createProxyActivationStateOptions('STARTING_VPN', 2), false)
        );
      });
      const failedWithPendingMessage: string = captureThrownMessage(() => {
        createProxyViewState(
          'READY',
          buildGroups(),
          buildTerminalNodes(),
          buildCompletedDelayViewOptions(
            createProxyActivationStateOptions(
              'FAILED',
              2,
              'proxies_one_click_confirmation_timeout',
              true
            ),
            true
          )
        );
      });

      expect(liveWithoutRowMessage.length > 0).assertTrue();
      expect(liveGroupRowMessage.length > 0).assertTrue();
      expect(livePrematureRuntimeMessage.length > 0).assertTrue();
      expect(failedWithoutErrorMessage.length > 0).assertTrue();
      expect(failedWithLeakyResourceMessage.length > 0).assertTrue();
      expect(idleWithErrorMessage.length > 0).assertTrue();
      expect(idleWithPendingMessage.length > 0).assertTrue();
      expect(liveWithFalsePendingMessage.length > 0).assertTrue();
      expect(failedWithPendingMessage.length > 0).assertTrue();
      expect(failedWithLeakyResourceMessage.includes(secretResourceId)).assertFalse();
    });

    it('rejectsMalformedIndexesGenerationDelayShapesAndRuntimeSelectionViolations', 0, () => {
      const secretLabel: string = 'Secret Node 312';
      const negativeGroupMessage: string = captureThrownMessage(() => {
        createProxyGroupTabState(-1, 'Group A', 'Selector', true);
      });
      const negativeNodeMessage: string = captureThrownMessage(() => {
        createProxyNodeRowState(-1, 'Node A', 'Direct', false, false, false);
      });
      const invalidGenerationMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), buildNodes(), {
          groupGeneration: -1
        });
      });
      const multipleRuntimeMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false),
          createProxyNodeRowState(1, 'Node B', 'Direct', false, true, false)
        ]);
      });
      const missingRuntimeMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, false, false)
        ], {
          groupGeneration: 1
        });
      });
      const availableWithoutDelayMessage: string = captureThrownMessage(() => {
        createProxyNodeRowState(0, secretLabel, 'Vmess', false, true, false, {
          delayStatus: 'AVAILABLE'
        });
      });
      const invalidDelayRangeMessage: string = captureThrownMessage(() => {
        createProxyNodeRowState(0, secretLabel, 'Vmess', false, true, false, {
          delayStatus: 'AVAILABLE',
          delayMs: 65536
        });
      });
      const nonAvailableDelayMessage: string = captureThrownMessage(() => {
        createProxyNodeRowState(0, secretLabel, 'Vmess', false, true, false, {
          delayStatus: 'WAITING',
          delayMs: 30
        });
      });
      const idleCountsMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false)
        ], {
          delayState: 'IDLE',
          totalDelayCount: 1
        });
      });
      const runningNoneMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false)
        ], {
          delayState: 'RUNNING',
          totalDelayCount: 1,
          testableDelayCount: 1
        });
      });
      const multipleFastestMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
            delayStatus: 'AVAILABLE',
            delayMs: 30,
            delayFastest: true
          }),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false, {
            delayStatus: 'AVAILABLE',
            delayMs: 40,
            delayFastest: true
          })
        ], {
          delayState: 'COMPLETED',
          totalDelayCount: 2,
          testableDelayCount: 2,
          completedDelayCount: 2,
          availableDelayCount: 2,
          fastestDelayNodeIndex: 0
        });
      });
      const mismatchedFastestIndexMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
            delayStatus: 'AVAILABLE',
            delayMs: 30
          }),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false, {
            delayStatus: 'FAILED'
          })
        ], {
          delayState: 'COMPLETED',
          totalDelayCount: 2,
          testableDelayCount: 2,
          completedDelayCount: 2,
          availableDelayCount: 1,
          failedDelayCount: 1,
          fastestDelayNodeIndex: 1
        });
      });
      const mismatchedFastestMarkerMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
            delayStatus: 'AVAILABLE',
            delayMs: 20,
            delayFastest: true
          }),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false, {
            delayStatus: 'AVAILABLE',
            delayMs: 10
          })
        ], {
          delayState: 'COMPLETED',
          totalDelayCount: 2,
          testableDelayCount: 2,
          completedDelayCount: 2,
          availableDelayCount: 2,
          fastestDelayNodeIndex: 1
        });
      });
      const outOfOrderGroupIndexMessage: string = captureThrownMessage(() => {
        const groups: ProxyGroupTabState[] = buildGroups();
        groups[0].index = 1;
        createProxyViewState('READY', groups, [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false)
        ]);
      });
      const duplicateNodeIndexMessage: string = captureThrownMessage(() => {
        const nodes: ProxyNodeRowState[] = [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false)
        ];
        nodes[1].index = 0;
        createProxyViewState('READY', buildGroups(), nodes);
      });
      const gapNodeIndexMessage: string = captureThrownMessage(() => {
        const nodes: ProxyNodeRowState[] = [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false),
          createProxyNodeRowState(1, 'Node B', 'Vmess', false, false, false)
        ];
        nodes[1].index = 2;
        createProxyViewState('READY', buildGroups(), nodes);
      });
      const terminalLiveStateMessage: string = captureThrownMessage(() => {
        createProxyViewState('READY', buildGroups(), [
          createProxyNodeRowState(0, 'Node A', 'Direct', false, true, false, {
            delayStatus: 'WAITING'
          })
        ], {
          delayState: 'FAILED',
          totalDelayCount: 1,
          testableDelayCount: 1
        });
      });

      expect(negativeGroupMessage.length > 0).assertTrue();
      expect(negativeNodeMessage.length > 0).assertTrue();
      expect(invalidGenerationMessage.length > 0).assertTrue();
      expect(multipleRuntimeMessage.length > 0).assertTrue();
      expect(missingRuntimeMessage.length > 0).assertTrue();
      expect(availableWithoutDelayMessage.length > 0).assertTrue();
      expect(invalidDelayRangeMessage.length > 0).assertTrue();
      expect(nonAvailableDelayMessage.length > 0).assertTrue();
      expect(idleCountsMessage.length > 0).assertTrue();
      expect(runningNoneMessage.length > 0).assertTrue();
      expect(multipleFastestMessage.length > 0).assertTrue();
      expect(mismatchedFastestIndexMessage.length > 0).assertTrue();
      expect(mismatchedFastestMarkerMessage.length > 0).assertTrue();
      expect(outOfOrderGroupIndexMessage.length > 0).assertTrue();
      expect(duplicateNodeIndexMessage.length > 0).assertTrue();
      expect(gapNodeIndexMessage.length > 0).assertTrue();
      expect(terminalLiveStateMessage.length > 0).assertTrue();
      expect(availableWithoutDelayMessage.includes(secretLabel)).assertFalse();
      expect(invalidDelayRangeMessage.includes(secretLabel)).assertFalse();
      expect(nonAvailableDelayMessage.includes(secretLabel)).assertFalse();
    });
  });
}
