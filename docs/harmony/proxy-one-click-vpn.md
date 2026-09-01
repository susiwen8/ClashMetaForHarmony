# Harmony One-Click VPN Contract

Public success enums:
- `ALREADY_ACTIVE`
- `APPLIED_TO_RUNNING_VPN`
- `APPLIED_TO_RUNNING_VPN_NOT_PERSISTED`
- `VPN_STARTED`
- `SAVED_VPN_START_FAILED`

Public failure stages:
- `ADMISSION`
- `SELECTION`
- `VPN_START`
- `VPN_CONFIRMATION`

Public failure codes:
- `OPERATION_BUSY`
- `PROXY_SELECTION_STALE`
- `PROXY_SELECTION_FAILED`
- `PROXY_PERSISTENCE_FAILED`
- `VPN_PROFILE_UNAVAILABLE`
- `VPN_PERMISSION_DENIED`
- `VPN_START_FAILED`
- `VPN_STOPPED_BEFORE_RUNNING`
- `VPN_CONFIRMATION_TIMEOUT`
- `VPN_SESSION_CHANGED`

Progress stages:
- `IDLE`
- `SAVING_SELECTION`
- `STARTING_VPN`
- `SWITCHING_VPN`
- `CONFIRMING_SELECTION`

Ownership and ordering:
- `ProfileApplication` owns one-click admission, selection persistence, VPN start, and runtime confirmation ordering.
- The stopped path persists selection before requesting VPN start and publishes success only after confirmation reaches `RUNNING` with same-group runtime selection.
- The running-VPN path hot-switches through proxy selection only and preserves the active VPN session.
- Shared runtime `STARTING` and `STOPPING` states fail closed as busy admission results.
- `STARTED` is not a public success on its own.
- `ProxyViewModel` and `Index` consume the application-owned contract and do not sequence Home or VPN runtime mutations directly.
- Retained diagnostic and TUN internals are implementation detail, not public API.

Safe error resource IDs:
- `proxies_one_click_busy`
- `proxies_error_selection_stale`
- `proxies_error_selection_failed`
- `proxies_error_persistence_failed`
- `error_vpn_profile_unavailable`
- `error_vpn_permission_denied`
- `error_vpn_start_failed`
- `proxies_one_click_confirmation_timeout`
- `proxies_error_session_changed`

Focused verification command:

```sh
node --test harmony/tests/structure/proxy-one-click-vpn-contract.test.mjs
node --test harmony/tests/structure/phase3-layer-boundary.test.mjs harmony/tests/structure/phase4-vpn-contract.test.mjs
```

Full structure suite command:

```sh
node --test harmony/tests/structure/*.test.mjs
```

Privacy guarantee:
- Public result, error, progress, documentation, and proof-facing surfaces stay free of raw node names, transport addresses, subscription locations, auth material, private durable fields, and raw platform failure detail.
- Private runtime identity comparison is allowed only in memory for confirmation and stale-session rejection, and it is not published or persisted through this contract.
