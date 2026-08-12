# HarmonyOS Phase 0–3 verification and handoff

## Scope and acceptance boundary

This document extends the HarmonyOS 6.x rewrite evidence through Phase 3:

- Phase 0 locks DevEco/HarmonyOS tooling and makes an empty HAP build falsifiable.
- Phase 1 packages the real AArch64 mihomo core behind a C ABI and an ArkTS/N-API bridge.
- Phase 2 proves the host-side and package-side traffic/runtime contracts needed for the physical-phone lane.
- Phase 3 adds the profile import/runtime UI surface and its provisional Simulator gate.

Android changes remain out of scope. HarmonyOS VPN/TUN, system proxy takeover,
or any system-wide packet capture remain out of scope and are not implemented.

Evidence still splits into two classes:

1. Host/cross-build evidence can prove source structure, ABI contracts,
   packaged bytes, N-API ownership, AArch64 ELF shape, provenance, and the
   presence of the production/profile-runtime codepaths.
2. Only signed artifacts running on a real HarmonyOS 6, API 20+, AArch64 phone
   can prove retail install, native load on device, real listener traffic,
   profile import/runtime behavior under HarmonyOS app lifecycle, and
   start/stop behavior outside host-only or packaged-byte inspection.

The second class is still unavailable here, so Phase 0-3 remains `incomplete`.
Simulator evidence is provisional only and never upgrades the device gates to
`pass`.

## Pinned source and toolchain

- Toolchain lock: `harmony/toolchain.lock.json`
- Upstream lock: `harmony/core/go/upstream.lock.json`
- API surface lock: `harmony/core/go/upstream.api-lock.json`
- mihomo: `v1.19.29`
- mihomo commit: `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`
- ABI version: `cmfa-harmony-v1`
- target: HarmonyOS API 23, compatible API 20, AArch64
- checked permission surface: `ohos.permission.INTERNET` only

## Signing and environment isolation

The checked-in `harmony/build-profile.json5` intentionally carries no signing
configuration. Developer certificates, keystores, passwords, local DevEco
profiles, device identities, generated signed HAPs, pulled device evidence, and
test secrets must remain local-only and untracked.

The current machine has no usable Harmony signing profile and no physical phone.
That is why signing, retail installation, and device-executed Phase 2/3 proof
lanes remain `incomplete`.

## Host and cross-build verification

The following fresh commands were run from this worktree on Wednesday,
August 12, 2026, China Standard Time:

```bash
node --test harmony/tests/structure/*.test.mjs

cd harmony
./hvigorw --mode module -p module=shared@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test
cd ..

node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/audit-mihomo-api.mjs
```

Fresh host-side results:

- `node --test harmony/tests/structure/*.test.mjs`
  - final rerun against the current document/head completed with `exit 0`
  - `215/215` passing
- `shared@default` debug Hypium
  - completed at `2026-08-12 11:04:49 CST`
  - `exit 0`
  - `86/86` passing
- `platform@default` debug Hypium
  - completed at `2026-08-12 11:06:15 CST`
  - `exit 0`
  - `86/86` passing
- `entry@default` debug Hypium
  - completed at `2026-08-12 11:07:02 CST`
  - `exit 0`
  - `28/28` passing
- `node harmony/tools/test-native-host.mjs --case contract`
  - `28` passing
- `node harmony/tools/test-native-host.mjs --case mihomo-backend`
  - `15` passing
- `node harmony/tools/test-native-host.mjs --case napi-environment`
  - `17` passing
- `node harmony/tools/audit-mihomo-api.mjs`
  - pinned `github.com/metacubex/mihomo v1.19.29`
  - pinned commit `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`

`entry@default` debug Hypium proves the normal `src/test` lane only. It does
not prove `entry/src/ohosTest` execution, and it must not be interpreted as
Phase 3 simulator or device completion.

The first `shared@default` attempt in a sandboxed environment is not counted as
evidence. That run stalled during Previewer initialization, and its
`coverage.log` showed `CommandLineInterface command pipe connect failed` before
test-case execution; the command was then interrupted with `exit 130`. The same
command completed with `exit 0` once it ran in an environment that allowed the
required local DevEco IPC, so this was an execution-environment restriction and
did not require source changes.

Go race status:

```bash
cd harmony/core/go
GOPROXY=https://goproxy.cn,direct go test -race -count=1 ./...
cd probe
GOPROXY=https://goproxy.cn,direct go test -race -count=1 ./...
cd ../../../..
```

- Verified summary for this handoff:
  - both `GOPROXY=https://goproxy.cn,direct go test -race -count=1 ./...`
    commands completed in the Task 16 fresh verification on Wednesday,
    August 12, 2026 with `exit 0`
  - individual completion timestamps were not retained
  - main Go race: `4` packages pass, `2` packages have no tests
  - probe Go race: `1` package pass
  - the successful rerun used a command-local `GOPROXY=https://goproxy.cn,direct`
    override only
  - `go.mod` and `go.sum` were not modified
