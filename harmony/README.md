# HarmonyOS native rewrite

This directory contains the isolated native HarmonyOS rewrite of
ClashMetaForAndroid. It targets HarmonyOS 6.x (API 20–25), HarmonyOS 7.x (API 26+), and AArch64. API 26+ uses authenticated loopback TCP for VPN RPC; earlier devices retain LocalSocket.
The Android application is not a compatibility target for this work.

The repository currently proves the API 24 toolchain, native ABI, ArkTS/N-API
bridge, real mihomo cross-build, signed HAP packaging, cross-process VPN RPC,
full-device TUN capture, proxy selection, and physical-device start/stop flow.
Signing material remains local and ignored even though signed-device builds are
part of the verified development workflow.

| Area | Current evidence |
| --- | --- |
| Phase 0: toolchain and application skeleton | API 24 toolchain, build, signing, install, and launch checks pass |
| Phase 1: native core and ArkTS bridge | Fresh AArch64 core/addon and signed HAP provenance pass |
| Phase 2: HTTP CONNECT and SOCKS5 traffic | Host, package, and physical-phone traffic paths are implemented |
| Phase 3/4 UI and VPN/TUN | Native UI, authenticated cross-process RPC, TUN capture, node management, and graceful stop are implemented |

See [the Phase 0–2 verification guide](../docs/harmony/phase-0-2-verification.md)
for the evidence model and deferred phone procedure. Third-party source and
license information is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Locked inputs

The checked-in locks currently require:

- DevEco Studio `6.1.1.300`
- HarmonyOS SDK and NDK `6.1.1.125`
- target API `24`, compatible API `20`
- Hvigor `6.24.4`
- OHPM `6.1.2.285`
- hdc `6.1.1.125`
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
