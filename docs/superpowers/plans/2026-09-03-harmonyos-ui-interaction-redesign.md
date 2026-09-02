# HarmonyOS UI and Interaction Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the current ArkUI presentation hierarchy so connection, configuration, node, and diagnostics tasks are fast, polished, and reachable while preserving every existing business contract.

**Architecture:** Keep the existing `Index` composition, ViewModels, callbacks, and semantic proof IDs. Change only resource tokens/copy and presentation components, use page-specific scroll identities to prevent inherited offsets, and make `HomePage` own a first-viewport connection hero while existing status/traffic/mode components remain pure renderers.

**Tech Stack:** HarmonyOS 6 Stage model, ArkTS, ArkUI, resource tokens, Node structure tests, Hypium, Hvigor, HDC physical-device screenshots.

---

## Chunk 1: Visual contract and token foundation

### Task 1: Lock the redesign contract with failing structure tests

**Files:**
- Create: `harmony/tests/structure/ui-redesign-contract.test.mjs`
- Reference: `docs/superpowers/specs/2026-09-03-harmonyos-ui-interaction-redesign-design.md`

- [ ] **Step 1: Add a structure test for the visual system**

  Assert that `color.json` exposes `color_surface_hero`, `color_surface_hero_subtle`, `color_text_on_hero`, `color_text_on_hero_secondary`, `color_signal_active`, and `color_signal_idle`; `float.json` exposes `radius_hero`, `radius_action`, `type_display`, and `type_metric`; and the production source continues using semantic resources rather than hard-coded colors.

- [ ] **Step 2: Add a structure test for interaction hierarchy**

  Assert that Home uses a `buildConnectionHero()` member builder, keeps `home.vpn.action` inside `HomePage`, renders that hero before `buildProfileCard`, and retains the required `RuntimeStatusCard → conditional HomeTrafficCard → RuntimeModeCard` order. Assert `home.scroll`, `profiles.scroll`, `detail.scroll`, and `logs.list` identities are unique. Pin the existing `<420vp` compact branch and the Home/Profile/Detail/Logs source order that implements the approved focus order, so the contract does not rely on screenshots alone.

- [ ] **Step 3: Add a structure test for preserved automation/security contracts**

  Assert that profile, detail, proxy, logs, and import semantic IDs remain present, and that the import sheet retains `import.file`, `import.qr`, `import.url`, `import.submit` plus the existing ViewModel calls. Assert no local/system proxy UI is reintroduced.

- [ ] **Step 4: Run the new test and verify RED**

  Run:

  ```bash
  node --test harmony/tests/structure/ui-redesign-contract.test.mjs
  ```

  Expected: FAIL because the new tokens, hero builder, and page-specific identities do not exist.

### Task 2: Introduce the Signal Paper design tokens and user copy

**Files:**
- Modify: `harmony/entry/src/main/resources/base/element/color.json`
- Modify: `harmony/entry/src/main/resources/dark/element/color.json`
- Modify: `harmony/entry/src/main/resources/base/element/float.json`
- Modify: `harmony/entry/src/main/resources/base/element/string.json`
- Modify: `harmony/tests/structure/phase3-ui-contract.test.mjs`
- Modify: `harmony/tests/structure/phase4-vpn-contract.test.mjs`

- [ ] **Step 1: Add palette and geometry tokens**

  Keep every existing resource key in both base and dark palettes, then add the hero/signal tokens required by Task 1 to both files. Use a warm `#F5F3EE` base page, white content surface, near-black/navy hero, cobalt action, mint healthy signal, amber recovery, coral error, restrained separators, 24vp hero radius, 14vp action radius, 32fp display type, and 24fp metric type. Give every new semantic token an intentional dark-mode value so `$r('app.color.*')` resolution cannot drift by resource qualifier.

- [ ] **Step 2: Replace engineering-facing Home copy**

  Keep resource names but change the Home product title/subtitle, status labels, VPN start/stop labels, notification/recovery labels, selected-node labels, and boundary note into concise Chinese user language. Change the profile trailing glyph to a word label so no text symbol acts as an icon.

- [ ] **Step 3: Update only copy assertions that intentionally changed**

  Update the exact Home VPN string values in `phase4-vpn-contract.test.mjs` and the exact `home_vpn_boundary_note` assertion in `phase3-ui-contract.test.mjs`. Do not relax forbidden system-proxy, enterprise, always-on, or lockdown copy assertions.

- [ ] **Step 4: Run the resource and VPN contract tests**

  Run:

  ```bash
  node --test \
    harmony/tests/structure/ui-redesign-contract.test.mjs \
    harmony/tests/structure/phase3-ui-contract.test.mjs \
    harmony/tests/structure/phase4-vpn-contract.test.mjs \
    harmony/tests/structure/local-proxy-product-removal-contract.test.mjs
  ```

  Expected: resource assertions pass; hierarchy assertions remain RED until Chunk 2.

