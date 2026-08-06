# HarmonyOS Phase 0–2 verification and handoff

## Scope and acceptance boundary

This document covers the native HarmonyOS 6.x rewrite through Phase 2:

- Phase 0 locks DevEco/HarmonyOS tooling and makes an empty HAP build falsifiable.
- Phase 1 packages the real AArch64 mihomo core behind a C ABI and an ArkTS/N-API bridge.
- Phase 2 proves real HTTPS traffic through both the core's HTTP CONNECT and SOCKS5 listeners.

Phase 3 UI work and Phase 4 VPN/TUN work are intentionally excluded. Android
maintenance and Android compatibility are also outside this rewrite's scope.

Phase 2 has two different classes of evidence:

1. Host/cross-build evidence can prove source structure, concurrency behavior,
   ABI contracts, AArch64 ELF shape, packaged bytes, provenance, and absence of
   stub/JNI/dynamic-loader fallbacks.
2. Only a developer-signed self-test HAP running on one physical HarmonyOS 6,
   API 20+, AArch64 phone can prove the end-to-end traffic claim.

The second class is currently unavailable, so Phase 2 must remain
`incomplete`. A Simulator never upgrades it to `pass`.

## Pinned source and toolchain

- Toolchain: `harmony/toolchain.lock.json`
- Upstream: `harmony/core/go/upstream.lock.json`
- API surface lock: `harmony/core/go/upstream.api-lock.json`
- mihomo: `v1.19.29`
- mihomo commit: `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`
- ABI version: `cmfa-harmony-v1`
- target: HarmonyOS API 23, compatible API 20, AArch64

The direct upstream license and redistribution notes are recorded in
`harmony/THIRD_PARTY_NOTICES.md`.

## Signing isolation

The checked-in `harmony/build-profile.json5` intentionally has no signing
configuration. Developer certificates, keystores, passwords, local DevEco
profiles, device serials, generated HAPs, extracted device evidence, and origin
test keys must stay in ignored local storage.

Proof writers redact repository/home paths, signing-material paths, device
identities, and tool output before persistence. Do not weaken that boundary to
make a proof pass.

## Host and cross-build verification

From the repository root:

```bash
node --test harmony/tests/structure/*.test.mjs

cd harmony/core/go
go test -race -count=1 ./...
cd probe
go test -race -count=1 ./...
cd ../../../..

node harmony/tools/test-native-host.mjs --case contract
node harmony/tools/test-native-host.mjs --case mihomo-backend
node harmony/tools/test-native-host.mjs --case napi-environment
node harmony/tools/audit-mihomo-api.mjs
```

An offline environment may point `GOMODCACHE`, `GOCACHE`, and `GOPROXY` at a
pre-populated local Go module mirror and set `GOSUMDB=off`. Those paths are
machine-local inputs and must not be persisted in evidence or commits.

The native host lanes cover ABI ownership/lifetime rules, callback and event
cleanup, the real mihomo backend adapter, and N-API environment behavior. The
API audit checks the pinned upstream listener/config APIs before cross-build.

## Production build evidence

Build and validate the default releasable configuration:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase1-native-provenance.json
node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase1-native-provenance.json
```

On an unsigned, device-free machine, the first command is expected to return a
non-zero overall status while still recording all of the following:

- `phase2SelfTest.enabled: false`
- `phase2SelfTest.purpose: "production"`
- `phase2SelfTest.releaseStatus: "releasable"`
- `nativeBuildResult: "pass"`
- core, addon, HAP, and archive build results `pass`
- signing and device results `incomplete`
- only explicit signing/device blockers

The validation command must return `0`. The HAP is written to
`harmony/entry/build/default/outputs/default/entry-default-unsigned.hap` until
a local DevEco signing profile is supplied.

## Strict Phase 2 package inspection

The device runner creates a fresh self-test build manifest with
`phase2SelfTest.enabled: true`. While that self-test output is still present,
inspect the exact HAP bytes:

```bash
node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --manifest harmony/artifacts/phase2-build-manifest.json
```

Passing inspection requires:

- exactly one `libs/arm64-v8a/libcmfa_mihomo.so` and one
  `libs/arm64-v8a/libentry.so` in the HAP;
- raw, pre-package, manifest, and packaged hashes/sizes to agree;
- both ELF files to be AArch64 and use only their allowlisted `DT_NEEDED` sets;
- the core to export the exact `cmfa-harmony-v1` surface;
- embedded build info to match mihomo version and commit;
- `stubDetected: false`, with no JNI, Android, `dlopen`/`dlsym`, or `libdl`
  fallback.

The self-test lane is non-releasable. Rebuild the default production lane after
inspection so a test-only addon is never handed off as a release candidate.

## Phase 2 physical-phone proof

With one authorized physical HarmonyOS 6/API 20+/AArch64 phone connected and a
valid local developer signing profile configured, run:

```bash
node harmony/tests/bin/run-phase2-device-proof.mjs \
  --build-manifest harmony/artifacts/phase2-build-manifest.json \
  --fixture harmony/tests/fixtures/phase2-match-direct.yaml \
  --out harmony/artifacts/phase2-device-proof.json
```

The runner builds a fresh signed self-test HAP, inspects it, starts a
run-correlated HTTPS origin with ephemeral test credentials, selects exactly
one supported physical target, installs and launches the app, pulls app
evidence, correlates origin and app run IDs, verifies both proxy paths, stops
the core, force-stops the app, and writes proof on every exit path.

The proof schema is
`harmony/tests/fixtures/phase2-device-proof.schema.json`. A passing proof must
have `result: "pass"`, no failures, a physical target classification, matching
fixture/HAP/core identities, `stubDetected: false`, a successful stop, and two
correlated HTTPS probes:

- `HTTP_CONNECT`: client → core HTTP listener → HTTPS origin
- `SOCKS5`: client → core SOCKS listener → HTTPS origin

Missing signing, no phone, more than one target, Simulator classification,
unsupported API/ABI, stale evidence, hash mismatch, uncorrelated origin data,
or either failed proxy path prevents `pass`.

## Current evidence status (2026-08-06)

- Structure contracts: `177/177` passing in the final full local run.
- Go race suites: locally passing for the core and probe modules.
- Host-native contract/backend/N-API lanes: passing.
- AArch64 core, addon, ArkTS compile, HAP package, archive, and provenance:
  passing.
- Strict self-test HAP inspection: passing with `stubDetected: false`.
- Production manifest live validation: passing.
- Signing: `incomplete` (`SIGNING_REQUIRED`).
- Physical-phone Phase 2 proof: `incomplete`; no physical device is available.

These local results are implementation evidence, not a substitute for the
deferred signed physical-phone proof. Do not begin Phase 3 or Phase 4 on the
strength of Simulator-only evidence.
