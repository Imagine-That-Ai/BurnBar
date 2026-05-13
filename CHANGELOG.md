# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Router mode toggle + model-landscape benchmark snapshots.** Settings ->
  Routing pools now persists a router mode in the daemon provider config:
  **Provider-Family Failover** keeps fallback inside the selected provider
  family/account set, while **Intelligent Model Router** ranks compatible
  routes using task, health, quota, cost, latency, capability, and benchmark
  freshness signals. Routing decisions now carry sanitized explanations,
  rejected alternatives, mode, selected route identity, and benchmark status.
  A daily Cloud Function normalizes public or fixture-backed model-landscape
  data from Artificial Analysis, Terminal-Bench/Hugging Face, Design Arena's
  documented API or cached fixtures, and manual fixtures into read-only
  benchmark snapshot/status collections without scraping private pages or
  persisting secrets. The Artificial Analysis key is bound through Firebase
  Secret Manager on the scheduled job.
- **Routing pools surface + Claude Code / Codex wiring helpers (macOS).**
  Settings now has a top-level **Routing pools** tab that mirrors the Fire
  Hydrant's two-pool model on the desktop. Each pool tab lists the routed
  upstream accounts with a live health pill, last-used timestamp, and the
  current active / next-fallback / cooling-down badges sourced from
  `ProviderQuotaService.routingStatesByProviderID`. Each pool also exposes
  a "Wire <client> through the Hydrant" card that ships in two modes: a
  one-click **config-file toggle** that writes
  `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` into
  `~/.claude/settings.json` (or a sentinel-fenced
  `[model_providers.openburnbar]` block into `~/.codex/config.toml`) with
  a timestamped `.openburnbar-backup-<UTC>` snapshot of the prior file,
  and a **shell-snippet sheet** that copies an `export …` block for users
  on bespoke shell setups. A 1-token probe button hits `/v1/messages` or
  `/v1/chat/completions` to confirm the wiring before the helper reports
  "wired". Anthropic credentials added through the existing Add-Account
  flow get validated by the new `AnthropicCredentialProbe`, which honors
  both `sk-ant-…` console keys (sent via `x-api-key`) and Pro/Team OAuth
  bearers (sent via `Authorization: Bearer`) and never logs the secret.
  Codex's ChatGPT-auth mode is honestly documented as
  **track-only, not routed**.
- **Insights tab (macOS, iPadOS, iOS).** A first-class destination that
  turns OpenBurnBar's local SQLite, JSONL ledgers, and Firestore rollups
  into a beautiful, modular, AI-authored analytics canvas. Pick any
  reachable model — Claude, GPT-5, Hermes, Pi, Ollama, or the always-on
  Local Rules adapter — and the canvas surfaces usage patterns,
  per-agent and per-model focuses, use-case clusters, anomalies,
  forecasts, quota health, and crisp recommendations. 26 widget kinds,
  8 built-in templates (Today, Cost Audit, Agent Focus, Model Focus,
  Use-Case Library, Quota Health, Quarterly Review, Anomalies), strict
  JSON-Schema generation with json_object fallback, content-addressed
  caching, append-only audit log, and an enforced 24 KB privacy ceiling
  on every digest. Canvases project deterministically from 12 columns
  (macOS) to 6 (iPad) to 2 (iPhone) — same intent, adapted. iPhone gets
  a new "Insights" tab between Burn and Streams; iPad joins it to the
  sidebar; macOS exposes it as a three-pane workspace (library · canvas
  · inspector). Renderers live in `OpenBurnBarCore/Views/Insights/` so
  every platform renders identically. See
  [`docs/INSIGHTS.md`](docs/INSIGHTS.md) and
  [`docs/INSIGHTS_ARCHITECTURE.md`](docs/INSIGHTS_ARCHITECTURE.md) for
  the full architecture, schemas, and extension recipe.
- **Multi-runtime chat tiles + Hermes sub-provider picker (iOS, iPadOS,
  Android, macOS).** The Assistants pill now exposes up to five top-level
  chat tiles — Hermes, Pi, Codex, Claude, OpenClaw — and the Hermes model
  picker surfaces the six routable sub-providers (Codex, Claude, Z.ai,
  Kimi, MiniMax, Ollama) even when the relay hasn't reported live models
  yet. Visibility is user-configurable: a new "Chat tiles" screen in
  Settings on each mobile platform lets users hide tiles they don't want
  and toggle which Hermes sub-providers appear in the model sheet. Hermes
  is always retained as a fallback so the chat surface is never empty.
  Shared `ChatTilePreferences` / `HermesSubProvider` types live in
  `OpenBurnBarCore` and a Kotlin mirror in `com.openburnbar.data.hermes`;
  both encode to the same deterministic JSON shape so preferences round-
  trip cleanly across platforms. `AssistantRuntimeID` is extended from
  two cases to five with stable persisted raw values
  (`hermes`/`pi`/`codex`/`claude`/`openclaw`) so existing
  `UserDefaults`/`SharedPreferences` selections continue to decode.
  Android now persists the concrete Hermes model override in the same
  preference blob and shows a resettable selected-model row in Settings,
  while macOS upgrades its Hermes strip from family-only pills to grouped
  live gateway-advertised model pills with the same family visibility gates.
- **Fire Hydrant: two-pool same-format routing.** The local gateway at
  `127.0.0.1:8317` now exposes two parallel routing pools:
  `POST /v1/chat/completions` (OpenAI-family) and the new
  `POST /v1/messages` (Anthropic-family). A request hitting one endpoint
  can only be served by accounts in that pool — format families never
  cross, which keeps tool-call schemas, prompt-cache markers, and
  streaming-event types intact. Within a pool the existing in-flight
  failover loop continues to mark slots `.exhausted` / `.coolingDown` on
  upstream `429` / quota / auth failures and retries against the next
  healthy candidate. `BurnBarProviderFormatFamily` (`openaiCompat` /
  `anthropic`) is a first-class catalog field on
  `BurnBarCatalogProvider`, threaded through `BurnBarProviderRoute`, and
  enforced by `ProviderRoutingPolicy.decide(...)`. New end-to-end tests
  cover the Anthropic happy path, in-flight Anthropic failover on
  quota-exceeded, and bidirectional 503 rejection when only the wrong
  pool is configured.