- [ ] **Step 5: Commit the token/test slice**

  Stage only the base/dark resource files, the two existing contract tests, and the new redesign contract. Use a Lore commit whose intent is to establish a deliberate, testable visual system.

## Chunk 2: Primary and secondary screen redesign

### Task 3: Put connection control in the first Home viewport

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/HomePage.ets`
- Modify: `harmony/entry/src/main/ets/components/RuntimeStatusCard.ets`
- Modify: `harmony/entry/src/main/ets/components/HomeTrafficCard.ets`
- Modify: `harmony/entry/src/main/ets/components/RuntimeModeCard.ets`
- Test: `harmony/tests/structure/ui-redesign-contract.test.mjs`

- [ ] **Step 1: Extend the RED test with the complete Home state matrix**

  Require `buildConnectionHero`, `resolveHeroStatusLabel`, `resolveHeroStatusColor`, and `resolveActionBackground/Foreground` to cover no-profile plus STOPPED, AWAITING_CONSENT, STARTING, RUNNING, RECOVERING, STOPPING, and ERROR without introducing lifecycle state. Require the existing `SafeErrorCard` to render immediately after the hero when the VPN state exposes an error, so `ERROR` feedback stays adjacent to the failed primary action.

- [ ] **Step 2: Add the Home connection hero**

  In `HomePage`, render the Chinese product header, then a near-black hero with textual status, signal mark, current profile/node context, and the existing `home.vpn.action` button. Keep the action callback and state-derived enabled/background/foreground behavior unchanged. Render its existing `SafeErrorCard` directly below the hero when present, then render `buildProfileCard` as a compact navigation row.

- [ ] **Step 3: Compress secondary Home surfaces**

  Redesign `RuntimeStatusCard` as a dense connection-detail surface while retaining all existing facts, selected group/node member builder, divider, safe placeholders, and boundary note. Redesign traffic as two high-contrast metrics and mode as one compact segmented row. Keep status/error text explicit.

- [ ] **Step 4: Add `home.scroll` and first-viewport spacing**

  Give the Home scroll a unique identity, keep it top-aligned, and ensure header + hero + profile row fit in the compact phone viewport. Keep logs reachable and the existing status/traffic/mode source order for proof contracts.

- [ ] **Step 5: Run Home contracts**

  Run:

  ```bash
  node --test \
    harmony/tests/structure/ui-redesign-contract.test.mjs \
    harmony/tests/structure/phase3-ui-contract.test.mjs \
    harmony/tests/structure/home-traffic-contract.test.mjs \
    harmony/tests/structure/phase4-vpn-contract.test.mjs \
    harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs
  ```

  Expected: PASS.

### Task 4: Redesign Profiles and Profile Detail around daily actions

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/ProfilesPage.ets`
- Modify: `harmony/entry/src/main/ets/components/ProfileListItem.ets`
- Modify: `harmony/entry/src/main/ets/pages/ProfileDetailPage.ets`
- Test: `harmony/tests/structure/ui-redesign-contract.test.mjs`

- [ ] **Step 1: Add RED assertions for stable list/detail navigation**

  Require `profiles.scroll` and `detail.scroll`, fixed compact headers, unchanged Back/Add/Refresh/row/detail semantic IDs, and the order identity → enable when available → proxy management → edit/refresh → auto-update → delete.

- [ ] **Step 2: Make Profiles a grouped list rather than stacked cards**

  Keep Back/title/Add in one row. Make Refresh All a compact utility strip with inline progress/summary. Render each profile as a dense row with monogram, name, explicit current/health labels, source, update time, and a restrained separator. Preserve the row callback and dynamic semantic ID.

- [ ] **Step 3: Reorder and compact Profile Detail**

  Left-align identity metadata, use shorter labels and restrained surfaces, surface Enable and node management before schedule controls, group edit/refresh as secondary actions, and visually isolate Delete at the bottom. Preserve every existing conditional and ViewModel call.

- [ ] **Step 4: Run profile contracts**

  Run:

  ```bash
  node --test \
    harmony/tests/structure/ui-redesign-contract.test.mjs \
    harmony/tests/structure/phase3-ui-contract.test.mjs \
    harmony/tests/structure/profile-edit-refresh-contract.test.mjs \
    harmony/tests/structure/subscription-refresh-contract.test.mjs \
    harmony/tests/structure/plan-d-proxy-ui-contract.test.mjs
  ```

  Expected: PASS.