- Earlier local diagnosis found the default `https://proxy.golang.org/...`
  path can time out when re-fetching `github.com/metacubex/mihomo`, so future
  reruns should treat proxy reachability as an environment prerequisite, not as
  a source regression.

## Production native build evidence

The production/default lane was rebuilt and recorded with:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase3-production-provenance.json
```

Recorded production provenance:

- artifact: `harmony/artifacts/phase3-production-provenance.json`
- run started: `2026-08-12T02:34:55.986Z`
- run completed: `2026-08-12T02:36:06.607Z`
- overall result: `incomplete`
- `nativeBuildResult: "pass"`
- `phase2SelfTest.enabled: false`
- `phase2SelfTest.purpose: "production"`
- `phase2SelfTest.releaseStatus: "releasable"`

Production/default HAP:

- path: `harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`
- version: `1.0.0`
- versionCode: `1000000`
- variant: `entry@default debug unsigned`
- size: `29962775` bytes
- sha256: `b69eba99161bbfa0430c1b0d021873c09fba0fc3b3180e539d40a718e813e2fc`

Native artifacts and byte identity:

- raw core: `harmony/artifacts/libcmfa_mihomo.so`
  - size: `53290440` bytes
  - sha256: `3949b77c1d6e68dac6673980b1ae6f088365980e02e412ec4507310349b65266`
  - architecture: `AArch64`
- pre-package core:
  `harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libcmfa_mihomo.so`
  - sha256 matches raw core:
    `3949b77c1d6e68dac6673980b1ae6f088365980e02e412ec4507310349b65266`
- addon:
  `harmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a/libentry.so`
  - size: `4489352` bytes
  - sha256: `f245bd80ca6847cb2c5d956cb67084c5832b639c63ab1d338bfcfbcadc577413`
  - architecture: `AArch64`

The production provenance evidence shows:

- real core bytes were built and packaged
- packaged core/addon identities agree with the inspected production/default HAP
- the lane stayed in the production tuple:
  `enabled false / purpose production / releaseStatus releasable`
- `stubDetected` remains false for the production lane
- the machine only blocked at signing/device gates, not at core/addon/HAP build

## Manifest validation and strict package inspection

The production lane was then validated and inspected:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase3-production-provenance.json

node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --manifest harmony/artifacts/phase3-production-provenance.json \
  --build-kind production
```

Recorded results for this handoff:

- manifest validation: `exit 0`
- package inspection:
  - executed fresh at `2026-08-12T02:46:47.754Z`
  - `exit 0`
  - `result: pass`
  - inspected production HAP sha256:
    `b69eba99161bbfa0430c1b0d021873c09fba0fc3b3180e539d40a718e813e2fc`

Inspection conclusions already confirmed for this handoff:

- production HAP path is fixed to
  `harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`
- production HAP version tuple is `1.0.0 / 1000000`
- packaged native ABI is arm64 production
- real core hash agreement holds:
  `3949b77c1d6e68dac6673980b1ae6f088365980e02e412ec4507310349b65266`
- real addon hash agreement holds:
  `f245bd80ca6847cb2c5d956cb67084c5832b639c63ab1d338bfcfbcadc577413`
- self-test tuple remains `enabled false / purpose production / releaseStatus releasable`
- `stubDetected: false`
- only `ohos.permission.INTERNET` is requested
- the default production HAP does not contain `ohosTest` runner payloads,
  test fixtures, or the isolated simulator runner lane

## Phase 3 simulator proof

The simulator proof command was run as:

```bash
node harmony/tests/bin/run-phase3-simulator-proof.mjs \
  --out harmony/artifacts/phase3-simulator-proof.json
```

Recorded simulator proof:

- artifact: `harmony/artifacts/phase3-simulator-proof.json`
- completed at `2026-08-12 10:34:41 CST`
- result: `incomplete`
- target classification: `host`
- fixture:
  `harmony/tests/fixtures/phase3-valid.yaml`
  - sha256: `a2a2fdada1df360186c7c66a3ddb800407d5150c65e9c2074f33b2a6f4d723af`
  - size: `52` bytes
- production HAP seen by the simulator gate:
  `harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`
  - sha256 in simulator proof:
    `c01207ddc3d70eda23db8b7f48ed8ec1b783e74953c7b2d645f5efa24c3f473c`
- `entry_test` HAP:
  `harmony/entry/build/default/outputs/ohosTest/entry-ohosTest-unsigned.hap`
  - size: `2226007` bytes
  - sha256: `55af1feea989145f25c662f2029008e282bec7e980d4e34ae359c7a32b46366f`

The simulator proof stopped at the expected unsigned/signing gate:

- failure `INPUT_HAP_UNSIGNED`
- failure `SIGNING_REQUIRED`
- `testStartedAt: null`
- `proofAt: null`
- `forceStopResult: not-run`
- `uninstallResult: not-run`
- `rebuildDefaultProductionLane: not-run`
- `phase2Traffic: incomplete`
- `phase3ProfileRuntime: incomplete`

This means the runner did not produce evidence of install, launch, `aa test`,
or device-side app execution. That is the correct and honest result for an
unsigned, unattended, device-free machine.

