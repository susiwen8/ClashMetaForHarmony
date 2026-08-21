# HarmonyOS Subscription Validation Compatibility Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the current subscription negotiate full Clash YAML and pass the production mihomo validator by provisioning a verified GeoIP database under one stable app-owned core home.

**Architecture:** Keep subscription credentials in the existing HUKS store and preserve the downloaded server-provided Clash configuration. Add an Android-compatible product User-Agent at the HTTP transport boundary, package a digest-pinned `geoip.metadb`, install it into the app files root, and make every managed configuration path initialize mihomo against that same root before parsing.

**Tech Stack:** ArkTS, HarmonyOS NetworkKit/Request Agent/CoreFileKit, Go, mihomo v1.19.29, Node.js build tooling/tests, Hypium, Hvigor, HDC.

**Spec:** `docs/superpowers/specs/2026-08-21-harmonyos-proxy-group-node-selection-design.md` — Plan A only.

**Observed compatibility contract:** Missing product User-Agent returns a 1,176-byte Base64 URI list. `ClashMetaForAndroid/HarmonyOS` returns full Clash YAML. The YAML fails with `GEODATA_MISSING` when mihomo home/`geoip.metadb` are absent and passes `mihomoexecutor.ParseWithBytes` when both are present.

**Dirty-worktree constraint:** The target transport, platform, core, build, and test files already contain unrelated uncommitted work. Preserve it. Do not reset, restore, clean, or commit entire overlapping files. Use scoped diffs after each task; implementation commits are deferred unless the user later authorizes safe partial staging.

---

## Chunk 1: Negotiate YAML and Provision Verified GeoIP Data

### Task 1: Send one stable product User-Agent through both HTTP transports

**Files:**
- Modify: `harmony/platform/src/main/ets/source/HttpTransport.ets`
- Modify: `harmony/platform/src/main/ets/source/SubscriptionDownloader.ets`
- Modify: `harmony/platform/src/main/ets/source/NetworkKitHttpTransport.ets`
- Modify: `harmony/platform/src/main/ets/source/RequestAgentRedirectTransport.ets`
- Test: `harmony/platform/src/test/SubscriptionDownloader.test.ets`

- [ ] **Step 1: Write the failing downloader request-contract test**

Add a constant expectation for `ClashMetaForAndroid/HarmonyOS`. Extend the fake
transport request recorder and assert that the first HTTPS request and every
manual redirect carry the exact same non-empty `userAgent` value. Assert that
the fragment is still removed and no authorization/cookie header is created.

```typescript
expect(networkTransport.requests[0].userAgent).assertEqual('ClashMetaForAndroid/HarmonyOS');
expect(networkTransport.requests[1].userAgent).assertEqual('ClashMetaForAndroid/HarmonyOS');
```

- [ ] **Step 2: Write failing transport adapter tests**

For NetworkKit, inject or extract a request-options factory so the test can
assert only one `User-Agent` header is produced. For Request Agent, inspect the
fake `RequestAgentCreateConfig` and assert its `headers` object contains the
same value. Header keys are case-insensitively unique.

- [ ] **Step 3: Run the platform suite and verify RED**

```bash
cd harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
```

Parse `platform/.test/default/intermediates/test/coverage_data/test_result.txt`.
Expected: compilation succeeds and only the new user-agent contract tests fail
because `HttpTransportRequest` has no `userAgent` and adapters send no header.

- [ ] **Step 4: Add a purpose-specific request field**

Extend `HttpTransportRequest` with required `userAgent: string`; do not add an
arbitrary caller-controlled header map. `SubscriptionDownloader` supplies one
private constant on each loop iteration:

```typescript
const SUBSCRIPTION_USER_AGENT: string = 'ClashMetaForAndroid/HarmonyOS';
```

All redirected requests reuse the same value.

- [ ] **Step 5: Apply the field in both adapters**

NetworkKit sets the request option `header` to a single `User-Agent` entry.
`RequestAgentCreateConfigRecord` sets `headers` to the equivalent plain object.
Reject blank/control-character user agents before creating a platform request.
Never include the value in error details or diagnostics.