### Task 5: Redesign proxy, logs, import, and error surfaces

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/ProxiesPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/LogsPage.ets`
- Modify: `harmony/entry/src/main/ets/pages/ImportProfileSheet.ets`
- Modify: `harmony/entry/src/main/ets/components/SafeErrorCard.ets`
- Test: `harmony/tests/structure/ui-redesign-contract.test.mjs`

- [ ] **Step 1: Extend RED assertions for dense secondary surfaces**

  Require the logs list identity; preserve `logs.back`, its `onBack` callback, `logs.search`, refresh/export/clear callbacks, and copy-on-tap behavior; preserve proxy delay/selection IDs, QR/import IDs, and safe-error copy behavior. Forbid one rounded card per log entry and one bordered card per proxy node.

- [ ] **Step 2: Make proxy groups and nodes scan quickly**

  Keep group chips horizontal and all current selection/delay behavior. Reduce visual nesting, use one grouped node surface with separators, and keep selected/fastest/delay/saved states readable in text.

- [ ] **Step 3: Make Logs a compact technical list**

  Keep `logs.back`/`onBack`, `logs.search`, level filters, refresh/export/clear, copy-on-tap, and redaction unchanged. Use a compact control rail and continuous list rows with restrained separators instead of individual outlined cards. Add `logs.list`.

- [ ] **Step 4: Recompose the medium import sheet**

  Use an internal scroll. Keep name + URL + primary submit together, then place File and QR as secondary actions. Preserve busy gating, QR exclusivity, plain-HTTP confirmation routing in `Index`, all four semantic IDs, and progress/error feedback.

- [ ] **Step 5: Restyle safe errors without widening data**

  Use a coral-tinted surface and strong code/message hierarchy. Preserve copy behavior and the existing bounded `SafeErrorState`; do not add raw exceptions or telemetry.

- [ ] **Step 6: Run secondary UI contracts**

  Run:

  ```bash
  node --test \
    harmony/tests/structure/ui-redesign-contract.test.mjs \
    harmony/tests/structure/phase3-ui-contract.test.mjs \
    harmony/tests/structure/proxy-delay-contract.test.mjs \
    harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs \
    harmony/tests/structure/profile-transfer-contract.test.mjs \
    harmony/tests/structure/local-proxy-product-removal-contract.test.mjs
  ```

  Expected: PASS.

- [ ] **Step 7: Commit the screen redesign slice**

  Run `git diff --check`, stage only UI source/tests/resources, and create a Lore commit explaining the hierarchy and preserved behavior constraints.

## Chunk 3: Compile, device iteration, and release delivery

### Task 6: Compile and repair presentation regressions

**Files:**
- Modify only files already in the UI redesign scope when a compile/test issue is found.

- [ ] **Step 1: Run affected Entry tests**

  Run:

  ```bash
  cd harmony
  ./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
  ```

  Expected: `BUILD SUCCESSFUL` and no Hypium `Error in` output.

- [ ] **Step 2: Run targeted and full structure suites**

  Run the targeted commands from Chunks 1–2, then:

  ```bash
  node --test harmony/tests/structure/*.test.mjs
  ```

  Expected: the redesign introduces zero new failures. Existing unrelated baseline failures must be reported separately and must not be hidden by changing their tests.

- [ ] **Step 3: Build a signed debug HAP**

  Run the exact ignored secure debug lane and inspector:

  ```bash
  CMFA_GO_MOD_CACHE="$(go env GOMODCACHE)"
  GOMODCACHE="$CMFA_GO_MOD_CACHE" node .omx/task16-build-signed-production.mjs
  node harmony/tests/bin/inspect-hap.mjs \
    --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
    --manifest harmony/artifacts/phase1-native-provenance.json \
    --build-kind production
  ```

  Require both commands to exit zero, provenance `result=pass`, `stubDetected=false`, bundle `com.github.kr328.clash.harmony`, debug build metadata, verified signature, real `libcmfa_mihomo.so`/`libentry.so`, and no self-test or Traffic Probe entries. Confirm `harmony/build-profile.json5` is restored to its unsigned baseline afterward.

### Task 7: Iterate on the physical-phone result

**Files:**
- Modify only UI scope files after each visual verdict.
- Evidence: ignored `harmony/artifacts/ui-redesign-device/`

- [ ] **Step 1: Install and launch the debug HAP**

  Use the integrated DevEco HDC, install with replace, launch `EntryAbility`, and leave the phone on the Home screen.

- [ ] **Step 2: Capture the required states**

  Resolve the one physical target with:

  ```bash
  HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
  "$HDC" list targets
  ```

  For each state, dump the semantic layout with `"$HDC" -t <target> shell uitest dumpLayout -i -p /data/local/tmp/cmfa-ui-<name>.json`, receive it into `harmony/artifacts/ui-redesign-device/<NN>-<name>.json`, capture with `"$HDC" -t <target> shell snapshot_display -f /data/local/tmp/cmfa-ui-<name>.jpeg`, and receive it as the matching `<NN>-<name>.jpeg`. Use these names: `01-home-stopped`, `02-home-running`, `03-profiles`, `04-detail`, `05-nodes`, `06-logs`, and `07-import`. Inspect every JPEG before accepting it. Reject loading, locked, clipped, or wrong-state captures.

- [ ] **Step 3: Run visual comparison and fix loops**

  Compare each accepted after screenshot with the matching pre-redesign audit image in `harmony/artifacts/ui-audit-2026-09-03/` at the same 1216 × 2688 viewport: Home against `01-home.jpeg`, Profiles against `02-profiles.jpeg`, Detail/Nodes against `03-detail.jpeg`/`04-proxy.jpeg` when available, and Logs against `05-logs.jpeg`. Check first-viewport action reachability, hierarchy, margins, typography, clipping, status text, minimum targets, safe areas, and consistent palette. Patch visible defects and repeat compile/install/capture until no high-impact issue remains.

- [ ] **Step 4: Exercise critical interaction paths**

  On the phone, verify Home → Profiles → Detail → node manager; select a node and confirm one-click VPN; run all-node delay test; switch Rule/Global/Direct; open Logs; open and close import sheet; stop VPN. Confirm no action depends on tapping inside the bottom system gesture area. In the unexpanded medium import sheet, verify header, name, URL, and Submit are reachable through its one internal scroll, followed by File and QR in deterministic order.

- [ ] **Step 5: Verify large text and accessibility order**

  Record the current system text-size setting, use semantic UI automation to select the device’s built-in large-text preset in Settings, relaunch the app, and repeat Home/Profile/Detail/Logs captures. Verify the VPN action, state label, selected node, configuration title, Back/Add, and destructive action neither overlap nor clip; verify semantic layout order matches the focus order in the approved spec. Restore the exact original text-size setting and relaunch before release testing.

### Task 8: Build and install the final Release HAP

**Files:**
- Evidence only: ignored release provenance and phone screenshots.

- [ ] **Step 1: Build signed Release from the verified source**

  Run:

  ```bash
  node .omx/task-release-build-signed.mjs
  node --input-type=module -e "import { defaultVerifySignature } from './harmony/tests/bin/inspect-phase4-packages.mjs'; const result = await defaultVerifySignature({ hapPath: './harmony/entry/build/default/outputs/default/entry-default-signed.hap' }); if (!result) process.exit(2); console.log(JSON.stringify(result));"
  node --input-type=module -e "import fs from 'node:fs'; import crypto from 'node:crypto'; const p=JSON.parse(fs.readFileSync('harmony/artifacts/release-build-provenance.json','utf8')); const b=fs.readFileSync(p.hap.path); const sha=crypto.createHash('sha256').update(b).digest('hex'); if(p.result!=='pass'||p.buildMode!=='release'||!p.releaseMetadata||p.hap.sha256!==sha) process.exit(2); console.log(JSON.stringify({result:p.result,buildMode:p.buildMode,releaseMetadata:p.releaseMetadata,sha256:sha,sizeBytes:b.length}));"
  unzip -Z1 harmony/entry/build/default/outputs/default/entry-default-signed.hap | rg 'libs/arm64-v8a/(libcmfa_mihomo|libentry)\\.so$'
  ```

  Also fail if `unzip -Z1` finds `ohosTest`, Traffic Probe, or self-test entries. Require release metadata, `debug=false`, verified signature, real `libcmfa_mihomo.so`/`libentry.so`, and restored unsigned `harmony/build-profile.json5`.

- [ ] **Step 2: Install and smoke-test Release on the phone**

  Replace-install, launch, repeat Home/profile/node/logs navigation, start VPN, issue a fresh HTTPS browser request, verify `vpn-tun` counters increase, then return Clash Meta to foreground.

- [ ] **Step 3: Capture final true-device screenshots**

  Repeat the exact Task 7 Step 2 HDC dump/capture commands into `harmony/artifacts/ui-redesign-device/release/` using the same numbered names. Save accepted final Home stopped/running, Profiles, Detail/node, Logs, and import screenshots. These are the only visual deliverables shown to the user.

- [ ] **Step 4: Final verification and commit**

  Run `git diff --check`, confirm no generated HAP/evidence/signing files are staged, commit any final UI fixes with Lore trailers, and leave the branch unpushed unless explicitly requested.