- **Anthropic, OpenAI, Kimi as routed upstream providers.** The bundled
  catalog graduates Anthropic, OpenAI, and Moonshot/Kimi to
  `capabilities: ["routing", "accounting"]`, exposing one flagship public
  model per provider (Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5, GPT-5.4 /
  GPT-5.3 Codex, Kimi K2.5). Existing accounts auto-classify into the
  correct pool via `BurnBarCatalogProvider.formatFamily`. Anthropic
  credentials route through the new `BurnBarAnthropicProviderExecutor`,
  which sends `sk-ant-…` keys as `x-api-key` and any other shape as
  `Authorization: Bearer …`, with the `anthropic-version: 2023-06-01`
  header attached for every request.
- **Cross-platform Settings search.** macOS, iOS/iPadOS, and Android Settings
  each gain a hand-authored manifest of every searchable control plus a
  shared-shape ranking engine (`title` × 3, `keywords` × 2, `subtitle` × 2,
  `helpText` × 1; AND-semantic tokens; diacritic-folded case-insensitive
  substring match; capped at 25 results). Tapping a result deep-links into
  the destination, scrolls the row into view, paints a brief halo, and —
  where supported — focuses the bound `@FocusState` / `FocusRequester`. macOS
  drives the existing sidebar tab selection plus a programmatic
  `NavigationStack(path:)` push; iOS uses `.searchable` over a `Form` with
  `navigationDestination(for: SettingsPageRoute.self)`; Android adds a
  `SettingsRootScreen` with a toggle-able top-bar search and routes from the
  You tab. Behavioral parity is pinned by `SettingsSearchEngineTests` on each
  platform plus a manifest-coverage test on macOS that fails the build if
  anchor / id uniqueness ever drifts.
- **One-click smart-display repair with proof.** Nest Hub and ULANZI Pixel
  Clock settings now share a `Make display work` action across macOS,
  iOS, and iPadOS. The Mac runs the full recovery path, streams typed
  repair status back through Firestore for mobile, and only marks a
  repair healthy when there is display proof: Nest Hub `/state.json`
  polling after cast/recast or Pixel Clock AWTRIX/stock-simulator frame
  acceptance.
- **Claude Code quota security posture.** Claude quota refresh no longer
  reads Claude Code's third-party Keychain item, no longer reads
  `~/.claude/.credentials.json`, and no longer writes refreshed OAuth
  tokens back into Claude Code files. The production path is now
  prompt-free by construction: statusline bridge snapshots first, local
  JSONL token counts next, and no automatic credential discovery.
  Internal OAuth usage tests now inject synthetic credentials explicitly,
  and a regression test scans the Claude quota source for forbidden
  credential-store access patterns.

### Fixed
- **Append-safe persistence across local, iCloud, and Firestore sync paths.**
  iCloud session mirroring no longer deletes mirrored records just because a
  local source path disappears; Firestore download watermarks advance only
  after a full page persists locally; shared-artifact transactions merge
  heads/revisions instead of replacing documents; remote device-local provider
  accounts are namespaced on collision; and Insight canvas imports now
  merge/preserve historical canvases instead of replacing or LRU-evicting
  them. Local provider routing event trails also persist full history instead
  of truncating storage to the display window. Regression coverage now
  exercises Firestore-only, iCloud-only, dual-sync, idempotent retry, failure
  retry, provider routing history, and insight-history preservation.
- **Mobile cloud-sync denial classification.** Android and iOS now split
  Firestore rules denials from App Check enforcement failures instead of
  showing every signed-in cloud-read failure as generic "Access denied";
  Android also reads the latest macOS `sync_status/{deviceId}` document
  instead of probing a stale `sync_status/latest` placeholder.
- **Android Streams now follows the canonical usage timestamp.** Android now
  orders and paginates `users/{uid}/usage` by `startTime`, matching iOS and
  the Cloud Functions schema, so usage rows without the old `timestamp` field
  no longer render as "No Activity Yet."
- **Local macOS App Check debug tokens work outside Debug builds.** When a
  local Firebase plist explicitly contains a registered App Check debug token,
  the macOS publisher uses the debug provider before falling back to
  App Attest/DeviceCheck.
- **Mac cloud-sync health publishes immediately.** The macOS app now writes
  `devices/{deviceId}` and `sync_status/{deviceId}` during the lightweight
  startup sync heartbeat, so mobile clients do not stay degraded while the
  heavier usage scan is delayed.
- **`PixelClockQuotaRenderer.awtrixPayload` missing `return`.** A drive-by
  fix while running the Claude robustness suite — the function was
  trailing-closure-returning but missing the explicit `return` keyword,
  which Swift 6's stricter inference now rejects. Added `return` so the
  `OpenBurnBarCore` module compiles cleanly for the test runner.
- **Maximized chat workspace + pop-out window (macOS).** The dashboard now
  has a dedicated **Chat** route — modeled after Claude.ai and ChatGPT —
  with a left thread rail, a centered conversation column (760pt reading
  width), a welcome state with insight-driven suggestion chips, and a
  centered composer. The floating `ChatPanel` keeps the same data and
  history but gains a **Maximize** button that swaps it for the full-canvas
  workspace, plus a **Pop out** button that hosts the same workspace inside
  a standalone resizable `NSWindow` (frame remembered between launches via
  `dashboardChatPopOutFrameJSON`). When the dashboard is on the chat route,
  the floating overlay and FAB are hidden so only one chat surface is
  visible at a time. The choice is sticky via the
  `dashboardChatPreferMaximized` `@AppStorage` flag, so future Hermes deep
  links open in the user's preferred surface. Backed by reusable
  `ChatHistoryRow`, `ChatMessagesStream`, and `HermesRuntimeGate` so the
  three surfaces stay coherent.
- **One-click Hermes launch on macOS.** Settings → Chat Gateway and the
  Hermes setup wizard can now open the Hermes Dashboard and local gateway
  together, with health readback and an opt-in startup toggle so both launch
  when OpenBurnBar opens.
- **Commercial launch README posture.** The README now describes the current
  product state as a commercial launch candidate for the iOS/App Store and
  hosted-cloud subscription path while keeping the macOS/source release
  explicitly labeled beta until that channel is cut.
- **Commercial hosted-cloud gates.** Firestore rules now require the
  Apple-verified `hosted_quota_sync` entitlement for conversation backup,
  chat-thread content backup, full session-log manifests/chunks, Hermes relay
  connections, and relay request/chunk writes while keeping free usage rows
  and metadata-only chat-thread sync available. The PR harness now runs the
  real Functions test suite and an emulator-backed Firestore rules suite
  (`functions/scripts/test-firestore-rules.mjs`) instead of echo-skipping
  those gates. App Store entitlement reconciliation now fails closed when ASC
  live status cannot be fetched, so a stale client JWS cannot mint paid cloud
  access during an Apple outage.
