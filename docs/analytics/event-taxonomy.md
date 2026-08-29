# OpenBurnBar Analytics — Canonical Event Taxonomy

**Status:** Source of truth. Every platform (macOS, iOS/iPad, widget, keyboard, Android,
website, console, VS Code extension, backend) emits event names and property names that
match this document **verbatim**. If a platform needs an event that isn't here, add it here
first, then instrument.

**Provider:** [Amplitude](https://amplitude.com) — **strictly opt-in** (see
[§ Consent model](#consent-model)). Disclosed as a subprocessor on the trust/privacy pages,
`website/CLAIMS.md`, and `THIRD_PARTY_NOTICES.md`.

**Owner artifacts**
- Gate: `AgentLens/Services/Analytics/AnalyticsConsentStore.swift` (tri-state, default `unset`).
- Wrapper: `AgentLens/Services/Analytics/Analytics.swift` (the recorder every call routes through);
  `AmplitudeTransport.swift` is the only caller of the SDK.
- Coverage matrix: [`docs/analytics/coverage-matrix.md`](coverage-matrix.md).

---

## Hard invariants

1. **No event leaves any device until the user affirmatively opts in.** Default consent is
   `unset`; `unset` and `declined` are treated identically — no SDK init, no network egress,
   no queued/buffered sends. See [§ Consent model](#consent-model).
2. **Fully manual.** Autocapture is **off** on every platform. Every event is an explicit,
   taxonomy-matching call through the per-platform wrapper. Nothing the SDK could auto-fire is
   allowed to bypass the consent gate or emit an off-taxonomy event.
3. **Never send PII or content.** No conversation/prompt/response text, message bodies, API
   keys, provider secrets, file paths, raw emails, raw IDs, or free-text the user typed.
   Send feature identifiers, enumerated outcomes, booleans, and **bucketed** numerics. This
   mirrors the existing privacy model in
   `AgentLens/Services/Telemetry/OpenBurnBarTelemetryService.swift`.
4. **One wrapper per platform.** No view/component calls the Amplitude SDK directly. The
   wrapper reads the consent gate on **every** call and drops the call when consent != granted.
5. **Separate projects** for dev/staging vs production; keys are injected from each platform's
   secret/config mechanism and **never committed**.

---

## Naming conventions

### Event names — `surface.object.action`

Lowercase, dot-separated **segments**, `snake_case` **within** a segment. Past-or-present is
not enforced; the `action` segment is a short verb/state (`opened`, `completed`, `failed`,
`changed`, `viewed`).

```
dashboard.provider.card_opened
chat.message.sent
quota.refresh.failed
auth.sign_in.completed
```

> **Why not Amplitude's house `Object Verb-ed` Title Case?** Deliberate divergence, documented
> here so it's a decision and not drift. This taxonomy's #1 goal is that the *same funnel reads
> across macOS (Swift), Android (Kotlin), web/console (TS), and the extension (TS)*. A
> dot-namespaced, space-free, lowercase constant is trivially kept byte-identical across four
> languages; `"Dashboard Provider Card Opened"` is not (spaces, casing, and pluralization drift
> between hand-written call sites). We therefore pick **one** convention and hold it everywhere —
> which is exactly what the Amplitude taxonomy guidance asks for ("consistency is the top
> priority… match the chosen convention"). Amplitude treats different casings as different
> events, so the gate enforces this scheme in tests (see [§ Governance](#governance)).

### Property names — `snake_case`

- `snake_case` always. (This normalizes the `insights` surfaces, which were drafted in
  camelCase — e.g. `canvasCount` → `canvas_count`, `durationMs` → `duration_ms_bucket`.)
- Descriptive + units when ambiguous: `duration_ms_bucket`, `amount_usd_bucket`,
  `size_bytes_bucket`, `*_seconds`.
- Same concept → same name everywhere: `provider_name`, `model_name`, `outcome`, `surface`.
- Distinct concepts → distinct names: `sign_in_method` vs `payment_method`, never bare `method`
  where two meanings collide (we use `method` only for auth, scoped by the `auth.*` event).

### Property types & null handling

| Concept            | Type                | Example                          |
|--------------------|---------------------|----------------------------------|
| IDs / keys         | string (enum)       | `provider_name: "anthropic"`     |
| Counts / amounts   | **bucketed** string | `session_count_bucket: "21-100"` |
| Durations          | **bucketed** string | `duration_ms_bucket: "500ms-1s"` |
| Flags              | boolean             | `is_first_launch: true`          |
| Outcomes / status  | string (enum)       | `outcome: "success"`             |

**Null handling:** omit absent properties entirely. Never send `null`, `""`, or `"undefined"`.
A property is either present with a real value or not on the payload.

### Bucketing (anti-fingerprinting) — identical on every platform

Raw counts/durations/amounts are **never** sent; they are mapped to coarse buckets by a shared
helper (`AnalyticsBuckets` in the wrapper, mirrored per platform). Boundaries are canonical:

| Helper                  | Buckets (string labels)                                                         |
|-------------------------|---------------------------------------------------------------------------------|
| `duration_ms_bucket`    | `<100ms`, `100-500ms`, `500ms-1s`, `1-3s`, `3-10s`, `10-30s`, `>30s`            |
| `duration_seconds_bucket` | `<5s`, `5-30s`, `30s-2m`, `2-10m`, `10-60m`, `>60m`                            |
| `count_bucket`          | `0`, `1`, `2-5`, `6-20`, `21-100`, `101-500`, `>500`                            |
| `amount_usd_bucket`     | `0`, `<1`, `1-10`, `10-50`, `50-100`, `100-500`, `>500`                         |
| `size_bytes_bucket`     | `<1KB`, `1-100KB`, `100KB-1MB`, `1-10MB`, `10-100MB`, `>100MB`                  |
| `percent_bucket`        | `0-10`, `10-25`, `25-50`, `50-75`, `75-90`, `90-100`                            |
| `tool_name`             | `file_read`, `file_write`, `file_edit`, `terminal`, `search`, `web`, `memory`, `browser`, `clipboard`, `todo`, `other`, `unknown` |

---

## Shared super-properties

The wrapper attaches these to **every** event automatically (set once at init / on change).
Instrumentation call sites never pass them.

| Property             | Type    | Notes                                                             |
|----------------------|---------|-------------------------------------------------------------------|
| `platform`           | enum    | `macos` \| `ios` \| `ipados` \| `widget` \| `keyboard` \| `android` \| `linux` \| `web` \| `console` \| `vscode` \| `backend` |
| `app_version`        | string  | Marketing version, e.g. `2.4.1`                                   |
| `app_build`          | string  | Build number                                                     |
| `surface`            | enum    | Current surface/area (see surface enum below); also passed on `screen.viewed` |
| `session_id`         | string  | Per-app-session UUID (rotated per launch); **not** a user id      |
| `locale`             | string  | BCP-47, region-only granularity (e.g. `en-US`)                    |
| `consent_version`    | string  | Version of the consent copy the user accepted                     |

**Identity:** anonymous by default — `device_id` only (a random per-install UUID, **not** a
hardware id). `user_id` is set **only** after authenticated sign-in, to the stable account uid
hash already used by the app. Never set `user_id` before verified login.

### `surface` enum (cross-platform)

`app` · `onboarding` · `dashboard` · `dashboard_overview` · `dashboard_activity` ·
`dashboard_credential` · `dashboard_model` · `dashboard_project` · `dashboard_provider` ·
`model_detail` · `provider_detail` · `chat` · `chat_composer` · `chat_stream` · `insights` ·
`settings` · `quota` · `budget` · `cloud_sync` · `menubar` · `mission_console` · `wallpaper` ·
`account` · `widget` · `keyboard` · `console`

**Website pages** (`platform: web`) — bounded set; any unmapped path collapses to `other` so a
unique URL can never become a unique surface value: `home` · `download` · `pricing` · `trust` ·
`privacy` · `security` · `support` · `mcp` · `router` · `control` · `floo` · `link` · `other`

**Console** (`platform: console`): `inventory` · `pensieve` · `escrow` · `account` · `settings`.
**VS Code** (`platform: vscode`): `panel` · `run` · `daemon`.
**iOS mobile tabs** (`platform: ios`/`ipados`): `pulse` · `burn` · `insights` · `streams` · `hermes` · `you`.

---

## Consent model

Tri-state, persisted, default `unset`. See `AnalyticsConsentStore`.

| State      | SDK initialized? | Events sent? | First-run prompt shows? |
|------------|:----------------:|:------------:|:-----------------------:|
| `unset`    | No               | No           | **Yes**                 |
| `declined` | No               | No           | No                      |
| `granted`  | Yes              | Yes          | No                      |

- The wrapper holds **SDK construction** behind a `granted` check — an un-consented session
  never builds the client.
- **On grant:** the wrapper initializes the SDK and emits exactly one
  `consent.analytics.granted` event (the opt-in-rate signal). Then normal events flow.
- **On revoke (`granted` → `declined`):** the wrapper stops immediately — it flushes nothing,
  emits no "revoked" event (that would be a send after revoke), and tears down the client.
- The first-run prompt records `granted` or `declined`; leaving it unset keeps analytics dark.

---

## Event categories

Every event is exactly one of: **`lifecycle`** (app/session milestones), **`screen_view`** (a
surface became visible), **`primary_action`** (a deliberate user action), **`conversion_auth`**
(sign-in / sign-up / onboarding / upgrade — the funnels), **`error`** (handled errors only).
Category is set via Amplitude's category metadata, not embedded in the name.

---

## Tier 1 — Core cross-platform events

Few, parameterized, **identical schema on every platform**. These are the funnel spine — they
make macOS, iOS, Android, web, console, and the extension line up. The collapse of the raw
inventory's per-variant events (per auth method, per screen, per setting, per sync domain) into
these parameterized events is intentional ("one action = one event + properties").

| Event                          | Category        | Properties                                                                 |
|--------------------------------|-----------------|----------------------------------------------------------------------------|
| `app.session.started`          | lifecycle       | `is_first_launch:bool`, `cold_start:bool`                                  |
| `app.session.ended`            | lifecycle       | `duration_seconds_bucket`                                                  |
| `app.foregrounded`             | lifecycle       | —                                                                          |
| `app.backgrounded`             | lifecycle       | —                                                                          |
| `app.startup.failed`           | error           | `error_category`, `recovery_available:bool`                               |
| `screen.viewed`                | screen_view     | `surface` (enum), `is_first_view:bool`, plus optional surface context props |
| `nav.route.changed`            | screen_view     | `from_route`, `to_route`                                                   |
| `auth.sign_in.completed`       | conversion_auth | `method` (`google`\|`apple`\|`github`\|`email`), `outcome` (`success`\|`failure`), `error_code?`, `duration_ms_bucket` |
| `auth.sign_up.completed`       | conversion_auth | `method`, `outcome`, `error_code?`                                         |
| `auth.signed_out`              | lifecycle       | `outcome`                                                                  |
| `auth.account.deleted`         | conversion_auth | `outcome`                                                                  |
| `onboarding.started`           | lifecycle       | `step_count`                                                              |
| `onboarding.step.viewed`       | screen_view     | `step` (enum), `step_index`                                               |
| `onboarding.completed`         | conversion_auth | `providers_enabled_count_bucket`, `backends_enabled_count`, `duration_seconds_bucket` |
| `onboarding.dismissed`         | lifecycle       | `last_step`                                                               |
| `subscription.upgrade.initiated` | conversion_auth | `target_tier`                                                           |
| `settings.changed`             | primary_action  | `setting_key` (enum), `new_value` (bool/enum/bucketed — never free text)  |
| `error.handled`                | error           | `error_category`, `surface`, `code?`                                       |
| `consent.analytics.granted`    | lifecycle       | `consent_version` (only event emitted at the moment of opt-in)            |
| `feature.used`                 | primary_action  | `feature` (bounded id), `outcome`, `duration_ms_bucket?` — the privacy-preserving TelemetryService fan-out (feature id + outcome + bucketed duration only) |

### Marketing funnel (CMO acquisition contract)

Small shared acquisition set. Consent required. `product` is always `burnbar`.
CMO logical names map to these taxonomy-legal wire names:

| CMO name | Wire name | Category | Notes |
|----------|-----------|----------|-------|
| `page_viewed` | `page.viewed` | screen_view | Website page view (also emits existing `screen.viewed`) |
| `app_opened` | `app.opened` | lifecycle | Opt-in app open (also emits existing `app.session.started`) |
| `cta_clicked` | `cta.clicked` | conversion_auth | Pricing / generic CTA |
| `download_clicked` | `download.clicked` | conversion_auth | Download CTA (also emits existing `download.cta.clicked`) |
| `install_started` | `install.started` | lifecycle | First launch after install, opt-in only |
| `email_captured` | `email.captured` | conversion_auth | Capture happened (`captured:true`); **never** a raw email |

Shared funnel properties: `product=burnbar`, `surface` (`macos`\|`ios`\|`android`\|`web`\|`extension` on native; website page surface stays the bounded page enum), `app_version`, optional `utm_*`, `click_id`, `campaign`, `slate_id`, `post_id`.

Amplitude routing: production project `830583`, dev project `830581`. Never CubeLove `852537` or Hormiga `703455` / `799824`.
The website browser never holds `AMPLITUDE_API_KEY`; it POSTs to a first-party collector URL.

`setting_key` enumerates the togglable settings (e.g. `appearance_mode`, `launch_at_login`,
`conversation_indexing`, `cli_assistant`, `default_time_range`, `usage_display_mode`,
`refresh_interval`, `cloud_backup_conversation`, `cloud_backup_session_log`,
`desktop_wallpaper`, `notifications_local`, …). The full enum lives next to the wrapper.

---

## Tier 2 — Surface-specific events (macOS reference)

Distinctive actions per surface, drawn and **normalized** from the 446-candidate macOS
inventory. Parameterizable families are collapsed (noted inline). Other platforms emit their
own Tier 2 events under the same naming rules; the [coverage matrix](coverage-matrix.md) tracks
who emits what.

### Dashboard (`surface: dashboard*`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `dashboard.scan.run`           | primary_action | `trigger_source` (`toolbar`\|`menubar`\|`popover`), `providers_scanned_count_bucket` |
| `dashboard.recount.run`        | primary_action | `trigger_source`                                                       |
| `dashboard.time_range.changed` | primary_action | `from_range`, `to_range`                                               |
| `dashboard.unit.toggled`       | primary_action | `to_unit` (`currency`\|`tokens`)                                       |
| `dashboard.lane_card.opened`   | primary_action | `lane` (`activity`\|`credential`\|`model`\|`project`\|`provider`), `entity_kind`, `rank_position` *(collapses 5 per-lane `card_opened` events)* |
| `dashboard.session.opened`     | primary_action | `from` (`model_detail`\|`provider_detail`\|`activity`), `has_conversation_record:bool` |
| `dashboard.refresh.triggered`  | primary_action | `scan_type`                                                            |

`screen.viewed` with `surface=dashboard_*` covers every lane/overview/detail appearance
(collapses ~30 per-lane `screen_view` candidates) with optional context props such as
`provider_count_bucket`, `model_count_bucket`, `session_count_bucket`, `time_range`,
`cache_hit_rate_bucket`.

### Chat (`surface: chat*`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `chat.message.sent`            | primary_action | `backend` (`hermes`\|`openclaw`\|`pi_agent`\|`cli`), `has_attachments:bool`, `attachment_count_bucket`, `mode` (`agent`\|`cli`) |
| `chat.generation.completed`    | lifecycle      | `backend`, `total_duration_ms_bucket`, `outcome`                       |
| `chat.generation.cancelled`    | primary_action | `backend`, `elapsed_ms_bucket`                                         |
| `chat.generation.failed`       | error          | `backend`, `error_type`, `elapsed_ms_bucket`                           |
| `chat.tool.invoked`            | primary_action | `tool_name` (closed tool bucket; never raw custom names or args)       |
| `chat.backend.switched`        | primary_action | `from_backend`, `to_backend`                                          |
| `chat.model.selected`          | primary_action | `backend`, `model_source`                                            |
| `chat.persona.selected`        | primary_action | `backend`, `persona_id` (closed app-authored set; never the prompt body) |
| `chat.attachment.added`        | primary_action | `attachment_kind` (`file`\|`image`), `attachment_count_bucket`        |
| `chat.attachment.failed`       | error          | `error_kind`                                                          |
| `chat.history.cleared`         | primary_action | —                                                                     |
| `chat.panel.action`            | primary_action | `action` (`maximized`\|`minimized`\|`popped_out`\|`new_chat`\|`closed`) *(collapses panel-header buttons)* |
| `chat.desktop_control.granted` | conversion_auth | `capability_count_bucket`, `trust_mode`                              |
| `chat.search.performed`        | primary_action | `result_count_bucket`, `elapsed_ms_bucket`                            |

> **PII guard (chat):** never emit message text, prompt/response content, attachment contents,
> file names/paths, or token-level data. Only backend, outcome, counts, durations, tool *names*.

### Insights (`surface: insights`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `insights.canvas.created`      | primary_action | `template_id`                                                         |
| `insights.canvas.selected`     | primary_action | — *(no raw object ids; bounded dims only)* |
| `insights.canvas.deleted`      | primary_action | —                                                                     |
| `insights.widget.changed`      | primary_action | `action` (`added`\|`removed`\|`moved`\|`resized`\|`pinned`\|`configured`), `widget_kind` *(collapses widget CRUD)* |
| `insights.analysis.requested`  | primary_action | `prompt_length_bucket`, `instruction`                             |
| `insights.analysis.completed`  | primary_action | `generated_widget_count_bucket`, `duration_ms_bucket`, `outcome`      |
| `insights.privacy_mode.toggled`| primary_action | `is_enabled:bool`                                                     |
| `insights.verdict.refreshed`   | primary_action | `window`                                                             |
| `insights.auditlog.cleared`    | primary_action | `entries_cleared_bucket`                                              |

### Provider / quota (`surface: quota`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `quota.refresh.started`        | lifecycle      | `provider_name?`, `trigger_source`                                    |
| `quota.refresh.succeeded`      | lifecycle      | `provider_name`, `duration_ms_bucket`, `bucket_count_bucket`          |
| `quota.refresh.failed`         | error          | `provider_name`, `duration_ms_bucket`, `error_code`                   |
| `quota.setup.saved`            | primary_action | `provider_name`, `setup_type`                                        |
| `quota.workspace.filter_changed` | primary_action | `filter_type`, `new_value`                                          |

### Budget (`surface: budget`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `budget.rule.changed`          | primary_action | `action` (`created`\|`updated`\|`deleted`\|`paused`\|`resumed`), `rule_scope`, `period`, `amount_usd_bucket` *(collapses rule CRUD)* |
| `budget.threshold.warning`     | primary_action | `rule_scope`, `used_percent_bucket`, `limit_usd_bucket`               |
| `budget.threshold.blocked`     | error          | `rule_scope`, `limit_usd_bucket`                                      |

### Cloud sync (`surface: cloud_sync`)

| Event                          | Category        | Properties                                                             |
|--------------------------------|-----------------|-----------------------------------------------------------------------|
| `cloudsync.completed`          | conversion_auth | `domain` (`usage`\|`conversations`\|`session_logs`\|`chat_threads`\|`download`\|`collaboration`), `outcome`, `duration_ms_bucket`, `item_count_bucket` *(collapses ~18 per-domain succeeded/failed events)* |
| `cloudsync.failed`             | error           | `domain`, `error_code`, `duration_ms_bucket`                          |
| `cloudsync.manual_backup.run`  | primary_action  | `pending_count_bucket`                                                |

### Menu bar / windows / wallpaper (`surface: menubar`, `mission_console`, `wallpaper`)

| Event                          | Category       | Properties                                                              |
|--------------------------------|----------------|------------------------------------------------------------------------|
| `menubar.popover.shown`        | screen_view    | `trigger` (`left_click`\|`right_click`)                                |
| `menubar.action`               | primary_action | `action` (`scan`\|`recount`\|`open_dashboard`\|`open_settings`\|`smartdisplay_cast`) |
| `mission_console.opened`       | screen_view    | —                                                                     |
| `wallpaper.toggled`            | primary_action | `is_enabled:bool`, `screen_count_bucket`                              |
| `wallpaper.config.changed`     | primary_action | `setting` (`background`\|`speed`), `value`                            |

---

## Tier 2 — Website surfaces (`platform: web`)

Marketing-site conversions. Emitted by `website/src/lib/analytics` through the same consent gate.
The browser POSTs to a first-party collector (`PUBLIC_ANALYTICS_COLLECTOR_URL`); it never
holds an Amplitude API key. No collector URL → the site stays dark even after opt-in.
The site also emits the Tier 1 spine: `app.session.started` (once per tab session;
`is_first_launch` from a durable browser marker, `cold_start: true` on that first
tab boot),
`screen.viewed` (every page; `surface` from the page super-property,
`is_first_view` from a per-tab marker), `page.viewed`,
`app.opened`, `consent.analytics.granted`,
and — on the Hermes connect / sign-in flow — `auth.sign_in.completed` and `error.handled`.

| Event                     | Category        | Properties                                                              |
|---------------------------|-----------------|------------------------------------------------------------------------|
| `download.cta.clicked`    | conversion_auth | `placement` (`header`\|`mobile_nav`\|`hero`\|`pricing`\|`footer`), `target_platform?` (`macos`\|`ios`\|`android`\|`linux`) — website `platform` stays `web` |
| `pricing.plan.viewed`     | screen_view     | — *(impression; the page is in `surface`. Fires once when the plans grid scrolls into view)* |
| `pricing.cta.clicked`     | conversion_auth | `plan` (`free`\|`cloud`\|`cloud_pro`\|`ultra`)                          |
| `nav.external.clicked`    | primary_action  | `destination` (`github`\|`discord`\|`docs`\|…; bounded outbound targets) |
| `arena.variant.exposed`   | primary_action  | `variant` (`neural`) — vote-page skin; once per session (capsule/arcade retired) |
| `arena.artifact.played`   | primary_action  | `variant` (`neural`), `side` (`A`\|`B`) — the voter took control of that artifact (in place or on the stage); once per side per matchup |
| `arena.vote.recorded`     | primary_action  | `variant` (`neural`), `choice` (`a`\|`b`\|`tie`), `rubric` (`none`\|`partial`\|`full`) — fires only after the vote commits server-side; `rubric` reports how much of the optional per-dimension rubric was filled in, never which axes or which way they went |
| `arena.auth.gate_shown`   | primary_action  | `variant` (`neural`) — the sign-in gate appeared when a signed-out voter pressed a vote button |
| `arena.sign_in.completed` | conversion_auth| `variant` (`neural`), `provider` (`google`\|`apple`\|`github`\|`facebook`) — a voter completed sign-in through the arena gate |

> **PII guard (web):** the wrapper only sends string/boolean properties (raw numbers are a compile
> error), every value above is a bounded literal set, and unmapped URLs collapse to `surface=other`.
> No query strings, referrers, IPs (SDK `trackingOptions.ipAddress:false`), or free text.

---

## Tier 2 — Console surfaces (`platform: console`)

The BurnBar web console (Next.js, shares the website's Firebase project). Same consent gate +
dynamic-import-after-opt-in as the website. Also emits the Tier 1 spine: `app.session.started`,
`screen.viewed`, `nav.route.changed`, `auth.sign_in.completed`/`auth.signed_out` (Firebase Google/
Apple/GitHub/passkey), `settings.changed`, `error.handled`, `consent.analytics.granted`.

| Event                          | Category        | Properties                                                              |
|--------------------------------|-----------------|------------------------------------------------------------------------|
| `inventory.domain.exported`    | primary_action  | `encryption_tier` (`end_to_end`\|`zero_access`\|`server_readable`), `outcome` (`success`\|`failure`) |
| `inventory.domain.deleted`     | primary_action  | `encryption_tier`, `outcome`                                          |
| `pensieve.repo.connected`      | primary_action  | `tier` (`free`\|`pro`\|`ultra`), `source_count_bucket`               |
| `pensieve.repo.disconnected`   | primary_action  | `tier`, `outcome`                                                     |
| `pensieve.resync.requested`    | primary_action  | `tier`, `outcome`, `flagged_count_bucket`                            |
| `escrow.device.registered`     | primary_action  | `outcome`                                                             |
| `escrow.device.trusted`        | conversion_auth | `prf_supported:bool`                                                  |
| `escrow.device.failed`         | error           | `error_stage` (`unwrap`\|`other`)                                     |
| `passkey.enrollment.completed` | conversion_auth | `outcome`                                                             |
| `account.access.revoked`       | primary_action  | `scope` (`sync`\|`all`), `outcome`, `revoked_count_bucket`           |

---

## Tier 2 — VS Code extension surfaces (`platform: vscode`)

Gated on BOTH the extension's opt-in setting AND VS Code's telemetry signal
(`vscode.env.isTelemetryEnabled`); it fans out alongside the existing telemetry, never replacing it.
Also emits Tier 1 `error.handled` + `consent.analytics.granted`.

| Event                       | Category       | Properties                                                                 |
|-----------------------------|----------------|----------------------------------------------------------------------------|
| `vscode.extension.activated`| lifecycle      | `host_kind` (VS Code host app name; bounded)                              |
| `vscode.command.invoked`    | primary_action | `command_id` (bounded enum of the extension's own command ids — never args/text/paths) |
| `vscode.panel.action`       | primary_action | `action` (`open_app`\|`switch_section`\|`new_chat`\|`open_workspace`), `surface` |
| `vscode.run.action`         | primary_action | `action` (`start`\|`cancel`\|`retry`\|`approve`\|`reject`\|`repair_daemon`), `outcome` (`success`\|`failure`\|`cancelled`) — never the prompt, run id, or diff |
| `vscode.daemon.connection`  | lifecycle      | `outcome`                                                                  |

---

## Tier 2 — Visual Capture (`platform: macos`)

Privacy-preserving toggle for *which surface* BurnBar visually shares per provider
(PTY terminal vs Desktop app window). No screen contents, window titles, or pixel hashes are ever sent.

| Event                              | Category       | Properties                                                                 |
|------------------------------------|----------------|-----------------------------------------------------------------------------|
| `visual_capture.surface_selected`  | primary_action | `provider` (persistedToken), `surface` (`cli_pty`\|`desktop_app`), `trigger` (`settings`\|`session_header`\|`mobile`), `fallback_used:bool`, `is_eligible:bool` |

> Emitted on commit by `VisualCaptureSelection.commit`, which both stores the preference and records the event, so a stored selection always has a matching event. `fallback_used=true` means the user chose `desktop_app` while that provider's desktop bundle is not installed, so the selection cannot be honoured. Eligible providers are the audit-corrected Both set (12 `AgentProvider` cases); ineligible ones report `is_eligible=false` rather than being dropped. Never includes `windowTitle`, `bundleId` beyond `persistedToken`, or `sha256Hex`.

## Tier 2 — Android surfaces (`platform: android`)

The Android app reuses the shared **chat** (`chat.message.sent`, `chat.generation.*`,
`chat.backend.switched`, `chat.search.performed`), **dashboard** (`dashboard.time_range.changed`,
`dashboard.lane_card.opened`), and **quota** (`quota.refresh.*`) Tier 2 events under the same names.
The one Android-specific event:

| Event                      | Category        | Properties                                                  |
|----------------------------|-----------------|-------------------------------------------------------------|
| `store.purchase.completed` | conversion_auth | `product_tier` (`cloud`\|`cloud_pro`\|`ultra`), `outcome` (Google Play Billing) |

---

## Tier 2 — iOS / iPadOS / widget / keyboard surfaces (`platform: ios`/`ipados`/`widget`/`keyboard`)

The iOS app emits the Tier 1 spine + the shared `chat.message.sent`. **Widget** and **keyboard** are
app extensions that read the HOST app's consent via a shared App Group and emit only when the host is
granted. The **keyboard NEVER sends keystrokes, text, or snippet bodies** — usage outcomes only.

| Event                        | Category       | Properties                                                       |
|------------------------------|----------------|------------------------------------------------------------------|
| `mobile.tab.selected`        | screen_view    | `tab` (`pulse`\|`burn`\|`insights`\|`streams`\|`hermes`\|`you`)  |
| `mobile.pairing.initiated`   | primary_action | — *(Mac-handoff surface)*                                        |
| `widget.render.completed`    | screen_view    | `family` (widget-size enum), `freshness` (`fresh`\|`stale`) — render outcome only, no content |
| `widget.tap.opened`          | primary_action | `target` (bounded deep-link destination)                        |
| `keyboard.session.activated` | lifecycle      | — *(usage outcome only)*                                         |
| `keyboard.snippet.inserted`  | primary_action | `available_count_bucket` — **never** keystrokes/text/snippet body |

---

## Tier 2 — Backend server-side events (`platform: backend`)

Firebase Functions emit **only** for requests carrying a verified granted-consent flag propagated from
the client (`analyticsConsent === 'granted'` + a propagated anonymous `device_id`) — never ambient. The
envelope carries the anonymous `device_id`, the authenticated `user_id`, and an `insert_id` (SHA-256
token hash) for 7-day dedup. Also registered for backend use: `auth.account.deleted`, `error.handled`
(Tier 1).

| Event                            | Category        | Properties                                                              |
|----------------------------------|-----------------|------------------------------------------------------------------------|
| `subscription.entitlement.granted` | conversion_auth | `entitlement_family` (`burnbar_pro`\|`burnbar_pro_max`\|`burnbar_ultra`\|`hosted_quota_sync`\|`other`), `source` (`stripe`\|`google_play`\|`app_store`\|`grandfather`\|`other`), `purchase_platform` (`ios`\|`android`\|`macos`\|`web`\|`other`), `outcome`, `expires_in_seconds_bucket?` |

---

## Platform emission matrix

Tier 1 events are emitted by **all** platforms (where the surface exists). Tier 2 events are
platform-specific; each platform contributes its own. The living per-surface × per-category grid
is in [`docs/analytics/coverage-matrix.md`](coverage-matrix.md) and must be green before a
platform is considered "done."

---

## Governance

- **Add the event here first.** No instrumentation call may reference an event name not in this
  file. Per-platform tests assert call sites only use names from a generated allow-list derived
  from this doc.
- **Casing/scheme is enforced** by a unit test that rejects any registered event name not
  matching `^[a-z0-9]+(\.[a-z0-9_]+)+$`.
- **Property casing** enforced: `^[a-z0-9]+(_[a-z0-9]+)*$`.
- **No raw numerics**: numeric properties must be the output of an `AnalyticsBuckets` helper
  (reviewed at PR time).
- **PII review**: any new property is checked against the prohibited list (content, secrets,
  paths, raw ids, free text) before merge.
- **Cross-platform parity**: a shared event added for funnels must land in every platform's
  wrapper enum, or be explicitly scoped in the coverage matrix with a reason.