The simulator proof recorded an earlier unsigned production HAP digest than the
final post-proof production rebuild. That digest change is expected here
because both artifacts are unsigned local rebuilds from different timestamps,
not because the simulator lane proved an install/run identity match.

## Picker and UI caveats

Phase 3 adds the local file picker and profile import/runtime UI flow, but the
current evidence only proves that the production/profile-runtime sources are
present, packaged, and isolated from the `ohosTest` lane.

If unattended UI automation around the local file Picker is unstable, picker
selection must remain manual/provisional until a signed device lane records it
from app evidence. Simulator-only or host-only artifacts do not upgrade that
claim.

## What is actually proven now

Host/cross-build evidence proves:

- the HarmonyOS rewrite structure through Phase 3 is present and contract-checked
- the real AArch64 mihomo core and real N-API addon are built, hashed, and
  packaged consistently
- production packaging stays on the releasable tuple and does not silently swap
  in self-test artifacts
- only `ohos.permission.INTERNET` is requested
- the default production HAP excludes `ohosTest` runner payloads and test
  fixtures
- the isolated Phase 3 `entry_test` bundle exists as a separate unsigned HAP
- host-side contract, backend, and N-API lifetime checks pass
- the pinned mihomo API audit still matches `v1.19.29`

## What remains incomplete

The following claims are still incomplete and must not be overstated:

- signing a HarmonyOS HAP on this machine
- retail or developer install on a real HarmonyOS 6 phone
- native load and runtime behavior on device
- real HTTP CONNECT / SOCKS5 listener traffic on a phone
- real profile import/runtime UI execution on device
- local Picker end-to-end selection under unattended device UI
- HarmonyOS network-change handling on device
- foreground/background transitions and process-restoration behavior on device
- simulator execution beyond the signing gate
- VPN/TUN/system-wide capture or proxy takeover

## Current status

As of Wednesday, August 12, 2026:

- Phase 0-3 host/cross-build and package-side evidence is strong.
- Production native packaging and inspection are in a releasable-but-unsigned state.
- Simulator evidence is provisional and correctly blocked at unsigned/signing gates.
- Device-side Phase 2 traffic proof and Phase 3 profile-runtime proof remain
  `incomplete`.

## Verification-before-completion

Fresh close-out checks for this handoff:

```bash
git diff --check
git diff --cached --check
rg -n "TO[D]O|TB[D]|placeholde[r]|FIXME|HACK|XXX" harmony docs/harmony
git grep -n -E 'TO[D]O|TB[D]|FIXME|HACK|XXX' -- harmony docs/harmony
git grep -n -E 'placeholde[r]' -- harmony docs/harmony
git status --short --untracked-files=all
git diff --name-only -- '*lock*'
git diff --cached --name-only
find harmony -type d -name '*.test'
ps -ef | rg 'hvigor|Previewer|TestAbility|node --test|go test|rg -n "TO\[D\]O|TB\[D\]|placeholde\[r\]|FIXME|HACK|XXX"'
```

Recorded results:

- `git diff --check` produced no output.
- `git diff --cached --check` produced no output.
- `rg -n "TO[D]O|TB[D]|placeholde[r]|FIXME|HACK|XXX" harmony docs/harmony`
  - final fresh rerun is not a reliable tracked-source gate
  - explicit directory search traversed large ignored local caches such as
    `harmony/artifacts/go-mod-cache` and ignored `phase2-origin` material
  - because of those ignored/local artifacts, the final raw scan produced
    thousands of matches and is not the authority for commit gating
  - an earlier capture produced `16` matches before large ignored caches
    existed, but that earlier number is not the final authority either
- `git grep -n -E 'TO[D]O|TB[D]|FIXME|HACK|XXX' -- harmony docs/harmony`
  - `exit 1`
  - produced no output
  - this is the authoritative tracked-source work-marker audit
  - no active `TODO` / `TBD` / `FIXME` / `HACK` / `XXX` work markers were found
- `git grep -n -E 'placeholde[r]' -- harmony docs/harmony`
  - `exit 0`
  - produced `16` matched lines across `10` tracked files
  - all `16` are legitimate placeholder semantics in tracked UI resources,
    source, tests, fixtures, or toolchain validation code
- `git status --short --untracked-files=all` showed only:
  - `.omx/state/task13/ralph-progress.json`
  - `docs/harmony/phase-0-3-verification.md`
- both files were unstaged at capture time; only the verification document is
  intended for commit.
- `git diff --name-only -- '*lock*'` produced no output.
- `git diff --cached --name-only` produced no output.
- `find harmony -type d -name '*.test'` produced no output.
- filtered `ps` output showed only the inspection command itself; no residual
  `hvigor`, `Previewer`, `TestAbility`, `node --test`, or `go test` processes
  remained.
- staging was empty at capture time, so no staged signing material, device
  identities, HAP artifacts, or test secrets were present.
- ignored artifacts, HAPs, and local origin test certificates may exist in
  ignored locations such as `harmony/artifacts/phase2-origin`, but they are not
  staged and are not part of the intended commit.