- **Conversation Atoms (macOS, iOS, iPadOS).** Hermes responses on every
  surface — macOS dashboard chat panel (`ChatPanel`), menu-bar popover
  (`HermesPopoverChatView`), mobile `ChatView`, and the iOS Hermes tab
  (`HermesTabView` / `HermesChatView`) — are now rendered through
  `HermesRichBubble` instead of a flat `Text(...)`. Hermes is instructed (via
  the new shared `HermesSystemPromptBuilder`) to wrap entities in
  `[label](burnbar://...)` markdown links, which a two-pass
  `HermesAtomParser` decodes into typed `HermesAtom` values: cost, session,
  provider, model, window, tool, project, tokens, quota, and Hermes runtime.
  Each atom renders as a tappable `HermesAtomChip` (SF-Symbol + label,
  accent per kind, atomic — never breaks across lines) that opens a
  quick-look detail (sheet on iOS, popover on macOS) wired through
  `HermesAtomNavigator`. A regex fallback also turns raw `$amounts` and
  known model identifiers into chips even when Hermes forgets to emit
  links. Bubbles wrap inside a `StreamingBubble` that measures the
  in-flight text via Pretext on every SSE chunk and animates
  `frame(height:)` between snapshots — and on completion runs
  `shrinkWrapWidth(targetLines: 4)` to animate the bubble's width down to
  its tightest comfortable size. **Activation pipeline:** when the user
  confirms a chip's primary action, `HermesAtomRouter.confirm(_:)` updates
  `confirmedDestination`, calls the chat surface's installed `onPerform`
  closure, and broadcasts `Notification.Name.hermesAtomActivated` with the
  typed `HermesAtom` so any top-level surface (sidebar, settings,
  dashboard) can route to the matching native view without coupling chat
  surfaces to specific destinations. Pretext infrastructure
  (`PretextEngine`, `PretextTypes`, themed `index.html` shell,
  `pretext.bundle.min.js`) was hoisted into `OpenBurnBarCore` so iOS and
  macOS share one bridge and one resource bundle (`Bundle.module`); chat
  surfaces eagerly call `PretextEngine.shared.start()` so the WKWebView
  loads before the first assistant turn. Tests in
  `OpenBurnBarCoreTests/HermesAtomParserTests.swift` (28 cases) cover
  markdown-link extraction, regex fallback for `$amounts` and known model
  IDs, mixed atoms+mentions+code, malformed URL fallback, ordering
  preservation, percent-encoded labels, Unicode (CJK + emoji) IDs, scheme
  rejection, and the no-op navigator's main-actor contract. **Docs:**
  [`docs/CONVERSATION_ATOMS.md`](docs/CONVERSATION_ATOMS.md) covers the URL
  scheme, the prompt directive, the activation pipeline, and the
  cross-platform component map.
- **Hermes chat attachments (macOS, iOS, iPadOS).** The Hermes composer now
  accepts file attachments on every surface — dashboard chat panel, popover
  strip, and mobile `ChatView`. Users can attach images, PDFs, audio,
  documents, and arbitrary files via paperclip menu, drag-and-drop, paste,
  Files-app picker, Photos-library picker, and on iPhone/iPad camera capture.
  Attachments are stored in a per-thread workspace (`HermesChats/<thread>/
  attachments/`), persist with the chat history on macOS (new
  `chat_message_attachments` migration + JSON column), and roundtrip across
  cloud sync as metadata only — never as binaries. Wire format follows the
  OpenAI multimodal spec (`image_url`, `input_audio`) with capability-based
  graceful degradation to inline text or workspace-path references when the
  active backend lacks vision/audio. Added 8 new encoder tests
  (`HermesAttachmentEncoderTests`).
- **iOS Pulse: Trend Atlas + Chart Studio.** Replaced the single-purpose
  `TrendSparkCard` with a tap-driven canvas system.
  - **Trend Atlas card** rotates three intricate scenes — provider-stacked
    stream graph with hour-of-day heat strip, "Lane Racer" model board with
    embedded sparklines and tok/s velocity, and a cache-hit constellation
    with ideal/actual guide rules. An auto-rotating insight strip below
    pulls from a 9-rule `TrendInsightEngine` (cache low/high, provider
    dominance, reasoning spikes, model champion, peak hour, weekend burn,
    writing speed, etc.).
  - **Chart Studio** is a full-screen AI canvas. Hermes streams back a
    typed JSON envelope that decodes to one of: native Swift Charts (10
    kinds — line, bar, stacked_bar, area, stacked_area, stream, scatter,
    heatmap, donut, rule), sandboxed Mermaid (offline `mermaid.min.js`
    11.4.1 in a `WKWebView`, sanitized against `<script>`, `javascript:`,
    inline `on*=` handlers), an "insight" narrative card, or a vertical
    `composed` stack of any of the above.
  - **Plumbing:** capped (≤12 KB) `TrendDataDigest` of rollups + recent
    sessions, strict JSON-only `ChartStudioPromptEngine` system prompt
    with three worked examples, and a `ChartStudioHermesBridge` SSE
    one-shot that does **not** pollute the main Hermes chat history.
    Recent canvases persist via `ChartStudioStore`.
  - **Docs:** [`docs/CHART_STUDIO.md`](docs/CHART_STUDIO.md) covers the
    wire format and architecture.
  - **Tests:** 22 new tests across `TrendDataDigestTests`,
    `TrendInsightEngineTests`, `ChartSpecRendererTests`,
    `MermaidSanitizationTests`, and `ChartStudioPromptEngineTests`. Full
    mobile suite: 180 passed, 2 skipped, 0 failed.

