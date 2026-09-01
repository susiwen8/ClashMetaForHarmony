# HarmonyOS Profiles Back Navigation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为管理配置页面增加一个可见、可测试的返回首页按钮。

**Architecture:** `ProfilesPage` 只暴露 `onBack` UI callback；生产路由仍由 `Index` 拥有，并在 callback 中切换到 `HOME`。复用既有 `common_back` 资源和页面 token，不引入导航栈或 ViewModel 变更。

**Tech Stack:** ArkTS, ArkUI, Node.js structure tests, Hypium/UI Test, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不改变配置、导入 Sheet、详情页或系统返回行为；目标文件已有未提交改动，只允许最小 hunk；不 commit、不 push。

---

## Chunk 1: Back Navigation

### Task 1: Add and verify the ProfilesPage back button

**Files:**
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfilesPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: Preserve existing dirty hunks**

Inspect `git status --short`, scoped diffs, and current contents for all four files. Use `apply_patch` only; do not format or reorder unrelated code.

- [ ] **Step 2: Write all navigation assertions before production code**

In `phase3-ui-contract.test.mjs`, require:

```text
ProfilesPage declares onBack
Button(common_back).id('profiles.back') calls this.onBack()
the title consumes remaining width with layoutWeight(1), Start alignment,
maxLines(1), and TextOverflow.Ellipsis
the header Row uses `$r('app.float.space_md')`
both back and add buttons retain touch_target_min
Index ProfilesPage wiring maps onBack to this.route = 'HOME'
```

In the existing `Phase3UiFlow` test, preserve both current `pressBack()` calls and all import/HTTP assertions. Append the `profiles.back` lookup, ID assertion, click, and `home.profile.manage` wait at the end of the existing flow. Write this before changing production code; on the current installed build that lookup has no match.

- [ ] **Step 3: Run RED**

From the worktree root:

```sh
node --test harmony/tests/structure/phase3-ui-contract.test.mjs
```

Expected: FAIL because `ProfilesPage` has no `onBack` or `profiles.back`.

- [ ] **Step 4: Implement the minimal UI and routing change**

In `ProfilesPage.ets`:

- add `onBack: () => void`;
- prepend a `Button($r('app.string.common_back'))` with ID `profiles.back`;
- use the existing minimum touch target and semantic colors;
- call only `this.onBack()`;
- change the header to `Row({ space: $r('app.float.space_md') })`;
- replace the header `Blank()` with a weighted, left-aligned, single-line title using `.textOverflow({ overflow: TextOverflow.Ellipsis })`, so Back/Title/Add fit on 360vp.

In `Index.ets`, pass:

```ts
onBack: () => {
  this.route = 'HOME';
}
```

- [ ] **Step 5: Run GREEN structure tests**

Run the same Node test and require exit 0.

- [ ] **Step 6: Run ArkTS/UI compilation and module tests**

From `harmony/`:

```sh
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
```

Expected: BUILD SUCCESSFUL and no Hypium Failure/Error.

- [ ] **Step 7: Build and install the signed HAP**

From the worktree root:

```sh
CMFA_GO_MOD_CACHE="$(go env GOMODCACHE)" GOMODCACHE="$CMFA_GO_MOD_CACHE" node .omx/task16-build-signed-production.mjs
```

Require `profilePrepared: true`, `buildExit: 0`, and `unsignedBaselineRestored: true`.

Use the integrated HDC:

```sh
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc list targets
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
```

If no authorized target is present, report physical-device verification as the only external blocker; do not change code or signing configuration to work around it.

- [ ] **Step 8: Verify on the physical device**

Launch the app, open management configurations, and confirm `profiles.back` is visible, enabled, and clickable. Click it and confirm `home.profile.manage` is visible again. Clean temporary layout files without recording profile names.

- [ ] **Step 9: Final reviews**

Run spec-compliance review, then code-quality review. Fix all Critical/Important issues and rerun affected verification. Do not commit or push.