- [ ] **Step 6: Run platform tests and verify GREEN**

Require all platform result records `Success`, including download, redirect,
timeout, size, NetworkKit, Request Agent, and new user-agent cases. Run
`git diff --check` for the five scoped files.

### Task 2: Lock and prepare the GeoIP build asset

**Files:**
- Create: `harmony/geodata.lock.json`
- Create: `harmony/tools/prepare-geodata.mjs`
- Create: `harmony/tests/structure/geodata-asset-contract.test.mjs`
- Modify: `.gitignore`
- Modify: `harmony/tests/bin/build-hap.mjs`
- Modify: `harmony/tests/bin/build-phase1-native.mjs`
- Modify: `harmony/tests/structure/phase0-proof-contract.test.mjs`
- Modify: `harmony/tests/structure/phase1-native-build-contract.test.mjs`
- Generated/ignored: `harmony/artifacts/geodata/geoip.metadb`
- Generated/ignored: `harmony/entry/src/main/resources/rawfile/geoip.metadb`

- [ ] **Step 1: Write failing lock and preparation tests**

The lock schema requires exactly one asset with canonical name
`geoip.metadb`, expected byte length `8593535`, SHA-256
`9d500c84613994153b531de7153b3602f2b9adde253a28307c74dba1bea1a957`,
the official release URL, and no credentials or machine paths.

The official URL may use the mutable `latest` alias only because size and
SHA-256 are mandatory. An upstream asset change must fail the build until a
reviewed lock update changes all three fields; silently accepting new bytes is
forbidden.

Test the preparation function with injected fetch/filesystem implementations:

- valid cached bytes are reused;
- valid downloaded bytes are written atomically to cache and rawfile;
- wrong size/hash fails and removes temporary output;
- all URLs fail without leaving a rawfile;
- symlink/out-of-repository outputs fail closed.

- [ ] **Step 2: Run the focused Node test and verify RED**

```bash
node --test harmony/tests/structure/geodata-asset-contract.test.mjs
```

Expected: FAIL because lock/script/generated-path rules are absent.

- [ ] **Step 3: Implement the bounded asset preparation tool**

Use Node built-ins only. Stream each response with a maximum of the expected
size plus one byte, hash while writing a mode-`0600` temporary file, require
exact size/digest, then rename into the ignored cache. Copy through another
verified temporary file into the generated rawfile path. Never accept a mirror
whose bytes do not match the same lock digest.

- [ ] **Step 4: Keep generated binary data out of Git**

Add exact ignore entries for the generated rawfile/cache, not broad resource or
artifact source patterns. Extend signing-isolation binary handling for the
exact generated `.metadb` path without excluding ArkTS/Go/Node source.

- [ ] **Step 5: Integrate preparation into the HAP build lane**

`build-hap.mjs` runs `prepareGeodata` before module/project Hvigor commands and
records safe asset identity (relative path, size, SHA-256, result) in build
evidence. A missing or invalid asset makes the build result fail before HAP
packaging. `build-phase1-native.mjs` inherits this through `buildHap` and must
not download a second time.

Even a pre-Hvigor failure appends one synthetic build-evidence command record
named `prepare-geodata` with `result=fail`, nonzero exit code, empty sensitive
output, and a typed `GEODATA_PREPARE_FAILED` failure. Update the phase1 build
report validator to accept/propagate the geodata identity and this synthetic
command without collapsing it into `PACKAGE_HAP_REPORT_INVALID`.

- [ ] **Step 6: Run focused and existing build-contract tests**

```bash
node --test \
  harmony/tests/structure/geodata-asset-contract.test.mjs \
  harmony/tests/structure/phase0-proof-contract.test.mjs \
  harmony/tests/structure/phase1-native-build-contract.test.mjs \
  harmony/tests/structure/signing-isolation.test.mjs
```

Use the existing one-shot generated-artifact excludes only if direct signing
isolation hits the documented `ENOBUFS`; all four signing assertions must pass.

### Task 3: Install the packaged GeoIP asset into the app files root