- **Factory Plus plan tier + rolling rate-limit vocabulary (May 2026
  pricing).** Factory's plans moved from a single monthly token bucket to
  rolling rate limits across three independent 5-hour / 7-day / 30-day
  windows, with Standard Usage consumed first and fallback to Droid Core
  (a separate free pool of open-weight models) or Extra Usage (prepaid
  USD credits, $10 minimum, no expiry). `FactoryQuotaPlanTier` now
  enumerates the published commercial tiers — **Pro** ($20/mo, 20M
  tokens/month), **Plus** ($100/mo, ~100M, ~5x Pro), and **Max** ($200/mo,
  ~200M, ~10x Pro) — plus the existing `.unknown` inferred-Pro default.
  Each tier exposes both a long `displayName` for menu pickers and a
  short `shortName` so the segmented popover picker doesn't overflow the
  340pt popover. `FactoryQuotaAdapter` now labels buckets "5-hour
  rolling" / "7-day rolling" / "Monthly · <tier>", uses a rolling 30-day
  reset (not a calendar-month boundary), and includes the Droid Core /
  Extra Usage fallback in every status message so users can find the
  escape hatch without leaving OpenBurnBar. Two new
  `ProviderQuotaServiceTests` cases cover the Plus 100M cap across all
  three rolling windows and the Droid Core / Extra Usage status copy
  guard. Plans are still per-org (not per-user) — Teams and Enterprise
  remain unaffected by rate-limit changes per Factory's docs.
