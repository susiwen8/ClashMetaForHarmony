# HarmonyOS Subscription Refresh Design

## Goal

Add manual refresh-all and system-scheduled refresh for remote profiles without racing UI updates, weakening HTTP consent, or restarting a running VPN.

## Chosen approach

Add per-profile update intervals and one persisted WorkScheduler job. The system job wakes at the platform minimum two-hour cadence and refreshes only profiles that are due. UI refresh-all uses the same batch use case but ignores due time.

Rejected alternatives:

- One WorkScheduler task per profile: exceeds the ten-work application limit and complicates reconciliation.
- Fifteen-minute exact alarms: Harmony WorkScheduler repeat work has a two-hour minimum and is power-policy controlled.
- Continuous background task: user-visible, battery-heavy, and inappropriate for polling.

## Data model and migration

`Profile.autoUpdateIntervalMs` is a safe integer. `0` disables scheduling. UI presets are 2h, 6h, 12h, 24h, and 7d. `lastSuccessfulUpdateAt` remains the due-time authority and becomes visible in application/presentation snapshots.

RDB schema v3 adds:

- `profiles.auto_update_interval_ms INTEGER NOT NULL DEFAULT 0`
- `profile_refresh_leases(profile_id PRIMARY KEY, owner_token, expires_at)`

Migration must explicitly support v2→v3 and validate the resulting schema. The profile row codec accepts legacy row v1 as interval 0 and writes row v2.

The version matrix is fixed: database `0/1/2 → 3`, durable profile row `1 → 2`. Initialization accepts current DB versions 0, 1, 2, or 3; runs additive proxy-selection migration before the v2→v3 profile/lease migration; then validates both tables and writes DB version 3. Row decoder accepts versions 1 and 2, defaults interval to 0 for v1, and encoder always writes v2.

## Batch use case

`RefreshProfilesUseCase` lists remote profiles, filters due items when scheduled, sorts oldest due first, and processes sequentially. Results are closed values:

- `SUCCESS`
- `FAILED_USING_CURRENT`
- `FAILED`
- `SKIPPED_HTTP`
- `SKIPPED_NOT_DUE`
- `BUSY`

The use case classifies an `UPDATED` result together with `lastError/availability`; it never equates persistence of a failed candidate with download success. A durable TTL lease prevents UI, batch, and WorkScheduler processes from refreshing the same profile concurrently.

Every remote refresh path—manual single refresh, URL-edit auto-refresh, refresh-all, and WorkScheduler—must call one `LeasedRemoteProfileRefresher` primitive. Lease TTL is 120 seconds. Acquire is one RDB transaction that inserts/replaces only when absent, expired, or already owned by the same token. It renews after each completed item, releases only with an owner-token compare-and-delete, and treats a non-expired foreign owner as per-profile `BUSY` rather than failing the whole batch. Expired leases are recoverable after process death.

Automatic and default batch refresh refuse plain HTTP because existing policy requires a fresh user confirmation for every HTTP operation. Manual single refresh keeps the current confirmation UI.

## Background execution

Register one non-exported `workScheduler` Extension. `SubscriptionRefreshWorkAbility` constructs a profile-only graph that does not import VPN notification/background-task modules. WorkInfo is persisted, requires any network, repeats every two hours, and is reconciled whenever profile intervals change.

Each callback has a 100-second start-new-work budget and then drains the current item. It writes profile results only. It never starts/stops/reloads the VPN; an active session keeps its loaded revision and the next VPN start uses the new revision.

Manual single and refresh-all preserve the existing local-runtime mutation lease: if the UI local runtime is not fully stopped, the command returns `BUSY` and performs no profile writes. WorkScheduler runs in a profile-only process and may commit a new revision while another process keeps an already-loaded local/VPN revision; it never deletes or mutates the loaded core state, and the next runtime start adopts the new revision. Tests lock these different entry-point semantics explicitly.

The foreground app exposes `reloadFromRepository()` and calls it on `EntryAbility.onForeground` so background changes become visible.

## UI

- Profiles page adds “Refresh all subscriptions”, pending progress, and a bounded result summary.
- Profile detail adds the interval selector and “last successful update”.
- Copy says “updated when the system allows”, never promises exact execution time.
- Only remote profiles expose auto-update controls.

No URL, source secret, response body, profile ID, or worker token enters public logs or notifications.

## Testing and acceptance

- Domain tests: due selection/order, HTTPS-only scheduling, result classification, deadline, cancellation, failure isolation, and lease contention/expiry.
- Platform tests: v2→v3 migration, codec compatibility, single-work reconciliation, two-hour minimum, persistence.
- Entry tests: WorkAbility start/stop, refresh-all double-submit guard, interval edit, foreground reload.
- Structure test: manifest Extension, no backgroundTaskManager import, no secret logging.
- Physical test: force-trigger WorkScheduler, verify RDB/content update, reopen UI, and confirm a running VPN was not restarted.
