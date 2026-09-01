# HarmonyOS Profile Refresh Feedback Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让配置详情页的重新获取操作立即显示处理中状态，并在成功后显示明确完成反馈。

**Architecture:** 复用 `ProfileDetailViewModel` 已有 `SUBMITTING/COMPLETED` 状态，不改下载或业务逻辑。`Index` 将两个状态投影成 primitive booleans，通过 `@Link` 传给 `ProfileDetailPage`；页面成员 builder 渲染反馈并统一锁住 mutation 控件。

**Tech Stack:** ArkTS, ArkUI, Node.js structure tests, Hypium, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不记录配置名/订阅地址；不新增 operation kind 或 timer；目标文件已有未提交改动，仅最小 hunk；不 commit、不 push。

---

## Chunk 1: Detail Operation Feedback

### Task 1: Project and render profile mutation feedback

**Files:**
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`

- [ ] **Step 1: Preserve current work**

Inspect status, scoped diffs, and current source for all four files. Use `apply_patch` only; do not reformat or revert unrelated changes.

- [ ] **Step 2: Write the failing UI structure contract**

Before production edits, require:

- resources `detail_operation_processing = "处理中…"` and `detail_operation_completed = "操作已完成"`;
- semantic IDs `detail.operation.pending` and `detail.operation.completed`;
- `Index` owns primitive boolean `@State` values `detailCommandPending` and `detailCommandCompleted`;
- every detail subscription publish, initial `current()`, and detail teardown updates/resets both values;
- `ProfileDetailPage` receives both as `@Link` and renders feedback through a zero-argument member builder;
- pending/completed are mutually exclusive conditional surfaces;
- enable, refresh, replacement `TextInput`, replace button, and delete button all use `.enabled(!this.commandPending)`;
- back remains enabled and existing SafeErrorCard/HTTP/delete alert wiring stays present.

- [ ] **Step 3: Run RED**

From the worktree root:

```sh
node --test harmony/tests/structure/phase3-ui-contract.test.mjs
```

Expected: FAIL on missing operation resources/primitive projection/semantic IDs.

- [ ] **Step 4: Implement primitive projection**

In `Index.ets`:

- initialize both booleans to false;
- after every `detailState = state`, set pending from `state.status === 'SUBMITTING'` and completed from `state.status === 'COMPLETED'`;
- seed both after `profileDetailViewModel.current()`;
- reset both in `disposeDetailViewModel()`;
- pass `$detailCommandPending` and `$detailCommandCompleted` to `ProfileDetailPage`.

- [ ] **Step 5: Implement page feedback**

In `ProfileDetailPage.ets`:

- add both boolean `@Link` properties;
- call a private zero-argument member builder near the existing source/error region;
- pending: render `detail_operation_processing`, ID `detail.operation.pending`, warning color;
- completed: render `detail_operation_completed`, ID `detail.operation.completed`, success color;
- add `.enabled(!this.commandPending)` to all mutation controls, including the replacement input;
- keep Back enabled and do not change command callbacks.

Add only the two new strings to `string.json`.

- [ ] **Step 6: Run GREEN and module verification**

```sh
node --test harmony/tests/structure/phase3-ui-contract.test.mjs
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

Require structure exit 0, entry test result with zero Failure/Error, and successful ohosTest ArkTS compilation.

- [ ] **Step 7: Build, install, and verify the original symptom**

From the worktree root, run:

```sh
CMFA_GO_MOD_CACHE="$(go env GOMODCACHE)" GOMODCACHE="$CMFA_GO_MOD_CACHE" node .omx/task16-build-signed-production.mjs
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
```

Require the build JSON to contain `profilePrepared: true`, `buildExit: 0`, and `unsignedBaselineRestored: true`; require exactly one authorized target and successful install/launch. Open the existing profile detail and click `detail.refresh`.

Pass conditions:

- observe `detail.operation.pending` or, for a fast request, `detail.operation.completed`;
- final `detail.operation.completed` is visible;
- `detail.refresh` is disabled while pending when the pending state is observable;
- dump one layout before and one after refresh into temporary host files; in one Node process extract the text immediately following the fixed label “最近更新”, compare the two strings in memory, and print only `{ "updatedAtChanged": true }`—never either raw value or its hash;
- no configuration name, source URL, or token is printed/persisted.

Delete both host layout files and both remote layout files after the boolean assertion.

- [ ] **Step 8: Final reviews**

Run spec-compliance review followed by code-quality/privacy review. Fix every Critical/Important issue and rerun affected verification. Do not commit or push.
