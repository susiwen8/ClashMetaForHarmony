# HarmonyOS UI and Interaction Redesign

## Goal

Make the native HarmonyOS client feel like a focused daily VPN tool instead of a diagnostic form. The primary path—see the active profile, connect or disconnect, understand the selected node, and reach configuration management—must fit in the first viewport and remain obvious in every runtime state.

This redesign changes presentation and interaction hierarchy only. It does not add networking features, change VPN lifecycle semantics, alter profile persistence, or widen the public RPC surface.

## Evidence from the current phone build

The 2026-09-03 physical-phone audit captured Home, Profiles, Profile Detail, and Logs on a 1216 × 2688 HarmonyOS 6 device. It found:

- Home opens with an English engineering title and exposes low-level IPv4, IPv6, DNS, MTU, notification, and recovery facts before the primary VPN action. The connect button is below the first viewport.
- Main tasks are represented as a sequence of similarly weighted outlined cards, so current status, navigation, diagnostics, and primary actions compete visually.
- Profiles can retain an unhelpful vertical offset when replacing another scroll-root route. Its refresh action consumes more vertical space than the configuration itself.
- Profile Detail centers metadata and ISO timestamps in a large card, while node management, refresh, and destructive actions sit below the fold.
- Logs uses large pills and one rounded card per raw JSON record, which makes scanning slow and produces excessive vertical density.
- Several mixed Chinese/English labels expose implementation terminology instead of user intent.

Accepted audit screenshots stay in ignored local evidence under `harmony/artifacts/ui-audit-2026-09-03/` and are not release assets.

## Chosen aesthetic: Signal Paper

The visual language combines a warm porcelain workspace with one near-black connection surface. Electric blue indicates action and current selection; mint indicates healthy live traffic; amber and coral are reserved for recovery and errors. The result should feel like a precise network instrument without becoming a cyberpunk dashboard.

The memorable element is the Home connection hero: a compact dark field with a single signal pulse, plain-language state, selected node context, and the VPN action in one visual unit.

Design constraints:

- ArkUI / ArkTS Stage model, API 20 compatibility, phone-first portrait layout.
- Use the existing HarmonyOS type engine and resource system; no bundled font, image, or package dependency.
- Avoid gradients, decorative shadows, nested cards, and icon-font dependencies.
- Preserve a minimum 48vp touch target, semantic IDs used by physical proof automation, resource-backed copy, safe areas, and adaptable width.
- Keep text contrast at least equivalent to the current semantic palette. Never use color as the only state signal.

## Information and interaction hierarchy

### Home

The first viewport is ordered by user intent:

1. Product header and a short Chinese purpose line.
2. Connection hero with status, active node/profile context, and the primary connect/stop action.
3. Compact active-profile row that opens configuration management.
4. Connection detail surface; technical facts remain available but become secondary and denser.
5. Traffic metrics when VPN is running.
6. Rule / Global / Direct mode selector.
7. Logs entry.

The VPN action remains owned by `HomePage` with semantic ID `home.vpn.action`. Its enabled, busy, and stop states keep the existing ViewModel contract. The selected group/node remains a read-only view of authoritative runtime state.

The connection hero follows this exact state matrix without inventing a second lifecycle:

| State | Hero treatment | Primary action |
| --- | --- | --- |
| No active profile | Neutral signal, “尚未选择配置,” and a short route-to-configurations hint | Disabled; the configuration row remains actionable |
| `STOPPED` | Neutral signal and “未连接” | Start |
| `AWAITING_CONSENT` | Amber signal and “等待系统授权” | Busy/disabled |
| `STARTING` | Amber pulse and “正在连接” | Busy/disabled |
| `RUNNING` | Mint signal, “已连接,” and current node context | Stop |
| `RECOVERING` | Amber pulse, “正在恢复连接,” and the last known profile/node context | Busy/disabled |
| `STOPPING` | Neutral animated signal and “正在断开” | Busy/disabled |
| `ERROR` | Coral signal and the existing safe public error next to the hero | Use the existing action contract: retry only when it exposes `START`, otherwise disabled |

### Profiles

Use a stable screen-specific scroll identity so route changes do not inherit another page’s offset. The header keeps Back, title, and Add in one compact row. Refresh All becomes a low-height utility strip with inline progress/results. Profiles become one grouped list surface with restrained separators, a monogram, status labels, source, and human-readable update context.

Existing actions and IDs remain unchanged: `profiles.back`, `profiles.add`, `profiles.refresh-all`, and `profiles.row.<id>`.

### Profile Detail and node management

Metadata becomes left-aligned and compact. The page prioritizes, in order: activation state, node management, edit/refresh, then subscription schedule. Delete remains visually separated at the end as the only destructive action.

The embedded proxy manager keeps all current query, selection, nested group, one-click VPN, and delay-test behavior. Group selectors and node rows use dense list styling; current, fastest, testing, unavailable, and saved-for-next-start states remain textual as well as colored.

### Logs