**Files:**
- Create: `harmony/platform/src/main/ets/geodata/HarmonyGeodataInstaller.ets`
- Create: `harmony/platform/src/test/HarmonyGeodataInstaller.test.ets`
- Modify: `harmony/platform/src/main/ets/files/FileDriver.ets`
- Modify: `harmony/platform/src/main/ets/files/HarmonyFileDriver.ets`
- Modify: `harmony/platform/src/test/fakes/PlatformFakes.ets`
- Modify: `harmony/platform/src/main/ets/PlatformFactory.ets`
- Modify: `harmony/platform/src/test/PlatformFactory.test.ets`
- Modify: `harmony/platform/src/test/List.test.ets`

- [ ] **Step 1: Write failing installer tests**

Inject a resource reader, expected size/digest, and `FileDriver`. Cover:

- matching installed file skips resource read/write;
- missing file installs verified rawfile bytes;
- mismatched installed file is replaced through a verified temporary path;
- bad packaged size/digest fails before replacing a known-good file;
- interrupted write/rename cleans temporary files and retries next startup;
- existing directory setup is idempotent;
- diagnostics contain stage/code only, not absolute paths or bytes.

Before the RED run, import and invoke `HarmonyGeodataInstaller.test` from the
platform module's `List.test.ets`; a missing registration is not a valid RED.

- [ ] **Step 2: Run platform tests and verify RED**

Expected: new suite fails because installer and replace-capable file operation
do not exist.

- [ ] **Step 3: Add an explicit replace operation to FileDriver**

Add `renameReplace(source, destination)` backed by the platform's replace move
mode. The fake must require an existing destination parent, move atomically,
and replace only a file. Injected move failure must leave the prior destination
bytes intact. Preserve `renameNoOverwrite` behavior for profile and secret
commits.

- [ ] **Step 4: Implement installer and composition ordering**

Install exactly `${filesDir}/geoip.metadb`. Verify an existing file with
`FileDriver.hash`; otherwise read the packaged rawfile, enforce exact bytes,
write and hash a unique temp, then `renameReplace`. `PlatformFactory.create()`
creates canonical paths and the file driver, then awaits installation before
`huks.prepare`, any repository call (including `repository.list`), content
reconciliation, or secret reconciliation. Installation failure produces a
typed startup persistence error; no repository operation or profile validation
starts. `PlatformFactory.test.ets` must assert this exact ordering and fail-fast
behavior.

- [ ] **Step 5: Run platform tests and verify GREEN**

Require all platform tests `Success`, including the strict fake rename tests,
geodata installer cases, secret store, downloader, and profile content store.
Run scoped diff/leak checks.

---

## Chunk 2: Initialize One Stable Core Home and Prove the Real Subscription

### Task 4: Resolve managed config paths to one stable mihomo home

**Files:**
- Create: `harmony/core/go/internal/config/home.go`
- Create: `harmony/core/go/internal/config/home_test.go`
- Modify: `harmony/core/go/internal/config/validate.go`
- Modify: `harmony/core/go/internal/config/validate_test.go`
- Modify: `harmony/core/go/internal/config/load.go`
- Modify: `harmony/core/go/cmd/cmfa_core/main.go`
- Test: `harmony/core/go/cmd/cmfa_core/main_test.go`

- [ ] **Step 1: Write failing managed-path tests**

For absolute paths rooted at one app files directory, assert:

```text
<files>/tmp/<stage>.yaml
<files>/profiles/<profile>/valid/<revision>.yaml
<files>/profiles/<profile>/failed/<revision>.yaml
<files>/<self-test>.yaml
```

all resolve to the same canonical `<files>` home plus a local relative
candidate. Reject traversal, foreign absolute paths, malformed managed depth,
symlink escape, and a later different home.

- [ ] **Step 2: Write failing home-initialization tests**

Inject a `SetHomeDir` function into a `HomeManager`. First canonical root calls
it once; repeated same-root validation/load is idempotent; concurrent first use
calls once; later drift returns a typed, redacted error. Tests must not mutate
mihomo global state.

- [ ] **Step 3: Run focused Go tests and verify RED**

