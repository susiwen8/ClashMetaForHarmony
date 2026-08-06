# HarmonyOS Phase 0

This directory holds the isolated HarmonyOS rewrite skeleton for ClashMetaForAndroid. As of Friday, July 31, 2026, Task 4 is an evidence gate, not a claimed device-pass gate: the checked-in helpers always write build/proof artifacts, but the gate is only passed by a fresh real run whose proof file ends with `"result": "pass"`.

## Locked toolchain

Current checked-in lock and structure tests expect:

- DevEco Studio: `6.1.0.860`
- HarmonyOS SDK: `6.1.0.105` (target API `23`, compatible API `20`)
- HarmonyOS NDK: `6.1.0.105`
- Hvigor: `6.23.7`
- OHPM: `6.1.1.830`
- hdc: `6.1.0.105`
- Node.js: `22.17.0`

The runner auto-discovers `hdc` from the integrated DevEco SDK when available, and otherwise falls back to `hdc` on `PATH` (for example from a DevEco Terminal session).

## Non-secret setup

- Keep signing material only in local ignored DevEco state. The repository keeps `harmony/build-profile.json5` with `signingConfigs = []` on purpose.
- Do not commit `local.properties`, `.p12`, `.cer`, passwords, device serials, or generated `.hap` / proof artifacts.
- The local wrapper entrypoint is `harmony/hvigorw`. It must remain executable.

## Exact commands

Hvigor module build:

```bash
cd harmony
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
```

Hvigor project build:

```bash
cd harmony
./hvigorw --mode project -p product=default -p buildMode=debug assembleApp
```

Always-write build evidence:

```bash
node harmony/tests/bin/build-hap.mjs
```

Always-write Phase 0 device proof:

```bash
node harmony/tests/bin/run-phase0-device-proof.mjs --hap <actual-signed-hap>
```

Optional custom proof output:

```bash
node harmony/tests/bin/run-phase0-device-proof.mjs \
  --hap <actual-signed-hap> \
  --out harmony/artifacts/phase0-device-proof.manual.json
```

The device runner verifies `hdc` help first, then uses the discovered `hdc` command with:

```text
hdc list targets
hdc -t <connectkey> install -r <hap>
hdc -t <connectkey> shell aa start -a EntryAbility -b com.github.kr328.clash.harmony
hdc -t <connectkey> shell aa force-stop com.github.kr328.clash.harmony
```

## Output paths

- Build evidence: `harmony/artifacts/phase0-build-evidence.json`
- Device proof: `harmony/artifacts/phase0-device-proof.json`

The build helper writes evidence even when build/signing fails. If Hvigor exits `0` but only emits unsigned output or skip-sign warnings, the helper still records `incomplete` with `SIGNING_REQUIRED` and exits `2`. The device runner writes proof on every exit path, including missing `--hap`, unsigned input HAP, missing signing, `hdc` help mismatch, `Connect server failed`, zero targets, multiple targets, install failure, and launch failure.

Before any device command runs, the proof runner validates a matching Phase 0 pass build evidence file from `harmony/artifacts/phase0-build-evidence.json` by default, or from `--build-evidence <path>` when explicitly supplied.

## Honest incomplete states

- Missing local signing or unsigned `*-unsigned.hap` output surfaces as `incomplete` evidence with `SIGNING_REQUIRED`; that is not HAP-ready for device install.
- Missing device or `hdc list targets` output containing `Connect server failed` must stay `incomplete`, even if `hdc` exits `0`.
- The proof only becomes `"result": "pass"` when the HAP hash is known, install succeeds, launch succeeds, and the exact device build version is recorded.

## Development without a physical phone

As decided on August 6, 2026, Phase 2 implementation may continue while no
HarmonyOS 6 physical phone is available. Host tests, cross-builds, ELF/HAP
inspection, static checks, and Simulator runs are provisional development
evidence only. Phase 1 and Phase 2 remain `incomplete`; publication, VPN/TUN,
real network takeover, traffic claims, and final completion require rerunning
the deferred device proofs on a physical HarmonyOS 6 phone against the exact
packaged build.