The header, search, filters, and utility actions become a compact control rail. Entries render as a continuous technical list: level and timestamp on one line, message below, subtle separators, and a monospaced-feeling numeric rhythm. Export, refresh, copy, and clear behaviors remain unchanged. Raw private content remains governed by the existing redaction layer.

### Import sheet and feedback

Import methods are visually grouped by task, with URL import as the primary path and file/QR as secondary paths. Pending work disables duplicate actions. Safe error cards adopt the new palette but keep the existing bounded public error model.

The current automation and security contract is frozen: file, QR, URL field, and URL-submit controls retain `import.file`, `import.qr`, `import.url`, and `import.submit`; system QR scanning remains exclusive while active; and every plain-HTTP import or edited subscription URL still uses the existing per-operation warning and confirmation flow before network access.

## Responsive and safe-area acceptance

- The existing `<420vp` compact breakpoint remains authoritative. At compact widths, the complete product header, connection hero, primary VPN action, and active-profile row must fit in the first app viewport without scrolling. Traffic, connection details, mode, and logs may continue below it.
- At widths of 420vp and above, horizontal space may be used to place short metrics or actions side by side, but the information order and semantic IDs stay identical.
- Each screen owns a distinct scroll identity and opens at offset zero. Fixed headers must not inherit the preceding route’s scroll position.
- Content must not sit beneath the status/navigation safe areas. No primary control may rely on coordinates inside the bottom system gesture region.
- The medium import sheet uses one internal scroll surface. Its header, name field, URL field, and URL-submit action must remain reachable without the sheet expanding; file and QR actions remain reachable in the same scroll sequence.

## Component boundaries

- `HomePage` owns ordering, primary actions, and navigation callbacks.
- `RuntimeStatusCard`, `HomeTrafficCard`, and `RuntimeModeCard` remain presentation-only and render existing state.
- `ProfilesPage` owns list-level actions; `ProfileListItem` renders one profile and emits only its ID.
- `ProfileDetailPage` keeps all current ViewModel calls and composes the existing `ProxiesPage`.
- `LogsPage` remains a pure state/callback surface.
- Color, spacing, radius, and type values stay centralized in resource tokens.

No page reads repositories, VPN APIs, HDC state, or native-core APIs directly.

## Motion and state changes

Use restrained native motion only where it clarifies state:

- 180–220ms pressed-state feedback on primary actions.
- A subtle pulse on the Home signal mark while STARTING or RECOVERING.
- Cross-fade or opacity transition for connection status and traffic availability when supported without raising the compatible SDK.
- No continuous decorative animation while idle, and no animation required to understand a state change.

Reduced-motion behavior is naturally satisfied by keeping every transition optional and every state fully represented in text.

## Error handling and accessibility

- Busy actions remain disabled and retain a visible processing label.
- Errors stay adjacent to the action or surface that produced them; technical details remain copyable through the established safe-error path.
- All existing semantic IDs remain unique and actionable.
- Every interactive control keeps at least 48vp height.
- Headings, values, and captions use a stable reading order; status is never conveyed only by a colored dot.
- Focus order follows visual task order. Home reads header → VPN action → active profile → connection details → traffic → mode → logs. Profiles reads Back → title → Add → Refresh All → configuration rows. Detail reads Back → identity/status → Enable when present → node management → edit/refresh → schedule → delete. Logs reads Back → search → level filters → refresh/export/clear → entries.
- At the device’s large-text accessibility preset, the VPN action, state label, selected node, configuration title, and navigation actions must not clip or overlap. Secondary timestamps and source labels may ellipsize to one line, while error copy and node names may wrap.
- Runtime changes remain visible as text. Where the platform exposes accessibility announcements without raising the compatible SDK, `AWAITING_CONSENT`, `RUNNING`, `RECOVERING`, `ERROR`, and completion/error feedback should announce once per transition; otherwise the refreshed text remains in deterministic reading order.
- Screenshots can verify hierarchy, contrast risk, spacing, and clipping. Screen-reader announcements and hardware focus behavior still require device checks.

## Verification and acceptance

- Preserve all existing business behavior and public presentation contracts.
- Add UI structure tests for the connection hero, screen-specific scroll identities, compact action hierarchy, and absence of the previous English engineering headline.
- Run affected Entry Hypium tests and targeted structure tests; repair any redesign-related failures rather than weakening semantic proof.
- Build a fresh signed Release HAP and install it on the registered HarmonyOS 6 phone.
- Capture and inspect fresh phone screenshots for Home stopped, Home running, Profiles, Profile Detail, node management, and Logs.
- Verify the VPN can still start/stop, the selected node is visible, Rule/Global/Direct remains actionable while running, profiles can be opened/refreshed, and logs can be reached without off-screen coordinate assumptions.
- Verify the compact first-viewport contract, every Home state in the state matrix through ViewModel/structure tests, the medium-sheet scroll/reachability contract, focus order, and the device large-text preset without clipping critical actions.

## Out of scope

- New settings, Provider management, connection inspection, backup, Geodata UI, system proxy, local proxy, and per-app routing.
- Changes to native core exports, VPN/TUN configuration, ownership recovery, subscription scheduling, or database schemas.
- AppGallery signing and distribution changes.