```bash
cd harmony/core/go
GOMODCACHE=<repo>/harmony/artifacts/go-mod-cache GOPROXY=off \
  go test ./internal/config ./cmd/cmfa_core -count=1
```

Expected: FAIL because managed-root resolution/home manager are absent.

- [ ] **Step 4: Implement managed-root resolution**

Replace the parent-directory-only native `configSandbox` behavior. Return one
canonical files root and a local relative path for the four allowed shapes.
Keep `readWithinSandbox` rooted at that files directory, so `tmp` and retained
revisions remain inside one sandbox boundary.

- [ ] **Step 5: Implement the home manager**

`HomeManager.Prepare(root)` canonicalizes and mutex-serializes first use, calls
`constant.SetHomeDir(root)` through an injected function, memoizes the root, and
rejects drift with `GEODATA_HOME_DRIFT`. `ValidateFile` and `Loader.load` call
`Prepare` before `ParseWithBytes`. Production uses one package-level manager;
tests use isolated instances.

Add `ValidateFileWithDeps` for tests with explicit `PrepareHome` and
`ParseBytes` functions; production `ValidateFile` delegates with the real home
manager and `mihomoexecutor.ParseWithBytes`. The seam may not skip sandbox file
reading or production home initialization.

- [ ] **Step 6: Add safe validation categories**

Wrap parser errors in a `ValidationError` with allowlisted codes including
`GEODATA_MISSING`, `YAML_SYNTAX`, `PROXY_INVALID`, `RULE_INVALID`, and
`VALIDATION_UNKNOWN`. Extract only a field/index/line pattern when available;
drop quoted values, URLs, addresses, node names, credentials, and absolute
paths. `Error()` is bounded and safe before `main.go` writes it to `cmfa_error`.

- [ ] **Step 7: Run Go tests and verify GREEN**

Require config and command packages pass with no network access. Include
synthetic secret-bearing error inputs and assert sanitized output contains only
category plus safe field/index/line metadata.

### Task 5: Lock the two root causes with non-secret compatibility fixtures

**Files:**
- Create: `harmony/tests/fixtures/phase5-geoip-rule.yaml`
- Modify: `harmony/core/go/internal/config/validate_test.go`
- Modify: `harmony/platform/src/test/SubscriptionDownloader.test.ets`
- Create: `harmony/tests/structure/subscription-validation-compatibility-contract.test.mjs`
- Create: `docs/harmony/subscription-validation-compatibility.md`

- [ ] **Step 1: Add a minimal synthetic GeoIP fixture**

Create a credential-free configuration with a local mixed port and only
`GEOIP,CN,DIRECT` plus `MATCH,DIRECT`. It must reproduce `GEODATA_MISSING` with
an injected production-shaped parser error. A second
`ValidateFileWithDeps` case uses an injected parser that requires the prepared
home to contain the expected `geoip.metadb` path and then returns a synthetic
config, proving the accepted wiring without checking in a binary database.
The real parser/database acceptance remains an integration/device gate. Do not
check in the user's downloaded YAML, a GeoIP binary, or real node definitions.

- [ ] **Step 2: Add the response-negotiation regression fixture**

Fake transport returns Base64 URI bytes when `userAgent` is missing/wrong and
full synthetic YAML when it equals `ClashMetaForAndroid/HarmonyOS`.
`SubscriptionDownloader` must stage the YAML response unchanged; it must not
decode or synthesize a configuration from the Base64 branch.

- [ ] **Step 3: Write the compatibility report**

Document safe evidence only:

- missing UA response class: Base64 URI list;
- product UA response class: full YAML;
- initial parser category: `GEODATA_MISSING` at a rule index;
- prepared-home/verified-GeoIP replay: accepted;
- selected fixes, pinned asset identity, and redaction controls.

The report must contain no URL/token, node/group name, endpoint, credential,
absolute path, raw parser text, or candidate bytes.

- [ ] **Step 4: Run fixture and report contract tests**

Run Go config tests, platform tests, and a Node structure test that scans the
report/fixtures for forbidden sensitive patterns and requires all four
root-cause/result statements.

### Task 6: Build, install, and convert the current profile to a valid revision

