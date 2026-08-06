# HarmonyOS native rewrite (Phase 0–2)

This directory contains the isolated native HarmonyOS rewrite of
ClashMetaForAndroid. It targets HarmonyOS 6.x, API 20 or later, and AArch64.
The Android application is not a compatibility target for this work.

The repository currently proves the toolchain, native ABI, ArkTS/N-API bridge,
real mihomo cross-build, and unsigned HAP packaging. Phase 2 is deliberately
still `incomplete`: this checkout has neither a developer signing profile nor a
physical HarmonyOS 6 phone. A Simulator is useful for development but cannot
satisfy the physical-device proof gate.

| Area | Current evidence |
| --- | --- |
| Phase 0: toolchain and empty application | Local build and structure checks pass; signing/device proof incomplete |
| Phase 1: native core and ArkTS bridge | Real AArch64 core/addon and HAP packaging pass; signing/device proof incomplete |
| Phase 2: HTTP CONNECT and SOCKS5 traffic | Host and package inspection pass; physical-phone traffic proof incomplete |
| Phase 3/4 UI and VPN/TUN | Out of scope until the Phase 2 phone gate passes |

See [the Phase 0–2 verification guide](../docs/harmony/phase-0-2-verification.md)
for the evidence model and deferred phone procedure. Third-party source and
license information is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Locked inputs

The checked-in locks currently require:

- DevEco Studio `6.1.0.860`
- HarmonyOS SDK and NDK `6.1.0.105`
- target API `23`, compatible API `20`
- Hvigor `6.23.7`
- OHPM `6.1.1.830`
- hdc `6.1.0.105`
- Node.js `22.17.0`
- mihomo `v1.19.29` at commit
  `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`

`harmony/toolchain.lock.json` and `harmony/core/go/upstream.lock.json` are the
machine-readable sources of truth. The runners discover `hdc` from the
integrated DevEco SDK and fall back to `hdc` on `PATH`.

## Non-secret local setup

- Keep signing material only in local ignored DevEco state.
  `harmony/build-profile.json5` intentionally keeps `signingConfigs = []`.
- Never commit `local.properties`, signing certificates/keystores, passwords,
  generated HAPs, proof artifacts, or device serials.
- Keep `harmony/hvigorw` executable.
- Use the checked-in wrapper and lock files; do not silently substitute Android
  libraries, JNI, `dlopen`/`dlsym`, `libdl`, or a fake core.

## Reproducible local verification

Run from the repository root unless a command includes `cd`:

```bash
node --test harmony/tests/structure/*.test.mjs

cd harmony/core/go
go test -race -count=1 ./...
cd probe
go test -race -count=1 ./...
cd ../../../..

node harmony/tools/test-native-host.mjs
node harmony/tools/audit-mihomo-api.mjs
```

Build the default production lane and validate its persisted manifest:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase1-native-provenance.json
```

Without local signing and a phone, the build command exits non-zero after
successfully producing the unsigned HAP because the overall result is
`incomplete`. The manifest must still say `nativeBuildResult: "pass"`, and the
validator must exit `0`.

The unsigned default output is:

```text
harmony/entry/build/default/outputs/default/entry-default-unsigned.hap
```

The direct Hvigor module command is:

```bash
cd harmony
./hvigorw --mode module \
  -p module=entry@default \
  -p product=default \
  -p buildMode=debug \
  assembleHap
```

## Evidence and device gates

Phase 0 proof against an actual signed HAP:

```bash
node harmony/tests/bin/build-hap.mjs
node harmony/tests/bin/run-phase0-device-proof.mjs --hap <actual-signed-hap>
```

Phase 2 always performs a fresh, explicitly gated, non-releasable self-test
build before it attempts device work:

```bash
node harmony/tests/bin/run-phase2-device-proof.mjs \
  --build-manifest harmony/artifacts/phase2-build-manifest.json \
  --fixture harmony/tests/fixtures/phase2-match-direct.yaml \
  --out harmony/artifacts/phase2-device-proof.json
```

The Phase 2 package inspector accepts the self-test HAP and manifest explicitly:

```bash
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --manifest harmony/artifacts/phase2-build-manifest.json
```

The self-test lane is test-only and overwrites the default build directory.
After using it, rerun the default production build command above before handing
off artifacts.

Generated evidence lives under `harmony/artifacts/` and is ignored. The key
files are:

- `phase0-build-evidence.json` and `phase0-device-proof.json`
- `phase1-native-provenance.json` and `phase1-device-proof.json`
- `phase2-build-manifest.json` and `phase2-device-proof.json`

Every proof runner writes evidence on pass, fail, and incomplete paths. Missing
signing stays `incomplete` with `SIGNING_REQUIRED`; no target stays `incomplete`
with `DEVICE_TARGET_MISSING`; Simulator or non-AArch64 targets stay
`incomplete` with `DEVICE_TARGET_UNSUPPORTED`. None of those states may be
reported as Phase 2 success.
