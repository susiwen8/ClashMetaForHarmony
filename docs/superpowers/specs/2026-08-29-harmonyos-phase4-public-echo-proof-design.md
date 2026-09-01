# HarmonyOS Phase 4 Public Protocol Capture Proof Design

**Date:** 2026-08-29
**Scope:** physical-device verification tooling and the standalone traffic-probe HAP
**Product impact:** none; the production VPN configuration remains unchanged

## Purpose

Phase 4 must prove that an unrelated application can send TCP, UDP, and
DNS-format UDP traffic through the production VPN TUN and mihomo runtime on a
physical HarmonyOS phone.

The controlled origin currently runs on the development Mac in the same LAN as
the phone. Physical-device evidence proved that HarmonyOS selects the more
specific connected-LAN route instead of either VPN default route for those
destinations. The native probe succeeds, but its LAN packets do not enter the
TUN. The earlier private `/32` route experiment and the historical probe-only
trusted-app allowlist experiment were both falsified on the phone and removed
from the proof path.

Connected-LAN traffic is therefore diagnostic-only and not a valid release gate
for global capture. The proof target changes to a validated public TCP exchange
endpoint plus documented public UDP/DNS exact-echo endpoints. The local
controlled origin remains in place for HTTPS identity, local HTTP/SOCKS, and
lifecycle checks.

## Decision

Use three distinct origin roles:

| Role | Transport | Purpose |
| --- | --- | --- |
| Controlled LAN origin | HTTPS | Prove the probe is fresh and bound to the current run. |
| Controlled LAN origin | local HTTP/SOCKS target | Prove loopback listeners still reach the existing core runtime. |
| Validated public TCP exchange endpoint | Native `tcpExchange` with an opaque flow marker and remote banner bytes | Prove ordinary non-LAN TCP enters TUN and mihomo on a validated public exchange path. |
| Documented public exact-echo origin | UDP echo, DNS-format UDP echo | Prove ordinary non-LAN UDP and DNS-shaped traffic enter TUN and mihomo. |

The initial single-origin attempt proved on the phone that public UDP and
DNS-format exact echo work while the earlier TCP marker experiment did not
survive carrier routing. The carrier amendment therefore converged the TCP
proof on native `tcpExchange`: the request sends an opaque `cmfa-<flowId>` SSH
identification line, waits for any remote banner bytes, and does not persist
response content. The runner keeps the TCP exchange endpoint and the UDP/DNS
exact-echo targets behind one validated test-only configuration seam so a
future organization-owned origin can replace them without changing product VPN
code.

Alternatives rejected for this iteration:

1. **Organization-owned public origin.** This is the strongest long-term
   option, but no externally reachable server or deployment authority is
   available in this workspace.
2. **Connect/send-only third-party targets.** These can show an outbound TUN
   event, but they cannot independently prove that the remote path returned the
   current opaque marker.
3. **More platform route or application-list exceptions.** Two independent
   phone experiments already falsified this direction, and it conflicts with
   the exact full-capture product contract.

## Product invariants

The proof change must not alter the production VPN architecture:

- routes remain exactly `0.0.0.0/0` and `::/0`;
- `trustedApplications` remains empty;
- `blockedApplications` contains only the production bundle;
- no public endpoint, test run ID, probe bundle, or diagnostic field enters the
  production `VpnConfig`;
- the UI-to-extension Want keeps only the established profile/version/session
  lookup data and redacted evidence run ID;
- no new production permission, dependency, native library, or network API is
  introduced.

## Components and data flow

### Host runner

`run-phase4-device-proof.mjs` owns a `Phase4ExternalOrigin` value containing a
validated public TCP exchange endpoint and a separate public UDP/DNS echo
target. Tests can inject synthetic values. Validation rejects hostnames,
non-canonical or non-public IPv4, invalid ports, and unrecognized fields.

The value is passed only to the probe ability as flat test parameters. It is
never forwarded to the production application, VPN extension, runtime journal,
proof JSON, command summary, or final report.

### Probe command

`ProbeCommand` keeps two explicit configurations:

- `lanOrigin`: HTTPS and the destination used by local HTTP/SOCKS checks;
- `externalOrigin`: TCP exchange target plus UDP/DNS exact-echo target.

`ProbeAbility` accepts both the existing nested test shape and the flat HDC Want
shape. A missing or invalid external origin fails closed before any probe starts.
No silent fallback to the LAN target is allowed.

### Traffic probe

`DirectTrafficProbe` resolves the two origins independently:

- HTTPS, HTTP CONNECT, and SOCKS use `lanOrigin`;
- TCP exchange, IPv4 UDP, and DNS-format IPv4 UDP use their protocol-specific
  addresses inside `externalOrigin`;
- the first native addon remains IPv4-only, so the existing IPv6 records remain
  `not-run` and create no ArkTS UDP socket.

The native port keeps `tcpEcho` and `tcpHttp` for host regression coverage and
uses `tcpExchange` for the device proof. `tcpExchange` completes only after
connecting, writing the full bounded request containing the opaque flow marker,
and observing banner bytes from the remote peer; it does not parse or persist
remote response content. UDP keeps `udpEcho` and `dnsUdpEcho`. DNS-format
traffic intentionally uses the public UDP echo port: the payload is DNS-shaped
for TUN/mihomo classification, while exact echo preserves the current
correlation and response-integrity contract.

### Evidence correlation