**Files:**
- Generated: `harmony/artifacts/geodata/geoip.metadb`
- Generated: `harmony/entry/src/main/resources/rawfile/geoip.metadb`
- Generated: `harmony/artifacts/phase1-native-provenance.json`
- No committed signing configuration

- [ ] **Step 1: Run complete Plan A verification**

```bash
cd harmony/core/go
GOMODCACHE=<repo>/harmony/artifacts/go-mod-cache GOPROXY=off go test ./... -count=1

cd <repo>/harmony
./hvigorw --mode module -p module=platform@default -p product=default -p buildMode=debug test
./hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug test

cd <repo>
node --test \
  harmony/tests/structure/geodata-asset-contract.test.mjs \
  harmony/tests/structure/phase3-layer-boundary.test.mjs \
  harmony/tests/structure/phase3-ui-contract.test.mjs \
  harmony/tests/structure/phase4-package-contract.test.mjs
```

Platform and Go tests must have zero non-success results. Entry must add no
failure beyond exactly these two pre-existing cases, and all Plan A affected
cases must be `Success`:

```text
extensionFactoryUsesTheExactInjectedRegistryForUnexpectedFailureCleanup
nonSharedStopResolvesWithoutTouchingTheSharedRegistry
```

- [ ] **Step 2: Build a fresh signed HAP without retaining secrets**

Use the established secure local-signing recovery workflow:

1. recover exactly one valid prior signing config into a mode-`0700` temp root
   with one mode-`0600` JSON file, without printing values;
2. verify referenced external materials exist, capture the exact pre-edit
   `build-profile.json5` bytes/hash in the protected temp, and abort if it is
   not the expected safe `signingConfigs: []` state;
3. inject only `app.signingConfigs` into `harmony/build-profile.json5` using
   `apply_patch`; never print or diff the injected file;
4. run the build inside a try/finally discipline;
5. in the finally path, restore the exact captured pre-edit bytes using
   `apply_patch`, verify the pre/post hash matches and no signing material
   remains, then Trash the signing temp root.

Run these exact build/inspection commands:

```bash
node harmony/tests/bin/build-phase1-native.mjs \
  --out harmony/artifacts/phase1-native-provenance.json

node harmony/tests/bin/build-phase1-native.mjs \
  --validate harmony/artifacts/phase1-native-provenance.json

node harmony/tests/bin/inspect-hap.mjs \
  --hap harmony/entry/build/default/outputs/default/entry-default-signed.hap \
  --manifest harmony/artifacts/phase1-native-provenance.json \
  --build-kind production

```

The production HAP result, provenance, signature, native payload identity, and
geodata asset identity must pass. Phase 4 cross-bundle inspection is not part
of Plan A because it requires a separately provisioned fresh signed probe HAP;
it remains a later Phase 4 release gate. No signing configuration remains in
tracked source.

- [ ] **Step 3: Install in place and refresh the existing profile**

Install the exact final HAP with `hdc install -r`; do not uninstall or clear
data. Refresh the existing remote profile without replacing its source. Poll
bounded UI state until durable `updatedAt` changes.

- [ ] **Step 4: Verify content and geodata behavior without exposing data**

Read-only device evidence must prove:

- request path used product-UA behavior and staged a YAML mapping, not Base64;
- installed `geoip.metadb` size/digest match the lock;
- profile is `VALID` with a current revision and no failed candidate;
- durable error is null;
- original HUKS secret reference/envelope remain unchanged;
- no credential/endpoint appears in logs, layouts, reports, or local evidence.

- [ ] **Step 5: Prove runtime load and preserve downstream gate**

Enable the profile and load its committed revision. Confirm core state reaches
`CONFIG_LOADED` without starting Plan B node-query work. If load fails after
validation, retain the valid revision/error evidence and stop; do not begin
proxy selection implementation.

- [ ] **Step 6: Clean temporary sensitive artifacts and finalize the report**

Move all raw response/database/layout/signing temp directories to Trash,
verify original paths absent/recoverable, and update the compatibility report
with safe PASS/FAIL booleans only. Leave generated GeoIP build cache/rawfile
ignored and retain canonical manifest/package evidence.