- **Factory quota collection: lane-aware session classification + four
  new data fields from the billing API.** Reworked the local-session
  reader and `/api/organization/subscription/usage` parsing so every
  field Factory actually exposes lands in the popover, and so the headline
  burn number reflects what's truly billed against the plan:
  - **Lane-aware filtering (CRITICAL correctness fix).** Sessions with
    `providerLock != "factory"` are user-configured proxies (VibeProxy,
    OpenCode-Go, localhost Ollama, BYOK keys, …) routed through
    `config.json.custom_models[]`. They never touch Factory's billing,
    but the old reader summed every session into the Pro monthly cap.
    On a power-user machine that meant 1488 / 1514 sessions
    over-reported the burn by ~58x — the popover routinely showed
    "100% of plan" within a week of fresh installs. The new
    `FactorySessionClassifier` excludes custom-proxy sessions from
    every Standard Usage bucket and surfaces their total in a separate
    diagnostic `factory-custom-proxy-30d` bucket so the segregation is
    transparent. Status message now discloses the excluded count.
  - **Standard vs Droid Core split.** Factory-billed sessions are
    sub-classified by model family. Frontier closed-weight models
    (claude-*, gpt-*, gemini-*, o-series) count as Standard;
    open-weight families published as "Core" (kimi-k, glm-, deepseek-,
    minimax-, qwen, llama-, mistral-, gemma-) count as Droid Core.
    Two new diagnostic buckets — `factory-standard-30d` and
    `factory-droid-core-30d` — let users see at a glance which lane
    is burning their plan vs which lane is free. The `custom:` prefix
    and `:cloud-N` shard suffix the CLI adds for proxy routing are
    normalized before matching.
  - **Plan auto-detection from `/api/app/auth/me`.** `FactoryQuotaAdapter
    .inferPlanTier(tier:planName:)` now maps `factoryTier=plus` /
    `plan.name="Plus"` (and Pro / Max / ultra-as-Max) to the right
    `FactoryQuotaPlanTier` regardless of casing — so users on the
    Factory API path don't need to pick a tier in Settings →
    Providers. Enterprise / Teams stay `.unknown` (those plans aren't
    rate-limited per Factory's docs).
  - **Droid Core lane bucket from billing API.** When
    `/api/organization/subscription/usage` exposes a `droidCore` /
    `core` / `coreUsage` lane block, it renders as a new
    `factory-droid-core` bucket alongside Standard / Premium.
  - **Extra Usage prepaid wallet bucket.** New `factory-extra-usage`
    bucket carries the USD credit balance returned by the billing
    payload (handles `extraUsage` / `extra_usage` / `additionalUsage`
    / `prepaidBalance` field aliases plus cents-vs-dollars
    normalization). Label suffixes `(disabled)` when the
    `enabled: false` toggle is set so users see why a positive
    balance isn't being drawn down.
  - **Subscription status badge.** The popover status line now
    surfaces `trial` / `past_due` / `canceled` states from the Orb
    subscription block when not `active`.
  - **Tests:** Seven new `ProviderQuotaServiceTests` cover the proxy
    filter (multi-session fixture with VibeProxy + anthropic + factory
    rows), the Droid Core classification, the plan auto-detection
    matrix (Pro / Plus / Max / ultra-alias / Enterprise →
    `.unknown` / casing), the classifier's `custom:` and `:cloud-N`
    normalization, the Droid Core lane + Extra Usage wallet from the
    API, the disabled-wallet labeling, and the subscription status
    badge. Total `ProviderQuotaServiceTests` suite: 54 passing.

### Fixed
- **"Connect Kimi" → "Sign in with Google" no longer hangs on a
  spinning loader.** Kimi's web sign-in invokes `window.open()` to
  launch Google's OAuth consent screen in a popup, which a default
  `WKWebView` refuses (no `WKUIDelegate` ⇒ the popup never opens, and
  the in-modal Google button spins forever). `FactoryLoginHelper`'s
  `LoginRunner` now implements
  `WKUIDelegate.createWebViewWith(_:for:windowFeatures:)` to route
  popup-opening navigations into the main webview — the macOS-standard
  approach for in-app OAuth — and sets a Safari user-agent so Google's
  embedded-browser sniffer doesn't reject the consent screen with
  "This browser or app may not be secure". The same popup support is
  enabled for the Factory and Ollama login windows so users can sign
  in via Google / Apple / GitHub there too. The Kimi cookie matcher
  also broadens to capture every `kimi-*auth*` jar variant plus the
  NextAuth fallback (`next-auth.session-token`, `authjs.session-token`),
  with `kimi-auth` always preferred in the captured value so the
  `KimiQuotaAdapter` JWT requirement is satisfied immediately.
- **Factory quota popover stops insisting "Readable quota not available
  yet" when the local droid sessions are right there on disk.** The
  Factory adapter's local-session path
  (`~/.factory/sessions/**/*.settings.json`) was emitting buckets with
  `limitValue: nil`, but the displayability filter for `.tokens` requires
  a non-nil positive limit — so every 5h / 7d / 30d window the adapter
  computed got dropped before reaching the UI. Adapter now anchors each
  window to `FactoryQuotaPlanTier.monthlyTokenCap` (Pro = 20M, Plus =
  100M, Max = 200M) so the buckets carry real `usedPercent` /
  `remainingValue`. When the user has not picked a plan tier yet it falls
  back to Pro as an inferred cap, marks the snapshot `.estimated`, and
  surfaces a "Set your plan tier in Settings → Providers" prompt instead
  of a blank card. Two new `ProviderQuotaServiceTests` cases cover the
  confirmed-Pro path and the inferred-Pro fallback.
- **Ollama Cloud quota now actually reads after "Connect Ollama".** The
  WKWebView login flow has stored the captured `ollama.com` session cookie
  in Keychain under `ollama_cookie_header` for a while, and
  `QuotaRefreshActor`/`ProviderQuotaService` already forward it through
  `context.resolvedAPIKeys`. `OllamaQuotaAdapter.fetchCloudUsage` was passing
  `cookieHeader: nil` to `OllamaCloudScraper`, so the scraper short-circuited
  and the popover stuck on "Readable quota not available yet" even after a
  successful sign-in. The adapter now resolves the stored cookie (or the
  `OLLAMA_COOKIE_HEADER` env override) and replays it against
  `ollama.com/settings`, so session / weekly usage windows surface as
  `.exact` snapshots. Tightened the connect-time cookie matcher to capture
  whichever auth jar Ollama is currently issuing (Better Auth, NextAuth, or
  custom session names) and refreshed the status copy so the no-cookie case
  prompts users to connect instead of showing the generic "no quota" line.
  Covered by two new `ProviderQuotaServiceTests` cases — one asserts the
  stored cookie is replayed to `ollama.com/settings`, the other proves the
  adapter never touches `ollama.com` without a session and surfaces a
  "Connect Ollama" call to action.
- **iOS provider connect now actually works for MiniMax, Z.ai, and Factory.**
  The cloud function adapters were calling endpoints that no longer exist
  (MiniMax `api.minimax.chat/v1/user/info` → 404, Factory `api.tryforge.io` →
  NXDOMAIN), so every paste in `Add MiniMax` (and friends) bounced to the
  generic "Couldn't connect" failure screen. Replaced them with the
  current production endpoints used by the macOS app:
  - MiniMax → `https://www.minimax.io/v1/token_plan/remains` (with
    `coding_plan/remains` as a fallback when the user pastes an `sk-cp-…`
    Coding Plan key). Inline `base_resp.status_code` errors are now surfaced
    instead of being treated as success.
  - Z.ai → `https://api.z.ai/api/paas/v4/models` for validation, with
    automatic fallback to `open.bigmodel.cn`. Quota now reads from
    `monitor/usage/quota/limit` (Coding Plan windows) with the
    pay-as-you-go `user/balance` endpoint as a backup.
  - Factory → `https://api.factory.ai/api/app/auth/me` for validation and
    `/api/organization/subscription/usage?useCache=true` for quota lanes.
  Server callable errors are now wrapped in `HttpsError` with the actual
  upstream message (e.g. "login fail: Please carry the API secret key…")
  instead of bare `Error("invalid-argument: …")` strings that surfaced as
  generic INTERNAL errors on iOS.
- **iOS connect picker now matches the backend.** The mobile catalog
  previously listed `kimi`, `warp`, and `copilot` as connectable providers,
  but the cloud function had no adapters for them and rejected every
  attempt at the `assertProvider` check. Trimmed the catalog to the
  providers the server can validate end-to-end (Claude Code, Codex,
  Factory, Cursor, MiniMax, Z.ai, OpenAI). Updated the recommended
  ordering and the MiniMax/Z.ai onboarding copy with the real dashboard
  URLs.

### Added
- **`functions/scripts/test-providers.mjs` regression tests** for each
  rewritten adapter: validation against the right host, auth-failure
  short-circuits, coding-plan vs token-plan key routing for MiniMax,
  api.z.ai → bigmodel.cn fallback for Z.ai, and Factory's `detail` error
  passthrough. Wired into `npm test`.

## [Released earlier] — iPadOS Port Phase 2 Hardening (2026-05-02)

### Changed
- **Responsiveness/performance pass:** dashboard usage now caches date-window
  aggregates and builds provider/model summaries in one pass; quota refreshes
  are bounded and coalesced across popover/dashboard entry points; the database
  workspace rebuilds snapshots on debounced input changes instead of polling;
  startup defers the first heavy refresh; mobile quota/provider stores keep
  derived state cached and lower idle animation cadences. SQLite now carries
  token-usage indexes for sync, provider, model, and provider-id time-window
  queries.
- **Hermes accent: gold → dark platinum.** `hermesAureate` is no longer a divine
  gold (`#B8942E` / `#D4AA3C`) — it is now a sophisticated dark platinum
  (`#3F4651` light, `#A2ACBA` dark). The mercury gradient (silver → platinum) now
  reads as polished gunmetal instead of mercury → gold, giving the Hermes
  surfaces a colder, more premium feel that better matches the app's industrial
  / utilitarian aesthetic. Cascades through the entire app (nav tab accent,
  badges, send buttons, message strokes, sidebar marker, popover strip border).

### Added
- **Provider-connection onboarding wizard (iOS / iPadOS):** replaced the placeholder
  welcome/cloud/Hermes screens with a five-stage wizard that walks new users from
  sign-in to a connected first account — `welcome → pick → connect → review → done`.
  Picker tile grid surfaces recommended providers first; the connect step uses a
  shared `ProviderSetupGuide` registry (per-provider instructions, dashboard URL,
  supported credential kinds, paste hints, hosted/self-hosted gating) and ships
  the same component (`OnboardingProviderConnectStep`) the renovated manual sheet
  embeds, so muscle memory transfers between first-run and post-onboarding adds.
- **Renovated manual "Add Account" sheet (iOS / iPadOS):** `AddProviderConnectionView`
  is now a 3-sub-step guided flow (`guide → paste → connecting/result`) backed by
  `OnboardingProviderConnectStep`. Provider hints, dashboard links, and credential
  kind options are pulled from the same `ProviderSetupGuide`, ending duplicate copy
  between the wizard and manual surfaces. The "Available providers" list now shows
  a one-line setup hint per provider (e.g. *Cursor — "Sign in once, then we capture
  the cookie"*) so the list reads as a menu, not a wall of avatars.
- **Factory and OpenCode routed-client sync:** the provider gateway now proxies
  real `/v1/chat/completions` traffic through quota-aware route ranking and
  failover, and the macOS app can write OpenBurnBar Gateway entries into Factory
  and OpenCode configs so those clients share exhausted-plan rotation with Cursor.
- **Ollama Cloud routed provider:** Ollama Cloud is now a catalog-backed upstream
  for the same gateway path, including API-key slot rotation, `:cloud`/`-cloud`
  alias handling, native `/api/chat` proxy translation, and exhausted-plan
  failover for Cursor, Factory, and OpenCode.

### Fixed
- **Google SSO keychain recovery:** Firebase Auth now binds to the app's
  runtime Keychain access group before cloud auth. Google SSO also clears stale
  GoogleSignIn/Firebase Auth Keychain rows before retrying credential saves that
  failed with a Keychain access error.
- **Hermes Remote Relay App Check handoff:** debug/local Mac and iOS builds now
  export the App Check debug token from `GoogleService-Info.plist` before Firebase
  initializes, so a signed-in Mac can publish its encrypted relay record for
  mobile discovery instead of falling through to rejected DeviceCheck requests.
- **Usage history no longer appears capped at 5,000 sessions:** dashboard
  refreshes now hydrate the recent 5,000 rows first for fast startup, then
  complete with an uncapped database read so all-time totals and session counts
  converge to the full local history.
- **Dashboard agent/model ranking correctness:** token mode now ranks providers,
  models, and model/provider drill-down stacks by token volume instead of
  spend; currency mode still ranks by spend. Kimi imports now reject
  `chatcmpl-*` request ids as model names, and the database repair drops or
  normalizes existing Kimi request-id rows so the Kimi agent bucket is not
  inflated by stale model identity pollution.
- **Cursor "Included usage" gauge renders as currency on iOS / iPadOS:**
  `ProviderQuotaUnit` gains a `.currency` case; `CursorQuotaAdapter` flips the
  `cursor-plan` and `cursor-ondemand` buckets to `.currency` (they already store
  dollars, not percentages). `UnifiedQuotaSignalView` reads `meta["unit"]` and
  formats `$0.39 / $3.61 / $4.00` instead of `39 / 361 / 400`. Mobile receives
  the corrected unit automatically via the existing `QuotaSnapshotSyncService`
  schema — no Firestore migration needed.

### Added
- **iOS App Store release runbook and ASC review tooling:** documented the
  iOS submission path in `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md`, including
  reviewer account seeding, subscription selection, build compliance,
  manual-release mode, and final-submit confirmation gates. The App Store
  Connect helper can now patch build encryption compliance, set manual release,
  and upsert App Review credentials/notes with redacted local credential input.
- **Routing-aware provider account cockpit (Mac + Mobile):** every quota- and
  account-bearing surface now shows which provider account is *currently* serving
  traffic, the next fallback, and any blocked/cooling-down accounts with
  sanitized switch reasons — never credential material. Mac surfaces in scope:
  `ProvidersSettingsView`, `ProviderDashboardQuotaPanel`, expanded popover
  rows. Mobile/iPad surfaces in scope: `QuotaView` cards, `QuotaDetailSheet`,
  `ProviderConnectionsView` group sections (with per-account
  Active/Next/Blocked chips), and `ProviderDashboardView` quota section.
  Backed by the existing `ProviderRoutingPolicy.decide` contract — no new
  routing semantics, just unified visualization.
- **Single source of truth for `AgentProvider` / `TokenUsage`:** the
  ~600-line macOS-only `AgentLens.AgentProvider` and `AgentLens.TokenUsage`
  duplicate definitions are deleted. The macOS app now uses
  `OpenBurnBarCore.AgentProvider`, `OpenBurnBarCore.TokenUsage`,
  `UsageProvenanceMethod`, `UsageProvenanceConfidence`, and `UsageSource`
  as the canonical types via thin module-level typealiases in
  `AgentLens/Models/AgentProvider.swift`. Mac-only behaviors
  (`logDirectory`, `filePattern`, `supportLevel`, `dataConfidence`,
  per-row `cacheEfficiency`, `CacheEfficiency.aggregate(_:)`) live as
  extensions on the package types so the macOS file watcher and dashboard
  surfaces still compile. The Mac module shrank by **−421 lines (−56%)**
  in `AgentProvider.swift`. RawValues, Codable keys, and init signatures
  were verified byte-identical before the consolidation, so SQLite rows
  and Firestore docs persist losslessly across the change. `ProviderSummary`,
  `ModelSummary`, and `ProviderUsage` carry an aggregate
  `OpenBurnBarCore.CacheEfficiency` so dashboard cache hit rate badges work
  end-to-end.
- **`scripts/clear-xcode-caches.sh`:** repo helper to clear DerivedData,
  SwiftPM caches, and XCFramework device-support caches. Use after
  shared-core migrations when SourceKit shows ghost errors or XCFramework
  symbol mismatches between Mac and Mobile targets. Supports `--dry-run`,
  `--derived-only`, `--xcframeworks`, `--packages`.
- **First-class provider accounts:** shared `ProviderAccountDoc` contracts,
  local SQLite persistence, account-aware quota snapshots, usage rollup account
  summaries, Cloud Functions account APIs, and mobile provider/account lists.
- **OpenAI provider accounts:** OpenAI is now a catalog-backed provider identity
  with backend credential validation and usage refresh through the OpenAI
  organization usage endpoint.
- **iPad Onboarding Wizard (`iPadOnboardingWizardView`):** 4-step onboarding (Welcome → Cloud Connect → Hermes Setup → Complete) with staggered entrance animations, progress dots, skip functionality, and `@AppStorage` persistence. Presented from `AuthGateView` on first launch.
- **Live Activity Infrastructure (`BurnBarLiveActivityAttributes`, `LiveActivityManager`, `BurnBarLiveActivityWidget`):** Lock screen banner + Dynamic Island with real-time cost, tokens, top provider, and pulsing session-active dot. Auto-managed by `DashboardStore`. All ActivityKit code guarded with `#available(iOS 16.1, *)`.
- **Siri Shortcuts Intent (`BurnBarStatusIntent`):** Voice query "What's my burn today?" returns cost, tokens, and provider count.
- **Deep Linking (`burnbar://dashboard`, `burnbar://settings`, `burnbar://chat`):** Handled in `OpenBurnBarMobileApp` via `.onOpenURL`. Widget tap routes to dashboard via `widgetURL`.
- **iPad Navigation UI Tests (`iPadNavigationUITests`):** 14 tests covering route model, settings tabs, auth gate, provider aggregates, Hermes state, session search, and deep links.
- **Keyboard Shortcuts:** ⌘1–4 (navigation), ⌘R (refresh), ⌘H (Hermes), ⌘, (settings), ⌘[ (back).

### Changed
- Provider quota sync now uploads non-secret provider account metadata and
  account-scoped snapshots so iPhone/iPad can show cloud-refreshable and
  Mac-local accounts honestly.
- **`DashboardView`:** Staggered entrance animations, chart entrance, hover scale on all interactive rows.
- **`ChatView`:** Real Hermes SSE streaming (`HermesService`), connection status bar, graceful error bubbles.
- **Settings:** All 7 tabs have real data — live Firestore provider connections, alert sliders, system settings link, multi-profile switcher.
- **Session search:** Expanded from 3 → 6 fields (session ID, cost, device name added).
- **Widget `Info.plist`:** Removed invalid `NSExtensionPrincipalClass` that blocked simulator installs.

### Fixed
- Secret Manager version names are kept out of public provider account docs and
  destroy-failure logs.
- `ProviderDashboardStoreTests` compilation (`usages` access).
- `FirestoreNormalizationTests` `TimeInterval?` coercion.
- Auth identity label showing raw email instead of provider.

## [0.1.3-beta.1] — 2026-05-01

### Added
- **Warp provider (`AgentProvider.warp`):** New parser, quota adapter, brand identity, tests.
- **App test driver (`scripts/test-openburnbar-app.sh`):** Retry logic, hang detection, JSONL telemetry.
- **Test-host short-circuit (`AgentLensApp`):** Skips Firebase/Sentry/DataStore when XCTest-injected.
- **Provider stable persistence token (`AgentProvider.persistedToken`).**
- **Synchronous test mode for settings persistence.**
- **Executable-path injection on `SwitcherCLIAuthCoordinator.Dependencies`.**

### Changed
- `SettingsPersistenceCoordinator` legacy migration scoped to `UserDefaults.standard`.
- Settings min-clamp policy falls back to default instead of floor.
- `TokenExtractionUtility.normalizeModelName` case-insensitive `custom:` strip.
- `TokenExtractionUtility.detectModelHint` captures first token only.
- `AlertSettings.costAlertThreshold = nil` fully removes keys.
- `SettingsSecretPersistence` no longer deletes legacy on keychain failure.
- `KeychainStore.set` verifies write bytes.
- `ProviderPathSettings` persists under `logPath_<persistedToken>`.

### Fixed
- DataStore-pollution test isolation.
- Snapshot reference refresh (22 images).
- `TimestampNormalizationTests` UTC-anchored calendar.
- Mobile app data-loading after auth (Firestore shape mismatches, Timestamp→Double, ISO date→Double, `sanitizeForJSON`, `decodeWithDocID`).
- `FirestoreRepository` reliability (typed errors, exponential backoff).
- Protocol-oriented normalization (`FirestoreNormalizable`).

## [Unreleased] — Server-side Apple JWS Verification (2026-05-04)

### Added
- **Full Apple App Store JWS verification pipeline (`functions/src/appstore/`).**
  Hosted-quota entitlements are now derived from chain-verified, live-reconciled
  Apple state. Replaces the v1 callable that only stored a SHA-256 of a
  client-supplied JWS.
  - `verifier.ts` — `AppleJWSVerifier` wraps `@apple/app-store-server-library`
    against three vendored root certificates (`AppleRootCA-G3`, `AppleRootCA-G2`,
    `AppleIncRootCertificate`) with SHA-256 fingerprint pinning enforced at
    cold start. Per-environment `SignedDataVerifier` instances, optional
    `autoFallbackEnvironment` retry, and stable `apple-jws-…` error codes.
  - `client.ts` — Cached `AppStoreServerAPIClient` per environment; surfaces
    `getAllSubscriptionStatuses` and `getTransactionInfo` for live reconciliation.
  - `reconciler.ts` — Single writer for `users/{uid}/entitlements/hosted_quota_sync`.
    Resolves UID via `appAccountToken` ↔ `entitlement_bindings`, picks the
    most recent `signedDate` transaction across the JWS + ASC view, enforces
    monotonicity on `lastVerifiedAt`, and merges stable fields forward.
  - `audit.ts` — Append-only `users/{uid}/entitlement_events/{eventId}` with
    `notificationUUID`-keyed idempotency, `signedTransactionInfo`/
    `signedRenewalInfo`/`signedPayload` redaction (raw JWS hashed,
    `appAccountToken` truncated).
  - `notifications.ts` — Public `appStoreServerNotificationsV2` HTTPS
    endpoint; verifies S2S `signedPayload`, distinguishes 4xx (terminal
    invalid) from 5xx (Apple-retry), idempotent on `notificationUUID`.
  - `scheduled.ts` — Daily `reconcileHostedEntitlementsDaily` rebuilds
    every active entitlement from ASC truth so missed webhooks converge
    within 24h.
  - `callable.ts` — Three iOS-facing callables: `beginEntitlementBinding`
    (mints `appAccountToken` UUID before purchase),
    `verifyHostedQuotaEntitlement` (verifies + reconciles a JWS),
    `restoreHostedQuotaEntitlement` (re-runs reconciliation for the
    signed-in user's known `originalTransactionID`).
- **Pinned Apple root certificates.** DER-encoded certs vendored under
  `functions/src/appstore/certs/` and copied to `lib/` by
  `scripts/copy-certs.mjs` (chained from `npm run build`). SHA-256
  fingerprints pinned in `verifier.ts:ROOT_CERT_FILES`.
- **`HostedQuotaEntitlementDoc` schema v2** (`schemaVersion: 2`,
  `verificationVersion: 2`, `source: "apple_jws_verified"`). Adds
  `revokedAt`, `revocationReason`, `environment`, `ownershipType`,
  `appAccountToken`, `signedTransactionHash`, `lastNotificationUUID`,
  `lastVerifiedAt`. Carries forward stable fields when a JWS omits them.
- **`EntitlementBindingDoc`** at `users/{uid}/entitlement_bindings/{token}` —
  server-only collection that maps a server-minted UUID to a Firebase UID
  pre-purchase. Required to attribute incoming JWS payloads when the
  callable was untrusted (e.g. S2S notifications).
- **`EntitlementEventDoc`** append-only audit log surfaced under
  `users/{uid}/entitlement_events/{eventId}` for forensics.
- **iOS `HostedQuotaSubscriptionStore` rewritten** for the new pipeline.
  Mints `appAccountToken` via `beginEntitlementBinding`, passes it through
  `Product.PurchaseOption.appAccountToken`, forwards the JWS to
  `verifyHostedQuotaEntitlement`, observes `Transaction.updates` for
  renewals/revocations, and adds `restorePurchases()` backed by
  `restoreHostedQuotaEntitlement`. Prefers the server's view of
  inactivity over the local StoreKit cache.
- **Firestore rules (`firestore.rules`):** server-only writes to
  `users/{uid}/entitlements/*` and `users/{uid}/entitlement_events/*`;
  `users/{uid}/entitlement_bindings/*` denied to clients for both reads
  and writes.
- **Regression suite (`functions/scripts/test-appstore.mjs`):** 31
  `node:test` cases covering root cert fingerprint pinning, environment
  enum round-trip, reconciler selection / merge / monotonicity logic,
  audit redaction + idempotency, binding doc construction, and stable
  error codes. Wired into `npm test` via `npm run test:appstore`.
- **`@apple/app-store-server-library` v3** added to `functions/package.json`.

### Security
- Trust pipeline: every entitlement field is now derived from a chain-verified
  Apple JWS, reconciled against live App Store Server API truth, and bound
  to a Firebase UID via a server-minted `appAccountToken`. Client-supplied
  values are no longer authoritative for activation, expiration, or
  ownership — see `docs/THREAT_MODEL.md` § "Hosted Quota Subscription".
- `entitlement_events` audit log makes every state change reviewable by
  the owner and replayable from raw JWS hashes.

### Migration notes
- Legacy v1 entitlement docs (where the server stored only a SHA-256 of a
  client-supplied JWS) keep their fields untouched until the next verified
  event. The first call into `verifyHostedQuotaEntitlement` /
  `restoreHostedQuotaEntitlement` upgrades the doc to schema v2 in place.
- Operators must populate `APP_STORE_ASC_KEY_ID`, `APP_STORE_ASC_ISSUER_ID`,
  and `APP_STORE_ASC_KEY_P8` via Secret Manager before the production
  callables are reachable; see `docs/HOSTED_QUOTA_SYNC.md`
  § "App Store JWS verification config".

## [Unreleased] — iOS / iPad Visual Depth & Polish Pass (2026-05-04)

### Added
- **38 provider logos shipped to iOS bundle:** all `AgentProvider.allCases` now have bundled image assets in `OpenBurnBarMobile/Resources/Assets.xcassets`, resolving the long-standing gap where iOS showed only SF Symbol fallbacks.
- **`ProviderAvatar` — canonical avatar component:** replaces `ProviderBadge` everywhere with three display modes (`.plain`, `.tile`, `.aurora`). The `.aurora` mode renders a radial glow, gradient ring, and `glassEffect()` on iOS 26+.
- **`EmberSurfaceBackground` — reusable brand backdrop:** promoted from `SignInScene` into `OpenBurnBarCore`. Warm gradient + drifting ember orbs + floating particles in dark mode; botanical cream wash in light mode. Respects `accessibilityReduceMotion` and `accessibilityReduceTransparency`.
- **`EmberSkeleton` — branded skeleton loading:** warm ember-tinted shimmer band on `surfaceElevated` base. Respects `accessibilityReduceMotion`.
- **`Haptics` — centralized feedback helper:** debounced impact/notification/selection generators hooked to period switches, refresh, quota thresholds, Hermes send, and errors.
- **`MercuryThinkingIndicator` — mercury pool animation:** three droplets that pool and separate (1.8s cycle, 0.3s stagger), replacing the old 3-dot pulse in `ChatView`.
- **`MercuryShimmerOverlay` — slow shimmer stroke:** mercury-tinted gradient band for assistant chat bubble overlays.
- **`FlameRefreshIndicator` — branded pull-to-refresh:** rotating flame spinner.
- **`RollingNumberText` — numeric transition wrapper:** `.numericText(countsDown:)` with proper font/scale handling.
- **iPad onboarding wizard upgrade:** animated SF Symbol scenes (`symbolEffect(.bounce/.pulse/.variableColor)`) layered over the ember backdrop with a continuous progress capsule.
- **iPad placeholder views (`ProjectsView`, `MissionsView`, `ModelDashboardView`):** meaningful shells with animated symbols, "Coming in v0.2" badges, and ember backdrops.
- **Widget refresh:** `HeroSmallView`, `CostSparklineMediumView`, and `DashboardLargeView` now use `UnifiedProviderLogoView` for the top provider. Sparkline gets soft area gradient + glow on the trailing dot. Live Activity expanded center swaps `flame.fill` for the active provider's logo.

### Changed
- **`DashboardView`:** `UnifiedGlassCard` hero with aurora avatar, rolling cost number with trend delta, `AreaMark` + `LineMark` chart with provider-tinted gradient, `RuleMark` annotation for today, iPad velocity sparkline in 2-column layout.
- **`QuotaView`:** glass cards with aurora avatars, `UnifiedQuotaSignalView` battery bars, warning/healthy section halos.
- **`ActivityView`:** grouped by day with sticky headers, provider-colored 3pt rail, monospaced token badge, glass `UnifiedGlassCard` rows, search result transitions.
- **`SessionDetailView`:** hero panel with aurora avatar, animated horizontal token-mix bar with provider chart palette, inset glass panels for provenance/device.
- **`AccountView`:** animated gradient halo around avatar (12s rotation), live account health line, pulsing sync dot, overlapping aurora avatars for connections, destructive sign-out with `confirmationDialog`.
- **`ChatView` (Hermes):** assistant bubbles get `mercuryGradient` 1pt stroke + shimmer overlay, caduceus glyph (`☿`) prefix, "via Hermes" badge, glass input bar with `glassEffect()` on iOS 26+.
- **`RootTabView`:** iOS 18+ value-based `Tab` API with `Tab(role: .search)`. iOS 26+ `tabBarMinimizeBehavior(.onScrollDown)`.
- **`RootNavigationView`:** glass sync health pill with pulsing dot + last-sync timestamp, keyboard shortcuts (`⌘1–4`, `⌘H`, `⌘,`) wired to sidebar items.
- **iPad settings views:** `.grouped` forms with `scrollContentBackground(.hidden)` so the ember backdrop shows through subtly.
- **`QuotaDetailSheet`:** provider hero with aurora avatar + gradient backdrop, horizontally swipable account card carousel, stats row for confidence/source/freshness.

### Tests
- `OpenBurnBarMobileTests/ProviderAvatarTests.swift`: asserts every `AgentProvider.allCases` resolves a bundled image asset.