The baseline probe runs before VPN start and must complete the public TCP
exchange plus the exact public UDP/DNS echoes and the controlled HTTPS
response. Failure is classified as external origin reachability and stops the
run before judging VPN behavior.

After VPN start and recovery, the same external flows run again. A protocol
passes only when all of the following are true:

1. the probe operation returns `pass` for the current opaque flow ID and
   protocol contract;
2. evidence declares expected ingress `tun`;
3. exactly one fresh runtime traffic record matches protocol, flow hash, and
   correlation hash;
4. that record has a positive counter delta;
5. TCP also has complete destination and outbound-chain proof plus the observed
   remote banner bytes.

DNS-format proof is not interchangeable with ordinary UDP proof.
`dns-packet-ipv4` must use the DNS-specific correlation hash and match exactly
one runtime record whose protocol is `dns`. A linked `udp` record, including a
record produced by the same external endpoint and port, cannot satisfy the DNS
gate.

The public service is not part of the controlled-origin observation journal.
Exact echo plus the fresh probe record proves remote reachability; unique
runtime correlation proves capture. The correlator therefore requires the LAN
origin observation only for controlled HTTPS/local checks, not for public
TCP/UDP/DNS flows.

## Failure handling and diagnostics

Failures use fixed, non-sensitive classifications:

- `EXTERNAL_ORIGIN_CONFIG_INVALID`
- `EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN`
- `GLOBAL_INGRESS_INVALID`
- `TUN_LINK_MISSING`
- `TUN_LINK_AMBIGUOUS`
- `COUNTER_DELTA_MISSING`

The traffic wait reason and cleanup stage are retained as fixed enums in
diagnostic output so a timeout can be distinguished from a malformed/stale
journal and stop cleanup can identify its failing boundary. Details must never
include an address, port, payload, DNS label, provider response, device ID,
signing path, subscription data, node data, or raw operating-system error.

Provider unavailability is not treated as evidence that the VPN is broken. It
fails at the pre-VPN baseline gate. The runner does not silently switch to an
unreviewed endpoint because that would make proof identity non-deterministic.

If an external echo succeeds before VPN start but fails during the VPN round,
the runner records a pending classification, performs graceful VPN stop and
confirms the runtime stopped, then repeats that protocol once against the same
endpoint while the probe HAP and controlled origin are still available. Only
after that triage does it force-stop bundles, close the origin, restore host and
device state, remove temporary files, and write the proof. A failed post-stop
check is classified as
`EXTERNAL_ORIGIN_REACHABILITY_NOT_PROVEN`; it must not emit a VPN capture
failure. A successful post-stop check confirms that the provider is still
reachable and allows the original VPN-round result to be classified as
`GLOBAL_INGRESS_INVALID`, `TUN_LINK_MISSING`, or the more specific correlation
failure. No retry may switch endpoint identity.

## Privacy and package isolation

- The public address and ports may exist in test-only source and transient Want
  parameters, but never in persisted evidence, runner stdout/stderr, command
  summaries, provider-response logs, or user-facing output.
- Probe evidence continues to store only opaque IDs, fixed outcomes, byte
  counts, durations, and fixed failure codes.
- The production HAP continues to reject every probe type, resource, native
  library, and marker.
- The probe HAP remains unrelated to the production bundle and requests only
  `ohos.permission.INTERNET`.
- Final artifacts are scanned for endpoint coordinates, raw payloads, device
  identifiers, signing material, subscriptions, and proxy-node material.

## Verification

Test-first delivery must prove:

1. the dead private-origin route chain is absent from production and runner
   launch paths;
2. every pass or incomplete proof continues to carry and validate the exact
   production addresses, two default routes, DNS endpoints, blocking mode, and
   self-only blocked-app list; empty `trustedApplications` remains mandatory
   and is locked by source/runtime contract tests rather than added to the
   persisted proof schema; any drift is a release failure;
3. external origin parsing and validation reject missing, malformed, or mixed
   configurations;
4. `ProbeModels`, `ProbeAbility`, and `DirectTrafficProbe` explicitly own and
   validate `externalOrigin`; global TCP/UDP/DNS source paths must not read the
   `lanOrigin` host or ports, while HTTPS/local proxy paths must not read the
   external origin;
5. global TCP/UDP/DNS calls use `externalOrigin`, while HTTPS/local proxy calls
   still use `lanOrigin`;
6. serialized probe evidence, final proof, runner stdout/stderr, command
   summaries, and provider-response diagnostics contain no endpoint
   coordinates;
7. baseline endpoint failure stops before VPN correlation, and a VPN-round
   echo failure is reclassified only after the same endpoint is checked once
   post-stop;
8. synthetic public-exchange evidence passes correlation without controlled
   TCP/UDP origin observations, but still requires the controlled HTTPS
   observation;
9. DNS proof requires the DNS-specific hash and exactly one linked runtime
   record with protocol `dns`; a linked ordinary UDP record must fail it;
10. runtime traffic and cleanup timeout reasons remain fixed and redacted;
11. native host, ArkTS, structure, package, and unsigned-build suites remain
   green;
12. on the phone, the public TCP exchange and UDP/DNS exact-echo baselines pass,
   VPN-mode TCP/UDP/DNS each produce one fresh linked TUN record with positive
   counters, lifecycle/local checks pass, stop cleanup passes, package hashes
   match, and `stubDetected` is false.

## Long-term migration

When an organization-owned public origin becomes available, only the runner's
validated endpoint configuration changes. The probe API, evidence schema,
correlator, product VPN configuration, and package boundaries remain stable.
