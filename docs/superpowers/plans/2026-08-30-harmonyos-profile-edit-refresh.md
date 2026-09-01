# HarmonyOS Profile Edit and Refresh Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除首页无用提示卡，并让配置详情可安全修改名称和订阅 URL，URL 保存后自动刷新节点。

**Architecture:** shared use case 原子保存名称和可选 URL，ProfileApplication 根据 `sourceChanged` 串联现有 refresh。ProfileDetailViewModel 管理临时 draft/校验/HTTP 确认，详情页渲染编辑表单；Index 在成功后刷新已展开的代理节点区。

**Tech Stack:** ArkTS, ArkUI, HUKS-backed secret store, Hypium, Node.js structure tests, Hvigor, HDC

**Constraints:** 不新增依赖；不修改 Android；不回显或记录完整 URL；保留工作树既有改动；仅用 `apply_patch` 编辑；不 commit、不 push。

---

## Chunk 1: Contracts and Domain Update

### Task 1: Write failing domain and UI contracts

**Files:**
- Modify: `harmony/shared/src/test/ProfileManagement.test.ets`
- Modify: `harmony/entry/src/test/ProfileDetailViewModel.test.ets`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Create: `harmony/tests/structure/profile-edit-refresh-contract.test.mjs`

- [ ] Assert atomic name/URL save, secret rollback and best-effort old-secret cleanup, `sourceChanged`, name-only no-download, update-before-refresh, explicit refresh outcomes, HTTP consent propagation, running-VPN URL rejection, UI IDs, removal of `home_info_*`, and expanded-node reload only on full success.
- [ ] Run RED and verify failures are caused by missing update/edit behavior.

### Task 2: Implement atomic metadata update

**Files:**
- Modify: `harmony/shared/src/main/ets/profile/ManageProfileUseCases.ets`
- Modify: `harmony/shared/src/main/ets/profile/ProfileApplication.ets`
- Modify: `harmony/shared/src/main/ets/profile/LocalRuntimeCoordinator.ets`
- Modify: `harmony/entry/src/test/fakes/PresentationFakes.ets`

- [ ] Add `ManageUpdateResult` and `updateProfile(profileId, name, sourceUrl?)`.
- [ ] Reuse mutation kind `REPLACE` for metadata edits; do not add a second concurrency mechanism.
- [ ] Encrypt new URL before repository save, rollback new secret on failure, delete old secret after success.
- [ ] Application facade drains delay work, calls update, refreshes snapshot, and invokes existing remote refresh only when `sourceChanged`.
- [ ] Add application-level `UpdateProfileResult` with `UPDATED`, `UPDATED_REFRESH_FAILED`, and `FAILED`; classify `UPDATE_FAILED_USING_VALID/lastError` as partial failure.
- [ ] Pass `allowPlainHttp` ViewModel → application → refresh; reject unconfirmed HTTP before metadata save.
- [ ] Allow name-only edits while VPN runs, but reject URL edits unless system VPN is `STOPPED`.
- [ ] Keep `replaceSubscriptionUrl` as a compatibility wrapper for existing callers/tests; the production detail UI moves to `updateProfile` and removes the standalone replacement form.
- [ ] Run shared/domain tests GREEN.

## Chunk 2: Detail Edit UI

### Task 3: Add ViewModel edit flow

**Files:**
- Modify: `harmony/entry/src/main/ets/presentation/PresentationModels.ets`
- Modify: `harmony/entry/src/main/ets/presentation/ProfileDetailViewModel.ets`
- Modify: `harmony/entry/src/test/ProfileDetailViewModel.test.ets`

- [ ] Add editing/issues to detail state while keeping drafts private.
- [ ] Seed name, keep URL blank, validate name and optional URL, require URL during source repair.
- [ ] Reuse CONFIRMING_HTTP for edit and refresh with explicit pending-action routing.
- [ ] Keep draft after HTTP cancel or metadata `FAILED`; full `UPDATED` clears and exits with `COMPLETED`.
- [ ] For `UPDATED_REFRESH_FAILED`, clear drafts and exit edit because metadata is already saved, then publish `ERROR`; do not emit `COMPLETED` and do not reload the proxy panel. Retry uses the existing refresh action.

### Task 4: Render edit controls and remove the home card

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/Index.ets`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/entry/src/ohosTest/ets/test/Phase3UiFlow.test.ets`

- [ ] Delete the complete home info panel and `home_info_title/body/indicator` resources.
- [ ] Add resource-backed edit/name/URL/helper/error/cancel/save controls with semantic IDs.
- [ ] Route HTTP confirmation through the pending edit action.
- [ ] Detect detail `SUBMITTING → COMPLETED`; if proxy section is expanded, reload it with the exact detail profile id.

## Chunk 3: Verification and Delivery

### Task 5: Verify, build, install and exercise

- [ ] Run shared and Entry unit tests, then relevant contracts and the repository-wide `node --test harmony/tests/structure/*.test.mjs` gate. Record the known API 23 lock vs API 24 SDK failures separately rather than hiding them.
- [ ] Compile ohosTest and run the Phase 3 simulator proof lane when the retained simulator/runtime and signed artifacts satisfy its gate; if the existing SDK-lock mismatch blocks it, retain the exact incomplete reason.
- [ ] Build signed HAP with the preserved signing profile and restore unsigned baseline.
- [ ] Cover-install on the connected device and run the signed-HAP device proof lane applicable to the production bundle.
- [ ] Verify home info panel absent; edit controls present; cancel works; save the existing name unchanged for a non-destructive persistence proof; never print the real name or URL during automation.
- [ ] Verify URL-triggered refresh through unit/integration tests without exposing credentials.
- [ ] Scan generated proof artifacts and build/test logs for URL/token/private profile name/node name leakage. Persist and report only booleans, counts, semantic IDs, fixed error codes and package hashes.
- [ ] Run final code/privacy review. Record the existing API 23 lock vs API 24 SDK environment risk separately.
