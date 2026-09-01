# HarmonyOS Home Traffic Statistics Design

## Goal

Show truthful current-session upload/download speed and cumulative bytes on Home while keeping one RPC polling owner shared with the ongoing VPN notification.

## Correct the source of truth first

Current Go counters are incomplete: TUN ingress trace commit increments only RX, TCP observes only `Read`, and UDP observes only request payload. Before adding UI:

- Bytes read from the app-side TCP connection are upload (`TX`).
- Bytes written back to the app-side TCP connection are download (`RX`).
- UDP request payload is upload (`TX`).
- UDP `WriteBack` payload is download (`RX`).

The recorder gains explicit, overflow-safe `addTx`/`addRx` operations. TCP wraps both `Read` and `Write`; UDP wraps `UDPPacket.WriteBack`. Counters add only the actual successful byte count `n`, including short writes; zero/failed bytes do not increment. Trace metadata and payload privacy remain unchanged.

## Shared monitor

`CoreComposition` creates the single `VpnTrafficMonitor` beside the shared RPC client. It injects the monitor lifecycle port into `HarmonyVpnController`, injects a notification subscriber/sink for ongoing-notification updates, and exposes only a read-only snapshot/subscription port through `ApplicationCompositionState` to `Index → HomeViewModel`. The controller remains the owner of start/stop/session transitions; Home cannot start polling.

The monitor owns one source, clock, scheduler, session generation, and subscriber set. It publishes an internal sample:

`available, txBytes, rxBytes, uploadBytesPerSecond, downloadBytesPerSecond`

The raw session ID is used only for stale-result rejection and is not placed in Home state. Notification traffic and Home subscribe to this monitor; Home does not start another `GET_SNAPSHOT` timer.

Rate rules remain:

- First valid sample establishes a baseline and reports zero rate.
- Counter/time rollback resets both rates to zero and replaces the baseline.
- Session change or stop clears totals/rates.
- `RECOVERING` publishes unavailable/zero rates and rebuilds the baseline after reconnect.
- All values remain safe non-negative integers at the ArkTS/RPC boundary.

## UI

`HomeTrafficState` contains availability, four byte values, and a recovery flag. The recovery flag comes only from `vpnSnapshot.state === RECOVERING`; monitor source failure does not change VPN lifecycle state. `HomeTrafficCard` appears for RUNNING/RECOVERING and shows:

- Upload speed and current-session upload total.
- Download speed and current-session download total.
- `RECOVERING`: keep the last totals, show zero rates, and label “Recovering”.
- `RUNNING` with a transient polling failure: keep the last totals, show zero rates, and label “Statistics temporarily unavailable”, not “Recovering”.
- `STOPPED/ERROR`: clear totals and rates.

Formatting is deterministic B/KiB/MiB/GiB with one decimal where useful. The page never exposes session IDs or native counter names.

## Testing and acceptance

- Go tests cover TCP/UDP both directions, short writes, concurrent updates, session reset, and zero-length operations.
- Monitor tests cover first sample, non-one-second elapsed time, counter/time rollback, source failure, stale async response, session switch, stop, and dispose.
- Home tests cover visibility, formatted totals/rates, recovering, and privacy.
- Structure test enforces one polling owner and prevents Home from importing NotificationKit.
- Physical test transfers controlled upload/download traffic and verifies both directions increase on Home and notification consistently.
