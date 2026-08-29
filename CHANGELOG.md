# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- First-party collector now rate-limits before buffering, rejects unreviewed
  collector hosts (including non-default ports and credentials), drops events
  that miss their per-event schema, remints a session spine after revoke,
  finishes device-id creation before the browser transport marks itself
  started, bounds client timestamps, and does not recapture campaign
  attribution after decline. Website `app.opened` accepts page surfaces.
  Funnel events require a surface. Allowlisted product events require
  their taxonomy properties after sanitize (`arena.vote.recorded` needs
  `choice`/`rubric`; `auth.sign_in.completed` needs `method`/`outcome`;
  `download.cta.clicked` needs `placement`; `pricing.cta.clicked` needs
  `plan`; `nav.external.clicked` needs `destination`;
  `consent.analytics.granted` needs bounded `consent_version`). This
  website collector rejects native funnel surfaces and `install.started`.
  Per-event property sets drop cross-event dimensions and stamp the
  registry category. The session marker is written only when the
  collector can send. `email.captured` dedupes per hashed account, not
  the whole browser. `error.handled` requires bounded `error_category`
  plus `surface`. The collector stamps `platform: web` on every event.
  Website collector drops `nav.route.changed`. Email-capture markers are
  written only when the collector can send. Extension first-activation
  ignores a synced opt-in setting. `app.session.started` requires
  `is_first_launch` and `cold_start`; website `boot()` stamps both.
  Pre-consent email captures keep a hashed pending signal on the
  session store and flush it from that same store on grant. `screen.viewed` requires `is_first_view`. Every accepted website
  event needs a website `surface`. Foreign origins are rejected before
  the collector rate limiter.
  Production hosting may only pin `collect.burnbar.ai`; staging may only
  pin `collect-staging.burnbar.ai`. Rejected campaign params clear the
  stored bag. `email.captured` fires once per fresh account, never a
  restored auth session. The collector reuses one isolate-local limiter
  when the Wrangler binding is absent.
- `openburnbar app install` (npm 0.2.2) no longer aborts a verified macOS DMG when the
  public feed advertises a SemVer tag with `+repair.N` (for example
  `1.0.40+repair.34` build 81) and the mounted app's
  `CFBundleShortVersionString` is the Apple-visible marketing version
  (`1.0.40` build 81). Apple forbids `+` in the bundle string; the feed keeps
  the immutable tag. Same-build marketing-version pairs now install; a
  different marketing version or build still refuses.
- Android now compiles and targets Android 16 (API level 36) across the app,
  native bridge libraries, and macrobenchmark producer. Google Play publishing
  also reads the signed AAB manifest and fails before authentication unless the
  exact artifact targets API 36, closing the August 31, 2026 target-level
  requirement without relying on a deadline extension.
- Release rollback packaging now binds the app release version and shared Rust
  core version as separate identities, so a valid app release is no longer
  blocked when the retained rollback core has its own independent version.
- Prime Agent gateway proxy resolves the auth token headlessly
  (`scripts/prime-agent-openburnbar-proxy.mjs`) — non-interactive shells (SSH,
  CI, subagents) fell through to the `openburnbar-local` placeholder and got 401s
  from the gateway. The emitted `apiKey` resolver now checks
  `$OPENBURNBAR_GATEWAY_AUTH_TOKEN` first, then the daemon LaunchAgent plist,
  then `openburnbar-local`, and `--live` probes follow the same order. The
  Keychain rung was **removed rather than reordered**: it had been querying a
  service/account pair the app never writes (dead since it was added), and
  querying the real pair (`com.openburnbar.chat-gateway-secrets` /
  `settings.gateway.http.authToken`) either blocks on a GUI authorization prompt
  or fails with `errSecInteractionNotAllowed`, because the item's ACL is
  app-scoped. The plist carries the same token by construction. Each rung also
  emits `printf '%s\n'` instead of `echo`, which was corrupting any token
  containing a backslash. A new `--token <tok>` / `--api-key <tok>` flag embeds a
  static token directly into `models.json`. `--print` previews the resolver
  verbatim (so `--print > models.json` works) and, with `--token`, redacts the
  literal to `<redacted: static gateway token>` plus a stderr warning that the
  preview is not a usable config; `--status` never shows the credential field.
  Locked by `scripts/prime-agent-openburnbar-proxy.test.mjs` in fast-feedback.
  Docs: `docs/PROVIDERS.md` → Prime Agent via OpenBurnBar Gateway.
- Prime Agent gateway proxy stops reporting success while writing a config that
  cannot work. A `models.json` whose root was a JSON array — or whose `providers`
  was an array — took the merge silently, because `JSON.stringify` drops named
  properties assigned to an array: the run printed `Synced openburnbar provider
  … models: 155` and wrote the original file straight back. Those shapes are now
  reported with the path and left untouched. `--gateway-host`/`--gateway-port`
  are validated before any read or write, so `--gateway-port abc` fails fast
  instead of embedding `http://127.0.0.1:NaN/v1`; IPv6 literals are bracketed;
  and the gateway URL is built in one place rather than concatenated at six call
  sites. `--remove --print` now emits the providers that actually survive the
  delete (it claimed an empty set) with its prose on stderr, so its stdout is
  valid JSON like every other `--print` mode. `--help` renders the header as help
  text instead of spilling `import` statements at the reader.
- Close SQLCipher before `NSApplication` calls `exit()`, so a quit (including
  the installed app terminating a DerivedData duplicate) cannot SIGSEGV inside
  `sqlcipher_memset` on a live GRDB reader. Concurrent usage hydration now
  parses SQLite timestamps without a shared `DateFormatter`.

### Added
- **Opt-in Amplitude funnel contract** — shared CMO acquisition events
  (`page.viewed`, `app.opened`, `cta.clicked`, `download.clicked`,
  `install.started`, `email.captured`) in `analytics/funnel-contract.ts`,
  wired through the existing default-off consent gate. The marketing site
  now POSTs to a first-party collector (`workers/analytics-collector/`) so
  the browser never holds `AMPLITUDE_API_KEY`. Production project is
  OpenBurnBar `830583`; Dev is `830581`. CubeLove `852537` and Hormiga
  `703455` / `799824` are rejected. Native apps emit `app.opened` /
  `install.started` only after the existing Settings opt-in (still off by
  default). The VS Code extension emits `install.started` on first activation
  after opt-in. Official `release.yml` injects optional native and extension
  keys; unset keeps shipping binaries dark. The collector drops unbounded
  / phone-shaped property values before Amplitude. `csp:check` stays on the committed dark CSP;
  `deploy-hosting.yml` runs `csp:update` when `PUBLIC_ANALYTICS_COLLECTOR_URL`
  is set. Docs: `README.md` § Opt-in analytics, `docs/analytics/`.
- **Monthly Recap** (`docs/RECAP.md`) — a new destination that reads a calendar
  month of AI usage back as an editorial deck of cards: favourite model and
  model+harness pairing, weekday and late-night habits, streaks, project focus,
  personal records, month-over-month change, and a closing "your month in a
  sentence". Shared engine (`OpenBurnBarInsights/Services/Recap`) and shared
  SwiftUI card system (`OpenBurnBarUI/Views/Recap`) render on macOS (sidebar,
  3 columns), iPad (tray, 2 columns) and iPhone (Insights banner, 1 column).
  Every statistic is computed locally by ~30 rules with per-rule data floors and
  computed significance; an opt-in LLM layer may only select, order and re-word
  those candidates, and a numeric-containment guard rejects any figure it cannot
  trace back to that card's own metrics. Project names are tokenized and
  candidate ids are opaque before anything leaves the device. Completed months
  seal so a past recap never rewrites itself. Cards export as 1080×1350 /
  1080×1080 PNGs. This is also the first production caller of the previously
  unwired `CadenceScheduler` monthly slot.

- **Vercel fx provider support** (`docs/PROVIDERS.md`) — Added Vercel `fx` (fx.sh)
  as a first-class provider across all layers: exact usage parsing from `~/.fx/sessions/`
  with `usage-v2.json` cost calculations and `events.jsonl` transcript ingestion,
  interactive REPL terminal launcher, `fx ask --json` chat engine streaming parser with
  multi-turn `--resume` session support, desktop grant mission policies, switcher discovery
  and authentication coordinators, and cross-platform provider parity across macOS,
  Android, Windows, Linux, and iOS.
### Security
- Mission create, claim, host status, cancel, and event append are server-owned
  Admin-SDK callables. Client creates and host merges of
  `cli_agent_mission_requests` are denied. The server trusts the attested Mac
  and never re-evaluates daemon policy.
- `burnbar_attachments` finalize-once against GCS generation, quotas from
  `getMetadata`, and OBFS1 chunked AEAD with stored random 12-byte IVs.
- Mac-signed mission pre-auth answers/ceilings; grok-bot input requires a peer
  credential (uid/pid) or compared 0600 token bytes. Unauthenticated loopback
  and non-loopback peers are rejected.

### Added
- **Local D box (Developer ID, default off)** — Settings → Agents lists live Grok Bot D box agents by UUID and can send one a prompt over `127.0.0.1`. Send is refused unless shim `:1337`, host `:1338`, and inference `:8787` are up. Turn follow uses `listAgents` plus a read-only `store.db` window when the roster includes `path`. See [`docs/GROK_D_LOCAL_BOX.md`](docs/GROK_D_LOCAL_BOX.md).
- **The Safari web extension is buildable again** (`docs/SAFARI_EXTENSION.md`) — the
  committed `extensions/safari/dist/` bundle had no source in the repo, so it could only
  be replaced by hand. Its TypeScript project is restored: `npm run build` reproduces the
  bundle byte for byte, and CI fails a source change that lands without its rebuilt
  output. The restored build also supersedes a stale snapshot that predated twelve fixes
  and shipped without its provider assets.
- The MV3 background is typechecked with no DOM lib (`tsconfig.background.json`), so a
  `window.*` call in the service worker fails at compile time instead of silently
  truncating every streamed Ask answer, and CI asserts the built bundle stays free of
  `window.` references.
- Catalog-generated mission runtime allowlists. Grok ACP, kimi ACP, and
  Antigravity argv launch paths per `docs/decisions/2026-08-19-acp-vs-argv.md`.

### Added (file plane)
- OBFS1 chunked AEAD with stored random 12-byte IVs. Cloud attachments cap at
  10GiB; P2P iroh landing stays 2GiB. Production GCS storage port; compose
  cannot un-finalize. Mac landing requires a verified blake3 (never SHA-256
  compared to contentBlake3).
- Catalog-generated mission runtime allowlists; grok/kimi ACP stdio JSON-RPC
  (not argv-only hang) and Antigravity argv per
  `docs/decisions/2026-08-19-acp-vs-argv.md`.
- Per-session `interrupt` distinct from Computer Use `panicHalt`, registered on
  the live CLI/ACP process and wired from Agent Control.
- Agent Control composer mounted on the live Computer Use maximize stage.

### Known blockers
- iOS Share Extension **appex target** is not in this train. The main app now
  processes a share-inbox directory via `BurnbarShareInboxProcessor` and
  `beginBurnbarAttachment`. Android `ACTION_SEND` copies then begins + chunked
  PUT. Do not claim iOS share-extension-to-Drive ready.

### Fixed
- The cloud screenshot disclosure is honored as a **session** acknowledgement again. It
  had begun persisting to `storage.local`, so acknowledging once let screenshots reach a
  cloud model from every later Safari session, contradicting the disclosure's own "for
  this session" wording. Acknowledgements now clear with the native session, and one
  stored by an earlier build is ignored.
- Safari content scripts validate only the API surface Safari actually gives them.
  Requiring the privileged `tabs`, `scripting`, and `permissions` namespaces threw before
  the content listener registered, disabling page extraction, screenshots, and every page
  action.
- A failed native attach no longer latches the extension offline until Safari restarts —
  the next popup open retries `bridge.hello`.
- Answering Safari's permission sheet slowly no longer fails the request. A scheduled
  refresh could advance the controller state version while the modal sheet was open, so
  access was rejected as a page change after Safari had already granted it.
- The Safari extension version tracks `MARKETING_VERSION`; it had drifted to 1.0.34 while
  the app shipped 1.0.40, and all three version surfaces are now gated.
- **Monthly Recap** (`docs/RECAP.md`) — a new destination that reads a calendar
  month of AI usage back as an editorial deck of cards: favourite model and
  model+harness pairing, weekday and late-night habits, streaks, project focus,
  personal records, month-over-month change, and a closing "your month in a
  sentence". Shared engine (`OpenBurnBarInsights/Services/Recap`) and shared
  SwiftUI card system (`OpenBurnBarUI/Views/Recap`) render on macOS (sidebar,
  3 columns), iPad (tray, 2 columns) and iPhone (Insights banner, 1 column).
  Every statistic is computed locally by ~30 rules with per-rule data floors and
  computed significance; an opt-in LLM layer may only select, order and re-word
  those candidates, and a numeric-containment guard rejects any figure it cannot
  trace back to that card's own metrics. Project names are tokenized and
  candidate ids are opaque before anything leaves the device. Completed months
  seal so a past recap never rewrites itself. Cards export as 1080×1350 /
  1080×1080 PNGs. The recap builds when the page is opened; scheduled monthly
  delivery via `CadenceScheduler` is not wired yet.


- **Vercel fx provider support** (`docs/PROVIDERS.md`) — Added Vercel `fx` (fx.sh)
  as a first-class provider across all layers: exact usage parsing from `~/.fx/sessions/`
  with `usage-v2.json` cost calculations and `events.jsonl` transcript ingestion,
  interactive REPL terminal launcher, `fx ask --json` chat engine streaming parser with
  multi-turn `--resume` session support, desktop grant mission policies, switcher discovery
  and authentication coordinators, and cross-platform provider parity across macOS,
  Android, Windows, Linux, and iOS.
## [1.0.40] - 2026-08-18

### Fixed
- Repair the Functions release-gate fixture so notification events include a
  future expiry timestamp, matching the production event contract.
- Advance the macOS, daemon, extension, Android fallback, Windows manifest, and
  release documentation surfaces to build 81 / version 1.0.40.

## [1.0.39] - 2026-08-18

### Fixed
- Bind the emergency release packet and all version surfaces to the new
  protected-main v1.0.39 successor after the immutable v1.0.36 candidate and
  stale-evidence v1.0.38 preflight were both held before publication.

### Added
- **War Room: the Wire dials, the Flame routes, and the fleet gets two faces**
  (`docs/WAR_ROOM.md`) — the multi-machine plan lands end to end on top of the
  identity spine below. The **Wire** grows its remaining three layers: a frame
  codec for the eight `war` frames, a fail-closed handshake state machine whose
  fleet and dispatch frames return nothing until the lane is admitted (and whose
  refusal yields *fall back to Firestore*, not an error), and a dialer that
  drives both over a real iroh transport. The **Flame** becomes a router with a
  hand — `FlameDispatchPlanner` turns a routing decision into a dispatch,
  refusing rather than aiming a mission at nothing, and missions carry an
  advisory `targetBodyID` that steers work without letting anyone force a
  machine to run it. The daemon exposes the Flame over three RPC methods
  (`war.flame.route`, `war.flame.distill.list`, `war.flame.distill.settle`) and
  archives every decision — including the ones that routed nowhere — into a
  bounded distill log, because a router that only remembers its successes cannot
  be audited. Two new surfaces in Settings → Devices & Sync: the **Hermes Room**,
  whose "can I move Hermes there?" answer *is* the Wire's admission decision so
  it can never promise a swap the Wire will deny, and the **Command Board**,
  which folds every run across every machine into one grid with a STARTED BY
  column and per-machine / per-originator cost rollups. Standing orders persist
  in `standing_orders` (migration **v63**), with `StandingOrderScheduler` as the
  single answer to "what should run now" for the app, the daemon, and tests, and
  a runtime host that actually fires them: an order pinned to an offline Mac
  waits for that Mac rather than being rerouted, a deferred order stays due
  instead of silently losing its cycle, and the run is credited to the schedule
  rather than to the router that placed it. Migration **v64** indexes
  `token_usage.startTime` so the Command Board's window scan has an index to
  stand on.
- **War Room: machine-bound Hermes identity and the Wire's fail-closed spine**
  (`docs/WAR_ROOM.md`) — a Hermes is now a name bound to a *machine*, not a bot.
  Every Mac publishes one **HermesBody** (`users/{uid}/hermes_bodies/{bodyId}`):
  the join of the device doc, the Hermes relay connection, the iroh endpoint,
  and sysctl-probed hardware, keyed by the existing
  `relay-host-<installationUUID>` connection id so no new identity is minted.
  Settings → Devices & Sync gains a **Hermes Bodies** roster with rename and
  removal. Presence is derived by the *reader* from heartbeat age rather than
  trusted from a publisher that cannot know it went offline, and unreadable
  hardware renders an em-dash instead of a synthetic default. `BurnBarOriginator`
  adds typed STARTED BY attribution (9 kinds × exact/inferred/unknown
  confidence) stamped onto Wand missions today, with a flat two-field codec for
  the new nullable `token_usage.originatorKind` / `originatorRef` columns
  (migration v62) and a full-map codec for Firestore. The **Wire** — the
  Pro/Ultra-only encrypted Mac⇄Mac lane — lands its policy spine: a `war` frame
  group in the canonical wire protocol (parity-gated across Swift, Kotlin,
  TypeScript, and Rust), a pure `WarWireGate` both peers evaluate identically,
  `war_wire_grants` consent records whose pair id is derived server-side and
  whose covered pair is immutable on update, and the `war_room_kill_switch`
  Remote Config flag that defaults to *engaged* so an install that cannot reach
  config keeps the shipped single-machine experience.
- **Liquid Plasma selectors** (`AgentLens/Views/Chat/Components/Plasma/`): the flat
  chat model menu becomes two living orbs. The left one wears a face — ten personas,
  each with its own eyes, palette and voice line, chosen per agent because the voice
  you want from a fast local CLI is not the one you want from a reasoning gateway.
  While the agent streams, droplets rise out of the orb and pop instead of a spinner.
  The right one opens a Route › Provider › Model cascade whose first rung lists
  BurnBar's *real* routes, not a catalog of endpoints that cannot serve a request
  here, and reports five status states rather than two so an unprobed gateway says
  "not probed" instead of claiming a server is down that nobody contacted.
- **Swarm Ember rebuilt around the BurnBar flame mark** (`apps/console` +
  `packages/gl-engine`): the old token-glyph / provider-slideshow field is
  gone. Embers murmurate on a curl-noise wind, then lock onto a color-accurate
  sampling of the official flame + bar-chart mark, hold with heat and tip
  sparks, and dissolve. Console default is `logoHero` (mark ↔ swarm only);
  the Linux/macOS dashboard cycle via `buildDashboardCycle` is unchanged.
- **Usage rollups: per-day provider split** (`functions/`, `COUNTER_SCHEMA_VERSION`
  3): the all_time rollup gains `dailyProviderTokens` — a sparse
  `day → provider → tokens` map alongside `dailyPoints`, with
  `sum(split[day]) === dailyPoints[day]` per day. Legacy counters (schema < 3)
  fall back to the reference path once, backfill, and persist with an
  updatedAt guard. The console normalizes it defensively (positive entries
  only) and fails soft until functions are deployed and backfilled.
- **Console profile: hover detail, metric toggle, self-healing first sync** —
  hovering a heatmap day (Daily mode) now floats a day card with the exact
  token count and, when the rollup carries schema-v3 data, the per-provider
  split with brand marks (top 3 + "other"); the hovered cell rings in
  accent-deep. The insights rail gains a "Break down by" Tokens / Runs / Spend
  toggle that re-bases provider mix, models, harnesses, and combos on the
  chosen metric. First visit with no rollup auto-fires `rebuildUsageRollups`
  (once per session) with a syncing banner instead of showing silent zeros,
  and the empty state gains a manual "Re-sync now".
- **Console: Experimental gallery selects in place** — picking a kernel tile on
  /experimental now takes over the page's own background instantly (the global
  backdrop renders behind the gallery, like every other route), so the preview
  IS the real thing. The "Your backdrop" hero strip is retired — the horizontal
  preview box is gone; the active tile keeps its ring + badge and the toast
  confirms the switch.
- **Usage rollups: execution-source + combo aggregation** (`functions/`): the
  counter pipeline gains an `executionSources` dimension and a harness × model
  `combos` dimension per counter bucket (`COUNTER_SCHEMA_VERSION` 2), aggregated
  into `executionSourceSummaries` / `comboSummaries` on every rollup window —
  the data behind the console profile's new sections. Both the reference path
  and the pending-delta queue drain carry the fields (`test-rollups.mjs`
  two-path equivalence still passes byte-identical). Legacy events without
  execution-source attribution are skipped, never zero-filled. History
  backfills via `rebuildUserRollupCounters` after deploy; until then the
  fields are absent and the console hides the sections.
- **Console command rail + ⌘K palette** (`apps/console/components/nav`): the
  numbered folio top bar is replaced by a slim left rail that groups
  destinations by intent (Observe · Vault · System), with the member identity,
  theme switcher, and a quarantined Panic control in the rail footer. The same
  rail content powers the mobile slide-over drawer (one nav component, no
  duplicated mobile strip). `⌘K`/`Ctrl+K` opens a command palette — every
  destination, every theme, and sign out — with ranked substring filtering.
  The destination model (`components/nav/navModel.ts`) is the single source of
  truth for rail, drawer, and palette. The "Private — not indexed" folio strip
  is retired; the footer's privacy line carries the message. Content routes are
  now left-aligned in a `max-w-5xl` column beside the rail (console convention)
  instead of floating centered, and the Pensieve membership pill becomes an
  icon-forward `PlanBadge` lockup (cloud crest in an accent tile + stacked
  tier name). `ThemeMenu` gained a `direction="up"` popover mode so the rail
  footer's switcher never opens past the viewport's bottom edge. The rail
  brand lockup is the bare BurnBar flame mark, enlarged — no tile, no
  hairline; the full-colour mark reads on every theme as-is.
- **Profile: agent harnesses + combos** (`apps/console`): the usage profile
  gains "Agent harnesses" (Claude Code, Codex, Cursor, … with brand logos via
  `lib/brandLogos.ts` + `components/BrandLogo.tsx`) and harness × model
  "Combos" sections, driven by the new `executionSourceSummaries` /
  `comboSummaries` rollup fields in `lib/usage.ts`. Both sections fail soft —
  they stay hidden until the server-side execution-source counters ship and
  backfill. On xl+ screens the insights become a right rail beside the main
  column (harness/combo blocks render from md up, where there's room);
  narrower layouts keep the single-column stack. The rail leads with an
  accent-led "Provider mix" share bar whose legend rows carry the providers'
  own brand marks, and the model rows are logo-led too; before the first sync,
  dimmed ghost shapes preview the layout without inventing numbers.
- **Console usage profile** (`apps/console/app/profile`): a Codex/Cursor-style
  activity page — identity header, lifetime stat row (lifetime/peak tokens,
  total requests, current and longest streaks), a GitHub-style contribution
  heatmap of daily token activity with Daily / Weekly / Cumulative modes, a
  90-day token trend, and most-used provider/model insights. All figures come
  from the owner-readable `usage_rollups/all_time` doc; untracked dimensions
  (fast mode, reasoning mix, skills) are stated as untracked, never mocked.

### Fixed
- **Console: experimental gallery tiles stay alive** — `LiveKernelCanvas`
  unmounts the canvas on scroll-away instead of calling `loseContext()` on a
  reused element. A lost WebGL context stays counted against the browser cap
  and `getContext` returns the same dead context forever, which is why retro
  plasma / blobs mesh / plasma orbs / flow imaging showed blank tiles.
- **Blobs mesh: cold-start wash** — blob centres are quadrant-anchored and
  the colour blend is keyed by the strongest single-blob weight so t=0 is a
  field of distinct bodies, not a featureless slate gradient.
- **Firestore: Hermes/Pi relay updates cannot change `mode`** — connection
  updates now require both the stored and incoming docs to stay `relayLink`.
- **Backdrop engine: leaked GL contexts on fast kernel switches** — a lazy
  kernel disposed before its chunk resolved never constructed the real kernel,
  so its `dispose()` was a no-op and the WebGL context the engine created for
  the slot leaked until GC. Rapid switching piled these toward the browser's
  per-page context budget until the compositor killed the LIVE context — the
  next kernel then compiled on a dead context and logged a spurious
  `shader compile failed: unknown`. The engine now force-releases the slot's
  context in `disposeSlot`, `lazyKernel` skips a deferred init whose context
  died in flight, and `compile()` treats a lost context as the lifecycle
  condition it is instead of logging a shader error. A kernel that throws on
  init now degrades to the 2D default instead of risking a black backdrop.
  (Both engine copies — `apps/console/lib/gl/engine` and
  `packages/gl-engine` — stay byte-identical per the parity gate.)
- **Console: passkey hydration mismatch** — `passkeySupported` was computed
  with `typeof window` during render, so the statically prerendered HTML and
  the client's first render disagreed (React hydration error on /settings and
  the Basin). WebAuthn support is now detected after mount.
- **Console: analytics consent banner on mobile** — the flex-wrap row squeezed
  the copy into a ~150px column at phone widths; the banner now stacks
  (text full-width, buttons on their own row) below sm.

## [openburnbar 0.2.0] - 2026-08-20

### Added
- npm `openburnbar proxy` is a portable loopback **relay** on `127.0.0.1:8320`
  for chat completions, Anthropic Messages, OpenAI Responses (HTTP SSE plus
  the Responses WebSocket), and `GET`/`DELETE /v1/responses/:id`. It does not
  translate dialects or count burn. OpenAI clients use
  `http://127.0.0.1:8320/v1`; Claude Code / Droid `anthropic` use the origin
  `http://127.0.0.1:8320`. Always `127.0.0.1`, never `localhost`.
- Optional `--tray`: on macOS, compiles shipped `macos-tray/` sources into an
  ad-hoc-signed `LSUIElement` helper (`point.3.connected.trianglepath`, not the
  BurnBar flame). Elsewhere it opens the loopback HTML panel at `/gateway`.
  Missing Xcode CLT keeps the proxy headless. Install Podex is an honest
  coming-soon sheet.
- `openburnbar proxy wire <client> [--write]` writes `:8320` snippets with a
  sentinel distinct from BurnBar Mac Connect (`:8317`). Dry-run is the default.
- Request bodies stay capped at **8 MiB**. The 413 names that limit and says
  this gateway does not raise it without a real client 413.

### Changed
- Bump the separately versioned `openburnbar` Node CLI from `0.1.2` to `0.2.0`.

## [openburnbar 0.1.2] - 2026-08-18

### Changed
- Bump the separately versioned `openburnbar` Node CLI from `0.1.1` to
  `0.1.2`; the CLI continues to follow the signed public macOS feed instead of
  embedding or downloading a DMG during npm installation.

## [1.0.37] - 2026-08-17

### Fixed
- Prioritize committed promotion bundles in `prepare-domain-core-native-release-gate.mjs`
  so the native release candidate gate hydrates the exact attested `a46c7234` bundle
  and cryptographic provenance against Sigstore attestation `38437922`.
- Supersede the unpublished `v1.0.36` candidate without moving its immutable tag.
  This release includes the full `1.0.36` and `1.0.35` feature sets.

## [1.0.36] - 2026-08-17

### Fixed
- Repair the strict Functions release gate after the Firestore rules helper
  refactor introduced local document aliases. The contract tests now bind
  their assertions to the exact Hermes and Pi helper blocks and continue to
  prove the same relay-only, encrypted-payload, and field-allowlist policy.
- Supersede the unpublished `v1.0.35` candidate without moving its immutable
  tag. This release includes the full `1.0.35` feature set below.

## [1.0.35] - 2026-08-17

### Added - `openburnbar app install` / `app update` (npm 0.1.1)
- The published npm `openburnbar` CLI (`tools/openburnbar-mcp-remote`) now has
  explicit `app install` and `app update` commands. They fetch
  `https://downloads.burnbar.ai/latest-macos.json` — the same public feed the
  notarized Mac app already uses — then verify SHA-256 + Ed25519 and copy
  `OpenBurnBar.app` to `/Applications`.
- The version is whatever that feed currently advertises. The CLI does not
  pin a marketing version; a newer public build on the feed is what gets
  installed.
- `npm i` does not download the Mac app. There is no `postinstall` hook and
  the tarball does not bake a DMG. Package version is **0.1.1**.

### Added
- **Live Agent Fleet** — dashboard Fleet view (watch running agents, designate
  an orchestrator, record directives) over `daemon.fleet.snapshot` /
  `orchestrator.get|set` / `directive.record`. Not in ⌘1–⌘8; Control Deck
  tile + section switcher + ⌘K. Honest empty/not-ready states, no fabricated
  running counts. Control Deck tile distinguishes preparing vs 0-running vs
  daemon-down. Fleet opens chat through the existing CLI-consent gate.
  Contract: `docs/fleet/BURNBAR_FLEET_API.md`.

### Added - OpenBurnBar Cursor Marketplace plugin
- **OpenBurnBar Cursor Marketplace plugin** (`plugins/openburnbar/`): an
  installable Cursor Plugin that connects desktop Customize and Cloud Agents
  to hosted Remote MCP at `https://mcp.burnbar.ai/mcp` over Streamable HTTP
  (protocol `2025-11-25`) with a GitHub-style bearer plugin variable
  (`OPENBURNBAR_MCP_ACCESS_TOKEN`, short-lived, never committed). Ships
  skills, commands, rules, agents, and a fail-closed `validate.mjs`; the
  plugin tree has no `package.json`, and the CI classifier routes
  `plugins/openburnbar/**` to the cheap web lane with a dedicated
  `plugin-fast` job. The editor extension remains source-only / load-unpacked
  (no VS Marketplace / Open VSX listing). Install + auth + sealed-field
  honesty: `docs/OPENBURNBAR_CURSOR_PLUGIN.md`.

### Fixed - iPhone mission-approval Deny now persists
- Tapping **Deny** on an Approvals-waiting card now leaves `waiting_for_approval`
  immediately (`respondMissionApproval` writes `status: canceled` plus
  `approvalStatus: rejected`). Approve still stays parked so the Mac listener
  can claim it.
- `MobileMissionConsoleHost` keeps a successful Deny/Approve hidden when the
  Firestore list listener re-emits the still-waiting document, and a failed
  callable now stays visible on the Hermes Square inbox instead of being
  cleared by the next snapshot (the previous silent no-op).

### Removed - iPhone Mission Console floating orb
- The circular floating Mission Console control (hand icon / "Approve") is gone
  from iPhone Pulse, Settings, Agents, and every other tab. It no longer
  auto-restores when Firestore mission approvals are pending.
- Settings → Experimental no longer has the "Mission Console orb" toggle or
  its auto-restore footer. The Experimental section is gone with it.
- `MobileMissionConsoleHost` and Skill Run live stage are unchanged. The
  console sheet stays in the tree for Hermes / Skill Run; this PR does not
  add a replacement launcher.

### Fixed - CI impact: Node Signal contracts lockfile no longer wakes macOS
- `packages/signal-envelope-contracts` `package.json` / lockfile changes used
  to match the catch-all npm `FULL_PATTERNS` and force every product lane,
  including App PR Gate. That burned ~90 minutes of macos-26 rebuilding
  libsignal FFI for a Node eslint bump, then cancelled at the job ceiling
  (BurnBar #2247). Those two npm manifests now select the functions lane
  only; other files under the package stay fail-closed. Fast Feedback still
  runs the contracts tests. Other `packages/*` lockfiles stay fail-closed
  full.

### Changed - App PR Gate and Headless leave the PR / merge-queue path
- **AgentLens macos-26 App PR Gate and Headless App Build no longer run on
  `pull_request`.** Fast Feedback plus the ten required security/quality
  contexts remain the merge door. Merge-queue ALLGREEN no longer waits 53–69
  minutes (App) or 21–30 minutes (Headless) on hosted macos-26.
- **The builds stay real.** App PR Gate runs on push to `main`, nightly at
  09:17 UTC, and `workflow_dispatch`. Headless runs on path-filtered push to
  `main`, nightly at 10:47 UTC, and `workflow_dispatch`. A broken AgentLens
  graph is visible after merge, not silent.
- **`merge_group` on App PR Gate emits skipped receipts only** so a stale
  base-SHA BurnBar CI Gate inventory cannot hang the queue. macos-26 jobs do
  not run on that path. Headless has no `merge_group` trigger.
- **BurnBar CI Gate's merge-queue inventory no longer lists**
  `App build + test (AgentLens)` or `Mobile build + unit test`. The ten
  required branch-protection contexts are unchanged. `CI_POOL` /
  `MACOS_GATE_POOL` are unchanged.
- **Domain Core control-plane trusted bytes refreshed** for the two files
  that inventory change actually edited (`burnbar-ci-gate.yml` and
  `governance/burnbar-ci-gate.json`). Promotion-contracts still fail closed
  on helper drift, omitted workflow executables, loaded-identity forgery,
  Firebase CLI shim swaps, and symlink escapes.
- **Post-merge App/Headless push proofs are keyed by SHA and never
  cancelled.** A later docs-only (or any) `main` push cannot evict an
  in-flight AgentLens/mobile or headless graph proof; the replacement
  classifier would otherwise skip macos/mobile until nightly.

### Added
- The Node MCP / resume / memory CLI (in `tools/openburnbar-mcp-remote/`) is now
  published to **npm** as **`openburnbar` 0.1.0** (AGPL-3.0-only, zero runtime
  dependencies). Install with `npm i -g openburnbar` or run ad-hoc with
  `npx -y openburnbar`. It is the Node CLI for the hosted Remote MCP
  (`mcp serve` / `mcp install` / `mcp doctor` / `mcp login`), session resume
  (`resume` / `obbresume` / `OBB`), and the Pensieve memory hook (`memory`).
  The package also keeps a legacy compat bin alias for existing local configs.
  Distinct from the native daemon operator CLI `openburnbar-cli`, which stays
  unpublished.

### Added - Metered usage-memory curation gateway (U4)
- **`curateUsageMemoryBatch` Cloud Functions callable**: entitlement-gated,
  token-metered gateway for cloud usage-memory curation inference
  (text lane = any active Pro on deepseek-v4-flash; multimodal lane =
  Pro Max/Ultra on minimax-m3). Reserve-before-spend / settle-to-actual
  Firestore ledger with monthly + daily lane meters, Remote Config-tunable
  limits, and a `usage_curation_enabled` kill flag. Every request pins
  OpenRouter routing to CoreWeave (US) with fallbacks disabled, provider
  data collection denied, and ZDR required; candidate text rides inside an
  untrusted-data fence with fence-marker neutralization. See
  `docs/USAGE_CURATION_METERING.md`.

### Changed - Approved first-run + homepage copy
- Homepage hero now uses Alberto-approved copy: **Watch your agents. Before the
  bill.** plus the locked receipt subhead, the real `/brand/logo-*.png` mark, and
  **Download for Mac — {shipping version}**.
- macOS first-launch popover (`OnboardingView`) uses the real `AppLogo` brand
  mark and the locked tip copy: **Look up. That's the app.** / menu-bar receipt /
  Claude or Codex / **Got it**.

### Added - Spend provenance: real API dollars vs subscription value
- **`billingKind` on every usage row** (migration `v60_billing_kind`, mirrored
  across the macOS/Windows/Linux migrators with deterministic backfill): `api`
  (per-token dollars leaving a wallet — deepseek, OpenRouter, gateway keys,
  billing APIs), `subscription` (imputed list-price value of plan-covered
  harness work — Claude Code on Max, Codex, Cursor, Copilot…), or an honest
  `unknown` bucket that is never silently folded into either side.
- **Spend Lens on the burn chart**: liquid-glass `All / Split / Overlay`
  capsule. Split shows real dollars and plan value side by side; Overlay
  breaks both out on one shared axis (ember = money, glacier = plan).
  Persisted per user.
- **The AI Inbox daily budget now guards real dollars only**: subscription-
  routed model calls no longer consume `dailyBudgetUSD` (opt back in with the
  new "Count subscription spend" setting). Budget/status copy stops saying
  "no model calls" when it means "rule-based fallback".

### Added - AI Inbox Founder Lens: judgment packs, replies, and compounding plans
- **Founder Lens judgment layer** (`BurnBarFounderLens`): engOps and
  productStrategy packs distilled from real founder/VC/engineering doctrine
  (gstack, YC, a16z, Sequoia, Horowitz, 2026 agent-readiness practice) as
  snapshot-tested code constants — the zero-egress rule-based path carries
  the same judgment as the model path. Voice ban list enforced by tests;
  `lens:vN` stamped into item provenance.
- **NextMoveRouter** (Swift-only): every substantive item ends with exactly
  one primary next move; refuted/unclear findings lose theirs. Models never
  author actions.
- **Reply threads** (`daemon.inbox.thread.get` / `daemon.inbox.reply`): keyed
  by condition fingerprint so conversations survive item resolve/reopen
  churn. Fail-closed gate order: feature switches → egress guard → daily
  budget → NEW per-reply budget (`perReplyBudgetUSD`, default $0.10) → G8
  `LLMSafeContent` fences on every untrusted surface. Refusals are stated
  reasons, never silent drops; reply spend lands in the authoritative usage
  ledger.
- **Founder Plan Ledger** (migration `v59_founder_lens`): accepted
  suggestions become durable plans/steps with lifecycle, append-only audit
  events, and grades (terminal outcomes auto-seed; explicit grades
  override). Accept/update/grade are human-confirmed config-capability RPCs;
  the analyst/reply model can only propose.
- **Execution spine reuse**: Promote to mission (`daemon.mission.create`,
  `recommendation: review`) and follow-up creation bind `mission_id` /
  `followup_id` back onto plan steps — no second mission system.
- **Compounding memory**: Remember routes plan steps through the existing
  quarantine→approve Chat Memory Authority with `ai-inbox:plan:*`
  provenance; approved snippets are pushed to the daemon
  (`daemon.inbox.memory.export`, full-set replacement so revocations
  propagate by omission) and re-enter every analyst/reply prompt as fenced
  "standing commitments". Pensieve `chat_memory` sync stays gated on
  approved + provenance + Pro Max/Ultra.
- **Mac UI**: Discuss section on item detail (thread, composer, refusal
  explanations, Accept-into-plan cards with provenance badges).
- **MCP**: read-only `burnbar_inbox_plans_list` / `burnbar_inbox_plans_get`
  (fenced, trust-signaled; deliberately no write tool).
- Docs: `docs/AI_INBOX_FOUNDER_LENS.md`, `docs/AI_INBOX_FOUNDER_PLANS.md`.

## [1.0.34] - 2026-08-15

### Changed - Instant graphics, GRDB, and quota mining
- **Constellation / logo swarm fills** now batch every live draw path
  (swarm, formed logo, color-driver) by `RGBA.bucketKey` instead of one
  `ctx.fill` per particle. Sparkles stay a deferred overlay. Wallpaper
  stays on the existing 30 Hz organic-motion cap.
- **Dashboard snapshot** builds last-7-day cost/token series and the
  rolling average from one overlapping-day SQL scan instead of 14
  per-day round-trips. Window membership is unchanged (intersection
  predicate), so long-running sessions still count on every overlapped
  day. Today / 7d / 30d / month / all-time aggregates are one `GROUP BY`
  with per-window membership flags. Workspace artifact and projection
  counts are one `GROUP BY status` each.
- **Idle usage persist** skips the `token_usage` upsert storm when a
  refresh tick re-parses byte-identical session totals and nothing else
  has written the table. New UUIDs/`createdAt` values do not bust the
  skip gate.
- **Grok Build quota/usage ticks** resume `updates.jsonl` from a
  mtime+size disk cache (token breakdowns only) so unchanged
  `~/.grok/sessions/` trees are not re-scanned. Codex and Claude already
  had this shape.
- **Chart Studio / Burn / Trend Atlas** memoize digest-derived gallery
  facts and insights so Hermes streaming and Compose recomposition do
  not rebuild them per token. Editorial backdrop is capped at 30 fps;
  substrate radius uses an in-place upper median; quota dial shadows
  flatten through a compositing group.
- **Quota refresh** follows `QuotaRefreshPolicy` on Mac and Linux
  (30m / 10m / 3m by remaining fraction). SuperGrok pacing tail-reads
  the 2h window; Claude JSONL quota scans resume on append-only growth;
  Codex rollout walks skip files older than the 7-day cutoff.
- **Charts page** uses one covering SQL scan (all-time, or last 31 days
  for every bounded range) and splits selected vs heatmap rows in memory
  with the intersection predicate. Conversation first-index writes land
  in chunks of 64 inside one transaction each (upsert + projection
  enqueue). Factory skips `.settings.json` older than 30 days; Antigravity
  history.jsonl tail-reads the 5h window. Decorative loaders, the Cloud
  store orbit, and the iOS easter-egg canvas cap at 30 fps. Database
  workspace snapshot reads overlap instead of awaiting one-by-one.
- **Warp quota fallback** tail-reads the last 512 KB of `warp_network*.log`
  for the newest credit bucket and only rereads the whole file when the
  tail has no credits or is not valid UTF-8. **Gemini CLI** usage ticks
  resume unchanged `session-*.json(l)` files from a mtime+size cache
  (token totals only) and skip transcript markdown on usage-only passes.
  Cursor Agent and Antigravity usage parsers share the process-wide
  ISO-8601 formatter; Cursor Agent skips conversation assembly on
  usage-only ticks. Factory quota timestamps use the same formatter.
  Logo formation (splash/onboarding) matches the 30 fps decorative cap.
- **Idle usage ticks** resume unchanged Cursor Agent, Cline-family,
  Copilot, Antigravity, and Goose transcripts from a mtime+size cache
  (token totals only). Copilot's process-log fallback integers and
  Antigravity's settings-model string participate in the signature.
  Quota spend/reset parsers reuse `ThreadSafeISO8601DateFormatter`
  (`parse` for fractional-then-basic, `parseBasic` where the default
  formatter's acceptance must not widen).
- **Remaining Core usage parsers** (Warp, Prime, Muse, Kimi, Windsurf,
  Hermes, Forge, Augment, Aider, Cursor SQLite, OpenCode, Pi, OMP,
  OpenClaw, Ollama, Junie, ModelFilter) resume unchanged session files
  from the same mtime+size cache. SQLite signatures include `-wal` when
  present and ignore `-shm` (a read-only open rewrites shm without
  changing totals). ModelFilter caches empty bundles for non-matching
  Factory sessions so zai/minimax ticks do not rescan every other
  provider's jsonl. Quota cache writes reuse `formatBasic`.
- **Mac-semantics idle caches** resume Copilot / Aider / Cursor /
  OpenCode / Pi / OpenClaw / Junie on the AgentLens parse math (not Core
  aliases), in dedicated `mac_*_parser_cache.json` files so isomorphic
  signatures cannot decode Mac totals as a Core hit. Daily summaries
  use intersection membership with a dedicated equality test. Quota
  provider / account / switcher phases overlap after Codex rollout
  merge-on-write. Warp usage resumes append-only logs from the last
  complete Body. Windsurf / Hermes reuse listing stats for discovery
  and gateway signatures; Forge skips `.forge.db` probes when a home
  child directory mtime is unchanged.
- **Distinct usage days, OpenCode `part`, Kilo quota, and Charts analytics.**
  Dashboard distinct-day count uses intersection membership (same days as
  daily summaries) instead of `DATE(startTime)`. OpenCode usage-only ticks
  skip `part` when every session has explicit token buckets and otherwise
  query only the zero-bucket message ids. Kilo Code quota resumes unchanged
  `ui_messages.json` files from a mtime+size cache of totals only. Charts
  heatmap / outliers / entropy have a SQL twin that matches
  `ChartsSnapshot.build` without decoding full `TokenUsage` rows. The Charts
  page covering scan now loads `ChartFactRow` columns only (burn / cache /
  provenance / histogram / Spend Lens included), so all-time no longer
  `SELECT *` / `decodeUsage`. Attribution still clamps `startTime`.
- **Dashboard persist ticks** reload with `fetchDashboardUsageSnapshot` (the
  same SQL window totals + hydration covering rows as init) instead of
  `fetchAllUsage` / `SELECT *`. The snapshot itself decodes covering rows
  once and filters them for bounded windows. **Factory quota** resumes
  unchanged `*.settings.json` from a mtime+size cache of totals / lane /
  session date only. Goose, Gemini CLI, Claude Code, Mac Pi, Forge, Muse,
  and Factory listings prefetch size/mtime so cache signatures do not
  re-stat.
- **Forge home discovery** reuses the `$HOME` child list when home mtime is
  unchanged (still re-stats known children for `.forge.db`). Dashboard
  covering scans name `decodeUsage` columns instead of `SELECT *`.
  Credential / project summaries fold from the window `GROUP BY` so a
  long-runner older than the newest N covering rows still appears.
  OpenCode `part` selects payload/id columns; Kilo quota lists tasks via
  URL `contentsOfDirectory` and drops the extra `fileExists`. Copilot,
  Warp, Augment, Prime, Muse, Mac OpenClaw, and shared local-parser
  listings prefetch size/mtime for `FileSignature`.
- **Aider quota, ChartFactRow index decode, and ISO-8601 reuse.** Aider
  analytics JSONL resumes from a mtime+size cache of tokens/cost/time
  plus a byte offset past the last terminated line (no prompt text).
  Charts / dashboard covering scans decode GRDB rows by SELECT ordinal
  through a cached statement cursor. Date fallbacks and daemon Pensieve
  sentinels reuse `ThreadSafeISO8601DateFormatter` instead of allocating
  a formatter per string or per file.
- **Usage watermarks, OpenCode JSON-only `part`, and pool EQP.** Usage
  refresh parse cannot carry indexing `idx2:` / `minimumFileModificationDate`
  / discovery tracker (`LogParseOptions.usageAccounting`). OpenCode
  usage-only ticks bound JSON-only `part` rows with `json_extract` on an
  existing payload column (no invented message-id column). On-disk
  `EXPLAIN QUERY PLAN` shows unsynced rows already use
  `token_usage_sync_pending_idx`; no covering-index migration. Production
  `DatabasePool` reader count is 8. Aider stays off `quotaSignalProviders`.

### Fixed - Domain-core protected signer path vs GitHub Actions API

- Accept the bare workflow `path` returned by GitHub Actions run metadata
  (`.github/workflows/domain-core-promotion-proof.yml`) when validating the
  protected promotion signer run. The gate previously required a
  `path@refs/heads/main` suffix that the live API does not emit, so `v1.0.33`
  OpenBurnBar Release passed Preflight and hydrated expired Actions artifacts,
  then failed Shared Rust verify on a false signer-path mismatch.

- Bumped Google Play `versionCode` to `46` with `versionName` `1.0.34`, and Mac
  `CURRENT_PROJECT_VERSION` to `76`.

## [1.0.33] - 2026-08-09

### Fixed - Domain-core release gate Actions artifact expiry

- When GitHub Actions artifacts for the activated Shared Rust candidate expire
  (org retention overrides the workflow's 90-day request), the native release
  gate now hydrates the attested candidate bundle from committed promotion
  evidence and regenerates the byte-identical rollback profile, then continues
  Sigstore verification. Unblocks `v1.0.32` OpenBurnBar Release after Preflight
  passed but Shared Rust verify failed on expired run `30754893279`.

- Bumped Google Play `versionCode` to `45` with `versionName` `1.0.33`, and Mac
  `CURRENT_PROJECT_VERSION` to `75`.

## [1.0.32] - 2026-08-09

### Fixed - Release preflight Lob false positives

- Broadened the publishable-tree TruffleHog Lob filter so camelCase XCTest
  identifiers (and docs/Vendor mentions) are not treated as verified Lob
  test-mode API keys — unblocking the Mac/iOS/Android release cut after
  `v1.0.31` failed Release Preflight.

- Bumped Google Play `versionCode` to `44` with `versionName` `1.0.32`, and Mac
  `CURRENT_PROJECT_VERSION` to `74`.

## [1.0.31] - 2026-08-09

### Changed - Menu bar popover liquid glass redesign

- Rebuilt the macOS menu bar popover for clearer burn/quota reading in light and
  dark Liquid Glass: stronger header copy, single primary quota bars with
  percent-left and resets-in lines, and tighter tray chrome contrast.

### Fixed - Release cut continuity

- Cut `1.0.31` because repository rules forbid deleting the existing `v1.0.30`
  tag after the first release attempt failed preflight. This build includes the
  liquid-glass popover and the publishable-tree Lob false-positive filter.

- Bumped Google Play `versionCode` to `43` with `versionName` `1.0.31`, and Mac
  `CURRENT_PROJECT_VERSION` to `73`.

## [1.0.30] - 2026-08-08

### Added - Muse (Meta) first-class provider

- **Muse is now a first-class provider at parity with Hermes, Codex, and Droid**: auto-detected at `~/.local/share/muse/sessions/**/*.jsonl` with no manual config; `MuseParser` extracts per-turn `input_tokens`/`output_tokens`/`cached_tokens`/`cache_read_tokens`/`reasoning_tokens`, tool calls (`tool_batch.effect.started`), and prompts (`started`/`inbox_item_queued`) from the envelope JSONL, with microsecond `recorded_at` timestamps and subagent session support (`subagent/<uuid>/session.jsonl`). Cost uses catalog pricing for `muse-spark-1.2` (standard $1.25/$4.25/$0.15) and `muse-spark-1.2-contributor` ($0.10/$0.20/$0.002) with fallback to `ModelPricing.fallback` when the model is unknown. Handles empty logs, truncated JSONL, missing fields, and multi-model sessions. Installed Muse is auto-detected with no manual config (like Droid/Hermes/Codex).

### Added - Prime Agent (Prime Intellect) first-class provider

- **Prime Agent is now a first-class provider at parity with Hermes, Codex, and Droid**: auto-detected at `~/.prime/agent/sessions/*.jsonl` with no manual config; `PrimeAgentParser` extracts per-turn `input`/`output`/`cacheRead`/`cacheWrite` and exact USD cost from `message.usage.cost.total` (fallback to `ModelPricing` catalog when cost is zero). Sessions appear in the meter with correct tokens and $ cost; pricing falls back gracefully when the model is unknown. Handles empty logs, truncated JSONL, and multi-model sessions.

### Added - Prime Agent OpenBurnBar proxy

- Added Prime Agent OpenBurnBar proxy: `node scripts/prime-agent-openburnbar-proxy.mjs` syncs the local gateway catalog into `~/.prime/agent/models.json` as `openburnbar/*` so `prime-agent /model` and `prime-agent --provider openburnbar --model claude-sonnet-4-6` route through BurnBar's loopback gateway (accounting + failover), matching the existing Claude Code / Codex / Droid / Forge / OpenCode wiring. Supports `--live` (gateway-first), `--status`, `--print`, and `--remove`; API key resolves at request time from the LaunchAgent plist → keychain → env var. Docs: `docs/PROVIDERS.md` → Prime Agent via OpenBurnBar Gateway.

### Fixed - Mercury release build reliability

- **Made clean Mercury XCFramework release builds deterministic across current
  Apple toolchains**: the cross-target builder keeps host proc-macro dylibs
  intact, strips debug data only from the final packaged archives, isolates its
  Cargo target directory, and serializes Cargo by default.

### Fixed - Trusted device identity control

- **Kept every distinct trusted-device registration visible and independently
  revocable**: a phone reinstall or identity rotation can no longer hide a stale
  trusted registration behind the replacement device's matching name and
  platform. Trusted Devices now shows a short identity suffix for precise,
  accessible revocation.

### Fixed - Android Mercury keyboard reliability

- **Made the screen-share keyboard reliably open and reopen on Android**:
  manually tapping Type no longer closes the keyboard merely because the Mac
  has not reported text-field focus, while keyboards opened automatically still
  follow the remote focus lifecycle. Dismissing the Android IME now clears the
  selected Type state so one tap reopens it, with JVM policy coverage and a
  physical-Samsung open, dismiss, and reopen regression test.

### Fixed - Audited GitHub release promotion

- **Made stable release promotion a verified second phase**: tag publication
  remains explicitly non-latest, while a `promote=true` retry must audit the
  exact published tag, metadata, attestations, asset bytes, GitHub asset IDs,
  sizes, and SHA-256 digests before the sole `--latest` mutation. The workflow
  then proves GitHub's latest endpoint still returns that unchanged release
  before validating the live updater feed. The audit binds the governed
  `domain_core_profile`: a rollback release promotes without the native
  domain-core evidence it never publishes (anything present is still verified),
  a published legacy GPG checksum signature must verify against the audited
  checksums file, and iOS release predicates now validate their embedded App
  Store Connect receipt end to end.

### Fixed - Stripe entitlement reconciliation

- **Made temporary Stripe-bound operator grants yield to the verified lifecycle
  for that exact subscription**: the first signed webhook now replaces the
  bridge grant with real renewal dates and restores normal cancellation,
  refund, and dispute revocation. Grants for another subscription or platform
  remain protected.

### Fixed - Android Mercury trust recovery

- **Made Android screen mirroring recover cleanly after a reinstall changes the
  phone's trusted-device identity**: Mercury now preserves the actionable
  approval failure throughout automatic reconnect attempts, directs the user
  to the exact Trusted Devices screen on the Mac, disables misleading mirror
  retries until approval is granted, and resumes automatically afterward.

### Fixed - Linux packaged launcher identity

- **Pinned every DEB, RPM, and Arch desktop launcher to the package-owned
  `/usr/bin/openburnbar-linux-desktop` executable**: login autostart, normal
  launch, safe mode, and Tauri's generated menu entry can no longer be
  shadowed by a stale `/usr/local/bin` or user `PATH` copy. Installed tray and
  notification proof now verifies the absolute launcher and the canonical
  `open-burn-bar` DEB/RPM package identity.

### Fixed - Full-history CI checkout reliability

- **Kept fail-closed compliance, secret-scanning, and public-download gates
  alive through slow GitHub checkouts**: the recursive-submodule
  product-license lane and full-history gitleaks scan now have enough runtime
  headroom to execute, while the macOS and Linux public-download change
  detectors use blobless full-history clones plus a bounded 60-minute ceiling.
  All four lanes now reach their security logic instead of being canceled
  during checkout.
- **Kept the fail-closed Domain Core PR gate alive through slow checkouts**:
  the required `Domain Core PR Gate` lane and its `promotion-contracts`
  prerequisite now budget 60 minutes for their full-history
  deletion-candidate clones (which must keep blobs for ancestry and
  historical-content proofs), and each trusted default-branch evaluator
  checkout stays bounded to a depth-1 sparse fetch of the evaluator scripts
  instead of a second full-history clone.
- **Removed a monolithic macOS test-host deadlock from the required app gate**:
  the two cross-thread memory-citation database tests now run in the existing
  fresh-host phase, where their focused suite completes deterministically,
  while the exact fresh-host result count rises from 126 to 128 so neither
  test can be skipped without failing the gate.

### Fixed - Z.ai cloud quota refresh

- **Restored Z.ai quota refresh for both Coding Plan and standard API
  accounts**: Coding Plan monitor requests now use Z.ai's required raw-token
  authorization while standard API validation keeps Bearer authentication.
  Valid accounts without a Coding Plan now return an honest empty quota
  snapshot instead of a server error or a fabricated balance. Coding
  Plan-only keys that the standard API rejects now pass connection
  validation via the monitor endpoint, and transient monitor failures
  (network errors, 5xx) propagate as refresh errors instead of overwriting
  valid quota with an empty snapshot.

### Added - Execution-source attribution

- **Split model usage by the product that executed each request** with a
  provider-independent execution-source dimension (for example Cursor, Grok
  Build, Codex CLI, or Codex Desktop). Local logs, daemon runs, HTTP gateway
  client markers, cloud sync, Android, and Windows now preserve the same
  normalized source fields, and model/session dashboards expose the split.
- **Backfilled historical usage only from durable evidence**: dedicated parser
  identities map existing rows to their runtime, while Codex rollout
  `session_meta` distinguishes CLI, Desktop, VS Code, and Cloud sessions.
  Ambiguous rows remain Unknown instead of being guessed.

### Fixed - Codex usage accounting

- **Stopped Codex subagents from multiplying their parent's cumulative token
  counter**: refreshes now purge mirrored subagent ledger rows and persist the
  top-level thread's cumulative high-water increases as exact local-day slices.
  This also repairs already-inflated dashboards on the next refresh and keeps
  long-running threads from charging their lifetime total to Today.
- **Added GPT-5.6 Sol, Terra, and Luna to the shared model catalog** with their
  current input, cached-input, output, and cache-write rates, so Codex 5.6 logs
  no longer fall through to generic GPT-5 pricing.
- **Made dashboard burn tiles follow the selected time range** instead of
  always labeling the selected range's cost as Today.

### Fixed - Elder Wand and Pareto Wand reliability

- **Hardened Elder fusion across malformed, repeated, over-budget, and cancelled
  calls**: duplicate panel IDs now execute once, judge output is validated before
  synthesis, every requested tool call receives a protocol-valid response, and
  cancellation stops before later paid stages.
- **Made Pareto routing durable from dispatch through Mac claim**: active Wand
  routing now fails closed when any selected runtime is missing, fan-out
  parallelism matches Firestore bounds, concrete mobile/manual routes are no
  longer replaced by the Mac default, and capability matching no longer reads
  `proxy` as `pro`. Incomplete headless proof results no longer wrap one proven
  model onto missing siblings.
- **Made Ministry wand persistence atomic and diagnosable**: sanitization no
  longer mutates caller data, concurrent saves use unique durable temp files,
  read/write permission failures are structured, and freshly saved stores no
  longer report timestamp-only rewrites.
- **Made the signed Mac Elder workflow use one executable model contract**:
  Wand settings and compatible chat engines now load the daemon's live catalog,
  Automatic selection follows the gateway default, stale explicit choices fail
  visibly, and exact advertised local Ollama IDs route without letting a local
  provider shadow unrelated cloud models.
- **Fixed signed-app startup and Wand settings navigation**: the packaged daemon
  now carries its SQLCipher runtime before signing, background wiring repair no
  longer crosses a main-actor boundary, and the dashboard opens Wand settings
  on the requested page with the same live chat controller.
- **Hardened production App Check readiness**: signed macOS builds select
  DeviceCheck instead of trusting an inapplicable App Attest support probe, and
  the production verifier now requires both enforcement and an uploaded
  DeviceCheck key for the canonical Firebase app.
- **Stopped database-encryption tests from touching a user's live Keychain**:
  XCTest now uses an in-memory client plus a process-local account namespace.
  Startup also preserves an existing encrypted database without creating a
  replacement key when its original key is missing, and reports a specific
  recovery error when the stored key is rejected.
- **Stopped failed async database reads from crashing the app test host**: the
  vendored GRDB queue now leaves read-only mode only after entering it, and
  rolls back a failed commit before reusing the connection.

### Fixed - Incremental conversation indexing

- **Stopped steady-state conversation indexing from re-reading the full log
  corpus every minute**: parser checkpoints now persist exact, content-free file
  identities in a normalized SQLite manifest. Claude Code, Codex, Factory Droid,
  Windsurf, and Hermes skip inputs already represented by the last successful
  checkpoint while still admitting restored or copied transcripts whose
  modification times predate the watermark. Byte-bounded passes persist only
  safely committed identities and freeze the watermark until deferred inputs
  are retried, so cold scans converge without gaps or silent truncation.
### Added - Windows fleet safety parity

- **Added fail-closed Remote Config polling for Windows Computer Use and
  Mercury media**: an Auth plus TPM App Check-protected callable relays the
  reviewed fleet booleans, while the desktop client validates a short server
  lease every 60 seconds. The privileged input broker now checks an independent
  expiring remote interlock on every dispatch, and remote recovery cannot clear
  a manual or watchdog panic latch.
### Fixed - Windows physical x64 usage-scan memory

- **Isolated native Swift parsing from the long-lived WinUI process**: usage
  scans now execute once in the signed companion CLI and exit, giving Windows a
  deterministic native-heap reclamation boundary. The worker uses a reviewed
  no-shell launch policy, bounded diagnostics, cancellation and timeout cleanup,
  typed fail-closed errors, and a streamed internal protocol. Release CI proves
  the real worker against the exact published x64 native-engine layout before
  signing and locks the app composition root against an in-process regression.

### Fixed - Windows Aurora physical validation

- **Closed the physical-build and command-palette regressions found by the x64
  screenshot run**: programmatic tab tooltips now use the WinUI attached-property
  setter, the global brand font is inherited from a valid `Control`, and the
  Aurora dialog style retains WinUI's required `ContentDialog` template so
  `Ctrl+K` renders its controls instead of only the dimmed backdrop. Portable
  source-contract tests lock all three framework requirements. Theme-aware
  color aliases now feed gradient stops, code-painted glass plates re-resolve
  for Light mode and reduced-transparency fallback, and Budget follows the
  active Aurora canvas instead of mixing light text with a fixed dark plate.

### Changed

- **Droid wiki generation is local-only** — retired the failing unattended
  Factory workflow after proving user-scoped API keys are rejected without an
  active paid subscription. Committed `droid-wiki/` pages still reconcile to
  mem0 through the post-commit hook and nightly mirror job.

### Changed — Android Play version metadata

- Bumped Google Play `versionCode` to `42` with `versionName` `1.0.30` so the
  three-platform cut can publish a fresh AAB after `1.0.29` (`versionCode` 39).


### Added — Shared Rust Console release evidence

- Stable and Rust-authoritative Hosting deploys now consume the exact protected
  Shared Rust candidate proof and rollback bytes. Live smoke verifies a
  no-redirect deployment identity, normal evidence publishes immutably, and
  explicit rollback is separately review-gated and every retained result binds
  the exact deploy and evidence workflow attempts.
- Protected Android bundles now embed the immutable release tag as their
  `versionName`; native release verification rejects any filename/manifest
  version split before publishing evidence.

### Changed — Windows shell now renders the macOS Aurora liquid-glass design

- **Full visual parity pass on the WinUI 3 app** (`windows/app/`): the shell now renders the
  same Aurora "liquid glass" look as the macOS and Linux apps instead of the Pensieve
  ink/brass recolor. The design-token pipeline gains an additive Aurora group
  (`packages/design-tokens/tokens/aurora.tokens.json` — macOS dark/light ramps, liquid-glass
  tint/stroke/sheen/shadow recipes, macOS type scale) emitted to CSS/Swift/Compose/WinUI from
  the same DTCG source; the Windows theme is rebuilt on `ThemeDictionaries` (Light mode no
  longer paints dark plates), the glass vocabulary carries the macOS card radius/hover
  physics, and brand fonts (Outfit/Geist/JetBrains Mono/Fraunces, OFL) are bundled so type no
  longer falls back to Segoe/Consolas. Tray flyout, command deck, chat bubbles, Settings,
  onboarding, command palette, and dashboard all consume the new tokens; a CI gate
  (`scripts/windows-port/check-xaml-token-discipline.sh`) blocks raw colors/fonts outside
  `Theme/`. See `docs/windows-port/MAC_GLASS_PARITY_PASS.md` for the review map, validation
  matrix, and Windows-host evidence checklist.

### Added — Liquid dashboard command deck

- **A live, customizable command deck for the dashboard**: Added a dominant
  liquid-glass top rail with an always-current burn chart, compact appearance
  and layout controls, provider-aware shortcuts, and user-created destinations
  for charts, settings, models, and chats.
- **A full Charts workspace**: Added configurable spend visualizations, saved
  card layouts, time-range routing, and privacy-preserving AI insights, while
  keeping dashboard totals and charts synchronized with newly mined logs.
- **A clearer menu-bar popover**: Rebuilt the popover as adaptive transparent
  glass with clear and frosted modes, rounded sections, improved provider
  branding, and a larger live trend tile.

### Added — Junie (JetBrains) integration

- **First-class Junie CLI agent and provider**: Fully added JetBrains `junie`
  as a first-class local agent provider at parity with Droid/Codex/Claude.
  Implemented `JunieParser` to read `~/.junie/sessions/index.jsonl` and
  per-session `events.jsonl`/`state.json` (explicit usage buckets when present,
  character-estimate fallback otherwise, per-row provenance confidence), with
  disk-cache signatures, project mapping via the session index, and pricing via
  the shared model catalog. Included official Junie branding (JetBrains green
  `#48E054`, `JunieLogo` vector mark in the macOS and iOS asset catalogs), the
  `junie` CLI switcher/launch profile (`~/.local/bin/junie`, `JUNIE_HOME`,
  `JUNIE_API_KEY`), conservative auth discovery off `~/.junie` (sessions or API
  key — the config dir alone is created before sign-in), chat backend + stream
  runner routing (`junie --task`), onboarding scan/add support, daemon
  resume-handoff target, mission-planner fallback membership, and mobile
  runtime/tile/transcript surfaces. Junie mirrors Droid's posture: mirrored +
  archived to mobile, handoff-only (not native-resume eligible).

### Added

- **Adaptive foregrounds for animated desktop backdrops** - macOS and Linux now
  sample the effective rendered kernel at a bounded cadence and automatically select
  a WCAG AA light or dark semantic foreground family. Crossfades, both skins, canvas
  and CSS/native fallbacks, increased contrast, forced colors, and reduced motion use
  deterministic scrim and hysteresis behavior without full-frame readback.
- **Candidate-bound Shared Rust Functions releases** - production Functions
  releases now verify the exact deterministic source run, protected signer run
  and attempt, rollback bytes, selected compiled receipt, live source/version,
  domain-core profile, and Sentry state before publishing immutable v2 release
  evidence; manual legacy rollback uses a separately authorized and retained
  proof path.
- **Production Windows TPM App Check transport** - added authenticated
  server-issued challenges, durable one-time replay protection, TPM-backed CNG
  claim/public-key transport, a Windows `NCryptVerifyClaim` service, and
  mandatory OAuth composition with no shipping mock-attestation fallback.
- **Launch-readiness hardening** — added durable account-erasure barriers,
  resumable oldest-first reconciliation with poison-record quarantine, and
  privacy-safe retained audit receipts across Functions, Firestore, and Storage.
- **Computer Use quota enforcement and telemetry** — added a locked local
  app/daemon quota ledger, replay-safe reservations, privacy-safe cloud headers,
  transactional aggregation, and monotonic reconciliation. Cloud aggregates are
  explicitly operational telemetry, not authoritative billing evidence.
- **Cross-platform proof gates** — added real Android, Windows, and Linux test
  floors; non-vacuous diff coverage and duplication checks; deployment trust
  fixtures; migration rollback contracts; and repair-loop provenance controls.
- **Linux daemon event subscription authority** - replaces one-shot terminal
  subscription fixtures with bounded daemon-owned start/resume/stop state,
  monotonic cursors, restart recovery, cancellation tombstones, strict scope
  validation, and explicit degraded-pull metadata. The packaged shell now owns
  one lifecycle-aware data supervisor with offline pause, bounded backoff,
  foreground/background cadence, shutdown cancellation, and coalesced refresh
  of the mounted route.
- **Daemon-owned Linux onboarding authority** - replaces browser-local completion
  with atomic daemon state and typed snapshot/action/reset RPCs. Required steps
  cannot be skipped or executed out of order; Linux verifies the daemon,
  performs an ephemeral Secret Service/KWallet round trip, checks writable XDG
  storage, persists privacy choices, supports retry/resume/reset, and rejects
  malformed or forged completion in both Swift and TypeScript decoders.
- **Round-4 performance sweep** — state-of-the-art throughput, latency,
  memory, and energy improvements across macOS and iOS with no feature or
  visual changes:
  - **ParserDiskCache binary plist** (A1): switched from pretty-printed
    JSON to binary plist with dual-read fallback for backward
    compatibility. ~3–5× faster encoding, ~2–3× smaller cache files.
  - **SearchQueryCache bounded LRU + metrics** (A2): replaced unbounded
    dictionary with bounded LRU cache (256 entries) with eviction and
    observability via `OpenBurnBarMetrics`.
  - **Daemon connection back-pressure** (A3): capped simultaneously
    in-flight connection handlers via `BurnBarConnectionGate` to prevent
    FD exhaustion under load.
  - **Single-scan SQL occurrence counts** (A4): collapsed N full-table
    scans into one for `countOccurrencesInConversationFullText`.
  - **SearchService hydration JOIN collapse** (A5): merged two DB
    round-trips (chunks + documents) into a single JOIN query.
  - **iOS TrendAtlasCard memoization** (A6): cached digest/insights
    recomputation behind input-hash check via `DigestCacheStore`.
  - **iOS HermesSquareRoot rollback cache** (A7): hoisted filter+sort
    out of `body` into a `.onChange`-rebuilt `@State` cache.
  - **Incremental HNSW delta segments** (B1): LSM-tree "base + delta"
    overlay (`BurnBarVectorIndexDeltaOverlay`) eliminates full O(n log n)
    HNSW rebuilds on every projection cycle; bounded delta with
    compaction threshold. The overlay is wired into
    `VectorSemanticCandidateProvider`'s snapshot lifecycle — when chunks
    are added/updated/deleted, a delta is computed via a cheap metadata
    scan (`fetchChunkEmbeddingKeys`) plus an O(k) vector fetch for only
    the changed chunkIDs, avoiding the full rebuild. Compaction triggers
    when changes exceed `max(2000, baseSize / 5)`. Delta metrics are
    surfaced in `SemanticRetrievalHealthDetails`.
  - **Streaming Claude JSONL bounded accumulator** (B2): replaced O(n²)
    string concatenation with array-based join-once-at-finalize and 1 MB
    `maxFullTextBytes` cap; added `maxLineBytes` guard to
    `BufferedLineSequence` for pathological inputs.
  - **SQL-side credential scan pre-filter** (B3): `INSTR`-based WHERE
    clauses skip conversations without credential indicators before
    loading `fullText` into Swift memory.
- **Linux Computer Use input and panic lane** — Linux daemon-owned `system`
  sessions now wire a native input dispatcher, preferring AT-SPI2 for
  Wayland-accessibility clicks and X11/XTEST via `xdotool` as an explicit
  degraded fallback, with missing adapters failing closed. Added
  `openburnbar-cli computer-use panic-halt --session-id '*' --source hotkey`
  and packaged Linux shell global emergency shortcut registration as
  daemon-backed panic paths that trip the
  `$XDG_RUNTIME_DIR/openburnbar/privileged-input-kill` flag before session
  teardown.
- **Linux dual-architecture release closure** - builds aarch64 and x86_64
  AppImage/deb/rpm/daemon shards on native GitHub runners, aggregates only
  matching clean-commit shards, requires the full eight-artifact matrix, and
  binds checksums, Ed25519 signatures, source, SBOM, VEX, provenance, parity,
  Sigstore attestations, and the signed update feed before publication. Every
  native package now embeds the architecture-matched daemon plus Swift and
  SQLCipher runtimes and executes that packaged payload during shard smoke.
- **Linux signed update availability** - adds a native Tauri update verifier
  with a pinned Ed25519 public key and fingerprint, strict signed-feed schema,
  semantic-version/channel/architecture checks, bounded HTTPS fetching, and
  first-party artifact URL validation. The Updates surface now distinguishes
  current, available, offline, and rejected metadata states while keeping
  installation and rollback under the owning Linux package manager.
- **Linux accessibility evidence gate** - audits every desktop route plus
  degraded capability states with axe, captures live AT-SPI names, roles,
  states, and actions from the installed package, and requires Orca discovery,
  keyboard focus traversal, and zoom evidence before accessibility proof can
  pass.
- **Linux daemon chat gateway parity** — the Linux HTTP gateway now serves
  `POST /v1/chat/completions` through the shared provider router, relays
  OpenAI-compatible SSE streams, and records gateway usage events with cache
  read/creation token fields when providers report them.
- **Mission fan-out synthesis now launches Phase B second-stage missions** —
  tapping Synthesize on a completed fan-out group queues a sealed, read-only
  Hermes synthesizer mission with the child results as input, then records the
  queued synthesizer request in the group merge summary.
- **Settings overhaul — "Command Bridge"** — completely redesigned the Settings
  sidebar and navigation for discoverability:
  - **Sectioned sidebar**: the flat 14-tab list is now grouped into labeled
    sections (Agents & Models, Look & Feel, Account & Sync, System, More) with
    Home above as the default landing page.
  - **Home overview**: mission-control landing with live status grid (Daemon,
    Model Proxy, Accounts, Hermes, Cloud Sync, Indexing), an attention strip
    for items needing action, and task cards for the most common destinations
    (Accounts, Model Proxy, Appearance, Text Expansion, Cloud, Data & Privacy).
  - **Model Proxy as first-class tab**: the local OpenAI-compatible gateway is
    no longer buried under Daemon. New `ModelProxySettingsView` with a
    status-first hero (on/off + copyable endpoint + model/provider counts),
    routing strategy, live model catalog, and plumbing behind Advanced.
  - **Settings Copilot**: search-or-ask command bar. Tier 1 = instant manifest
    search (unchanged engine). Tier 2 = agentic: asks the question through
    `CLIBridge.chat()` with a system prompt carrying the action grammar and
    live settings state. Proposed changes render as confirm chips — nothing
    mutates until confirmed. Secrets are never writable through the registry.
    Falls back gracefully when no CLI backend is detected.
  - **Daemon rebranded to "Engine Room"** for clarity.
  - All legacy deep links, routes, and anchors resolve via the existing alias
    machinery — no saved link 404s.
  - Covered by `SettingsActionRegistryTests` (20 cases),
    `SettingsCopilotControllerTests` (14 cases), and
    `SettingsHomeAndSectionTests` (16 cases).
- **OMP provider parity** — added Oh My Pi (`omp`) as a first-class local CLI
  provider across Mac chat, direct mission launch, mobile relay/catalog
  surfaces, provider identity, and quota refresh. OpenBurnBar now reads
  redacted OMP usage via `omp usage --json --redact` and documents the provider
  in `docs/PROVIDERS.md`.
- **Chat workspace tiling (cmux/tmux-style) is now live in the dashboard.** The
  chat window mounts the pane workspace, so `⌘D` splits the active pane right,
  `⌘⇧D` splits it down, and `⌘W` closes a pane (the last pane falls through to
  the standard window close). Dragging a chat chip from the thread rail onto a
  pane now *suggests* where it will land: dropping in the center loads the
  conversation into that pane, while dropping on an edge opens it in a brand-new
  split pane on that side. Thread rows show an "open in a pane" hint, and the top
  toolbar hides its duplicate engine pickers while tiled (each pane carries its
  own). `AgentLens/Views/Chat/PaneWorkspace/*` + `DashboardChatWorkspaceView`.
- **Command Deck top-chrome redesign** — collapses ~146pt of stacked chrome
  (toolbar + tab-card strip) into one ~52pt bar with a ⌘K command palette for
  section fuzzy-filter + session search, and ⌘1–⌘7 section shortcuts.
- **Nest Hub Speak Now** — makes `/voice-refresh` queue a real bridge-page
  announcement event instead of acknowledging a no-op, so the rendered smart
  display can pulse and speak the current provider summary on its next poll.

### Fixed

- **macOS StoreKit entitlement resolution** — `MacCloudEntitlementStore` now
  reads StoreKit 2 current entitlements and transaction updates, maps the same
  Cloud / Cloud Pro / Cloud Ultra SKUs as iOS, and uses locally verified
  entitlements only when the cloud entitlement document is absent.

### Fixed

- **iPhone Call Mac action** — replaces the Mercury Live Sheet follow-up stub
  with real `media.call.invite` signaling over the live paired-Mac control
  stream, shows pending/ack status on iPhone, and keeps the Mac wake path scoped
  to the existing PushKit/FCM callable for Mac-originated calls.

- **Recount cloud usage duplication** - makes Mac usage IDs deterministic across
  Recount reparses, removes stale same-device Firestore usage docs, and reports
  the full cloud-sync batch total to analytics.

### Added - Windows 1.0.32 parity release

- **Windows parity release line** - advances the Windows x64 and ARM64
  direct-download candidates to the completed F1 product ledger and applicable
  F2 source composition, including the local gateway, durable agent runs,
  Computer Use, project-code memory, Elder Wand fusion, companion CLI,
  Switcher, indexed search, connectors, and native release packaging.

- **Signed native-engine packaging** - stages both the Core and Kernel SwiftPM
  resource bundles beside the Windows native engine, hashes every resource in
  its manifest, and executes the usage parser from the staged and published
  layouts before Authenticode signing and portable/MSIX packaging.
- **Physical certification integrity** - binds imported physical-device and
  performance receipts to their raw hardware attestation and exact signed
  artifact manifest hashes, rejecting virtual, stale, mismatched, or
  substituted evidence.
- **Windows artifact-profile validation** - accepts the UTF-8 BOM emitted by
  MSBuild's `WriteLinesToFile` task while continuing to reject malformed or
  mismatched signed domain-core profile receipts.

## [1.0.29] - 2026-07-05

### Added

- **Latest-main macOS release cut** - advances the direct-download release to
  `1.0.29` from `origin/main` commit `1b62ec42bd`, including the Windows
  parity integration merge, the post-merge Windsurf/Windows/AAR fixes, Command
  Bridge settings IA, Model Proxy tab, and Command Deck top-chrome redesign.
- **Fresh TestFlight build line** - bumps the iOS, widget, and keyboard build
  number to `82` while keeping the approved iOS marketing version at `1.0.2`,
  giving App Store Connect a unique upload for the newest source cut.
- **Android release metadata** - bumps the Android release bundle to
  `versionCode` 39 / `versionName` `1.0.29` so Google Play metadata remains
  aligned with the same release source.

### Fixed

- **iOS 27 mobile stability** - carries the Firebase source-built gRPC guard,
  Firestore cloud-sync repair, edge-to-edge backdrop fixes, Face ID usage
  description, and Mercury mirror consent/session stability fixes into the
  mobile release line.
- **Cloud sync resilience** - keeps one bad escrow entry from killing all usage
  uploads and binds usage project-name seals to their document AAD context.

## [1.0.28] - 2026-07-03

### Fixed

- **Cloud device presence** - publishes the Mac sync heartbeat before encrypted
  usage uploads can block, so signed-in iPhones can see the Mac as recently
  active instead of "last seen: never."
- **Mobile sync health fallback** - lets iOS build the Mac sync status from the
  device registry when the richer `sync_status` document has not landed yet.
- **Release signing workflow** - exports the Developer ID app provisioning
  profile path before decoding it in GitHub Actions, preventing the notarized
  DMG job from failing before signing.
- **Android release metadata** - bumps the Android release bundle to
  `versionCode` 38 / `versionName` `1.0.28` so Google Play receives the same
  source cut as the macOS sync hotfix.

## [1.0.27] - 2026-07-03

### Fixed

- **Direct-download Firebase Auth Keychain access** — signs the notarized
  Developer ID app with the `4Y367DF25B.com.openburnbar.app` Keychain access
  group and embeds the matching all-devices Mac App Direct provisioning profile,
  so the downloaded app can open the Firebase Auth account page without the
  macOS Keychain error banner.
- **Release signing guardrails** — makes the macOS website-release builder,
  GitHub release workflow, and public download trust gate fail if the app is
  missing the direct-download provisioning profile, application identifier,
  team identifier, or Firebase Auth Keychain group.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 37 / `versionName` `1.0.27` so Google Play receives the same
  source cut as the macOS hotfix.

## [1.0.26] - 2026-07-02

### Added

- **Tabbed Chat pane workspaces** — extends the cmux-style Chat tiling surface
  with multiple conversation tabs, tab restore/reopen, per-tab names/colors,
  per-pane names/colors, pane zoom, pane-to-tab moves, drag-to-swap panes, and
  rail indicators that distinguish open panes from hidden panes with completed
  background replies. Completion alerts now route through local notifications
  and focus the relevant pane when tapped. The workspace persists via a v2
  snapshot while still migrating the original v1 tiling layout.

### Fixed

- **Dashboard chat launch stability** — hardens the shared CLI launch path used
  by the dashboard and popover so Claude, Hermes, and Codex chat replies keep
  working when the search-index projection backlog is unavailable or the pinned
  executable needs localized recovery messaging.
- **Hermes fallback chat** — lets Hermes chat recover without a configured
  bearer token and turns key rejection into a self-healing, actionable prompt
  instead of a dead chat pane.
- **Release download link** — keeps the public website's macOS fallback download
  pinned to the smoke-proven GitHub Release asset while the updater feed remains
  owned by the promoted release.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 36 / `versionName` `1.0.26` so Google Play receives the same
  source cut as the macOS release.

## [1.0.25] - 2026-07-02

### Fixed

- **Release publish job** — replaces the macOS publish step's Bash 4-only
  `mapfile` usage with Bash 3.2-compatible provenance collection, so the
  already-built, signed, notarized, and smoke-tested artifacts can be uploaded
  from GitHub's hosted macOS runners.
- **Current-main release cut** — moves the public release forward from the
  smoke-proven `v1.0.24` tag to the newest `main` state, including the Computer
  Use downgrade-only trust clamp and the committed remediation tracker.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 35 / `versionName` `1.0.25` so Google Play receives the same
  release cut as the macOS publish retry.

## [1.0.24] - 2026-07-02

### Fixed

- **Release smoke health check** — retries the public release from the newest
  `main` cut after `v1.0.23` built and notarized successfully but failed the
  packaged DMG smoke test. The signed `OpenBurnBarCLI health` command now uses
  the daemon socket client directly for the exact health probe instead of
  constructing the full CLI runner and opening the default profile store first,
  preventing the smoke harness from hanging before it can verify the packaged
  daemon.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 34 / `versionName` `1.0.24` so Google Play receives the same
  release cut as the macOS retry.

## [1.0.23] - 2026-07-01

### Fixed

- **macOS release libsignal link** — prepares the ignored
  `OpenBurnBarSignalFfiMac.xcframework` from the vendored libsignal submodule
  inside the protected release workflow before Xcode resolves packages or links
  the Developer ID app, so the public DMG no longer depends on a developer's
  local FFI build output.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 33 / `versionName` `1.0.23` so Google Play receives the same
  release cut as the website retry.

## [1.0.22] - 2026-07-01

### Fixed

- **Release notarization watchdog** — supersedes the wedged `v1.0.21` macOS
  publish run after the signed DMG entered the Apple notarize/staple step and
  never returned from the old unbounded shell command. Release CI now wraps
  `notarytool` and `stapler` in a process-group watchdog so Apple-tool hangs
  retry or fail with clear logs instead of consuming the protected release job.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 32 / `versionName` `1.0.22` for the fixed release cut.

## [1.0.21] - 2026-07-01

### Fixed

- **Release smoke auth hardening** — pulls the public release forward from the
  failed `v1.0.20` tag to the newest `main` commit and closes the release-smoke
  token leak: the smoke daemon now receives its socket auth token from a chmod
  600 token file instead of LaunchAgent environment, diagnostics redact token
  fields, local smoke runs no longer print the raw GitHub mask command, and
  explicit token-file arguments override stale inherited launchd auth.
- **Fresh mobile release build** — bumps the iOS, iPadOS, widget, and keyboard
  build number to `81` so the TestFlight upload for this release is unique and
  tied to the same source cut as the macOS and Android artifacts.
- **Android release metadata** — bumps the Android release bundle to
  `versionCode` 31 / `versionName` `1.0.21` so Google Play receives the same
  release cut as the website and Apple lanes.

## [1.0.20] - 2026-07-01

### Fixed

- **Release DMG smoke resilience** — supersedes the failed `v1.0.19` publish
  run after the signed app, notarized DMG, Android AAB, and provenance artifacts
  built successfully but the macOS 15 smoke runner timed out during the
  installed-layout daemon/CLI health handshake. The gate still requires the
  mounted DMG to launch the app and authenticate through the signed CLI, but it
  now gives first-run code-signature validation realistic cold-runner headroom
  and emits launchd/socket diagnostics if health does not come up.

## [1.0.19] - 2026-07-01

### Fixed

- **Foreground Xcode release heartbeat** — supersedes the failed `v1.0.18`
  publish run. That run proved Android packaging, extension build, Functions,
  daemon release binaries, package resolution, and the initial heartbeat all
  ran, but the macOS unsigned Release app step still went silent during the
  long Xcode phase. The release lane now runs `xcodebuild` in the background,
  keeps the foreground shell printing a one-minute heartbeat plus recent
  `xcodebuild` log output, and emits the final Xcode tail on failure so the
  runner cannot silently kill a healthy build without evidence.

## [1.0.18] - 2026-07-01

### Fixed

- **Release Xcode heartbeat** — supersedes the failed `v1.0.17` publish run
  with the same newest-`main` source after Android AAB packaging succeeded.
  The macOS unsigned Release app build entered a long quiet whole-module Xcode
  phase and GitHub terminated the step without a compiler error. The release
  lane now emits a one-minute heartbeat while `xcodebuild` is still running, so
  quiet-but-active macOS packaging can reach signing, notarization, upload, and
  live feed verification.

## [1.0.17] - 2026-07-01

### Fixed

- **Release lane wall-clock cap** — supersedes the cancelled `v1.0.16`
  publish run with the same newest-`main` source after the Android entitlement
  fixture fix was proven in CI. The prior run passed Swift tests, release app
  smoke, SQLCipher, mobile smoke, retrieval replay, and Android unit tests, then
  hit the protected `build-and-release` job's 180-minute cap while the signed
  Android AAB was still building. The release packaging lane now has enough
  bounded headroom for Android signing, macOS signing, notarization, provenance,
  and artifact upload to finish instead of cancelling before publish.
- **Owner-approved release retry path** — manual release reruns can now skip
  already-proven slow validation gates only when the operator supplies owner
  approval and a prior GitHub Actions run URL. The retry still rebuilds the
  signed Android bundle, signs/notarizes macOS artifacts, runs artifact smoke,
  publishes, and verifies the live feed.

## [1.0.16] - 2026-06-30

### Fixed

- **Android release gate entitlement fixture** — supersedes the failed
  `v1.0.15` publish run with the same newest-`main` source, but fixes the
  Android `HostedQuotaSubscriptionStoreTest` active-subscription fixtures that
  expired at noon UTC on release day. The full Android JVM gate now uses a
  stable future active-entitlement fixture, while the explicit expired-purchase
  regression remains pinned to `2020-01-01T00:00:00Z`.

## [1.0.15] - 2026-06-30

### Fixed

- **Bounded release-critical mobile gate** — supersedes the failed `v1.0.14`
  publish run with the same newest-`main` source and pane-enabled macOS app, but
  keeps the release workflow from running the full iOS simulator suite in the
  artifact publication path. The release lane now runs a focused mobile XCTest
  slice for App Store/TestFlight metadata, Firebase/App Check readiness, auth
  startup safety, iPad navigation, mobile kernel/backdrop parity, Pulse/theme
  basics, Sentry scrubbing, and provider setup contracts. The full mobile suite
  remains a PR/CI gate.

## [1.0.14] - 2026-06-30

### Fixed

- **Cold-runner release app smoke timeout** — supersedes the failed `v1.0.13`
  publish run with the same newest-`main` source and pane-enabled macOS app, but
  gives the bounded release-critical app XCTest slice enough GitHub macOS
  cold-build headroom to compile the app host and SwiftPM graph before XCTest
  starts. The release gate still uses the narrow direct-download, Firebase/App
  Check, menu-bar/popover, and Chat pane tiling filters instead of the full app
  suite.

## [1.0.13] - 2026-06-30

### Fixed

- **Promoted release cut from newest main** — supersedes the failed `v1.0.12`
  publish run with the same pane-enabled source plus the release-lane fix
  itself. The tag includes PR #1095's cmux-style Chat pane tiling, PR #1104's
  chat send fallback repair, and the `v1.0.12` release metadata.
- **Bounded release-critical app gate** — the release workflow now runs a
  shared, focused app-host XCTest slice for direct-download metadata,
  Firebase/App Check readiness, menu-bar click/popover behavior, and Chat pane
  tiling instead of the full app suite that timed out while still passing. The
  full app suite remains a PR/CI gate; `scripts/test-openburnbar-release-smoke.sh`
  uses the same shared release-critical filter list so the runbook and workflow
  cannot drift.

## [1.0.12] - 2026-06-30

### Added

- **cmux-style multi-pane tiling for the Chat workspace** — the right-side
  conversation viewer is now a tiling tree of independent panes. Press ⌘D to
  split the active pane side-by-side, ⌘⇧D to split it stacked, and ⌘W to close
  the active pane and re-flow its sibling into the freed space (the last pane is
  indestructible — single-pane ⌘W falls through to the normal macOS window
  close). Drag any thread from the left rail onto a specific pane to load that
  conversation there, with a live drop highlight on the targeted pane and the
  others unchanged. Each pane is a fully independent conversation — its own
  thread, message stream, model/engine picker, and composer — streaming
  concurrently with zero cross-talk (per-pane `ChatSessionController`,
  `CLIBridge`, and search service; every pane shares the one GRDB-backed
  `DataStore`, isolated by thread id). Dividers drag to resize neighbors. The
  layout tree, split fractions, each pane's bound thread, and the active pane all
  persist across relaunch. With a single pane the screen is pixel-identical to
  before — per-pane chrome (header, focus ring, split/close affordances) appears
  only once tiled, and the top toolbar hides its now-duplicate engine pickers.
  The app-wide controller becomes the workspace's primary pane, so every other
  surface that holds it is unaffected; tiling panes run with persistence disabled
  so they never touch the global chat `UserDefaults` keys. Covered by
  `PaneWorkspaceModelTests` (split / close / primary re-home / persistence
  round-trip / exactly-one-primary repair / fraction clamp) and
  `ChatSessionControllerPaneModeTests`. Design, adversarial loophole-hunt, and
  review history documented in `docs/CHAT_PANE_TILING_PLAN.md`.

### Fixed

- **Newest-main release cut** — supersedes the canceled `v1.0.11` publish run so
  the public release includes the current `main` tip, including PR #1095's
  cmux-style chat pane tiling and PR #1104's chat send fallback state repair in
  addition to the v1.0.11 release-lane bounds.

## [1.0.11] - 2026-06-30

### Fixed

- **Newest-main release cut** — supersedes the canceled `v1.0.10` publish run so
  the public release includes the latest `main` tip, including the mobile
  Agents/Insights Aurora backdrop top-blend fix from PR #1102.
- **Release lane duration bounds** — keeps Swift and macOS app tests in the
  release workflow, but removes release-time coverage collection and adds
  explicit Swift/app-test step timeouts so emergency publishes do not sit opaque
  for hours on a cold GitHub macOS runner.

## [1.0.10] - 2026-06-30

### Fixed

- **Release-gate Pixel Clock test hardening** — prevents the no-controller
  Pixel Clock settings adapter test path from starting a real controller and
  scanning the LAN in CI, avoiding a full macOS app-test hang during release.
- **Latest main inclusion** — carries forward the `v1.0.9` menu-bar flame,
  left-click popover, mobile Pulse seam, and dashboard Liquid Glass sidebar
  refinements now landed on `main`.

## [1.0.9] - 2026-06-30

### Fixed

- **Menu-bar flame and popover hotfix** — the macOS menu bar now defaults to
  the flame-only status item while preserving the `OpenBurnBar` accessibility
  label, and left-click reliably opens the popover instead of being swallowed by
  the secondary-menu path. Added focused runtime/prewarm regression coverage and
  verified the installed app live from `/Applications/OpenBurnBar.app`.
- **Mobile Pulse top seam fix** — removes the scroll-edge suppression that
  caused a visible hard seam under the iOS/iPadOS status bar after the latest
  mobile backdrop work.

## [1.0.8] - 2026-06-30

### Fixed

- **Current public macOS release cut** — advances the direct-download release to
  the current `main` tip after `v1.0.7` was cut before PR #1094 landed. The
  release includes PR #1086's continuous-field substrates, Atelier spend graph,
  iOS WebGL kernel parity, substrate picker redesign, and macOS tall-card
  substrate previews; the popover keyboard retoggle fix; the v1.0.7 publishable
  scanner repair; the mobile navigation/backdrop/kernel work already merged to
  main; and a named owner-emergency release lane for the public macOS artifact
  while the signed counsel packet is collected.

## [1.0.7] - 2026-06-30

### Fixed

- **macOS public release cut** — ships the public-download trust gate from
  `1.0.6` on a fresh release tag after the `1.0.6` workflow failed before
  GitHub Release asset publication. The publishable-tree secret scan now
  allowlists only reviewed public Firebase client identifiers, deterministic
  test/KAT strings, and fake no-secrets-test sentinels, and it handles
  uninitialized gitlink submodules without trying to copy directory entries.

## [1.0.6] - 2026-06-29

### Added

- **Swipe-through mobile navigation with live Liquid Glass tray preview** —
  iPhone users can now navigate between Pulse, Burn, Insights, Streams, Agents,
  and Store via two complementary gestures. (1) Horizontal swiping on the root
  content area advances one tab per completed swipe, respecting the
  `AuroraNavDestination.allCases` order and preserving vertical scrolling inside
  each tab. (2) Pressing and dragging across the bottom nav tray live-previews
  the destination under the finger: the visible content follows in real time, a
  Liquid Glass viewfinder capsule tracks the touch position and snaps to the tab
  center, the tab item under preview shows its selected visual state, and
  releasing commits the tab. Haptics fire once per destination boundary crossing
  during scrubbing with a stronger impact on final commit; analytics fire only on
  commit. Full-screen overlays (Hermes keyboard, Cloud Store, Chart Studio,
  Mission Console, Agent Live Stage split/maximize) disable both gestures. Reduce
  Motion and Reduce Transparency are respected throughout. A pure gesture model
  (`AuroraNavGestureModel`) holds the testable destination resolution, edge
  clamping, and commit/cancel logic; 35 focused unit tests cover the math.

- **Mobile backdrop kernels** — iOS/iPadOS and Android now expose the same 30
  app.burnbar.ai backdrop kernel IDs and labels used
  by the website console. The existing Website Background switch remains the
  coarse on/off control; when enabled, Theme settings now include a Backdrop
  Kernel picker backed by native SwiftUI/Compose Canvas renderers, with
  Constellation continuing to use the provider-glyph field and serving as the
  launch-safe default so heavier kernels are opt-in. Added catalog and
  persistence tests on both mobile platforms so future website kernel additions
  cannot silently drift from the apps.
- **Swarm substrates** — the provider-glyph swarm can now be composed in any of
  ~24 hand-tuned *materials* ported from the imaginethat-llc lab, organized into
  six families that couple to the active backdrop theme exactly like the web
  glyph gallery: **Constellation** (Stellar Plasma, Cut Star Sapphire, Drawn
  Constellation, Dendritic Frost), **Flow Field** (Plankton Wake, Glass Ribbon,
  Silk Streamline, Petal Drift), **Aurora** (Wisp Plasma, Polar Ice Prism, Aurora
  Filament, Drift Motes), **Iridescent Mesh** (Caustic Pool, Gradient Patch, Iso
  Contour, Living Grain), **Moiré** (Fringe Bloom, Lattice Facet, Ruling Grating,
  Film Bubble), and **Volumetric** (Crepuscular Shafts, Smoked Glass Slab, Silk
  Filament, Dust Motes). Each repaints the live particle field in its own idiom
  (additive bloom + hot cores, silk streamlines, faceted gems, godrays…) on a
  native SwiftUI `Canvas`, perf-tuned with cached sprites and a shared
  nearest-neighbor structure provider to hold 60fps. Pick one per theme in
  Settings → Appearance → Background & Effects → Swarm Substrate; the offered
  styles re-couple live when you switch the backdrop kernel. Persisted via the
  shared `swarmSubstrate` preference and honored by the dashboard backdrop. The
  default ("Plain · DOTS") is the original dot look, so nothing changes until you
  opt in.
- **Dashboard layout concepts** — the macOS Overview can now render in any of
  six named layouts: **Atelier** (the default; a full-bleed, kernel-forward
  hero with floating glass stat cards), **Aurora** (provider rail + open swarm
  field + data band), **Nebula** (bento grid), **Constellation** (centered
  command column over a full swarm), **Cockpit** (mission-control KPI grid with
  spend-share rail, routing stage, and The Wand), and **Classic** (the original
  information-dense scroll). Switch instantly from the inline switcher pinned
  atop the Overview, or set a default in Settings → Appearance → Theme. Every
  concept floats glass over the shared kernel + provider-swarm backdrop and
  keeps the full provider / model / activity lanes one click away in a "more
  details" drawer, so no information is lost. Persisted via the shared
  `DashboardLayout` preference (`dashboardLayout` key), mirroring `AppSkin`.
- Live Appearance Preview card at the top of the Appearance settings page.
  Renders a miniature dashboard mockup (toolbar, sparkline, provider cards,
  backdrop) that reflects the current theme, skin, background, and Liquid
  Glass transparency selections in real time, so users see exactly what they
  will get before applying changes.
- Quick-Theme menu (`BurnRailAppearanceQuickMenu`) on the dashboard toolbar.
  A compact menu-pill next to the actions capsule lets users flip appearance
  mode (System/Light/Dark), app skin (Aurora/Editorial), and background
  (Off/Swarm/Constellation) without opening Settings. Includes a shortcut to
  open the full Appearance settings page.
- Standalone settings gear (`BurnRailSettingsButton`) promoted to its own
  toolbar slot so it is always visible regardless of window width.

### Fixed

- **macOS public release copy** — replaces the stale `0.1.2-beta.1` website
  fallback lane with a current `1.0.6` release path and adds fail-closed gates
  for the two user-visible regressions it exposed: unsigned/unstapled DMGs that
  trigger Gatekeeper "move to Trash" warnings, and app bundles missing the
  sealed `GoogleService-Info.plist` needed for Google, Apple, and email auth.
- **Swarm substrate renderers** — tightened the bespoke substrate ports with
  frame-scratch reuse, cached glow/sprite work, safer contour/neighbor gating,
  richer dark/light paint passes, and an explicit skipped preview-render test
  harness that can rasterize every substrate for local visual QA without
  running during normal CI.
- **Swarm substrate throttling** — restored battery-mode gates for expensive
  bloom, sheen, and sprite halo passes in the polished substrate renderers while
  keeping the core dot/body marks visible.
- Settings cog (gear icon) no longer disappears from the dashboard toolbar at
  narrow window widths. Previously it was bundled inside the
  `BurnRailActionsSection` capsule with import and recount, and macOS would
  crowd it off-screen. The gear now lives in its own `ToolbarItem` slot,
  independent of the actions capsule.

### Changed

- Appearance settings page reorganized from a single 20+ row flat list into
  three clearly-labeled sections behind a segmented control: **Theme**
  (mode, skin, Liquid Glass), **Menu Bar & Launch** (menu bar, icon, login,
  Premium UX), and **Background & Effects** (swarm, constellation, kernel
  backdrop, desktop wallpaper, sparkles, shape cycling). All existing options
  are preserved — just grouped for discoverability.
- Drag-and-drop files onto the floating 3D pet (or 2D avatar) to auto-attach
  them as chat attachments from any page, Space, or fullscreen app. The pet
  floats above every desktop surface, so it's inherently a global drop target.
  Dropping an acceptable file (file URL, image, PDF, text document — same
  pasteboard types and per-kind size caps as the chat composer) stages it on
  the shared `ChatSessionController` via the existing `HermesAttachmentLoader`
  pipeline, plays a celebratory `react` beat, and opens the pet chat bubble
  which renders a mercury-styled `ChatAttachmentTray` (Option C feedback). A
  drop on empty panel padding passes through to whatever window is beneath
  (reusing the renderer's existing `containsVisibleContent(at:)` gate), so the
  pet never swallows a drop aimed at another app. When no chat is attached the
  pet still reacts so a drop is never inert. Covered by
  `PetDropAttachmentTests` (11 tests: gate acceptance, URL/image staging,
  oversized rejection, react+bubble feedback, no-chat safety, forwarder
  round-trips, delegate perform).

### Changed

- Redesigned the Prepare Hermes wizard with a state-driven "Make Gateway
  Reachable" action and the editorial Observatory design language. The wizard
  no longer loops "not reachable yet" with no remediation: a new
  `HermesSetupWizardController` derives a single `GatewayReachabilityState`
  (cliMissing / apiServerDisabled / dashboardOnly / gatewayRunning /
  unreachable / unknown) and the Connect step renders one editorial hero per
  state, each with its own copy and the single primary action that resolves it.
  The "Make Gateway Reachable" button drives `openHermesAndGateway` (ensure
  `.env`, install + launch gateway, launch dashboard, re-probe) instead of
  just re-probing. The wizard's mutable state is extracted behind a
  dependency-injected, `@MainActor @Observable` controller so the reachability
  logic, step gating, and remediation are unit-testable. Window size grew to
  560×620 to fit the editorial hero.

### Fixed

- Kept a static dashboard fallback underneath the experimental Window Backdrop
  kernels, so a WebKit/WebGL renderer failure no longer leaves the dashboard
  blank while avoiding a permanent second native swarm renderer. Window
  Backdrop now works independently from the Swarm Background toggle.
- Fixed isolated Claude OAuth accounts (Settings → Accounts) showing a red
  "Credential not found" badge and a permanent "Refresh credential" button even
  right after a successful sign-in. Claude Max/Pro OAuth profiles routinely
  authenticate while Anthropic returns no quota buckets; the row classified that
  empty-quota snapshot as a missing credential, producing a self-contradictory
  card (the message said the credential *was* signed in) and an endless
  refresh-nag loop. A credential that auth discovery — or an official-API quota
  snapshot — confirms is present is now reported as "Quota unavailable" (amber),
  never "Credential not found", and the post-refresh confirmation truthfully
  reports "Credential refreshed and connected" instead of promising quota that
  some accounts never expose. The classification is covered by new unit tests.
- Unblocked the test target: `HermesSetupWizardController.autoProbeTask` was
  `private` but the committed `HermesRuntimeLauncherTests` test asserts
  `controller.autoProbeTask` is nil after `stopAutoProbe()`. The property is
  now `internal` so the test compiles and the full test target builds cleanly.
- Stopped the 3D pet/avatar from flashing a bird's-eye (top-of-head) view the
  instant you click it to chat. The SceneKit camera was re-fitting itself to the
  model's presentation bounds on *every* pose change (`idle → listen` on chat
  open). Re-running that fit against an unsettled, mid-blend skinned pose — whose
  bounding sphere is momentarily degenerate/NaN — snapped the camera for a frame
  and read as a top-down look. The camera now frames the pet exactly once per
  mount/form-swap (upright, face-on, after the skinner settles) and then stays
  put until the user drags it; the one-shot fit also guards against a non-finite
  bounding sphere so a degenerate first frame retries instead of latching a bad
  (bird's-eye) framing. Regression test asserts the camera stays level and its
  world transform is unchanged across an `idle → listen` pose change.
- Made macOS updates converge on one canonical app launch. The direct-download
  updater now terminates stale OpenBurnBar GUI processes, normalizes
  LaunchServices registrations, and relaunches `/Applications/OpenBurnBar.app`
  by exact path; source-channel updates use the same one-click install/cleanup
  flow through `scripts/source-update-install.sh`.

### Security

- Hardened Android credential transfer to v2 split tokens: Android now generates
  a public `ct_...` handle plus a device-only human-safe secret, encrypts with
  AES-GCM AAD bound to `credential_transfers:v2:<ownerUid>:<transferId>`, and
  sends Cloud Functions only the handle and ciphertext. Firestore rules deny all
  client access to `credential_transfers`; create/claim/complete/cancel are
  server-owned, legacy 12-character transfers are rejected with no fallback,
  `expiresAt` has a TTL override, logs redact old/new transfer secrets, and
  Mac/iOS ECIES escrow remains on `escrow_grants` / `escrow_envelopes`.
- Hardened production Firebase deploy boundaries: Hosting now builds immutable
  artifacts in an unprivileged job, deploys with a hosting-only WIF service
  account, verifies SHA-256 manifests and artifact file types, and uses generated
  no-predeploy Firebase configs. Functions and Firestore deploys now prepare the
  pinned Firebase CLI before auth, use direct binary deploys with generated
  no-predeploy configs, and the PR security gate self-tests the fail-closed
  boundary against raw `firebase.json`, post-auth npm/build, legacy secrets,
  shared hosting SA, and special-file artifact regressions.

## [1.0.5] - 2026-06-19

### Release

- Cut macOS `1.0.5` from `origin/main` after the June 2026 security,
  reliability, analytics-consent, memory, and daemon-routing hardening work.
- Prepared a fresh iOS TestFlight build line as `1.0.2 (75)` without
  auto-releasing the already-approved `1.0.1` App Store version.
- Fixed Claude Code Anthropic overload handling so upstream `529 overload`
  responses cool down the saturated route and fail over to the next healthy
  key instead of surfacing avoidable user-visible failures.

### Removed

- Removed the experimental interactive-Claude meter-bypass path (Part B0 + B2): the `ClaudeInteractiveSessionExecutor` gateway executor, the `ClaudeInteractiveMeterExperiment` diagnostic + its `claude-meter-experiment` CLI command, the `OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE` opt-in and its Settings UI toggle. Claude Code's first-run workspace-trust dialog cannot be driven reliably from a headless PTY (verified against 2.1.183), so the path no longer worked and is gone rather than patched. The legitimate human-driven `claude-handoff` feature (B1) is retained; its `ClaudeCodeJSONLUsageProbe` and claude-binary discovery helpers were relocated into the handoff service.

### Quota Freshness

- Audited all 16 adapters in `QuotaRefreshActor.adapters` for eager-fetch capability. Every adapter can produce a snapshot on first launch when credentials are present: API-key adapters (MiniMax, ZAI, DeepSeek, Copilot, Kimi, OpenAI, Mimo, Warp) hit their provider endpoints directly; cookie/session adapters (Cursor, Ollama, Factory) resolve from keychain or local stores; local-file adapters (Factory droid sessions, Codex rollout scan, Claude JSONL, Antigravity history, Aider analytics, Kilo Code, Forge) read on disk with no prior-usage dependency. The three trigger-adjacent adapters already have eager fallback paths: Claude (JSONL scan + OAuth usage API), Codex (OAuth usage API + rollout scan), XAI (Management API for GrokBuild, pacing log for SuperGrok).
- Fixed Android `QuotaStore.startAutomaticRefresh`: the first `refreshStaleCloudQuotaIfPossible` call now fires immediately on loop entry instead of after a 15-minute `delay()`, so connected providers' quotas land on first render after sign-in.
- Fixed iOS Mobile `QuotaStore.startAutomaticRefresh`: the first `refreshStaleCloudQuotaIfPossible` call now fires immediately on task entry instead of after a 15-minute `Task.sleep`, matching the Mac `initialDelay = .zero` behavior.
- Mac (`ProviderQuotaService.startAutomaticRefresh`) already fires at `initialDelay = .zero` and is covered by `test_startAutomaticRefreshFiresImmediatelyByDefault` (77/77 ProviderQuotaServiceTests green).

### Added

- Added the BurnBar Remote UniFFI bridge for the gen-2 remote-control engine:
  a Rust `burnbar-remote-ffi` crate, reproducible XCFramework/AAR build scripts,
  generated Swift/Kotlin bindings, a Swift `BurnBarRemoteEngine` package product,
  an Android `:burnbar-remote` module, and CI parity checks that rebuild the
  native artifacts before running focused Swift/Kotlin bridge smokes.
- Added local MCP Project Code Memory and durable agent-memory tools: project-scoped remember/recall/forget/audit/analytics, local-only code indexing/search/context packs, lexical symbol/reference/call-graph lookups, cached diagnostics, index status, and a memory doctor. Code indexing rejects secret-bearing files before persistence, stamps blob/commit identity, records label-only audit events, and stays local-only by default.
- Hardened Project Code Memory readiness signals: code snippets/context packs now use explicit untrusted-content envelopes, stale code indexes degrade instead of returning clean empty success, deterministic fingerprints no longer influence project-code ranking, Python code read tools open SQLite read-only, hosted code MCP tools are disabled by default, Swift/Python share a secret-scanner corpus with decode/entropy coverage, Git worktrees use exclude-standard ignore semantics, manifest-backed delta indexing skips unchanged files and prunes removed files, Git fingerprint-backed Project ID v2 preserves identity across moved checkout paths, audit hashes use a unified sequence-bound v2 payload, per-query freshness caches avoid repeated file reads while filtering stale candidates, Swift call graph traversal honors bounded `depth`, and `doctor`/index status report `PROJECT_CODE_MEMORY_PRODUCTION_READY=false` until remediation proof gates complete.
- Hardened local MCP setup for Project Code Memory: `tools/openburnbar-mcp/setup.sh` now builds or verifies the Rust `project-code-static-parser` helper with a smoke JSONL request, rebuilds stale parser releases when source/tests are newer, recreates stale path-bound virtualenvs, the README tools table is valid Markdown again, and the Hermes `burnbar-operator` skill documents the code-memory tools.
- Unified Project Code Memory chunker parity fixtures: Swift and Python now read `tools/project-code-memory/chunker-parity-fixture.json`, share the 2400-character/240-overlap newline-aware chunking contract, and regression-test identical chunk ranges.
- Added Project Code Memory storage budgets and daemon-owned watch mode: index status now reports storage bytes, budget, and compaction metadata, storage accounting includes source bytes, stored chunk text, an FTS mirror/metadata estimate, and vector blobs where present, SQLite incremental vacuum now runs only when freelist/page metrics cross the local compaction policy, `index --watch` / `burnbar_watch_project` reindex on source or git-ref changes through the daemon write path, and direct local MCP indexing honors the same budget fields.
- Hardened Project Code Memory watcher signatures for Git metadata: daemon watch signatures now resolve worktree-aware git dirs/common dirs, hash `.git/HEAD`, refs, and `packed-refs`, and test that HEAD/ref movement changes the index signature even when source files are unchanged.
- Added native FSEvents nudges to daemon-owned Project Code Memory watch mode: watches include the project root plus resolved git metadata dirs, wake the existing signature-based reindex path quickly, and keep the timer as a fallback.
- Hardened the Project Code Memory static parser JSONL service: the Rust helper now flushes every per-line response and has an integration test proving one long-lived process handles multiple requests.
- Recorded and enforced the Project Code Memory SQLCipher release policy: ADR 011 makes SQLCipher a release-readiness dependency, Swift/Python status reasons keep stock plaintext builds non-production, and fast feedback now fails a release-ready flip unless the daemon SQLCipher proof flag is present.
- Added explainable Project Code Memory rank features: code search hits now keep the existing numeric rank/score while exposing BM25, lexical-rank, and fallback feature values for callers and tests.
- Improved Project Code Memory context-pack token budgeting: Python MCP packs now estimate the final wrapped file sections with `tiktoken` when available, fall back to a structured heuristic, and report the estimator used.
- Exposed Project Code Memory repo maps through `explore`: responses now include artifact/symbol totals, language byte/file counts, and top indexed files alongside context-pack hits.
- Narrowed default Project Code Memory indexing to static-parser-supported source extensions (`.swift`, `.ts`, `.tsx`, `.py`) until additional Tree-sitter/SCIP coverage lands, keeping indexed languages aligned with the precision tier.
- Documented Project Code Memory retention/forget and hosted-code asset policy: added local/hosted retention rules, explicit Pensieve and Remote MCP code asset-class gates, an operator runbook for reindex/reset/compaction/parser/SQLCipher/hosted-disable, and a fast-feedback policy check for default-off sealed-only hosted code.
- Added the Project Code Memory Phase 4 static parser tier: a stateless Rust Tree-sitter helper for Swift, TypeScript/TSX, and Python emits SHA-gated `static_tree_sitter` symbols with structured tier evidence, while daemon/local MCP fall back to `lexical_fallback` when the helper is unavailable or stale.
- Added a Project Code Memory 100k-symbol load gate (`scripts/ci/project-code-memory-load-test.py`) that verifies storage-budget accounting, exact symbol lookup latency, and no writes to non-code search rows; the proof now runs in the scheduled/manual nightly E2E lane.
- Completed the Project Code Memory retrieval/precision hardening pass: Swift/Python now use AST-aware chunks and complete-symbol context packs where ranges are available, Python caches syntax diagnostics during indexing, the Rust parser keeps an allowlisted persistent LSP pool with response caps, local MCP code/memory tools have per-minute rate limits, TypeScript/JavaScript SCIP JSON import lands at `scip_index` confidence, dense retrieval is gated behind real current Ollama embeddings, and CI now runs retrieval, telemetry, SQLCipher, hosted-code, and benchmark policy checks.
- Tightened local MCP memory/code writes to fail closed at the daemon boundary; legacy direct-write override env vars no longer bypass the daemon for `burnbar_remember`, `burnbar_forget`, `burnbar_index_project`, `burnbar_watch_project`, or `burnbar_explore`.
- Added Cursor to the hosted MCP installer target list and registered explicit hosted memory/code rate-limit buckets so future tools do not fall through to the generic metadata bucket.
- Added encrypted Project Memory cloud deletion with opaque doc IDs, content-free tombstone receipts, Functions BOLA coverage, and a local MCP `burnbar_cloud_delete_project_memory` tool.
- Added an animated BurnBar launch identity: a 3D isometric glass-cube logo formation where converging dots assemble the flame, the flame solidifies inside an Apple Liquid Glass cube (with an obsidian-glass fallback) lit by a domain-warped oil-on-water sheen, and three color-matched provider dot-glyphs drift beneath the glass and re-form on collision. Shipped as a shared SwiftUI component (`BurnBarLogoFormationView`) plus a Jetpack Compose port (`BurnBarLogoFormation`), now driving the iOS/iPad sign-in hero, the macOS first-launch onboarding popover, and the Android login screen.
- Added a one-shot full-screen iOS launch splash (`View.burnBarLaunchSplash()`) that plays the logo formation over a dark backdrop on cold start, then crossfades to reveal the app; skipped entirely under Reduce Motion.
- Added routed-model parity for Codex CLI and Claude Code. Their model pickers now keep native GPT/Codex and Claude rows visible while appending every route-ready OpenBurnBar proxy model from the live local gateway catalog; Codex proxy rows route through `model_providers.openburnbar` with `wire_api = "responses"`, and Claude Code gateway discovery uses `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` plus Claude-safe `anthropic.openburnbar.<base64url-route-id>` aliases backed by `/v1/messages`.
- Added current routed-client catalog rows for Codex GPT-5.5/GPT-5.4 and Ollama Cloud `kimi-k2.7-code:cloud` / `glm-5.2:cloud`, including route eligibility coverage and modality/context metadata.
- Added explicit Codex CLI and Claude Code `Connect + Sync` / `Sync models` lifecycle parity with Droid/Factory, including stale-catalog state, preserved user config, OpenBurnBar-owned markers/sidecars only, routed-client sentry refresh, and one-token probes against `/v1/responses` for Codex and `/v1/messages` for Claude Code.
- Polished the Settings Connections routed-client rows into a "routing cockpit" instrument surface. Each row now reads as a precise, three-zone control: a pulsing status indicator (animated glow ring during busy states), an identity cluster with provider logo and endpoint-shape badge (Messages, Responses, Chat Completions), a status cluster with connection/freshness/source badges plus a monospace metadata strip for model counts and probe endpoint, and a primary action with icons (Connect + Sync, Sync models, Retry probe, Disconnect). Hover states, gentle spring transitions for state changes, and degraded-state color semantics (amber for stale, red for failed) give all three CLI clients equal visual weight and instant scannability.
- Hardened routed-client parity after launch-readiness review: Claude Code, Codex, and Droid readiness now key off bridge endpoint capability instead of native upstream family, stale catalog and probe failure states have distinct recovery actions, and Factory/Droid provider adapter selection stays tied to provider/model family so bridged endpoint metadata cannot misclassify custom models.

### Security & Launch Readiness Hardening

- Hardened Firestore `escrow_grants` validation rules: enforced `status == "granted"` on creation and restricted status updates to transition only from `"granted"` to `"revoked"`, completely blocking client-side reactivation of revoked credentials.
- Added comprehensive unit tests in `escrow-grants.test.js` validating unauthorized field creation, status smuggling, and revoked status update rejections.
- Resolved Swift compiler and SwiftUI layout warnings under Xcode 27.0-Beta: refactored conditional charts in `InsightTimeSeriesView` and `ProjectMemoryEditorialPrimitives` to view-level `if-else` blocks wrapping separate `Chart` containers.
- Enhanced Sentry DSN configuration: added fallback lookup from `GoogleService-Info.plist` inside `AgentLensApp` and `AppDelegate` if the main Info.plist DSN is unpopulated.
- Refactored subject fragment sanitization in `ComputerUseSecurityCallableClient` to utilize Unicode scalar parsing instead of Regex matching, ensuring broad Swift version compatibility.
- Fixed Firebase config injection script to apply PlistBuddy updates across all build targets in the loop.
- Hardened Stripe checkout and billing-portal redirect URL validation: exact raw-host loopback allowlist (`localhost`, `127.0.0.1`, `[::1]`), HTTPS-only for non-loopback, blocked parser-differential bypasses (e.g. `localhost.attacker.example`, IP obfuscation, userinfo tricks), and added an optional production origin allowlist (`STRIPE_REDIRECT_URL_ALLOWLIST`).
- Scrubbed account-deletion logs in `functions/src/accountDeletion.ts`: warnings now route through the structured PII scrubber with hashed `user_id_hash`/`account_id_hash` correlation fields; removed raw `document_id` and UID-bearing storage-path logging (OPUS-F-005). Added `functions/src/__tests__/accountDeletionLogScrub.test.ts` regression tests.
- Extended the run-09 privacy-invariants gate with **I7**, which fail-closed detects any raw UID/path logging regression in `accountDeletion.ts`.
- Integrated the Firestore App Check enforcement probe into the ops-readiness release gate: `scripts/ci/verify-ops-readiness.sh` now runs the evaluator unit test and the live `scripts/ops/verify-firestore-app-check-enforcement.sh` probe, so a release fails if Firestore App Check enforcement is off or unknown (C.1 / FINDING-004).
- Added product-layer sliding-window rate limits for all public HTTPS endpoints (`functions/src/callables/publicRateLimit.ts`): per-IP limits for health probes, the router rundown, the Hermes Gateway, CLI link bootstrap/poll, and provider webhooks (Apple App Store, Stripe, GitHub). The endpoint authorization catalog now correctly classifies `latestRouterRundown` and `onKnowledgeRepoPush` as public HTTP, and the inventory test fails CI if any public endpoint lacks a declared limit (B.2 / FINDING-005).
- Closed the Handoff 2 local-data gaps: macOS database encryption setup now throws a typed Keychain persistence error, refuses unpersisted SQLCipher keys, links SQLCipher 4.16.0 in app/daemon release builds, gates `PRAGMA cipher_version`, and migrates legacy plaintext stores on first encrypted launch while rejecting plaintext fallback (D.1 / D.2).
- Removed long-lived credential fallback paths from production deploy workflows: Firebase/hosting/firestore production deploys now require OIDC/WIF credentials and CI blocks `GCP_SA_KEY`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `FIREBASE_TOKEN`, and `credentials_json` regressions (E.1 / FINDING-007).
- Added explicit CODEOWNERS coverage for security-sensitive trees and a static CI guard covering security callables, Stripe callables, CI scripts, vendored Signal code, Firestore rules, and project generation metadata (E.2 / OPUS-F-012).

### Changed

- Polished the BurnBar logo-formation cube into a more luminous, liquid-glass hero: a warm ember glow lives inside the cube, a slow mercury shimmer sweeps across the surface, specular highlights and amber-tinted rim edges catch the light, and the iOS 26 / macOS 26 Liquid Glass layer now carries a subtle brand tint and interactive response. The pre-26 obsidian fallback is also more translucent so the glyphs and sheen read through the glass.
- The macOS Mercury incoming screen-mirror / call sheet now shows the requesting account's profile photo in the avatar circle (cross-fading in over a pulsing ring), falling back to the name monogram — or a generic person glyph when no name is available (e.g. Sign in with Apple) — instead of always showing only the name initial.

### Security - Cure53 remediation sweep (2026-06-12)

- Fail-closed local data protection across macOS, iOS, and Android: encrypted database startup now refuses existing plaintext stores when encryption is enabled, mobile enables complete file protection and screenshot protection, Android remote-unlock secrets require biometric-gated Keystore keys, and the legacy provider continuity vault is scrubbed instead of reused.
- Hardened Computer Use and hosted automation paths: daemon installs validate the bundled binary statically before copy/launch, Browser/AX tool output and focus transcripts are wrapped as untrusted model data, browser targets deny local/private/metadata/blocked URLs, Remote Config kill switches fail closed, and media sessions stop when entitlement or active-session admission is revoked.
- Bound more Cloud Vault payloads to Firestore paths with AEAD AAD for conversation sync, mobile chat history, CLI mission requests/states/events, and notification replies, while documenting the remaining same-path replay boundary in the security claims register.
- Tightened cloud/backend controls: Firestore owner profiles and Cloud Vault wrapper paths are write-constrained, trust revocation now records required vault rotation for surviving trusted devices, Sentry scrubs request/env/context/breadcrumb data before send, hosted MCP prefers Ed25519 access tokens with legacy HMAC explicitly gated, and MCP desktop tokens default to Keychain-only storage.
- Added durable operator gates for the review package: Firestore disaster-recovery verification, live GitHub governance checks, hosted MCP security smoke, Java/Kotlin CodeQL, mutable remote shell installer detection, supply-chain workflow hardening, ops-alert channel validation, and updated docs/runbooks/claim boundaries.

### Performance — deferred round-2 fixes (2026-06-10)

The eight findings deferred from the 2026-06-09 sweep (Apple platforms), each with regression tests:

- **iOS tab-return reload (P0)** — Pulse/Burn data stores (`DashboardStore`/`QuotaStore`/`ActivityStore` and the Pulse quick-ask `HermesService`) are hoisted to the tab roots (`RootTabView`/`RootNavigationView`, precedent: the Insights hoist) and injected; the remounted views' `loadIfNeeded` warm path only restarts the listeners `onDisappear` tore down, so a return to Pulse costs zero network round-trips instead of ~10+ (including duplicate `rebuildUsageRollups` callables from per-instance cooldowns).
- **iOS Hermes runtime split** — the shared runtime catalog (connections, reachability, models, session/profile/job lists, persisted connection+model selection) moved into one `HermesRuntimeStore` injected from the root, while every surface keeps its own conversation state (Pulse quick-ask and the Hermes tab no longer risk transcript collisions, and `selectedConnection` can no longer diverge between surfaces); `refreshRuntime`'s in-flight coalescing is now global, collapsing the duplicate 6-op launch/foreground refreshes, with a `refreshRuntimeIfStale` warm path for remounts. The dead preview-only `ChatView` was deleted and the Settings hub stopped re-creating a `HermesService` per body evaluation.
- **iOS live-usage listener** — `listenToUsageSince` is incremental (Android-parity design): `documentChanges` patch a docID-keyed accumulator on a serial decode queue (off the main actor), sealed project-name AEAD opens are memoized by `(docID, updatedAt)`, and both live queries carry a defensive newest-first `limit(2000)`.
- **iOS Pulse hero glow** — the hero's three stacked soft-glow passes collapsed to one: the provider halo and depth glow are pre-shaped gradients (no full-card blurs), and the burn-velocity pill breathes via an opacity-animated pre-blurred halo instead of re-rendering its shadow every frame.
- **iOS Insights session trace (Mac parity)** — `InsightsMobileVerdictModel.buildTraceFor` is implemented (was an empty stub), so upgraded verdicts on iPhone/iPad now carry the session-trace strip the shared `VerdictHeroView` already renders; `SmartHubStore`'s contradictory listener-cleanup comments were corrected.
- **macOS popover prewarm** — the menu-bar popover content is rebuilt off the click path (on runtime-context readiness and after every close) instead of synchronously inside the click handler on every open; the deliberate fresh-state-on-show behaviour is preserved. See `docs/architecture/macos-performance.md` §15.
- **macOS↔daemon RPC plane** — socket reads use 64 KB buffers (was 1 KB — ~64× fewer read syscalls on large responses); a new aggregated `daemon.controller.runtime_snapshot` RPC replaces the six sequential per-list RPCs on every popover open/periodic tick, and controller mutations embed the refreshed snapshot (7 connections → 1 per action), with full version-skew fallback to the legacy path against older daemons. See §16.
- **macOS no-change refresh ticks** — content-identical periodic usage replacements short-circuit (no double sort, no aggregate-cache rebuild, no `usagesVersion` bump) until the next time-window boundary (midnight / rolling 7d-30d row exits), which preserves the load-bearing "Today" reset and window decay; the always-bump contract test was deliberately inverted. See §14.

### Performance — invisible-wins sweep (2026-06-09)

A cross-surface performance/quality pass (website, Android, iOS/iPadOS, macOS, daemon, Cloud Functions) under a strict pixel/behaviour-parity contract — every fix shipped with regression tests and passed its surface's full validation gate.

- **Website (burnbar.ai)** — the four large inline `BaseLayout` scripts moved to hashed immutable `/_assets` modules (index.html gzip −33%; repeat navigations re-download zero script bytes; per-page inline executable script 59.7 KB → 2.3 KB); Fraunces fonts switched to the `opsz`-instanced faces (−45% on the critical-path latin faces) with preloads; all 7 in-use screenshots converted to WebP (−89.8%, homepage image payload −3.1 MB) and the OG card recompressed (−82.5%); 35 orphaned `public/` assets (~5.2 MB) pruned; canvas backgrounds now honour `prefers-reduced-motion`, lazy-load their ~1.1 MB provider-logo payload, park their rAF loops in the inactive theme, and coalesce scroll-driven layout reads to one pass per painted frame; platform-mockup timers gate on visibility and tab state; marketing hosting caching fixed (`no-store` → `no-cache` + ETag 304s, 5-minute TTL for unhashed JS, dist-stage minification of public scripts). Six new verify-chain gates lock all of this in (inline-script budget, orphan assets, reduced motion, idle canvas loops, lazy background assets, cache headers).
- **Android** — the ember-swarm backdrop frame-caps at 60 Hz with dt-corrected physics, fixing double-speed motion on 120 Hz panels (~50% less backdrop work there) while staying bit-identical on 60 Hz; heavyweight swarm shape-point tables prewarm off the main thread; Pulse live metrics moved into a subscription-gated 1 Hz store confined to the hero card, with the usage listener bounded at `.limit(2000)`; chat-attachment thumbnails decode downsampled on `Dispatchers.IO` (a 12 MP photo no longer decodes ~48 MB ARGB on the UI thread); the Hermes transcript is keyed by message id and the permission-inbox subscription hoisted out of every bubble; AURORA backdrop phases read in draw/layout scopes and both infinite transitions gate on reduce-motion; the Mercury heartbeat probe is event-driven instead of a 25 ms busy-poll; the iroh pairing listener is server-side bounded; visual-settings first load is race-free with all 8 swallowed `catch (_: Throwable)` blocks removed; the never-loaded duplicate 41.6 MB iroh cdylib is excluded from packaging (−10.3 MB per arm64 install).
- **iOS/iPadOS** — the Pulse 1 Hz live clock is localized to the hero card via a pausable `TimelineView` (the 8-card feed no longer re-evaluates every second); the AURORA mesh drift is frame-capped at 24 Hz (~5× fewer GPU blur passes on ProMotion); `MotionStore` gained a tilt deadband with exact snap-to-target, ending ~30/s Observation invalidations at rest; a reachable Live Activity end/start race is fixed (handle captured + cleared synchronously, injectable backend); Pulse display-mode/timeline-scope toggles re-derive from cached rollups instead of 5 serial Firestore round-trips; widget-snapshot writes and Live Activity updates are diff-guarded so `reloadTimelines`/ActivityKit fire only on real content change, and the Insight Today widget now also reloads within seconds of a verdict change instead of waiting for its 15-minute poll; the Siri burn-status intent is a pure read (no leaked process-lifetime Firestore listener, no widget/Activity side effects); Mercury transfer rows render 144 px cached thumbnails instead of synchronously decoding full-resolution photos.
- **macOS** — insight rollup snapshots run off the main actor with change-gated health writes (fresh-path popover opens no longer take the GRDB writer queue); ISO8601 parsing in the log-ingestion parsers uses lock-guarded cached formatters (4.5× measured); the Session Logs filter/group pipeline is memoized to one rebuild per input change; battery monitoring switched from 5 s IOKit polling (17,280 snapshots/day) to event-driven limited-power notifications; the daemon heartbeat halved in cadence and collapsed to one atomic write (~86k → ~17k FS ops/day); the GRDB query tracer is wired into all DEBUG pool opens with self-calibrating N+1 query-count budget tests. See [`docs/architecture/macos-performance.md`](docs/architecture/macos-performance.md) §7–13.
- **Cloud Functions / Firestore** — declared the 8 missing collection-group indexes that were failing rollup rebuilds, approval reaping, audit anchoring, computer-use rollups, App Store reconciliation, and knowledge resync, with a CI coverage gate that statically checks every `.collectionGroup()` call site; `googleapis` is lazy-loaded (module import 454 → 238 ms, shared by all 144 deployed functions); the Hermes Gateway grant path coalesces `lastSeenAt` writes (~97% fewer at the 1 s poll cadence) and overlaps entitlement/PoP/client reads with byte-identical error precedence; rollup dirty-flag clears are transactional so mid-compute usage events are never silently dropped; rollup computation reads are deduped (one 90-day range query + a rolling all-time daily map — no more unbounded scans or 128 per-window point reads); routine app opens no longer trigger destructive full rollup rebuilds on any platform (counters path by default, full rebuild only on force/missing job/error, client staleness now compares newest usage to `computedAt`); the mobile rollup fetch is one collection read instead of 5 serial round-trips on both iOS and Android; the public `latestRouterRundown` endpoint is hardened against cost-DoS (bounded in-memory cache, zero-read 404s for implausible dates, `maxInstances: 10`); legacy Kimi/MiniMax wire pricing moved to a named-constants module with a catalog-drift CI test.
- **Shared assets** — the 1024 px/641 KB Warp provider logo re-exported at 256 px and propagated byte-identically to Android, macOS, iOS, and the website (~594 KB off each bundle); 30 byte-identical duplicate Android logo drawables deduped and 11 more moved out of the mdpi density bucket (Android res payload 3.4 MB → 1.7 MB, ~1.7 MB off the APK); dead CloudTierCrest @3x PNGs stripped from the macOS asset catalogs.

### Fixed

- **Droid routed Claude models through OpenBurnBar** — the local gateway no longer lets Ollama Cloud's dynamic `:cloud` fallback claim Anthropic-owned Claude model IDs such as `claude-opus-4-8-max`. Claude requests now fail closed to an Anthropic route/no-route error instead of being rewritten to Ollama Cloud, while unlisted Ollama Cloud aliases such as `glm-5.2:cloud` still route dynamically.
- **Android Mercury remote keyboard duplicate typing** — the hidden screen-share keyboard now suppresses repeated raw IME callbacks for the same buffer value while preserving intentional double letters (`l` -> `ll`), and the Mac receiver has explicit signed text-intent replay coverage.
- **Droid custom models (Anthropic BYOK)** — the local gateway now accepts the gateway bearer token via `x-api-key` as well as `Authorization: Bearer`, matching Factory Droid's Anthropic adapter. Routed Claude custom models (`provider: anthropic` in `~/.factory/settings.local.json`) no longer fail with `401 unauthorized` / `Exec failed`.
- **Mobile Hermes Gateway replies** — BurnBar Cloud gateway replies now reopen the exact Hermes thread, persist replies before rendering mobile reply cards, hide older duplicate reconnect entries for the same device, and show the answering provider badge in notifications and gateway status UI.

### Added

- Added a daemon-backed Route log in Settings -> Agents -> CLIs for the local proxy, showing the requested model slug/name, the upstream model/provider/logo identity actually used, provider-reported model slug, exact-route invariant status, attempts, and usage metadata without logging prompt or response bodies.
- Added Settings -> Agents -> Advanced quota-popover controls so users can choose which provider quotas appear in the menu-bar drop-down, with a compact quick-access button in the popover header.

### Security

- **Hermes Gateway E2EE remediation** — paired BurnBar Cloud gateway links now treat the relay as untrusted: new writes require production `relayEnvelope` (v2/v3) or `ratchetEnvelope` for text/control when both peers publish ratchet material; message/attachment IDs round-trip for AAD binding; replay ledgers record only after successful open; both-key 128-bit safety codes include ratchet identities when available; macOS Keychain holds agent relay/ratchet private keys; setup no longer silently enables allow-all users. Proof gate: `bash scripts/ci/verify-hermes-gateway-e2ee-remediation.sh` (privacy scanner, focused Functions vitest, Firestore rules, schema drift, v2/v3 fixture mirrors, adapter mirror, local gateway smoke, 211 external Hermes pytest). See [`docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md`](docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md) for the honest claim boundary (not whole-product SOTA E2EE).
  - Post-implementation principal review found and fixed a control-dispatch gap: iOS E2E sends for `model_switch`/`approval_decision`/`oversight_mode` now emit `kind` (and control fields) at the root of the sealed payload so the agent's pinned open path dispatches to the special sealed handlers instead of dropping as empty chat text or leaking as JSON messages. Added unit coverage and updated oversight E2E delivery. All gates re-verified green.
- Sealed the remaining same-pattern cloud privacy surfaces: approval-policy labels/paths/globs, CLI session snapshot file/path labels, rollback request scopes/errors, agent identity persona text, subscription topic labels, and Hermes Gateway typing/private routing metadata. Mac, iOS/iPadOS, Android, functions, Firestore rules, privacy scans, and registry tests cover the sealed-only contract.

## [1.0.4] - 2026-06-18

### Security

- Shipped the Firebase rules release fix that keeps shared-artifact sealed-payload
  and mission fanout integrity rules deployable in production without weakening
  the enforced Firestore and Storage App Check posture.
- Verified the live Firebase project remains App Check enforced for both
  Firestore and Cloud Storage after the production rules deployment.

### Changed

- Advanced macOS direct-download release metadata to `1.0.4` build `44`.
- Advanced iOS/TestFlight, widget, and keyboard metadata to `1.0.2` build `74`.

## [1.0.3] - 2026-06-18

### Fixed

- Shipped the June security hardening stack on the release line: Firestore and
  Storage App Check enforcement probes, owner-only avatar Storage rules, stricter
  endpoint authorization inventory, SQLCipher release gating, sensitive logging
  redaction, CODEOWNERS security-tree coverage, and OIDC-only production deploy
  gates.
- Hardened release-critical CI against transient Xcode/SwiftPM and native
  submodule failures: app/mobile/retrieval wrappers now retry classified package
  resolution flakes, Mercury media proof gets multiple mobile attempts, and
  native libsignal submodule initialization is bounded and fails closed.
- Advanced macOS direct-download release metadata to `1.0.3` build `43` and iOS
  TestFlight build metadata to build `73` without changing the approved iOS
  marketing version line.

## [1.0.2] — 2026-06-03

### Fixed

- Aligned release metadata for the commercial launch candidate.

### Added — agent knowledge in mem0 (token-efficient retrieval)

- Mirrored the canonical Droid wiki (`droid-wiki/`) into a dedicated BurnBar mem0 project as verbatim, retrievable chunks via `scripts/wiki/mem0-sync.mjs` (mem0 REST, `infer=false`, scope `user_id=burnbar`), so agents query for the exact knowledge a task needs instead of bulk-loading whole wiki pages or `docs/`.
- Kept mem0 fresh automatically: a raw `post-commit` git hook (installed by `scripts/wiki/install-hooks.sh`) syncs only the wiki pages a commit changed, and `.github/workflows/wiki-mem0-reconcile.yml` reconciles the full wiki nightly. An idempotent committed manifest (`droid-wiki/.mem0-manifest.json`) makes re-runs zero-write.
- Pointed BurnBar agents at the BurnBar mem0 project via repo-scoped `.mcp.json` (`mem0-burnbar`, key from `MEM0_BURNBAR_API_KEY`) and a "query mem0 first" directive in `AGENTS.md` / `CLAUDE.md`; moved the Computer Use phase/flag/budget reference out of `AGENTS.md` into the mem0-backed wiki.
- Consolidated to a single canonical wiki by archiving the superseded `wiki/` scaffold (recoverable from git history).

### Security — LLM/GenAI prompt-injection hardening

- Added a dedicated LLM/GenAI agent threat model covering log parsing, RAG, hosted insights, Computer Use, MCP, model routing, tool grants, and budget/loop guardrails.
- Wrapped untrusted RAG snippets, transcript summaries, CLI chat user messages, and hosted insight questions with provenance-tagged untrusted-content blocks so prompt-injection payloads remain data, not instructions.
- Added prompt-injection hardening tests for the wrapper and CLI prompt assembly paths.

### Added — macOS 1.0.1 beta

- Cut a new Developer ID direct-download beta for macOS with unique `1.0.1`
  website artifacts, notarized DMG/ZIP provenance, checksums, and SBOM.
- Added the BurnBar Cloud profile avatar upload path for mobile account
  settings, including Firebase Storage rules and refreshed avatar rendering.
- Replaced Cloud badge PDF assets with source SVG vectors shared by the Mac,
  mobile, and website brand surfaces.

### Changed — Unified tool-call accordion (all chat surfaces)

- Replaced five separate tool-call strip implementations (Hermes, Pi, CLI agents, ChatView compact mode, AgentLens dashboard, and the Hermes menu-bar popover) with a single `UnifiedToolCallAccordion` component in `OpenBurnBarCore`.
- The accordion stays **collapsed by default** and shows only the most recent call between messages; tapping reveals the full history with raw arguments and, where the runtime captures one, the call result. Running calls pulse their status dot; the accordion never auto-expands mid-stream.
- Each surface retains its own accent — Hermes keeps its mercury gradient, Pi its whimsy, CLI agents their per-runtime brand colours.
- Fixed a bug where the Mac transcript path used `.toolResult` IDs when computing the in-flight call for streaming pulse, causing live tool calls never to pulse correctly.
- Grok's CLI accent updated from `#111111` (invisible in dark mode) to `#E0E0E0` (light warm gray — Grok monochrome brand).
- 31 pure-logic unit tests added in `UnifiedToolCallAccordionTests` covering state classification, icon routing, expansion logic, accessibility hint selection, and streaming-pulse correctness.


- Added a Settings -> Agents -> CLIs migration card that scans `~/.cli-proxy-api`, imports supported VibeProxy API-key secrets into OpenBurnBar provider slots, and rewrites detected Claude Code, Codex, OpenCode, Forge, Droid/Factory, and Grok Build configs to OpenBurnBar's local gateway.
- Routed-client wiring now has a VibeProxy migration mode that strips VibeProxy-owned local `8317` provider entries while preserving unrelated user profiles/settings and writing the normal OpenBurnBar backup files.

### Added — Local Ollama auto-discovery, advertising, and routing

- Local Ollama models (`ollama pull`) now auto-list, catalogue, and advertise themselves: a new credential-less `ollama-local` provider (`http://localhost:11434`, `local: true`) discovers installed models live from Ollama's canonical `GET /api/tags` endpoint and advertises them as route-eligible through the gateway with zero configuration — local providers auto-enable and need no API key. `:cloud` models are left to the dedicated Ollama Cloud provider.
- Advertised local models route credential-free straight to `localhost:11434` through the gateway `/v1/chat/completions`, resolved as free, zero-priced passthrough models by the provider router. A local provider claims only model names no non-local catalog vendor owns, so it never shadows real providers (e.g. an unconfigured `gpt-5.5` fails cleanly instead of routing to localhost).
- The chat model picker groups discovered local models under the existing Ollama family (advertised `provider: "ollama-local"`); when the local server is down, nothing is advertised and a "start `ollama serve`" status is surfaced instead of a silent 404.
- Added a shared `CLIRuntimeModelCatalog.parseOllamaTags` parser (with `ollamaLocalCatalog`/`ollamaCloudCatalog` sources) that separates locally-pulled models from `:cloud`/`-cloud` Ollama Cloud models served by the local daemon.

### Added — BurnBar Cloud Hermes Gateway platform

- Added a BurnBar Cloud Hermes Gateway HTTP surface with device-code linking, scoped bearer grants, destination discovery, event polling/SSE, message delivery, typing state, and signed attachment upload initiation.
- Added Hermes Gateway management callables for approving, listing, revoking, and enqueueing BurnBar-originated gateway events.
- Added Firestore rules, the `/hermes/connect` web approval flow, Firebase Hosting routing, tests, docs, and a contribution-ready upstream Hermes platform plugin under `tools/hermes-platform-burnbar/`.
- Added selected-client targeting for iPhone/iPad gateway messages and model switches so multiple paired Hermes gateway clients can stay online without consuming each other's events.
- Mac Remote Relay now publishes a per-installation `relay-host-...` connection ID and marks the legacy device-id relay as replaced, preventing two Macs with migrated device IDs from overwriting one another.

### Added — Touchless live model discovery and routed-client sync

- Codex and Grok model pickers now use the paired Mac's live CLI catalogs (`codex debug models`, `grok models`) when available, and Grok also merges `~/.grok/models_cache.json` so cached model releases show up even when the command output is sparse.
- Claude Code and Antigravity model pickers now enumerate all known Claude/Gemini catalog rows for the paired Mac instead of reflecting only the CLI default/profile; Antigravity appends the selected `agy` profile model only when it is a custom non-catalog model.
- The gateway router can resolve newly discovered Anthropic model IDs before the static catalog is updated, preserving the rule that any route-eligible advertised row must be callable.
- Routed-client auto-repair now refreshes stale Droid custom model arrays from the live `/v1/models` catalog, so enrolled Droid installs pick up new proxy models without pressing Sync.
- Android decodes the new Antigravity, Claude Code, Codex, Grok, and Cursor Agent model-source labels for mobile CLI model pickers.

### Added — Cross-provider CLI session restart/handoff

- Added `cliAgentSessionAction` relay contracts so iOS, iPadOS, and Android can ask the physical Mac to resume, hand off, or package any indexed CLI session through the daemon `run.resume` path.
- Handoff packages now include full indexed transcript text when available, stay Mac-local with `0600` permissions, and mark untrusted historical transcript context explicitly.
- Cross-provider targets now generate concrete Mac argv for Codex, Claude Code, Droid, Forge, Antigravity, Grok, Cursor Agent, OpenCode, and Gemini CLI, while native resume remains limited to locally validated Codex/Claude handles.
- Android runtime parity now includes Grok and Cursor Agent session tiles, relay operation names, session-action payload decoding, and Firestore rule allow-lists.

### Security — Computer Use WS4 client migration (2026-05-30 remediation)

- Mac, iOS, and Android clients route escrow device registration and trust elevation through `registerEscrowDevice`, `approveEscrowDeviceTrust`, and `revokeEscrowDeviceTrust` callables instead of direct Firestore writes to `trustState: trusted`.
- `bindAppCheckAttestation` runs after sign-in on all platforms; clients force-refresh the Firebase ID token so `obb_app_check` custom claims propagate before high-risk Computer Use callables.
- Mac and mobile Settings surfaces show user-visible App Check attestation bind failures (not silent log-only warnings).
- Privileged-socket red-team drill documented in [`docs/security/PRIVILEGED_SOCKET_AUTH.md`](docs/security/PRIVILEGED_SOCKET_AUTH.md) (`RUN_PRIVILEGED_SOCKET_REDTEAM=1`).

### Added — Budget envelope split + error-debt gates (ADR 006)
- Split `ops/*_budget_status` into a **public envelope** (`state/current`, signed-in read, level + caps only) and **operator metrics** (`metrics/current`, operator read, USD projections). Cloud Functions write both docs; clients listen on the public path only.
- **Supersedes** the 2026-05-28 operator-only hardening that blocked signed-in envelope reads — see [ADR 006](docs/architecture/006-budget-envelope-visibility.md).
- `MediaBudgetStatusStore` (Mac) + `MobileMediaBudgetStatusStore` (iOS) with error-code classification and last-known cache; `MacMediaCapabilityGate.shared` reads live budget; `media_kill_switch` Remote Config wired via `mediaRemoteConfig.ts`.
- CI ratchets for empty `catch {}` (**97** baseline) and `try?` in Services (**779** on branch) via `tools/error-debt/count-error-debt.py`; informational SwiftLint step in the PR harness.
- Firestore rules tests for CU + media budget public/operator/unauth matrix.

### Security — Computer Use WS3 verifiable audit (2026-05-30 remediation)

- Terminal **`signed_head.json`**: Ed25519 signature over `{sessionId, lastEntryIndex, headHashHex, closedAt}` using the trusted-device export key; written on session close, panic halt, and export.
- **`openburnbar-cli audit-verify`** offline verifier: parent-hash walk, signed-head check, optional `ots verify`, and `--max-entry-index` completeness (“no actions after panic P”).
- Export requests accept **`anchorOpenTimestamps`** to mint `chain.jsonl.ots` before packaging; server cross-check remains `validateOpenTimestampsProof`.
- Keychain export signer provider moved to **`OpenBurnBarComputerUseCore`** for shared Mac app + daemon use.
- Runbook: [`docs/runbooks/computer-use-audit-disputes.md`](docs/runbooks/computer-use-audit-disputes.md).

### Security — Privileged input WS1 minimal TCB (2026-05-30 remediation)

- New **`OpenBurnBarPrivilegedInputExecution`** launchd Mach service holds the sole `hid.virtual.device` entitlement; Virtual HID bridge is a socket-only adapter that forwards dispatch over XPC with the peer audit token re-validated on the leaf.
- App clients prefer **XPC** (`PrivilegedInputXPCClient`); legacy Unix socket path retained for migration. `PrivilegedInputDispatchRequest` / envelope types are schema-stable for WS2 capability tokens.
- Root **Remote Access Agent** narrowed to wake display, worker launcher, and `requestCapabilityToken` stub; no HID/network/keychain entitlements on privileged helpers.
- **Hardened Runtime** enabled on privileged helper targets in `project.yml`.
- **Developer-ID release lane:** `DeveloperIDReleaseCapability` + entitlements smoke tests document intentional omission of keychain/iCloud/Sign in with Apple (no silent feature breakage).
- Isolation tests assert input-execution has no network/keychain and bridge/agent have no HID.
- See [`docs/security/PRIVILEGED_SOCKET_AUTH.md`](docs/security/PRIVILEGED_SOCKET_AUTH.md).

### Security — Capability tokens & attestation (WS2, 2026-05-30 remediation)

- **`CapabilityToken`** in `OpenBurnBarComputerUseCore` (schema-synced): domain-tagged (`remote_unlock` | `computer_use`), short TTL, single-use nonce, `allowedActionKinds`, `scopeHash`, optional `attestationHashBlake3`, Ed25519-signed compact JSON.
- **Remote Unlock:** certification-provisioned issuer key (Keychain); trust material published for **offline** bridge verification; tokens minted only while a pending attested unlock session is active; Virtual HID `"input"` requires a valid token layered on the action-kind policy gate.
- **Computer Use:** in-process PDP mint via `ComputerUseCapabilityTokenService` for post-unlock mac input bursts.
- **`PhoneControlAuthorityValidator`:** authority TTL (`authorityMaxLifetime`), optional attestation binding on `HermesRealtimeRelayAuthorityEnvelope`, peer/escrow revocation propagation.
- Tests: `CapabilityTokenVerifierTests`, `VirtualHIDBridgeCapabilityGateTests`, `PhoneControlAuthorityValidatorAttestationTests`.

### Security — Privileged socket P0 (2026-05-30 remediation)

- Virtual HID bridge and root Remote Access Agent sockets now require **first-party code signature** (audit token + designated requirement) in addition to console-user UID checks. Unsigned local processes can no longer drive arbitrary HID `"input"`.
- Bridge `"input"` is **fail-closed** on certified Remote Unlock action kinds (pointer click/move, escape/delete/return/tab keys) **and** capability tokens (WS2).
- Structured audit events: `privileged_socket_peer_rejected`, `privileged_bridge_input_accepted/rejected`.
- Leaf-reaching panic kill flag at `/var/run/openburnbar-privileged-input-kill`.
- See [`docs/security/PRIVILEGED_SOCKET_AUTH.md`](docs/security/PRIVILEGED_SOCKET_AUTH.md).

### Added — Cloud backup catch-up guardrails
  usage meter for conversations, included transcript storage, and searchable
  index size without exposing infrastructure costs.
- Enabling conversation backup now starts a resumable full catch-up
  automatically; completed records continue to use `logSyncedAt` as the local
  “already backed up” marker so only new or changed conversations upload after
  catch-up.
- Session-log backup now checks included plan limits before uploading encrypted
  blobs or search metadata, and Settings maps raw backend failures such as
  `INTERNAL` into actionable user-facing messages.

### Added — Burn tab view switcher (iOS · iPad · Android)
- The Burn tab now has a **view switcher** so you can pick how your burn is
  visualized. The original layout is the default **Cards** view; four new views
  join it: **Orbit** (an orbital ring constellation around a central fleet
  score), **Grid** (a dense grid of per-provider gauge tiles), **Ranked** (a
  spend leaderboard with bars normalized to the top spender), and **Trends**
  (per-provider burn sparklines over the selected window). The shared header
  (fleet score, urgent banner, period/mode chips) stays put; only the content
  region swaps. The choice is remembered per device (iOS `@AppStorage`, Android
  `QuotaPreferences` DataStore). New views reuse existing quota/rollup data —
  no backend changes.

### Added — Cursor Agent integration
- **First-class Cursor Agent CLI and provider**: Fully added `cursor-agent` as a first-class local agent provider. Implemented `CursorAgentParser` to parse precise session tokens, models, and conversation transcripts from `~/.cursor-agent/sessions/` in both nested and flat JSONL schemas. Included custom branding visual identity (electric cyan `#00E5FF`), CLI execution profile, argument builder options, and stream runner routing.

### Fixed — Smart display recovery and Claude data freshness
- **Instant cast recovery on wake / activate**: The Nest Hub cast watchdog now
  fires immediately when the Mac wakes from sleep (with a 3-second network settle
  delay) or when OpenBurnBar becomes the active app. Previously the watchdog ran
  at a 150-second cadence when backgrounded, leaving the Hub stuck on Ambient Mode
  for minutes after a Mac sleep or any event that evicted the DashCast session.
- **Claude context-window fallback on Pixel Clock / Nest Hub**: When Claude's
  statusline snapshot has no `rate_limits` key (common when the CLI is idle or
  between sessions), the quota adapter now surfaces the `context_window` data
  (usage percentage, token counts, model name, session cost) instead of falling
  through to the JSONL scanner and showing "0% / no recent activity." Stale
  context-window snapshots are rendered with `.estimated` confidence so the
  display always reflects the most recent Claude session state.

### Fixed — Streams hosted search recall and cost
- Streams cloud search now uses database-level encrypted token/semantic posting
  lookups instead of relying on the phone to download and filter the corpus.
- The encrypted search callable now validates candidate chunks against the
  current document body hash/storage path, so one-conversation-at-a-time Mac
  sync commits no longer make only the latest commit searchable.
- New search index commits write exact token postings as well as semantic
  postings, improving name/exact-term recall while keeping Firestore reads
  bounded.
- macOS hosted search indexing is now versioned at v4, splits long transcripts
  into smaller 16 KB chunks, keeps up to 1024 exact and keyed prefix token
  hashes per chunk, and caps token posting writes per chunk. This forces
  existing cloud session logs to re-index so names buried late in long
  transcripts or inside long path/user tokens remain searchable without making
  every token a Firestore posting.

### Added — Universal provider auto-discovery
- **Anthropic `/v1/models` live discovery** — `BurnBarLiveModelCatalog.anthropicLiveModels()` hits Anthropic's `/v1/models` endpoint with `anthropic-version: 2023-06-01`, supporting both Console API keys (`x-api-key` header) and OAuth tokens (`Authorization: Bearer` header). Pagination is fully handled via `has_more` / `last_id` / `after_id` cursors.
- **Factory Droid CLI live discovery** — `BurnBarLiveModelCatalog.factoryDroidLiveModels()` runs `droid exec --help` via the injectable `FactoryDroidProcessRunning` protocol and parses the output with `CLIRuntimeModelCatalog.parseDroidExecHelp`.
- **Pluggable discovery dispatch** — `liveModels()` now dispatches by format family: `.openaiCompat` → `openAICompatLiveModels()`, `.anthropic` → `anthropicLiveModels()`, `factory` → `factoryDroidLiveModels()`. Unknown format families return `nil` (static catalog only).
- **Anthropic dated-ID normalization** — `normalizeAnthropicModelID()` strips trailing `-YYYYMMDD` suffixes from Anthropic snapshot model IDs (e.g. `claude-opus-4-8-20260514` → `claude-opus-4-8`), ensuring live-discovered models match catalog families.
- **`droidProcessRunner` injectable dependency** — `BurnBarLiveModelCatalog.init` now accepts `droidProcessRunner: any FactoryDroidProcessRunning` (defaults to `FactoryDroidSystemProcessRunner`), enabling test doubles for Factory CLI discovery.
- **19 discovery tests** — `OpenBurnBarLiveModelDiscoveryTests` covers normalization, parsing, pagination, deduplication, display name fallback, credential header selection, and CLI output parsing.

### Added — Opus 4.8 as first-class model + catalog promotion
- **`claude-opus-4-8-family` is now a canonical model** with its own `canonicalModelID: "claude-opus-4-8"` and `capabilityClassRank: 110` (above Opus 4.7's rank 100), making it the flagship Anthropic model.
- **`claude-opus-4-7-family` no longer borrows 4.8 aliases** — the 4.7 family's aliases and matchers are scoped to 4.7 only (with `"4.8"` in the `"none"` exclusion list), so requests for `claude-opus-4-8` route through the 4.8 family, not the 4.7 family.
- **Factory provider gains `factory-claude-opus-4-8-family`** with the same canonical model and capability class, keeping both 4.7 and 4.8 available through Factory.
- **Variant seed default updated** from `claude-opus-4-7` to `claude-opus-4-8` — new daemon installations seed thinking-level variants on Opus 4.8.
- **Display mirrors updated** — `openburnbar_models.json` in both AgentLens and OpenBurnBarMobile now list Opus 4.8 as the flagship Anthropic model, with Opus 4.7 still present.
- **`AnthropicInsightAdapter.defaultModels`** flagship entry updated from `claude-opus-4-7` to `claude-opus-4-8`.
- **`CrossEncoderConfiguration`** now lists both Opus 4.8 and Opus 4.7 as available Claude models.
- **Router test added** — `testRouterRoutesClaudeOpus48WireIDsThroughOwnFamily` verifies that Opus 4.8 routes through its own canonical model with `canonicalModelID == "claude-opus-4-8"`, and `testRouterRoutesClaudeOpus48Through47FamilyViaMatcher` verifies both 4.7 and 4.8 route correctly when both families are configured.
- **Gateway test updated** — `testGatewayMessagesRoutesClaudeOpus48WireIDViaOwnFamily` replaces the old stopgap test that routed 4.8 through the 4.7 family.

### Fixed — Mobile Terminal relay
- The iOS/iPadOS inline Terminal mirror now refreshes Mac relay discovery before
  showing “No Mac available,” so Grok Build and other runtime threads can reuse
  the same live Hermes Remote Relay without relying on stale in-memory cache.
- Interactive Terminal capture now recognizes Terminal sessions opened in an
  existing retitled window/tab and falls back to the frontmost Terminal window
  after polling, avoiding the tiny full-desktop mirror when the Mac could not
  resolve a brand-new Terminal window ID.
- Terminal-window capture now enables ScreenCaptureKit's independent-window
  scale-to-fit mode, so the live phone viewer receives a Terminal-sized frame
  instead of a small window floating inside a mostly black 1920x1080 canvas.
- If ScreenCaptureKit cannot reopen the Terminal as an independent window, the
  Mac mirror now crops the display source to the resolved Terminal window before
  encoding, keeping black padding minimal even on the fallback path.
- The inline Terminal viewer now uses a softer first-frame zoom and collapses
  the special-key strip into a single expandable button, keeping the prompt and
  chat input area visible.
- The inline Terminal viewer now treats first-frame zoom as a small readability
  nudge instead of height-fill zoom and refocuses the captured Mac Terminal
  window before phone-originated typing/shortcuts, preventing text from landing
  in the wrong Mac input.

### Fixed — Mercury Remote Unlock display wake
- The privileged Remote Unlock helper now explicitly wakes a sleeping display
  and holds a short no-display-sleep assertion before typing the Mac password,
  preventing the first synthetic key press from being consumed by display wake
  instead of focusing the login-window password field.
- The credential worker now uses the session-scoped CoreGraphics event source
  inside the loginwindow bootstrap, avoiding a macOS 26.5 SkyLight deadlock that
  made one-tap unlock report “sent” while no keystrokes reached the login
  window.
- The root helper now enters the loginwindow bootstrap directly with
  `launchctl bsexec` for credential workers and then explicitly drops the worker
  to the logged-in console user before posting keys, preventing a root-owned
  worker from reporting “sent” while loginwindow ignores the password events.
- The helper now passes credentials to the loginwindow worker through a
  short-lived `0600` file and launches `launchctl` with `posix_spawn` plus a
  hard timeout, avoiding Foundation `Process`/stdin hangs inside the privileged
  daemon.
- The Remote Unlock helper and Mac app now use bounded socket I/O and ignore broken
  pipe failures so stale helper clients cannot wedge the local unlock lane.
- The macOS “Launch at Login” setting now registers/unregisters the app with
  `SMAppService.mainApp` instead of only writing a preference, keeping the Mac
  relay process available for Mercury/Remote Unlock after login.

### Added — Streams conversation cockpit (import, faceted cloud query, export)
- **Every indexed provider transcript now flows into the encrypted hosted
  backup.** New SQLite/JSONL transcript parsers cover **OpenCode**
  (`~/.local/share/opencode/opencode.db` — `session`/`message`/`part` tables),
  **Goose** (`~/.local/share/goose/sessions/sessions.db`, with legacy JSONL
  fallback), and **Pi Agent** (`~/.pi/sessions/*.jsonl`), registered in
  `ParserRegistry.defaultParsers()`. The Goose and OpenCode parsers read through
  GRDB `DatabaseValue.storage`, so a column whose stored type differs from the
  expected one (e.g. a `TEXT` `created_at`) resolves cleanly instead of tripping
  a force-decode crash.
- **`SessionLogSyncService` backs up the full provider corpus** (not just the
  in-app CLI thread) and enriches each sealed manifest with cockpit facets —
  tokens, cost, `workingDirectory`, model, provider, project, message count, and
  tags — behind a unified backup toggle plus a one-time backfill. Bodies stay
  client-side encrypted with `CloudVaultCrypto`; manifests carry no plaintext.
- **`queryConversations` callable** powers the cockpit: faceted filters (provider,
  model, project, date range), sort, cursor pagination, and aggregates over the
  sealed `session_logs` manifests. It is gated on an active hosted-quota
  entitlement; `firestore.rules` permits the new facet fields while keeping bodies
  encrypted and paid-gated, with matching composite indexes.
- **The iOS/iPadOS Streams tab and the Android Streams screen are now a faceted
  conversation cockpit** — KPI header, facet bar, result rows, and a detail sheet
  that decrypts titles/snippets/bodies locally through `CloudConversationSearchService`.
- **Export / share:** macOS adds **Export all conversations** (a timestamped
  bundle with `conversations.json`, a `README.md` index, and one Markdown file per
  transcript via `ConversationBundleExporter`); iOS and Android share a single
  conversation as formatted Markdown. CLI-agent import remains the inbound path.
- **Mobile lightweight search:** Streams now routes active cockpit/session search
  through the encrypted hosted search index before local page filtering, returns
  up to 50 matching conversations without downloading full bodies, and pages the
  cockpit manifest list at the callable's 100-row cap with an explicit Load more
  affordance for older records.
- **On-device transcript cache:** iOS Streams now re-seals downloaded transcript
  bodies into an encrypted local cache with a user-adjustable storage cap
  (default 250 MB), visible usage, clear-cache control, and a Download loaded
  action for warming the currently loaded cockpit rows. The same cache size
  control is now searchable from iOS Settings, and Android Settings adds a
  matching encrypted transcript-cache limit/usage/clear screen.

### Fixed — Gateway token burn & reliability
- **The local proxy now accepts legacy Ollama Cloud model aliases.** Requests
  for unsuffixed cloud models such as `glm-5.1`, or stale provider-prefixed
  client entries such as `deepseek/deepseek-v4-flash`, resolve to the single
  advertised `*:cloud` route before execution instead of failing with
  `No eligible route`.
- The local gateway (`127.0.0.1:8317`) now **streams upstream responses through
  chunk-by-chunk** instead of buffering the whole completion. Long generations no
  longer blow past client idle timeouts and trigger full-prompt retries that get
  billed again. When client and upstream wire formats match, SSE relays verbatim.
- **No failover after the first byte** has streamed to the client, and the
  retryable error set was narrowed to genuine quota/rate-limit exhaustion
  (dropping the `"rate"` substring false-positives and bare `401`/`403` replays).
- **Idempotent usage accounting:** completions record under a stable key derived
  from the request signature, route, and attempt, so retries are counted once.
  Streaming responses now parse their final token usage from the stream
  (OpenAI `stream_options.include_usage`; Anthropic `message_delta.usage`),
  fixing the prior `usage=nil` under-reporting on SSE.
- **Thinking variants are effort-only:** reasoning effort no longer inflates the
  caller's `max_tokens`; the Anthropic `budget_tokens + 4096` floor applies only
  when a variant explicitly requests thinking.
- **Daemon no longer flaps** during upgrades — the binary swap is atomic
  (copy-to-temp + rename) so `KeepAlive` cannot restart into a missing binary,
  and a failed gateway socket bind now surfaces a clear error.

### Added — Post-June-15 Anthropic routing options (opt-in)
- Documented and implemented routing paths for Anthropic's June 15 metering split
  (programmatic `claude -p`/SDK billed separately from the interactive
  subscription window). All gray-area paths are **off by default**:
  - **Console API key** stays the legitimate default Anthropic route.
  - **B1 interactive handoff** — `openburnbar-cli claude-handoff dispatch/reconcile/list`
    dispatches a task into a real human-driven `claude` window and reconciles the
    subscription-window token delta as a companion.
  - **B2 PTY interactive executor** — experimental resident interactive `claude`
    behind `OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE=1`, subscription
    (`sk-ant-oat…`) routes only, with a loud ToS/brittleness warning.
  - **B3 cross-vendor degrade** — `OPENBURNBAR_CROSS_VENDOR_DEGRADE=1` (optionally
    `OPENBURNBAR_CROSS_VENDOR_DEGRADE_VENDORS=…`) substitutes an allow-listed
    OpenAI-compatible vendor on the user's own key when the requested model
    cannot be served.
  - **B0 meter diagnostic** — `openburnbar-cli claude-meter-experiment` reports
    whether an interactive turn drew from the subscription window or the metered
    credit before trusting B2.
- **Exposed B2 and B3 as `EXPERIMENTAL`-badged toggles** under **Settings →
  Agents → Advanced → Experimental routing**, alongside the routing-strategy and
  local-gateway cards. Each toggle persists, explains its risk posture inline
  (B2 is against Anthropic's terms and brittle; B3 uses your own keys but won't
  return the exact model requested), and prompts a one-click "Restart daemon to
  apply" — the app emits the matching env var into the launchd plist so the
  gateway picks it up at launch. The env vars remain the path for headless
  daemons.
- See [`docs/ROUTED_CLIENT_GATEWAY.md`](docs/ROUTED_CLIENT_GATEWAY.md) and
  [`docs/PROVIDERS.md`](docs/PROVIDERS.md) for the full risk posture.

### Changed — iOS background power policy
- iOS now throttles or freezes the animated swarm background when it is subtle,
  obscured, hidden, inactive, in Low Power Mode, or behind focused Mercury/Hermes
  surfaces, while keeping the full live background for prominent foreground use.

### Added — Interactive CLI Link (`openburnbar mcp login`) & Secure Local Vault Key
- Fully implemented the RFC 8628 style device link flow for `openburnbar mcp login` (no args) with automated user code verification and browser launching.
- Added a secure, hierarchical local Vault-Key store resolver (`vaultStore.ts`) that reads from Env, Keychain, or fallback file with 0600 permissions, ensuring `obb resume` works seamlessly on decrypted hosted session-memory search results.
- Added new cloud-hosted HTTPS endpoints `startCliLink` and `pollCliLink` and an authorized callable `completeCliLink` requiring BurnBar Pro entitlement.
- Integrated a premium dark-themed glassmorphism `/link` page on the web site allowing easy Google Sign-in to authorize CLI devices.
- Wired deep link `openburnbar://link-cli` and a "Link this Mac's CLI" Settings button inside the macOS app to instantly sync secure cloud vault keys down to the CLI Keychain and fallback storage.

### Added — Mercury Remote Unlock saved credential mode
- iPhone, iPad, and Android Remote Unlock now support optional one-tap saved
  credentials after locked mirroring is trusted. Saved credentials stay in the
  mobile secure store, require local device authentication before save/send, and
  travel only as signed HPKE `remote_unlock.credential` envelopes with
  `credentialKind=saved_password`.

### Fixed — Mercury Smart Text keyboard activation
- Smart Text auto-keyboard now switches the iOS mirror into direct Control mode
  when enabled, so tapping a Mac text field actually sends the focus tap before
  Smart Zoom and the phone keyboard react.
- Mac Smart Zoom focus context now refreshes unchanged text-field targets before
  the phone's stale-context window expires, preventing the keyboard follow mode
  from silently timing out while focus remains in the same text box.

### Fixed — iOS Hermes CLI mode
- iOS Hermes chat **CLI** mode now dispatches the turn as a `mac_visible_cli`
  mission, opens `hermes chat` in a visible Mac Terminal session, streams that
  Terminal output back into the mobile thread, and keeps the inline Mercury
  mirror in Smart Zoom follow mode so the phone frames the active Terminal
  instead of a zoomed-out desktop. Attachment turns now fail fast with a clear
  CLI-mode explanation instead of silently falling back to hidden native chat.

### Added — SOTA remediation closure (2026-05-28)
- Daemon `GET /metrics` exposes **`rpc_latency_ms_p95`** alongside RPC request/error counters.
- Mac app **`metrics.jsonl`** rotation (5 MiB, 3 archives) via `LocalMetricsJSONLWriter`.
- Functions **`withCallableLogging`** helper; structured start logging on encrypted search, insights hosted answer, OpenTimestamps, and App Store callables.
- Firestore **`ops/*_budget_status`** reads restricted to operator claim.
- `CloudSyncCoordinator` sync methods use **`MainActor.run`** for observable state (type not `@MainActor`).
- **`CloudSyncContext.syncGate()`** — off-main sync domains read immutable account/settings snapshots; class-level `@MainActor` cleared on CloudSync domain services and legacy `CloudSyncService` shim.
- Tech-debt metric counts **class-scoped** `@MainActor` on listed I/O facades only ([ADR 002](docs/architecture/002-actor-boundaries.md)).

### Changed — Hermes WSS relay retired
- Deleted the production Cloud Run WebSocket relay and
  `hermes-realtime-relay-redis-prod-secure` Redis backend from the `burnbar`
  project. Mobile now cascades from iroh directly to Firestore fallback, and the
  Mac host no longer starts or advertises the retired WSS fallback.
- Updated the commercial launch gate to require the retired relay and Redis to
  stay absent instead of treating them as production launch prerequisites.

### Added — Grok Build first-class CLI harness
- **`GrokParser`** — reads `~/.grok/sessions/` (`summary.json`, `signals.json`, `chat_history.jsonl`, optional `updates.jsonl`) under `AgentProvider.xAI` with exact token confidence.
- **Catalog** — `grok-build-0.1` model family; `grok-code-fast-1` retains `grok-build-0.1` alias for retirement migration.
- **Switcher** — `SwitcherCLIProfileType.grok` discovery, Connections wiring, and `RoutingClientWiringTarget.grok` TOML block in `~/.grok/config.toml`.
- **Quota / failover** — daemon gateway emits `XAISuperGrokPacingLog` on xAI routes; GrokBuild low prepaid balance → routing pressure; live catalog deprioritizes xAI slots ≤ 20% remaining.
- **Session mirror** — `CLIAgentRuntime.grok` archive mapping; `Grok Build` in MCP `eligible_providers.json` `all_known` (not `native_eligible` until resume verified).
- **Docs** — [docs/PROVIDERS.md](docs/PROVIDERS.md), [docs/PROVIDER_ACCOUNTS.md](docs/PROVIDER_ACCOUNTS.md).

### Fixed — SOTA remediation CI stability
- **`UsageRefreshPipelineTests`** — mark suite `@MainActor` to match `SettingsManager` / `DataStore` isolation.
- **`NSAppleEventsUsageDescription`** — declare Automation usage in `OpenBurnBar-Info.plist` for Computer Use onboarding compliance test.
- **`CLILaunchInvokerTests`** — use injected `launchHandler` for repeated quota-exhaustion launches (eliminates process-timing flake).
- **`BurnBarHTTPGatewayServerTests`** — align `/v1/messages` pool-isolation expectations with generic `No eligible route` responses and live-catalog probe behavior.
- **Quarantine → Archive** — move stale suites to `AgentLensTests/Archive/`; quarantine directory is pointer-only.

### Fixed — Switcher drain-target grouping (branch `follow-up/switcher-sqlite-profile-tests`)
- **Drain-target grouping** — `DrainTargetSwitcher` groups CLI profiles via `SwitcherCLIProfileType.canonicalAgentProvider` (OpenBurnBarCore); covers all six CLI types including OpenCode.
- **Account switcher** — OpenCode maps to `.openCode` provider row (no longer silently dropped).
- **Daemon SQLite profile store** — remove force-try in regression tests; per-provider round-trip and global active-ID semantics covered.
- **Tests** — `DrainTargetSwitcherGroupedTests`, expanded `SwitcherCLILaunchTests` (`launchUsingDrainTarget`), drain-pin UI in ProviderRoutingCockpit.

### Added — Custom proxy model aliases
- **Gateway model aliases** — Settings → Agents → Models can expose any route-ready model under a custom wire id (optional display name, per-alias “hide original model in /v1/models”). Clients call the alias in `/v1/models` and chat requests; routing still uses the canonical upstream model. Re-sync Droid after alias changes.

### Added — Phase 5–6 SOTA remediation (observability & governance)
- **SLO runbook** — [docs/runbooks/slos.md](docs/runbooks/slos.md) defines latency, availability, and error-budget targets for macOS app, daemon, and Cloud Functions, aligned with [OBSERVABILITY.md](docs/OBSERVABILITY.md) trace fields and log-based metrics patterns.
- **Architecture ADRs** — [docs/ARCHITECTURE/](docs/ARCHITECTURE/README.md): naming conventions, actor isolation, error taxonomy, schema ownership, sync ownership.
- **Tech debt metrics CI** — `./scripts/ci/update-tech-debt-metrics.sh` refreshes [docs/TECH_DEBT_METRICS.md](docs/TECH_DEBT_METRICS.md) (quarantine count, MainActor I/O facades, empty catches, service LOC, schema barrel vs legacy, unsafe-cast budget).
- **Daemon metrics endpoint** — `GET /metrics` on the loopback HTTP gateway returns JSON snapshot (uptime, heartbeat, stub counters) for local SLO verification.

### Added — BurnBar Resume
- Added cross-harness conversation resume across the local MCP server, hosted
  Remote MCP shim, daemon RPC/CLI, and Mac session-log UI. Native Claude Code
  and Codex handles are delegated only after on-disk validation; all other
  targets receive a deterministic local briefing.
- Added explicit resume spawning via `burnbar_spawn_resume` and
  `openburnbar resume --spawn`, with detached stdio, working-directory launch,
  delayed temp-briefing cleanup, and GUI editor hint files under `.cursor`,
  `.windsurf`, or `.openburnbar`.
- Added `conversations.workingDirectory` with lazy background backfill from
  absolute key-file paths, plus parser/cloud-sync passthroughs so resume can run
  from the right project without blocking app launch.
- Documented the privacy contract: hosted resume returns sealed envelopes,
  the local shim checks vault-key availability before network access, and
  plaintext briefings stay on-device or in 0600 temp files.

### Fixed — Mercury mirror reconnect loops
- Accepted first-frame `media.control` classification when a phone connects
  through a still-signed persisted route whose `connectionId` differs from the
  Mac's freshly published relay document. The Mac now registers the stream under
  the frame's route id, audits the drift, and keeps subsequent presence/mirror
  traffic flowing instead of leaving iOS/iPadOS/Android stuck in
  "connecting / reconnecting".

### Added — Mercury auto keyboard on text focus
- **Added opt-in Auto keyboard on text focus for Mercury screen share.** iOS,
  iPadOS, and Android now expose a persisted **Auto keyboard on text focus**
  toggle in Media settings and in the mirror dock customize panel. When enabled,
  the phone keyboard opens when the Mac reports a focused text field over
  Mercury focus context; Smart Zoom still controls viewport framing on its own.
  Default is off. Manual **Type on Mac** remains available when auto-type is
  disabled or after the user dismisses the keyboard.
- **Fixed Android manual-dismiss cooldown applying when auto-type was off**, and
  **CoPilot mode leaving the IME open**; iOS now re-evaluates auto-type when
  interaction mode or remote-unlock state changes (parity with Android's reactive
  effects).

### Changed — type safety (unsafe cast zero-lock)
- Burned down all hand-written unsafe casts and force unwraps across TypeScript
  (`functions/`, extension/service tests, website), Kotlin (Android tests and
  FFI bridges), and Swift (already at zero) to **0** live violations.
- Added shared runtime guards/decoders in `functions/src/guards.ts`,
  `firebaseRuntime.ts`, and `remoteConfigGuards.ts`; typed test fixtures in
  extension helpers and `HermesRunAssertions.kt`.
- CI now gates on `budgets/unsafe-cast-baseline.json` via
  `scripts/debt/check-unsafe-cast-budget.sh` (see `docs/TYPE_DEBT.md`).

### Changed — macOS performance sweep
- Capped the wallpaper swarm canvas at 30 fps with asynchronous rendering and
  batched all data-driven particle fills by quantized color bucket
  (`RGBA.bucketKey`), dropping per-frame fill counts from hundreds to a
  handful while preserving visual fidelity.
- Replaced the 1 s / 3 s wallpaper space-change polls with
  `NSWorkspace.activeSpaceDidChangeNotification` plus a 30 s defensive
  backstop, and added a 30 Hz pointer-coalescing window (4 pt movement
  gate) so high-rate `mouseMoved` events stop re-evaluating the canvas
  body.
- Added `DataStoreCoordinator.usagesVersion: Int`, bumped on every
  `replaceUsages` / `replaceUsageSnapshot`, and migrated six dashboard
  surfaces (`MenuBarPopoverView`, `DatabaseWorkspaceView`,
  `DashboardChatWorkspaceView`, `ChatPanel`, `DashboardDeviceBreakdownCard`,
  `DashboardLiveCostCurve`, `ProjectsView`) from observing `lastRefresh`
  (Date) and `usages.count` to the integer ticker.
- Cached `DashboardLiveCostCurve.buildSamples` and
  `ProjectsView.computeMergedProjects` behind versioned cache keys so the
  expensive aggregation only runs when the underlying data actually
  changes. Both functions are now pure static and unit-tested.
- Switched `ChatMessageRecord.content` and `.transcriptPieces` to `var`
  and rewrote the streaming hot path in `ChatSessionController` to
  mutate the active message in place, eliminating per-token struct
  + array reallocations. Subscribers should observe `streamingTick` for
  view updates.
- Introduced `BackgroundCadenceCoordinator` — the single home for all
  timer-driven background work. Migrated `SystemPermissionMonitor`,
  `MercuryPeerSource`, `SettingsManager` (Computer Use Remote Config),
  `AgentLensApp.periodicRefreshTask`, `SmartHubBridgeController` (four
  loops), `SmartDisplayActionsListener`, `HermesRelayHostService`,
  `PiAgentCloudRelayHostService`, and `ComputerUseDaemonApprovalPresenter`
  to it. Every cadence now backs off when the app is in the background
  and pauses entirely while the display sleeps, with observer-coalescing
  for the Mercury peer poll (push heartbeat ⇒ poll stretches to 30 s).
- Replaced `Timer.publish` in `CyclingProviderIconView` with a
  `TimelineView(.periodic(...))` so the dashboard's provider-logo cycler
  auto-suspends when the view is off-screen.
- Documented the new contract in `docs/architecture/background-cadence.md`
  and the broader sweep in `docs/architecture/macos-performance.md`.
- Added `BackgroundCadenceCoordinatorTests`, `SwarmCanvasFrameRateTests`,
  `DataStoreUsagesVersionTests`, `DashboardLiveCostCurveCacheTests`,
  `ProjectsMergedProjectsCacheTests`, and `ChatStreamingMessageMutationTests`
  (44 new tests, all green).

### Added — Xiaomi MiMo first-class provider
- Added `mimo` as a first-class provider with endpoint profiles for regional Token Plan
  (`tp-…` → `cn` / `sgp` / `ams`) and global pay-as-you-go (`sk-…`), router failover
  constrained to matching profiles, tiered quota (vendor remains → BurnBar credit ledger →
  unavailable), and cross-platform cloud connect metadata.
- Added Mac quota/settings UI, mobile connect payloads, Cloud Functions adapter, probe
  scripts, and documentation updates in `docs/PROVIDERS.md`.
- Added dedicated `MimoLogo` assets on Mac (`AgentLens`), iOS (`OpenBurnBarMobile`), and
  Android (`mimo_logo.xml`), replacing the OpenCode placeholder across provider avatars,
  catalog `logoKey`, and brand resolution.
- Added schema-sync domain `provider-account.tsp` with TS/Swift/Kotlin emitters for
  `ProviderAccountDoc` and connect-context metadata (`endpointProfileID`, region, token-plan
  tier/cycle, `authMethodID`).
- Retrofit MiniMax legacy single-key routing through `ProviderRouteEndpointResolver` so
  `sk-cp-…` resolves `minimax.token-plan` and `sk-api-…` resolves `minimax.payg`.
- Committed redacted MiMo API probe fixture (`functions/scripts/fixtures/mimo-api-probe.fixture.json`)
  with `--validate-fixture` and `test-mimo-probe-fixture.mjs` wired into `npm run test:providers`.

### Hardened — MiMo / endpoint-profile follow-through
- Added schema-sync hand-mirror guard (`tools/schema-sync/check-hand-mirror.mjs`) and
  `functions/scripts/test-provider-account-schema.mjs` so generated provider-account fields
  cannot drift from Swift/Kotlin/TS hand mirrors unnoticed.
- Aligned MiniMax macOS quota adapter with registry + Cloud Functions dual-endpoint fallback;
  added `MiniMaxQuotaAdapterTests`, `ProviderRouteEndpointResolverTests`, MiMo auth-registry tests,
  Android `MimoConnectMetadataTest`, and MiMo logo unit coverage.
- Added MiMo PixelClock stencil + website presenter port; quota popover/setup/search parity on Mac/iOS.

### Added — Agent reply notifications
- Added Cloud-owned agent reply notifications across CLI and mobile assistant
  chat mirrors, with deterministic event documents, FCM/APNs fanout,
  active-thread suppression, stale-token cleanup, and Firestore rules for
  durable inline reply commands.
- Added iOS/iPadOS, Android, and macOS notification handling with native inline
  reply actions, assistant deep links, mobile FCM token/device heartbeats, Mac
  event-stream notifications, Mac-host processing of queued phone/tablet reply
  commands, and immediate local reply routing where the runtime is available.
- Hardened the notification audit path with Android data-only FCM delivery for
  background direct replies, Mac event timestamp indexing, and Firestore reply
  rules that bind every queued reply to its server-created notification event.
- Documented Apple APNs and Firebase Cloud Messaging setup plus verification in
  `docs/AGENT_REPLY_NOTIFICATIONS.md`.

### Added — Remote Unlock certification
- Added a machine-bound Remote Unlock certification report so Macs advertise
  locked-screen unlock only after a fresh hardware proof matches the current
  macOS build, HPKE recipient key, Screen Sharing backend, daemon install, and
  successful lock-screen capture / credential-input / unlock probes.
- Added `openburnbar-cli remote-unlock-certification` status/reset/record
  tooling plus `scripts/e2e/remote-unlock-hardware-smoke.sh` for iOS, iPadOS,
  and Android locked-Mac certification without collecting or logging the Mac
  password.

## [1.0.1] — 2026-05-26

### Added — macOS release channels
- Prepared the macOS `1.0` release for both channels: a sandboxed Mac App Store
  build with `DISTRIBUTION_MAS=1`, and a Developer ID signed/notarized direct
  download build for the website and GitHub Releases.
- Added explicit local release scripts for Mac App Store archive/export/upload
  and website DMG/ZIP/checksum/SBOM artifact generation.
- Updated website and release documentation so macOS no longer points at the
  old public beta artifact.

### Added — Text expansion snippets
- Added `&&trigger` text expansion across macOS OpenBurnBar chat, opt-in macOS
  global fields, iOS/iPadOS Hermes composer plus keyboard extension, and
  Android Hermes/CLI composers plus IME.
- Added user-managed snippet settings, static snippet insertion, Mac in-app LLM
  rewrite previews, shared trigger matching tests, macOS/iOS encrypted Firestore sync
  with tombstones, and rules coverage that accepts sealed snippet documents
  while rejecting plaintext snippet fields.
- Documented the surface matrix, trigger grammar, privacy model, and validation
  commands in `docs/TEXT_EXPANSION.md`.

### Fixed — CLI agent model pickers on mobile
- **Allowed `cliAgentModelCatalog` through Firestore relay rules.** iOS and
  Android Droid, Forge, Codex, Claude Code, and Antigravity model pickers were
  failing with permission-denied copy even when Hermes relay models loaded,
  because `hermes_relay_requests` rejected the catalog operation. Mobile now
  surfaces the real relay error instead of mislabeling every failure as a
  sign-in problem.

### Added — Model capability intelligence
- Added a canonical `ModelIOCapabilities` shape for per-model input/output modalities, limits, supported parameters, accepted MIME types, and source references.
- Wired `/v1/models`, Codex-compatible model descriptors, Mac/iOS/Android attachment encoders, and the OpenAI-compatible proxy so Kimi K2.6 is advertised and routed as text+image instead of text-only.
- Enriched user-facing model names across the proxy and CLI runtime catalogs so Droid, Forge, Codex, Claude Code, Antigravity, Hermes, Pi, and OpenClaw pickers show the model, provider/source, `via OpenBurnBar`, and reasoning level without changing machine-readable model IDs.

### Added — Computer Use editorial empty state (iOS + Android)
- **Replaced the blank "Waiting for Mac session" placeholder.** Tapping the
  Computer Use tab on iOS and Android used to land users on a near-blank
  surface with only a dashed-rectangle icon and the cryptic line
  *"Select an online Mac Remote Relay in Hermes to watch the agent live."*
  No explanation of what Computer Use is, no path to enable it, no idea why
  the screen was empty. That entire surface is now an editorial onboarding
  card: mercury-stroked hero ("Let the agent drive your Mac"), live
  3-row setup checklist (Signed in / Hermes Remote Relay selected / Live
  session) with green check or red dot per row, ordered 01/02/03 how-it-works
  guide with mono ordinals, 2x2 capability strip (mirror / tap-to-drive /
  audit / panic halt), and a footer that explains Mac permissions live on
  the Mac.
- **Status row CTAs are wired.** "Sign in" deep-links to Settings, "Open
  Hermes" switches tabs, "Use {Mac name}" one-tap selects the suggested
  relay-link connection via `HermesService.connectToSuggestedRelay(refresh:)`
  on iOS and `HermesService.selectConnection(...)` on Android. The legacy
  red coral pill overlay is gone — its blocker copy is now folded into the
  live checklist row so users see *why* they're stuck and what to do about
  it.

### Added — Antigravity agent-tab parity
- **Made Google Antigravity / `agy` a first-class assistant runtime.**
  Antigravity now has shared runtime IDs, built-in Agent identities, provider
  aliases, default mobile pins, Mac chat backend rows, onboarding/account
  switcher support, branded assets, and iOS/Android chat surfaces alongside
  Hermes, Pi, Codex, Claude Code, OpenClaw, Droid, and Forge.
- **Routed mobile Antigravity chat through the trusted Mac.** The Mac relay and
  mission fallback accept `antigravity`, `agy`, and Google-Antigravity aliases,
  launch the real local `agy` CLI, stream output into mobile threads, and map
  grants onto `agy --sandbox` or the explicit dangerous bypass only when the
  user selected that capability.
- **Kept Antigravity model selection Mac-sourced.** Because `agy 1.0.2` exposes
  no enumerable model-list command, mobile asks the paired Mac for the
  Antigravity-compatible Gemini catalog and appends the Mac profile row only
  when the selected `agy` model is a custom non-catalog target.

### Changed — Android assistant toolbar parity
- **Brought Android assistant chat tool chrome up to iOS parity.** CLI chat now
  uses provider identity instead of a misleading back arrow, removes the dead
  Settings affordance, disables attachment tools while streaming, shows
  icon-plus-label Chat vs Mac CLI controls, and renders Hermes/Pi/CLI tool
  calls with shared, instantly recognizable category glyphs.

### Fixed — Android CLI agent chat relay parity
- **Moved Android native Codex/Claude/OpenClaw/Droid/Forge/Antigravity chat onto the same
  encrypted Mac relay path as iOS.** Android now sends `cliAgentChat` requests
  to `/v1/cli-agent/chat`, streams `CLIAgentRelayChatEvent` snapshots directly
  into `mobile_assistant_chats`, and keeps the Firestore mission queue for the
  explicit visible Mac CLI mode or safe relay fallback.
- **Hardened the Android relay fallback for long Mac agent turns.** If direct
  iroh fails for `cliAgentChat`, Android now falls back to the encrypted
  Firestore relay instead of immediately queuing a mission request, and that
  fallback honors the same 10-minute stream window as iOS native chat.
- **Fixed Android CLI Agent / Hermes connection loopback stuck on localhost.** When starting up or using the model catalog/chat streaming on Android, the connection resolution now automatically detects and connects to the active online paired Mac remote relay (`RELAY_LINK`) instead of staying stuck on the loopback default (`127.0.0.1:8642`) and incorrectly reporting offline/unreachable status.

### Added — Mobile visible CLI agent sessions
- **Added Chat vs Mac CLI session modes for mobile CLI agents.** iOS, iPadOS,
  and Android now let users choose whether Codex, Claude Code, OpenClaw, Droid,
  Forge, or Antigravity replies stay in the native chat surface or launch as a
  visible macOS Terminal session that can be watched through Mercury screen
  sharing.
- **Threaded the interface mode through the mission contract.** Mobile requests
  now write `presentationMode = native_chat | mac_visible_cli`; the Mac listener
  runs visible-mode requests through a real Terminal-backed CLI process and
  streams the captured output back into the mobile thread.

### Added — Mercury remote clipboard
- **Added explicit Paste to Mac and Grab from Mac mirror controls.** iOS,
  iPadOS, and Android now expose text-only Mercury clipboard actions beside the
  keyboard controls, read or write phone clipboards only inside user-tapped
  handlers, and show compact status chips for pasted, copied, empty, denied,
  and too-large outcomes.
- **Signed and gated clipboard control like phone input.** Clipboard requests
  now use shared `control.clipboard.request` / `control.clipboard.response`
  frames, Ed25519 authority envelopes, the phone-control monotonic counter, Mac
  trust/session/entitlement/Accessibility/scope gates, and audit descriptors
  that never persist clipboard text.

### Added — Mercury multi-device Mac mirroring
- **Allowed up to three iOS/Android devices to watch the same Mac mirror.**
  The Mac now runs one ScreenCaptureKit capture/encoder session and fans out
  encoded frames to every active viewer instead of treating the second phone as
  a competing mirror request.
- **Made mirror control ownership explicit.** The first viewer becomes the
  controller, later viewers join as read-only watchers, and phone-control
  intents are rejected on the Mac when they come from a non-controller peer.
- **Scoped mirror lifecycle messages by session and viewer.** iOS, Android,
  and the shared relay contract now carry viewer IDs, device IDs, session IDs,
  viewer role/count metadata, and selected-display updates so reconnects,
  stops, and display switches do not tear down the wrong viewer.

### Added — Droid and Forge agent-tab parity
- **Made Droid and Forge first-class assistant runtimes.** Droid and Forge now
  have shared runtime IDs, built-in Agent identities, provider aliases, default
  mobile pins, chat backend rows, model/agent pickers, and mobile/Android
  history surfaces alongside Hermes, Pi, Codex, Claude Code, and OpenClaw.
- **Routed mobile Droid/Forge chat through the trusted Mac.** The Mac relay and
  mission fallback now accept Droid/Factory and Forge aliases, launch the real
  local CLIs, stream text/tool events into mobile threads, and preserve explicit
  runtime/model selections.
- **Mapped grants onto Droid and Forge safely.** Droid uses
  `droid exec --output-format json` with workspace, model, and grant-derived
  autonomy flags; Forge uses `--prompt`/`--agent` plus OpenBurnBar safety
  constraints when edit or shell grants are absent.
- **Scoped model pickers to each CLI's real catalog.** Codex and Claude Code
  now default to the paired Mac CLI profile instead of guessed static model
  menus, while Droid and Forge pull their runtime-native model/agent lists from
  the paired Mac through `cliAgentModelCatalog`. Droid uses `droid exec --help`,
  Forge uses `forge agent list`, and mobile fails closed with refresh/error copy
  instead of showing bundled stale rows when the Mac cannot verify the catalog.
- **Made Droid model cost source visible before selection.** Droid model
  pickers now separate first-party Droid Standard/Core quota rows from
  OpenBurnBar proxy rows that use connected API/OAuth subscriptions, with
  OpenBurnBar-badged proxy model logos on iOS and Android.

### Added — Dashboard drill-down affordances
- **Made overview activity cards navigable.** Recent Sessions now opens the
  full Session Logs workspace, and Model Leaders rows open the matching model
  detail page with the searchable session ledger.

### Fixed — Swarm background visual improvements
- **Replaced broken scattered Hermes logo points with the high-fidelity Hermes girl.** The old raw scattered points that resulted in a messy, visual glitch on both iOS and Android have been replaced with a beautifully thinned and scaled vector-particle mapping of the signature Hermes anime girl with headphones directly from the canvas SVG. This ensures perfect visual parity and SOTA rendering of the Hermes AI chat assistant logo in the dynamic ember swarm wallpaper.

### Fixed — Mercury Mac mirror reliability
- **Restored the Mac Local Network permission declaration.** The built macOS
  app now carries the real `NSLocalNetworkUsageDescription` and Bonjour service
  declarations used by Mercury, Hermes relay, Cast, and Smart Hub paths, so
  macOS can prompt and authorize LAN transport instead of silently reporting
  `Local network prohibited`.
- **Kept OpenBurnBar chrome out of display mirrors.** Display capture now
  excludes the OpenBurnBar Mac app from ScreenCaptureKit display streams, so the
  phone sees the real Mac desktop instead of the transient "Starting mirror"
  overlay or tray popover.
- **Made mirror controls use the live Mercury control stream.** iOS and Android
  now send tap, pointer, keyboard, scroll, and display-select actions through
  the active `media.control` stream, and both clients surface Mac
  `control.denied` replies such as missing Accessibility permission.
- **Kept full-screen mirror tools interactive while control warms up.** iOS no
  longer disables touch, trackpad, keyboard, or direct display switching while
  the phone-control sender is being prepared, and legacy v1 mirror frames use
  the larger screen-frame ceiling before chunking so fallback keyframes do not
  drop before reaching the phone.
- **Retargeted stale iPhone control streams before sending Mac input.** Phone
  control frames now verify that the live Mercury stream matches the frame's
  current Mac connection ID before sending. If the app had been attached to an
  older route, the coordinator closes that stale stream, redials the active Mac,
  and only then sends taps, trackpad clicks, keyboard input, or display actions.
- **Added the missing iPhone trust path for Mac control.** The iOS mirror now
  registers the phone as a controller, exposes a Trust action in the mirror
  dock, auto-retries signed control setup after promoting a pending current
  iPhone, accepts current and legacy Computer Use/Pro Max product IDs in the
  Firestore authority gate, and explains trusted-device or entitlement failures
  instead of silently showing local tap ripples that never reach the Mac.
- **Made mobile mirror keyboards type directly into the Mac.** iOS and Android
  now use hidden keyboard-capture fields for Mercury mirror typing, stream
  committed text plus Return/Tab/Delete over phone-control intents, and keep the
  phone UI free of lingering text-entry bars after the keyboard is dismissed.
- **Stopped defaulting to fake mobile cursors.** The iOS mirror hides its local
  cursor overlay by default, and Android no longer draws its own mirror cursor,
  so the Mac cursor captured in the stream is the pointer users see and control.
- **Stopped applying agent Computer Use action caps to human phone control.**
  Signed iOS and Android mirror input still goes through entitlement,
  Accessibility, deny-region, scope, and kill-switch checks, but no longer burns
  through the browser/agent action budget or returns a generic Computer Use
  limit after repeated taps, pointer moves, or keyboard input.

### Added — Agent desktop permission grants
- **Made desktop tools user-grantable from Hermes chat.** Hermes, OpenClaw, Pi,
  Codex, and Claude now share a per-thread `AgentCapabilityGrant` model for
  Browser, screenshot, Accessibility inspect, Mac input, workspace read,
  workspace write, and shell access.
- **Brought desktop grants to iPhone, iPad, and Android.** Hermes, Pi, Codex,
  Claude, and OpenClaw mobile chat surfaces now include an Agent Permissions
  control with Off, Low, Workspace, Desktop, All, and YOLO presets. Desktop,
  All, and YOLO require Face ID/Touch ID or Android biometric unlock before the
  phone can issue the signed grant. iOS now declares the Face ID usage purpose
  string for App Store review and install-time privacy readiness, and Android
  keeps BiometricPrompt open after a failed face/fingerprint attempt instead of
  aborting the grant flow.
- **Preflighted trusted-device state before mobile grants.** iPhone, iPad, and
  Android grant requests now register the current device if needed, verify the
  `escrow_devices/{deviceId}` record is explicitly trusted, and show a direct
  Devices & Sync recovery message before Face ID/Touch ID, Android biometrics,
  or Firestore writes.
- **Made mobile grants live-first and queue-safe.** Phones send signed
  `control.agent_grant.request` frames over the paired Mac iroh control stream
  when available, or fall back to a metadata-only Firestore queue that the Mac
  listener validates and receipts.
- **Routed granted tools through the real Computer Use stack.** Hermes/OpenClaw/Pi
  receive OpenAI-compatible function tools while a grant is active; browser
  actions go through daemon Browser Computer Use, Mac input/inspect actions go
  through the app-owned System Computer Use coordinator, and workspace/shell
  tools stay confined to the selected chat workspace. Workspace file tools now
  reject symlink escapes, empty-file writes work, and shell writes are denied
  outside the workspace by the local macOS sandbox.
- **Added explicit Desktop export and YOLO shell tools.** `desktop_export_file`
  copies granted workspace artifacts to
  `~/Desktop/OpenBurnBar Agent Drops/{threadId}/`, while
  `shell_run_unrestricted` is available only through YOLO/Trusted
  all-capability grants.
- **Mapped grants onto native CLI permissions.** Codex receives read-only or
  workspace-write sandbox arguments from the active grant, while Claude receives
  matching `--allowedTools` and edit-permission arguments. The YOLO preset maps
  to each CLI's explicit dangerous/full-permission bypass flag.
- **Made permission choice obvious.** The chat UI now starts with Off, Low,
  Workspace, Desktop, All, and YOLO presets, with fine-grained toggles and risk
  copy for users who want exact control.
- **Added revocation and docs.** Grants are revoked on backend/thread changes,
  checked before every brokered tool call, surfaced in the chat UI, and
  documented in `docs/HERMES_COMPUTER_USE.md`.

### Added — Hermes Skill Runs on mobile
- **Made Hermes Skill Runs first-class mobile missions.** iOS, iPadOS, and
  Android mission requests now carry shared Skill Run metadata
  (`sourceSkillID`, `sourceSurface`, `deliveryMode`, and
  `parentHermesThreadID`) so companion apps can receive and follow live Mac
  execution timelines.
- **Added customizable delivery controls.** Agent subscriptions now support
  `action_only`, `full_stream`, and `muted` delivery modes across iOS/iPadOS
  and Android, with Android subscription topics syncing through Firestore
  instead of staying local-only.
- **Added live follow-along and PiP for Skill Runs.** iOS, iPadOS, and Android
  now surface eligible Skill Runs in a floating in-app tile, and text-only
  Skill Runs can enter OS Picture in Picture while preserving the existing
  Mercury/Agent Watch video PiP path.
- **Documented the Skill Run contract.** Added `docs/HERMES_SKILL_RUNS.md` and
  updated the Hermes BurnBar skill with stable mobile-ready skill IDs.

### Fixed — Cross-platform swarm palette settings
- **Made app-wide mobile swarms follow the selected palette and provider glyph
  filters.** iOS, iPadOS, and Android now apply the chosen color palette to the
  shared app backdrop and swarm particles, and the provider glyph customization
  controls affect the general app background instead of only wallpaper
  generation surfaces.

### Fixed — Live desktop wallpaper appearance settings
- **Applied wallpaper appearance changes immediately.** The macOS desktop
  wallpaper now observes the provider glyph list, auto-cycle toggle, and
  click-to-cycle toggle without requiring an app restart, and Hermes provider
  glyphs now resolve to the anime-girl Hermes logo instead of falling back to a
  generic generated mark.

### Fixed — Mobile quota freshness
- **Stopped stale quota snapshots from winning mobile summaries.** iOS and
  Android now drop time-stale bucket values when a fresh snapshot exists for
  the same provider account, normalize bucket dedupe keys across punctuation
  changes, and avoid presenting no-signal Android quota docs as `0%`.

### Fixed — iPad Agent Watch screen-share parity
- **Opened paired-Mac screen shares from the iPad Hermes split view.** iPad now
  keeps the same app-scoped Agent Watch live stage as iPhone and resolves the
  paired Mac tile directly into Mercury Live, so screen-share viewing, PiP
  setup, and live-activity deep links work from the iPad shell instead of
  requiring the phone layout.
- **Stopped stale Mercury reconnect loops on iPad.** The iPad Mercury Live
  detail view now rejects stopped, failed, or wrong-relay control-stream
  coordinators and reboots the selected Mac route instead of cycling between
  connecting and lost-connection states.

### Fixed — Swarm glyph inspection timing
- **Let provider and symbol glyphs settle before cycling.** Standard swarm mode
  now waits for static glyph formations to finish converging, then keeps them
  visible for a short admire hold before transforming into the next swarm shape
  across macOS/iOS/iPadOS and Android wallpaper surfaces.

### Added — Click-to-Open and Long-press-to-Cancel Active Missions
- **Click-to-Open progress dashboard**: Active mission tiles in the Agents tab (iOS single-column and multi-column split layout sidebars) are now clickable, opening the live progress tracking sheet (`MissionLiveDetailView`) to observe real-time logs, outputs, and milestones.
- **Tap-and-Hold visual interactive cancellation**: Added a premium spring-animated visual transition that reveals a circular red `"X"` overlay button on active mission tiles during long-press, complete with custom threshold haptics (`HapticBus.threshold()`).
- **Destructive cancellation confirmation**: Pressing the close `"X"` button triggers an elegant Swift confirmation dialog before destructively cancelling the mission via the client's `cancelMission(requestID:)` Firestore writer.
- **Daemon-level shell process and streaming generation termination**: Defined a thread-safe `MissionCancellationTracker` inside the Mac daemon listener. The daemon intercepts the cancellation snapshot, immediately terminates running CLI sub-processes (via `process.terminate()`), and cleanly cancels active interactive chat stream generation (via `chatController.cancelGeneration()`).

### Added — xAI / Grok as a full-service quota provider
- **Promoted Grok (xAI) to a first-class quota provider.** xAI now appears as a
  subscription card with a real remaining-percentage, participates in failover
  routing alongside Claude / Codex / Factory / MiniMax, and renders on the Pixel
  Clock and Nest Hub smart-display surfaces with a dedicated 8×8 Grok glyph.
- **Three SuperGrok consumer tiers plus the GrokBuild developer tier.** A plan
  picker (SuperGrok Lite / SuperGrok / SuperGrok Heavy / GrokBuild) is available
  in the quota popover, command center, and the macOS plan wizard. SuperGrok
  tiers estimate a rolling 2-hour prompt window from local routing activity;
  GrokBuild reads exact prepaid credit balance and 24h/7d/30d spend from the xAI
  Management API.
- **Management-key auth.** A new optional `xai-mgmt-…` Management Key (stored in
  the device keychain, separate from the inference key) unlocks exact GrokBuild
  credit reporting. Mobile provider connections and the Firebase quota-refresh
  backend recognize xAI end-to-end.

### Fixed — Quota account visibility controls
- **Allowed multiple OpenAI/Codex OAuth profiles with the same account label.**
  The add-account flow now dedupes only the exact local auth directory, keeps
  same-email isolated profiles distinguishable, and shows the current local CLI
  login beside saved reserve profiles on the quota dashboard.
- **Added per-account quota bar visibility.** Expanded quota cards now let users
  show or hide individual bucket bars, with Show all / Hide all controls and
  persisted selections per account.

### Fixed — Mercury mirror iOS controls
- **Persisted mirror consent after the first Mac approval.** Accepting a phone
  mirror request now enables the existing Mac auto-accept fast path, advertises
  the trusted state through Mercury presence, and changes mobile pending copy to
  “opening mirror” instead of telling an already-approved user to check the Mac.
- **Stopped false “Mac video stalled” recovery prompts.** The Mac mirror sink
  now emits lightweight health heartbeats while a mirror is active, Android
  treats fresh Mac heartbeats as live stream health even when the desktop is
  visually idle, and stale receiver state starts automatic mirror recovery
  instead of telling the user to tap Retry.
- **Restored direct Mac input from the iOS mirror.** Single taps now send
  primary click intents immediately, long-press still maps to secondary click,
  trackpad mode appears as soon as it is selected, the mirror cursor is visible
  before the first pointer event, and the Mac typing bar retries focus so the
  iOS keyboard reliably opens.
- **Restored Android mirror control parity.** Android now sends the same
  `pointer_move`, `pointer_click`, and `mouseButton` control payloads as iOS,
  exposes explicit View/Touch/Trackpad/Scroll modes, shows a live mirror cursor,
  opens a focused Mac typing row, and sends complete scroll endpoints instead of
  malformed partial scroll intents.
- **Cleared Mac-side mirror sessions when phones hang up.** iPhone/iPad now sends
  `media.mirror.stop` even when the full-screen viewer is dismissed outside the
  close button, Android emits the same stop frame on close/back/activity teardown,
  and the Mac immediately frees the active mirror slot so reconnects and another
  paired device can connect without waiting for a stale session to time out.

### Fixed — Cached input cost accounting
- **Corrected inflated GPT-5.5 cached-input estimates.** Added the OpenAI
  GPT-5.5 catalog entry and refreshed the GPT-5.5 Factory-family cache pricing
  so cached input uses the current `$0.50 / 1M tokens` rate instead of the stale
  `$1.25 / 1M tokens` fallback that made large Codex sessions look far too
  expensive.
- **Prevented OpenAI-style cached-token double counting.** Usage importers now
  store uncached input separately from cached input when payloads report
  inclusive `prompt_tokens` / `input_tokens` plus `cached_tokens`, while keeping
  Anthropic's already-disjoint `input_tokens` / `cache_read_input_tokens`
  semantics intact.
- **Hardened provider-wide cache accounting.** Gemini CLI logs now subtract
  `cachedContentTokenCount` from billable input and no longer double-count
  `message_update` usage rows, Anthropic cache writes use the documented
  5-minute write premium, and Factory-side GPT-5.4 / GPT-5.3 Codex catalog
  pricing now matches current cached-input rates.

### Added — Swarm Background theme across all platforms
- **Active, reconverging token-ember swarms in the app.** Ported the
  "Interactive Token Ember Swarm" canvas from burnbar.ai into every
  OpenBurnBar surface that already honored the *Website Background* toggle —
  macOS, iPadOS, iOS, and Android. Hundreds of particles murmurate across the
  screen and periodically reconverge into the four signature shapes from the
  marketing site: a `$`, `</>`, concentric quota rings, and the router
  failover S-curve, then break back apart. Pointer / touch position pushes
  nearby particles away, matching the web build. The toggle's old "perspective
  grid" copy was renamed to "Swarm Background" with updated search keywords.
- **Cross-platform shared simulation.** Added `SwarmCanvasView` in
  `OpenBurnBarCore` driving both AgentLens (Mac) and OpenBurnBarMobile from
  one `TimelineView` + `Canvas` implementation with two paces (energetic for
  Mac, cinematic for iPhone/iPad) and adaptive particle budgets (1800 on Mac,
  1080 on iPad, 520 on iPhone, halved under Low Power Mode). Android gets a
  parallel `SwarmBackground` composable using `withFrameNanos` + Compose
  `Canvas`, scaled per device class and respecting Power Save mode. Both
  honor Reduce Motion (pauses cycling, silences the noise field).
- **Desktop wallpaper background presets.** The macOS desktop swarm wallpaper
  now offers background choices instead of a single AMOLED toggle: macOS
  Desktop, Midnight, AMOLED Black, Graphite, Warm Ember, and Deep Indigo. The
  old AMOLED preference migrates into the new picker.
- **Live provider colors on wallpaper beads.** The desktop swarm color driver
  now checks running agent activity before historical usage, so concurrent
  Codex and Claude work paints separate teal and clay bead bands instead of
  staying all Codex teal.
- **BurnBar logo swarm formation.** The shared swarm cycle now adds the
  OpenBurnBar flame-shaped bar graph mark as a first-class particle formation
  between the code glyph and quota rings.
- **Provider-logo and Grok/xAI swarm formations.** Provider logos can now form
  concurrently instead of one-at-a-time, default mode preserves each provider's
  brand colors, selected swarm palettes tint logo highlights intentionally, and
  macOS can cycle through symbols, individual provider marks, Grok, xAI, and
  multi-provider formations by clicking empty desktop space.
- **Asset-derived logo dot masks and wallpaper speed dial.** Provider-logo
  formations now sample bundled logo assets into pure dot masks instead of
  letting text glyph particles pollute the marks, so Gemini/Antigravity keeps
  its rainbow source colors, Cursor/Grok/OpenAI/Codex match the app assets, and
  macOS gets a live speed dial for desktop swarm drift and cycle pacing.
- **Complete provider-logo swarm coverage.** The desktop click-cycle and
  cross-platform swarm cycle now include every `AgentProvider` case — Factory,
  Claude Code, Codex, OpenCode, Gemini CLI, Antigravity, OpenAI, DeepSeek,
  MiniMax, Z.ai, xAI, Cursor, Copilot, Kimi, Aider, Cline, Kilo Code, Roo Code,
  Forge, Augment, Hermes, Pi Agent, Goose, OpenClaw, Ollama, Windsurf, and
  Warp — with grouped formations sized for legible logo detail instead of one
  overcrowded tile.
- **Pristine logo sampling.** Swift and Android logo samplers now detect and
  remove solid asset backgrounds before generating dot targets, preventing
  white rounded-square PNG backgrounds from turning into giant dotted boxes
  around provider marks.
- **Provider glyph customization.** macOS desktop wallpaper settings and the
  iPhone/iPad wallpaper exporter now include a collapsible provider-glyph
  customizer, while Android live wallpaper settings expose the same provider
  filter. Selection changes feed the live swarm cycle so disabled providers no
  longer appear in click-cycle, default-cycle, or grouped logo formations.
- **Swarm wallpaper polish.** The BurnBar logo formation now uses the real
  bundled flame/bar-graph silhouette so the flame stays above the bars instead
  of wrapping under them, active wallpaper particles share the field across
  every running provider detected from the process table, and the Desktop
  Wallpaper Background picker uses distinct preview swatches instead of nearly
  identical dark dots. Provider colors remain exact outside the BurnBar flame,
  whose particles now use provider-family highlights and shadows so a single
  active provider still reads dimensional instead of flat.

### Added — Iroh Services observability
- **Official Iroh Services endpoint metrics.** Upgraded the native iroh bridge
  to the 1.0.0-rc.0 line and starts `iroh_services::Client` whenever
  `IROH_SERVICES_API_SECRET` is present, keeping the client alive for the
  endpoint lifetime so native iroh metrics flow to Iroh Services without a
  parallel Firestore rollup. Added `scripts/e2e/iroh-services-smoke.sh` for a
  live auth + ping + metrics push check.

### Added — Mercury Media user-facing surfaces (Phase 8)
- **Mercury Mirror streaming evidence gates.** Added cross-platform streaming
  capability snapshots, optional capability fields on mirror requests and
  presence heartbeats, MediaFrame v2 envelope codecs, HEVC/H.264-first codec
  policy with AV1 experiment gating, shadow BWE/datagram policy scaffolding,
  VideoToolbox LTR token hooks, receiver-to-encoder `media.ltr.ack` control
  frames for decoded v2 LTR tokens, and a 5x3 impairment dry-run harness. Live
  mirror remains `MediaFrame` v1-only until v2 sender/datagram/LTR recovery
  promotion and real benchmark data are green.
- **Mercury mirror session restart + control polish.** Ending a mirror from the
  iPhone close button now sends a real stop to the Mac, clears local iPhone
  mirror state, resets the Mac HUD timer, and allows the next mirror request
  without restarting either app. The iOS viewer also gains a draggable control
  panel, display selection, edge/button/volume scrolling options, and an
  auto-revealing glass trackpad mode.
- **Mercury mirror audit hardening.** Display switching now treats
  display-selection acknowledgements as in-session state updates instead of
  rejected mirror requests, failed Mac display switches preserve the current
  capture stream, point-click taps use a more forgiving intent resolver, point
  mode supports pan/zoom without losing click intent, landscape taps map through
  the actual letterboxed video rect, the iPhone typing bar has explicit keyboard
  dismissal, and the trackpad no longer draws a drift-prone predicted cursor
  over the Mac-rendered cursor.
- **Internal TestFlight App Check build path.** Build 25 was cut with the
  internal App Check debug-provider path enabled so enforced Firestore remains
  on while TestFlight devices avoid DeviceCheck/App Attest configuration drift.
- **Mercury mirror click and type control (iOS → Mac).** Full-screen iOS screen sharing now has explicit View/Control modes. Control mode maps taps through the current zoom/pan viewport into signed Phone Control click intents, adds a floating keyboard composer for Mac typing, and starts the existing Computer Use control stream when a mirror request is accepted.
- **Redesigned Liquid Glass `MercuryLiveSheet` (iOS).** Completely redesigned the My Mac live sheet on iOS adopting standard Liquid Glass tokens. Added an elevated, glassy header card with an animated pulsing indicator, high-performance button styling (`LiquidGlassButtonStyle`) with spring scaling, custom glass capsule overlays, silver-shimmer border gradients, and a dedicated preferences card.
- **Mac-to-iOS Wallpaper Sync (Zero-Latency).** Implemented a high-performance wallpaper sync system between the Mac client and the iOS app. Captures the Mac desktop wallpaper without screen recording TCC permissions by querying the active lockscreen caches under `/Library/Caches/Desktop Pictures/` and downscaling to a `120x80` thumbnail using `CGImageSourceCreateThumbnailAtIndex` to prevent OOM issues. Decodes the thumbnail on iOS in real-time, displaying it as a beautifully blurred (`.blur(radius: 30)`) background backdrop. Added a "Mimic Mac Wallpaper" toggle to toggle this sync dynamically.
- **Instant Heartbeat Sync.** Updated `MediaControlStreamCoordinator` to fire a presence heartbeat immediately upon establishing a stream, guaranteeing that capability and wallpaper synchronization happens instantaneously when opening the sheets.
- **iOS Hermes Square "My Mac" tile.** An auto-pinned tile in the Hermes Square
  pinned grid that opens a Mercury Live sheet with three actions: Ask to Mirror
  (sends `media.mirror.request` over the iroh control stream), Call Mac (existing
  VoIP path), and Send File (UIDocumentPicker → iroh-blobs transfer). The tile
  resolves from the paired Mac peer presence and carries the mercury-silver palette.
- **Mac menu-bar popover Mercury section.** A new `.mercury` tray section (between
  Providers and Chat) with a live `MercuryRing` indicator, paired-device label,
  monospaced phase string, and three outbound buttons: Call iPhone, Send File, and
  Settings. Gated on `runtimeContext.mercuryRouter != nil` for builds without the
  iroh xcframework.
- **Three new iroh control-stream frame types.** `media.mirror.request`,
  `media.mirror.ack`, and `media.presence.heartbeat` ride the existing
  `media.control` stream. No new ALPN. Codable with full forward-compat
  (optional fields omitted from the wire, unknown capability strings silently
  filtered).
- **`MercuryPeer` shared model.** Cross-platform `Codable Sendable` snapshot
  (connectionID, displayName, isOnline, lastSeenAt, capabilities). Mac and iOS
  each get a platform-specific `MercuryPeerSource` ObservableObject.
- **`MercuryRouter` (Mac).** Arbitrates inbound mirror requests — cooldown gating
  (30s default), consent fast-path ("Always allow my iPhone"), IncomingCallSheet
  presentation. Emits `media.mirror.ack` on every path. Wired through
  `OpenBurnBarRuntimeContext.startMercuryServices()` and
  `CloudSyncService.attachMercuryRouter(_:)`.
- **`MercuryGlobalChrome`.** App-scene-root overlay that presents
  `IncomingCallSheet` on `.ringing` (visible even when popover is closed) and
  `CallHUD` on `.streaming`.
- **Settings + consent.** Mac: "Always allow my iPhone to mirror this Mac"
  toggle in `MediaPermissionsView`. iOS: "Show My Mac on Hermes Square"
  toggle in `MediaSettingsView`.
- **Test coverage.** 19 SPM tests (8 protocol + 6 peer + 5 dispatch),
  5 MercuryRouter behavioral tests, 4 iOS registry URI tests — all green.

### Added — Computer Use (Phases 8–13, flagged off)
- **Phase 8 substrate.** `MediaStreamClass` gains `control.surface.frame`,
  `control.action.log`, `control.input`, `control.approval`; the four route
  to the new `MediaStreamClass.Feature.computerUse` quota bucket.
- **Cursor extension to `MediaPacketCodec`.** `MediaFrame.Flags.hasCursorMetadata`
  (bit `0x08` — `0x04` was already taken by `.muted`) prefixes 4 trailing
  bytes (`i16 cursorX`, `i16 cursorY`, big-endian) after the existing
  18-byte header. Decoder ignores the bytes when the flag is absent so
  the codec stays byte-identical for pre-Computer-Use senders.
- **Wire frames.** Six new `HermesRealtimeRelayFrameType` cases
  (`control.classify`, `control.action.log.entry`, `control.input.intent`,
  `control.approval.{request,response}`, `control.denied`) carried by a
  new `HermesRealtimeRelayControlPayload` sibling-of-`media` payload.
- **OpenBurnBarComputerUseCore.** New cross-platform SwiftPM target with
  session metadata, scope rules + matcher, built-in deny registry, audit
  chain + logger + hasher (SHA-256, BLAKE3-swappable), action descriptors,
  capability gate + budget envelope, and the pure Ed25519 signer/verifier
  used by the Mac validator and iOS issuer. 50-test suite green.
- **BurnBarToolKind extensions.** 13 new tool kinds (7 browser + 5 mac
  input + 1 mac inspect) plus `BurnBarBrowserActionArguments`. Available
  via `BurnBarToolKind.computerUseToolKinds` for daemon dispatch routing.
- **Daemon.** `OpenBurnBarPlaywrightDriver` (long-lived Node subprocess
  speaking newline-delimited JSON-RPC), `OpenBurnBarPlaywrightLifecycle`
  (auto-install pinned at `playwright@1.49.1`), `ComputerUseRunCoordinator`
  (capability gate + scope + approval flow + per-action audit append).
  Node.js bridge script lives at
  `OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js`.
- **Mac.** `MacInputController` (CGEvent + display-bounds gating),
  `MacAccessibilityInspector` (AX role probe + deny-region matcher),
  `ComputerUsePanicHaltCoordinator` (global hotkey `⌃⌥⌘.`, NSWorkspace
  auth-gate listeners, Remote Config kill-switch, Accessibility
  revocation), `PhoneControlAuthorityValidator`.
- **iOS.** `AgentWatchState` observable model, `PhoneControlAuthorityIssuer`
  Ed25519 envelope builder.
- **Cloud Functions.** `evaluateComputerUseBudget` (hourly), `recomputeComputerUseQuotaUsage`
  (hourly), `rollupComputerUseDaily`. New types `ComputerUseSessionDoc`,
  `ComputerUseActionDoc`, `ComputerUseQuotaUsageDoc`,
  `ComputerUseSessionDailyRollupDoc`, `ComputerUseBudgetStatusDoc`,
  `ComputerUseEntitlementDoc`.
- **Firestore rules.** New `hasActiveHostedComputerUseEntitlement(userId)`
  helper and gated rule blocks for `computer_use_sessions`,
  `computer_use_actions`, `computer_use_quota_usage`. Operator-side
  `ops/computer_use_budget_status` + `ops/computer_use_session_daily_rollups`
  are read-only for authenticated users; server-only writes.
- **Docs.** `docs/HERMES_COMPUTER_USE.md` (engineer/operator reference),
  `docs/runbooks/computer-use-rollout-status.md` (phase ship log),
  `docs/runbooks/computer-use-budget.md`, `docs/runbooks/computer-use-quota.md`,
  `docs/runbooks/computer-use-app-store.md`,
  `docs/runbooks/computer-use-audit-disputes.md`.
- **Scripts.** `scripts/install-playwright.sh` reproducible recipe
  (matching `OpenBurnBarPlaywrightLifecycle.pinnedPlaywrightVersion`).

### Fixed
- **Nest Hub Claude quota refreshes within a debounce window instead of
  every 2 minutes.** The Smart Hub bridge was double-gating the auto-refresh
  loop: an outer 60 s gate in `SmartHubBridgeController` plus the inner 60 s
  gate in `ProviderQuotaService.refreshIfNeeded`. Tracing the interaction,
  the second tick always landed inside the inner window and skipped — so
  the effective cadence was ~120 s, not the advertised 60 s. The same
  heartbeat also serialized the 5 s pump behind whatever-multi-second
  `refreshAll` happened to be in flight, which froze the dashboard mid-refresh.
  Now: the pump runs in its own task (so the Hub stays live during a refresh),
  the auto-refresh runs in a second task that delegates to
  `refreshIfNeeded` as the single source of truth for staleness, and a new
  `ClaudeStatuslineWatcher` FS-event watcher fires
  `ProviderQuotaService.refreshClaudeFromStatuslineHook` the moment Claude's
  CLI rewrites the statusline snapshot. The hook path deliberately does
  not bump `lastFetch`, so a chatty Claude session can no longer gate the
  next all-provider tick and starve Codex/Cursor/etc. The watcher uses
  exponential backoff (250 ms → 30 s) when the file is absent, so machines
  without Claude installed don't burn syscalls on a 4 Hz reopen loop. It
  also defends against future bridge variants that use atomic
  `mv tmp → snapshot` writes by re-arming the FD on `.rename`/`.delete`
  events; the current `cp`-based wrapper writes in place, but the
  defensive path costs nothing and absorbs the change automatically.
- **Factory Droid Max can route as a strict same-model failover provider.**
  Factory is now in the daemon provider catalog with Standard and Droid Core
  lanes separated. Gateway requests for Factory Standard models run through a
  supervised read-only `droid exec` executor, reject silent Droid Core fallback,
  and fail over to another exact same-model route when Standard Usage is
  exhausted.
- **Exact Model Failover replaces the visible Smart routing mode.** The new
  `same_model_failover` mode may switch provider/account only after the
  destination route proves the same canonical model ID. Legacy
  `intelligent_model_router` configs decode safely into the exact-model mode,
  while the default remains provider-family failover for existing installs.
  Gateway retries now fail closed instead of treating broad capability classes
  such as `openai:standard` as proof that two routes serve the same model.
- **OpenCode credential entry accepts real route-key formats.** The Accounts
  wizard no longer treats OpenCode auth JSON as a generic JWT session token;
  it accepts the `opencode-go` object, the full `auth.json`, or the bare route
  key, and the live quota hint now points users to local CLI stats instead of
  the hosted per-plan quota path.
- **Catalog provider accounts use their real logos and account rows.** DeepSeek,
  Alibaba/Qwen, Meta, Mistral, xAI/Grok, and Cohere no longer borrow unrelated
  agent logos, and daemon keychain slots now appear immediately in the Accounts
  list even before a cloud `provider_accounts` row exists.
- **Droid model sync is now a first-class proxy-catalog action.** The
  Settings → Agents → CLIs and Models proxy catalog panels expose **Sync to
  Droid**, which rewrites Factory/Droid custom models from the live
  route-ready `/v1/models` list and preserves cloud-suffixed model IDs such as
  `kimi-k2.6:cloud`.
- **Proxy model advertising can be controlled per model.** The Settings →
  Agents → Models and CLIs catalog rows now expose a per-model advertise
  toggle; disabled models stay visible in Settings but disappear from the
  public `/v1/models` route list and from Droid sync until re-enabled.
- **Hermes Square now opens from the iPad sidebar.** The iPad Hermes
  destination uses the shared `HermesSquareSplitLayout` with the live mobile
  mission host instead of falling back to the legacy conversation list, so
  iPad gets the same Square inbox, pinned grid, approvals, missions, search,
  and detail layout as the compact mobile surface.
- **macOS Google SSO keychain recovery.** Firebase Auth access-group binding
  now retries after clearing stale default Firebase Auth keychain rows, including
  the current `firebase_auth_1_<app>_firebase_user` row used by Firebase 11.x.
  This prevents Google sign-in from completing the browser handoff but leaving
  Settings stuck on "Anonymous Account" with the generic Firebase keychain error.
- **Android Hermes relay wire-protocol parity with iOS / macOS.** The first
  pass shipped Android crypto that derived per-request keys directly from a
  static ECDH shared secret and put that raw secret in the `wrappedKey`
  field. That diverges from the Mac/iOS contract on every wire-visible
  surface — AAD strings, per-request symmetric key + ECIES key wrap, JSON
  field names, chunk kinds — so Mac ⇄ Android decryption silently failed.
  `HermesRelayCrypto.kt`, `HermesIrohRelayTransport.kt`, and
  `HermesRelayClient.kt` now port iOS' `wrapSymmetricKey`/
  `unwrapSymmetricKey` (X9.63 ephemeral pub || sealed key, HKDF-derived
  wrapping key under `OpenBurnBar-HermesRelay-KeyWrap-v1|<keyAAD>`),
  canonical `requestAAD` / `keyAAD` / `chunkAAD` shapes, camel-cased
  Firestore envelope (`connectionId`, `payloadCiphertext`, `wrappedKey`,
  `relayEncryption`, `relayKeyVersion`, `expireAt`, `schemaVersion`), and
  the `sse | data | error` chunk-kind enum. A deterministic Swift fixture
  (`OpenBurnBarCore/Tests/.../Fixtures/HermesRelayWireVector.json`) is
  pinned into the Android test resources and replayed by the new
  `HermesRelayWireVectorTest` so a future drift fails CI on both
  platforms.

### Changed
- **Mobile-selected agent models now bind across Hermes, Pi, OpenClaw, Codex,
  and Claude missions.** `cli_agent_mission_requests` carries the selected
  `requestedModelID`, the trusted Mac records `selectedModelID`, Pi/OpenClaw
  launch with explicit `--model` arguments, Codex/Claude/Hermes set the chat
  session model before send, and shell-backed direct missions now use
  non-interactive login shells so GUI-launched Pi jobs do not stop before
  spawning.
- **Android reaches full Hermes Square + iroh transport + Mercury Media
  parity with iOS.** Android now ships the entire Hermes surface that
  iOS does — Hermes Square (approval inbox, fan-out group cards, pinned
  grid, Project Memory wiki, active missions, rollback, conversations,
  subscriptions, 5-tab Discover, voice intent banner, brand zones with
  parallax + dispatch / forward / subscribe, tablet split layout,
  upgraded voice sheet with sine breath-pulse), Hermes messaging (atom /
  mention / code rich bubbles, the 7-case `HermesChatMessageOutcome`
  chrome, mercury-stroked tool cards with capability grouping, mercury
  thinking dots + caret, streaming-tick mirror for live Hermes
  responses, the 5-tool catalog with in-app `HermesAtomNavigator`
  routing, the empty-response fallback path), iroh transport
  (`:openburnbar-iroh-relay` Kotlin library mirroring `OpenBurnBarIrohRelay`
  1:1 — protocol, frame codec, Ed25519 pairing verifier via Tink,
  loopback transport, JNI/UniFFI backend reflection bridge, `IrohJniTransport`,
  `HermesIrohRelayTransport`, `HermesCompositeRelayTransport` cascade
  with kill-switch and Firestore fallback), and Mercury Media (file
  transfer over iroh-blobs through `AndroidFileTransferService`,
  `MediaControlStreamCoordinator` with exponential-backoff supervisor,
  `AttachmentSaver` routing through MediaStore + SAF with per-partner
  save preferences, HEVC screen-share viewer with PiP, CameraX +
  `MediaCodec` 1:1 video pipeline, libopus audio pipeline over the new
  `openburnbar/mercury/audio/1` QUIC datagram ALPN, `CallSessionCoordinator`,
  `MediaSessionForegroundService` with `microphone|camera|mediaProjection|phoneCall`
  granular foreground service types, `IncomingCallActivity` +
  `MercuryFcmService` driving a CallStyle full-screen incoming sheet
  with `MANAGE_OWN_CALLS` ConnectionService surface, `AndroidMediaCapabilityGate`
  read-only mirror of Mac authority, and `MediaAnalyticsLogger` routing
  to the existing `iroh_audit_events` rollup). Rust crate gains a new
  `datagrams.rs` UniFFI surface (`IrohDatagramChannel`, `mercury_audio_alpn`,
  `MERCURY_AUDIO_ALPN`); `scripts/build-iroh-android-aar.sh` builds
  `Vendor/openburnbar-iroh.aar` (arm64-v8a, x86_64, armeabi-v7a, x86)
  with auto-installed NDK + cargo-ndk + UniFFI Kotlin bindgen, and
  `scripts/build_opus_android.sh` builds `Vendor/opus-android.aar` from
  libopus 1.5 for the four ABIs. CI workflows
  `.github/workflows/build-iroh-android-aar.yml` (and the existing
  iroh-xcframework workflow) ensure the binaries are reproducible.
  Cloud Functions gains an FCM Android branch in `functions/src/fcmAndroidSender.ts`
  with high-priority data-message routing and a `voipPush.ts`
  `resolveFanOut` helper that picks the freshest channel per device.
  Tests: 253 JVM unit tests green (`:app:testDebugUnitTest`),
  full Compose instrumented suite compiles green, the iroh-relay
  library's own suite is 14/14 green. Docs:
  `docs/runbooks/android-iroh-transport.md`,
  `docs/runbooks/android-mercury-media.md`,
  `docs/runbooks/iroh-rollout-status.md`,
  `docs/runbooks/media-rollout-status.md`,
  `docs/runbooks/wss-retirement-checklist.md` all updated. Three new
  DESIGN.md decision-log entries (Android Mercury incoming-call sheet,
  per-partner save preferences over MediaStore + SAF, Android iroh
  transport over UniFFI/JNI AAR).
- **Codex CLI is wired as a first-class MCP client.**
  `openburnbar mcp install codex` now emits a complete
  `~/.codex/config.toml` block with three options — stdio shim over the
  hosted MCP (recommended; preserves local sealed-content decrypt and
  pins MCP-Protocol-Version 2025-11-25), native streamable HTTP for
  users whose Codex build negotiates that version, and the local Python
  stdio MCP. Quick-add via `codex mcp add openburnbar -- openburnbar-mcp-remote mcp serve`
  still works. New onboarding doc at
  [`docs/CODEX_AGENT_ONBOARDING.md`](docs/CODEX_AGENT_ONBOARDING.md);
  Codex section added to
  [`tools/openburnbar-mcp/README.md`](tools/openburnbar-mcp/README.md).
  Installer covered by `installers.test.ts` (4 cases).
- **Project Memory detail sheets adopt the Editorial Observatory voice
  used by the iOS Intelligence Brief.** The hero card, page rows, visual
  tiles, and citation chips on the macOS Projects hub now open into four
  full editorial sheets (`ProjectMemoryHeroDetailSheet`,
  `ProjectMemoryPageDetailSheet`, `ProjectMemoryVisualDetailSheet`,
  `CitationInsightSheet`) with eyebrow + subtitle + 22pt headline + mono
  meta strip + mercury hairline hero, numbered 01/02/03 section rows
  with severity-bar leading edge and footnote-chip citations, a live
  Hermes "Reading" card streaming the model's response in real time
  via a new `streamingTick` on `ChatSessionController`, Swift Charts
  visuals with annotations, evidence callouts that explain empty
  sentinels instead of rendering empty bodies, cascade-in motion (with
  `accessibilityReduceMotion` opt-out), and "Continue in chat" footers
  that pipe directly into the existing chat panel. Citation chips and
  the hero card are now fully tappable surfaces. Covered by
  `ProjectMemoryDetailSheetTests` (10 cases).

### Added
- **Mercury media (all 7 phases — source-complete, off by default).**
  Mac ⇄ iPhone/iPad file transfer, screen share, and 1:1 video calling
  layered on the existing iroh QUIC mesh as new in-band stream classes.
  Plan of record: `plans/2026-05-15-mercury-media-master-plan.md`.
  Per-phase rollout log: `docs/runbooks/media-rollout-status.md`. Real
  phase activation requires per-phase TestFlight + App Store review +
  device-matrix soak.
    * **Phase 1a (substrate):** `OpenBurnBarMedia` SwiftPM target with
      stream classes, packet codec, frame envelope, bitrate controller,
      capability gate, budget envelope, telemetry buckets;
      `HermesRealtimeRelayFrame` extended with `media.classify`,
      `media.blob.advertise`, `media.blob.ack`; stream-class dispatch
      across Mac iroh + iOS iroh + WSS legacy paths; `iroh-blobs = "0.92"`
      pulled into Cargo.toml; `crates/openburnbar-iroh/src/blobs.rs`
      module; 5 cargo tests + 28 OpenBurnBarMedia XCTests.
    * **Phase 1b (file transfer end-to-end):** `IrohBlobNode` UniFFI
      object owning its own iroh `Endpoint` + `FsStore` + `Router`
      pinned to `iroh_blobs::ALPN`; `IrohBlobBackend` Swift protocol +
      xcframework-gated bridge; `MediaFileTransferService` actor;
      `IrohBlobKeyStore` (Mac + iOS) with separate Keychain entry;
      `MacFileTransferService` + `iOSFileTransferService` adapters with
      chat-stream advertise/ack flow; `MediaFrameDispatcher` /
      `IrohMediaFrameDispatcher` typealiases on Mac + iOS dispatch
      sites; xcframework reshipped via `scripts/build-iroh-xcframework.sh`;
      7 new MediaFileTransferServiceTests.
    * **Phase 2 (file UI + SKU + Cloud Functions):** iOS
      `MediaPartnerSavePreferenceStore` + `AttachmentSaver` (Decision 3);
      iOS `PerPartnerSavePreferencesView`; Mac `AttachmentChipRow` +
      `PaperclipButton`; iOS `AttachmentBubble` + `PaperclipButton`;
      Mac `MacMediaCapabilityGate` (Decision 2 — Mac is source of
      truth); Cloud Functions `mediaQuota.recomputeMediaQuotaUsage`
      (hourly), `mediaSku.grantMediaGrandfather`,
      `mediaSku.validateMediaPurchase`, `mediaMonitoring.rollupMediaSessionDaily`;
      `firestore.rules` `hasActiveHostedMediaEntitlement` helper +
      gates for `media_quota_usage`, `media_session_events`,
      `media_attachment_manifests`, `ops/media_budget_status`,
      `ops/media_session_daily_rollups`; 6 new
      `MediaPartnerSavePreferenceStoreTests`.
    * **Phase 3 (Mac → iOS screen share):** Mac `ScreenCapturePipeline`
      (ScreenCaptureKit), `VideoEncoder` (VTCompressionSession HEVC +
      H.264 fallback), `MediaSessionCoordinator` orchestrator; iOS
      `VideoReceivePipeline` (VTDecompressionSession +
      AVSampleBufferDisplayLayer) + `ScreenShareViewerView` (full-bleed
      + three-finger-tap stats overlay); Mac UI `StartMirrorButton` +
      `MercuryRing` + `MediaPermissionsView`.
    * **Phase 4 (Mac ⇄ iOS audio):** Mac `MicrophoneCapturePipeline`
      (AVAudioEngine + Voice-Processing IO) + `AudioEncoder` (Apple's
      built-in `kAudioFormatOpus` instead of vendoring libopus — same
      wire profile, no third-party binary); iOS
      `MicrophoneCaptureService` + `AudioReceivePipeline` (60 ms jitter
      buffer + AirPods route-change handler); mute via
      `MediaFrame.Flags.muted` in-band.
    * **Phase 5 (video + CallKit + budget):** Mac `CameraCapturePipeline`
      + `VoIPCallTrigger` (Firebase Functions callable wrapper); iOS
      `CameraCaptureService`, `VoIPCallService` (PKPushRegistry +
      CXProvider + CXCallController), `MercuryCallTransitionController`
      (Decision 1 — app-active → Mercury sheet, app-background → direct
      CallHUD); Mac `IncomingCallSheet` + `CallHUD`; iOS
      `MercuryIncomingSheet` + `CallHUDView` + `SelfPiPView` (88×128
      drag-to-corner); Cloud Functions `voipPush.triggerVoIPCall`
      (verifies Mac entitlement per Decision 2, writes
      `voip_outbound`); `mediaBudget.evaluateMediaBudget` (hourly,
      $600 soft / $1000 hard cap per Decision 4, writes
      `ops/media_budget_status/current`).
    * **Phase 6 (iPad multicam + PiP):** iOS
      `iPadMultiCamCaptureService` (AVCaptureMultiCamSession with
      single-cam fallback), `ScreenSharePiPController`
      (AVPictureInPictureController), iOS `MediaSettingsView` with
      back-camera toggle + stats overlay toggle.
    * **Phase 7 (macOS PiP + WSS retirement):** Mac
      `ScreenShareViewerWindow` — `NSPanel` `.floating` +
      `.canJoinAllSpaces + .fullScreenAuxiliary` for cross-Spaces /
      fullscreen-app overlay with mercury hairline border;
      `docs/runbooks/wss-retirement-checklist.md` — 14-day gate
      criteria + 10-step decommission sequence + 7-day rollback window.
  Verification: `swift test` 687 tests, 0 failures, 2 skipped (was 641
  before the rollout — 46 new tests across all phases). `cargo test`
  5 tests, 0 failures. `npx tsc --noEmit` in `functions/` clean.
  Documentation refreshed: `docs/HERMES_MEDIA_TRANSPORT.md`,
  `docs/runbooks/media-rollout-status.md`,
  `docs/runbooks/media-quota.md`, `docs/runbooks/media-budget.md`,
  `docs/runbooks/media-device-matrix/README.md`,
  `docs/runbooks/wss-retirement-checklist.md`.
- **Mercury media (Phase 1a — substrate, off by default).** Lays the
  forward-compatible foundation for Mac ⇄ iPhone/iPad file transfer,
  screen share, and 1:1 video calling — all layered on the existing iroh
  QUIC mesh as new in-band stream classes (no ALPN bump). Plan of record:
  `plans/2026-05-15-mercury-media-master-plan.md`. This entry covers the
  substrate that ships in Phase 1a; the multi-ALPN endpoint router,
  `publish_blob`/`fetch_blob` UniFFI methods, xcframework reship, and
  Mac/iOS attachment UI land in Phase 1b. Touches:
    * **New SwiftPM target** `OpenBurnBarMedia` in `OpenBurnBarCore/Package.swift`
      — pure-Swift substrate (`MediaStreamClass`, `MediaPacketCodec`,
      `MediaFrame`, `BitrateController`, `MediaSessionMetadata`,
      `MediaCapabilityGate` protocol, `MediaBudgetEnvelope`).
    * **Frame protocol extension** in `OpenBurnBarCore` —
      `HermesRealtimeRelayFrameType` adds `media.classify`,
      `media.blob.advertise`, `media.blob.ack` cases. New optional
      `media: HermesRealtimeRelayMediaPayload?` field on
      `HermesRealtimeRelayFrame`. Wire is byte-identical to pre-rollout
      for chat-only frames; older decoders skip unknown frame types.
    * **Stream-class dispatch** wired on Mac
      (`AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift`),
      iOS (`OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift`),
      and the WSS legacy paths (`HermesRealtimeRelayHostClient.swift`,
      `HermesService.swift`) so every existing exhaustive switch handles
      the new cases without a build break.
    * **Rust crate** `crates/openburnbar-iroh/` — adds `iroh-blobs = "0.92"`
      (the line that targets `iroh ^0.91`), creates `src/blobs.rs`
      exposing `parse_blob_ticket`, `iroh_blobs_alpn`,
      `iroh_blobs_crate_version`, `BlobTicketBytes`, `BlobTransferStats`
      via UniFFI. 5 cargo unit tests cover ticket round-trip, garbage
      rejection, whitespace trimming, ALPN identity, version exposure.
    * **Cloud Functions schema** `functions/src/types.ts` —
      `MediaSessionEventDoc`, `MediaQuotaUsageDoc`,
      `MediaAttachmentManifestDoc`, `MediaSessionDailyRollupDoc`,
      `MediaBudgetStatusDoc`. Compile-only in Phase 1, no server writes
      yet.
    * **Documentation**: new `docs/HERMES_MEDIA_TRANSPORT.md` (architecture
      spec), `docs/runbooks/media-rollout-status.md` (phase log),
      `docs/runbooks/media-quota.md` (operator quota runbook),
      `docs/runbooks/media-budget.md` (n0 hosted-relay $600 soft / $1000
      hard cap operations), `docs/runbooks/media-device-matrix/README.md`.
      `docs/HERMES_IROH_TRANSPORT.md` extended with a "Media stream
      classes" section.
  28 new XCTests + 5 new cargo tests; existing 641 OpenBurnBarCore +
  IrohRelay tests still pass with 0 regressions. See
  `docs/runbooks/media-rollout-status.md` for the Phase 1b queue.
- **Hermes iroh production monitoring rollups.** Added the scheduled
  `rollupIrohTransportDaily` Function to summarize daily
  `iroh_audit_events` into operator telemetry for rollout gates, with focused
  Functions test coverage and a secrets/rotation runbook.
- **Hermes Realtime Relay → iroh peer-to-peer transport (all 7 phases).**
  Migrates the Hermes relay off Cloud Run + Memorystore + WSS onto an
  [iroh](https://www.iroh.computer/) QUIC mesh between the Mac and
  iOS/iPadOS clients. Same `HermesRelayCrypto` envelope, same
  `HermesRealtimeRelayFrame` wire JSON, holepunched QUIC peer-to-peer with
  iroh relay fallback. Touches:
    * **Rust crate** `crates/openburnbar-iroh/` — UniFFI surface around
      `iroh-net` (bootstrap/identity/connect/accept/send/recv/shutdown/close),
      now accepts a `relay_url` to pin a hosted relay (Phase 6).
    * **xcframework build** — `scripts/build-iroh-xcframework.sh` builds for
      macOS arm64 + iOS arm64 + iOS Simulator (arm64/x86_64);
      `.github/workflows/iroh-xcframework.yml` publishes the artifact.
    * **SwiftPM target** `OpenBurnBarIrohRelay` — frame codec, transport
      protocol, in-process loopback transport, xcframework-backed transport
      (`IrohXcframeworkTransport`), Ed25519 pairing primitives
      (`IrohPairingSignature` + `IrohPairingPublisher` +
      `IrohPairingDirectory`), and the encrypted echo path
      (`HermesIrohEcho`).
    * **Mac adapter** `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient`
      — drop-in for `HermesRealtimeRelayHostClient` over the iroh transport
      with Keychain-backed `IrohRelayKeyStore` + `IrohPairingKeyStore` and
      a pairing-record heartbeat.
    * **iOS adapter** `OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport`
      — conforms to `HermesRelayTransporting`, fetches + verifies the Mac's
      signed pairing record, dials the iroh `NodeId`, falls back to WSS on
      any iroh failure.
    * **Composite chain** `HermesCompositeRelayTransport` becomes
      iroh → WSS → Firestore, with cascade reasons surfaced through the
      audit log.
    * **Schema** `functions/src/types.ts` — `IrohPairingRecordDoc`,
      `IrohTransportAuditEventDoc`, freshness constants, canonical AAD
      string.
    * **Rules** `firestore.rules` — gates `/users/{uid}/iroh_pairing/*`
      (owner write, ≤24h freshness window) and
      `/users/{uid}/iroh_audit_events/*` (append-only).
    * **Feature flag** `SettingsManager.hermesIrohTransportEnabled` — sticky
      per-device, default off, can be flipped per cohort via Remote Config.
    * **Hosted relay cutover** `scripts/cutover-n0-hosted-relay.sh` —
      provisions the n0 hosted relay through the services API and rolls
      out the relay URL via Firebase Remote Config.
    * **Retirement runbook** `docs/HERMES_IROH_RETIREMENT.md` — Phase 7
      gates, decommissioning steps, rollback playbook, and cost analysis.
  27 unit tests cover the wire format, pairing signatures, transport
  primitives, the xcframework adapter (against a fake backend), the
  Firestore-backed publisher (against an in-memory directory), and the
  encrypted echo round trip; all green on macOS arm64. See
  [`docs/HERMES_IROH_TRANSPORT.md`](docs/HERMES_IROH_TRANSPORT.md) and
  [`docs/HERMES_IROH_RETIREMENT.md`](docs/HERMES_IROH_RETIREMENT.md).
- **Hermes Square now searches across all assistant runtimes and archived CLI
  sessions.** Codex, Claude Code, and OpenClaw are enabled as first-class mobile
  runtimes alongside Hermes and Pi. macOS publishes encrypted Codex/Claude/OpenClaw
  session-log archives into the shared `cli_sessions` surface with resume
  handles, while keeping full transcript bodies in the encrypted hosted
  session-log store. The Hermes Square search bar now merges local Square hits,
  live chats, missions, and encrypted hosted session-log results, with a
  decrypting detail view for cloud archive matches.
- **Mobile Codex, Claude Code, and OpenClaw chat/import parity.** The mobile `+`
  flow now opens a blank Mac-backed chat composer instead of a setup blocker,
  Android has the same remote composer and import progress surface as iOS, and
  trusted macOS devices claim `agent_import_jobs` transactionally before
  scanning local harness histories.
- **Real-time quota refresh for Codex, Claude Code, Kimi, MiniMax, and Z.ai on iOS/iPadOS.**
  Pro users can now get accurate and fresh quota numbers for all five providers
  from any signed-in device at any time.
  - **Kimi (Moonshot AI):** Full Cloud Functions adapter with multi-host fallback
    (`api.kimi.ai` → `api.moonshot.cn`), credential validation via `/v1/models`,
    balance endpoint probing, and automatic scheduled quota refresh. Kimi API
    keys are connectable from iOS through the provider wizard (cloud refresh,
    not hosted runner — API keys don't need a CLI).
  - **Claude Code:** Hosted quota runner support. Claude Code accounts can now be
    connected via hosted sync (credentials stored encrypted server-side) in
    addition to the existing self-hosted runner path. The hosted runner writes the
    auth bundle to a temp `CLAUDE_CONFIG_DIR` and runs `claude /usage` on behalf
    of the user.
  - **On-demand refresh:** Added a refresh button (⟳) to the quota detail sheet
    with haptic feedback, allowing pro users to force-refresh any provider's
    quota at any time without waiting for the 15-minute scheduled cycle.
  - **Provider setup guides updated:** Claude Code guide now shows hosted sync
    option; Kimi guide updated with cloud refresh and multi-host details.
  - **Hosted credential kind:** `connectHostedQuotaAccount` now uses
    provider-appropriate credential kinds (`session` for Codex/Claude,
    `bearer` for API-key-based providers) instead of hardcoding `"session"`.

- **Hosted Remote MCP service scaffold for BurnBar Pro.** Added a dedicated
  `services/hosted-mcp` Cloud Run service implementing MCP Streamable HTTP
  health/readiness, OAuth metadata, bearer-token validation, origin/protocol
  checks, deny-by-default tool registry, entitlement/rate-limit/audit seams,
  encrypted search/resource tools, and bounded JSON-RPC errors. Added
  `tools/openburnbar-mcp-remote` as the local stdio shim with deterministic
  client installers, doctor checks, token storage via Keychain/fallback file,
  and local sealed-result decrypt support. Functions now include remote MCP
  grant/client helpers and callable grant/revoke entrypoints; Firestore rules
  deny direct client writes to remote MCP grant, audit, rate-limit, and manifest
  docs. The iOS/iPadOS Cloud membership screen now lists connected hosted MCP
  clients with scopes, decrypt mode, last-used status, and a revoke action wired
  to the server callable. Direct MCP resource routes now enforce the same
  scope, active-client, entitlement, and rate-limit gates as tool calls. Docs
  and deploy/security/compatibility proof scripts cover the launch path; live
  production proof still requires the branded domain and final client matrix.
- **BurnBar Pro adds encrypted hosted session search.** Premium services now
  supplement Hosted Quota instead of replacing it: active `burnbar_pro`
  entitlements unlock hosted MiniMax-backed LLM answers, Hosted Quota, and
  encrypted searchable hosted session logs. macOS seals session-log titles,
  previews, chunks, and full bodies on device, uploads only ciphertext to
  Firebase Storage, and uploads HMAC token hashes, keyed semantic hashes,
  semantic posting edges, and sealed snippets to Firestore. iOS/iPadOS and
  Android register device public keys, unwrap the cloud vault key, search by
  locally derived opaque token/semantic hashes, and decrypt results locally.
  Hosted index uploads now go through server-only callable validation and are
  commit-generation stamped so search ignores partial or stale multi-batch
  commits.
  `tools/openburnbar-mcp` now exposes both local deterministic semantic search
  and an opt-in hosted encrypted semantic MCP path for trusted external agents.
  Firestore rules now gate `cloud_search_*` and `cloud_vault_key_wrappers`
  behind active premium entitlement, block mobile/Mac self-trusted device
  creates, require trusted source/target devices for vault wrappers, and reject
  plaintext `title`, `snippet`, `body`, and `text` fields. Verified by
  `npm --prefix functions run build`, `npm --prefix functions run
  test:firestore-rules`, focused cloud crypto tests, MCP pytest, macOS/iOS
  simulator `xcodebuild`, and Android `./gradlew assembleDebug`.
- **Hosted Intelligence Brief gated behind BurnBar Pro.** The
  OpenRouter → MiniMax 2.7 fallback now requires an active BurnBar
  Pro subscription (`com.openburnbar.pro.monthly`, while the legacy
  Hosted Quota Sync entitlement remains accepted for compatibility). The
  `insightsHostedAnswer` callable requires Firebase Auth + a live
  entitlement doc and returns `permission-denied` with
  `{ code: "subscription-required", productID }` for free-tier
  callers. Swift and Kotlin adapters detect the marker and surface a
  dedicated brief state: `briefingAnswer.modelDisplayName ==
  "BurnBar Pro required"`, with body text that discloses the
  upgrade path. `IntelligenceBriefView` (Swift) and
  `IntelligenceBriefScreen` (Kotlin) swap the generic "Connect your
  own model" CTA for "Upgrade to BurnBar Pro" via a new
  `onUpgradeToPro` callback the shell wires to the StoreKit / Play
  Billing flow. Connected users with their own LLM keep using it
  for free — only the hosted fallback is paywalled. Verified by
  `testHostedRouteSubscriptionRequiredLandsOnProUpgradeDisclosure`.
- **Intelligence Brief now always answers with a real LLM.** The
  Q&A path was silently degrading to deterministic rule-based text
  whenever the user's selected gateway failed or wasn't registered.
  Routing now follows an explicit four-outcome contract: (1) the
  user-owned route answers (Hermes / Pi / OpenClaw / Claude / Codex
  / OpenCode / OpenAI-compatible / Ollama), (2) the BurnBar-hosted
  fallback answers (OpenRouter → MiniMax 2.7) and is disclosed via
  the briefing eyebrow + "connect your own model" CTA, (3) privacy
  mode short-circuits past every non-local tier and lands on local
  rules without trying the hosted route, or (4) both LLM tiers
  failed → local rules answers with `isFallback = true` and a
  "→ Local rules" display-name suffix so the UI surfaces a Retry
  hint. Adds `InsightBriefingAnswer.Source.hostedFallback` (Swift)
  and `InsightBriefingAnswer.Source.HOSTED_FALLBACK` (Kotlin); the
  brief's eyebrow and CTA logic update across macOS, iOS/iPadOS, and
  Android. Backed by the new `insightsHostedAnswer` Firebase
  callable, which holds the OpenRouter API key server-side (App
  Check enforced, anonymous-tolerant). Configurable via
  `OPENROUTER_API_KEY` secret and
  `INSIGHTS_HOSTED_FALLBACK_MODEL` / `INSIGHTS_HOSTED_FALLBACK_URL`
  env vars. Verified by five regression tests in
  `HostedFallbackTests.swift`.

### Fixed
- **Hermes iroh Phase A build path is reproducible across local and CI builds.**
  The xcframework script now uses the rustup toolchain explicitly, generates a
  pinned UniFFI Swift helper instead of installing a non-existent global crate,
  and normalizes the generated modulemap for static-library xcframework slices.
  `OpenBurnBarCore` conditionally wires the UniFFI binary target only when
  `Vendor/OpenBurnBarIroh.xcframework` exists, so fresh checkouts still compile
  the relay package while release/local artifact builds use the real iroh FFI.
  macOS, iOS device, iOS Simulator, SwiftPM, and Functions gates are green
  locally; the final Phase A gate is the GitHub xcframework workflow after push.
- **Pulse 1M / 1H / 1D hero stopped showing $0.00 on iOS, iPad, and Android.**
  `FirestoreRepository.fetchUsageSince` and `listenToUsageSince` (Swift + Kotlin)
  filtered `startTime` against an ISO-8601 *string* cutoff, but every writer
  (`UsageSyncService.swift`, `CloudSyncService.swift`) stores `startTime` as a
  Firestore `Timestamp`. Firestore's type-order rules placed every Timestamp
  before every string, so the live `usage` query matched zero rows and the
  Pulse hero — which derives 1M/1H/1D from `liveUsages` — rendered as
  "Awaiting today's first burn" even when the daily rollup had real cost.
  Both platforms now pass `Timestamp(date:)` / `Timestamp(Date(...))` so the
  comparison stays in the same Firestore type lattice.
- **Pulse live-window totals are now raw-event accurate.** The iOS and Android
  Pulse hero now computes `1M`, `1H`, and `1D` from the live
  `usage` stream instead of reusing coarse rollup documents. `1D` is pinned to
  the viewer's local calendar day, `1M` / `1H` decay every second as events age
  out, and `7D` / `30D` stay rollup-backed for stable long-window totals.
- **Editorial Observatory generated widgets now paint real charts.** The
  rule-based `InsightAnalysisEngine` previously set `data = nil` for
  `barRanking`, `timeSeriesLine`, and `quotaPulse` widgets, so the
  Intelligence Brief rendered chrome with empty bodies until a canvas
  refresh re-evaluated each binding through the `InsightExecutor`. The
  engine now synthesizes those payloads directly from the privacy-bounded
  digest (`synthesizeData(for:binding:digest:)`) so the brief paints
  provider-mix bar rankings, peak-annotated cost lines, and quota pulses
  on first render. Cache schema bumped to `v2-engine-widget-data-synth`
  so any pre-fix cached results are invalidated on launch.
- **Intelligence Brief follow-up question taps now fire reliably.** The
  previous `AttributedString.link` + `OpenURLAction` pipe silently
  swallowed taps inside the brief's `ScrollView`. Follow-up questions
  now render through a `FlowLayout` of dedicated `Button` views
  (`FollowUpLinkButton`) styled identically (underlined whimsy color)
  but driven by real `Button` taps, with accessibility labels + hints.
- **Widget extension contract restored.** The dashboard redesign in
  `a1f72dd42` shipped four call sites (`WidgetEyebrow`,
  `WidgetMiniSparkline`, `WidgetCompactShareBar`, `widgetGlassCard /
  widgetGlassCardElevated / widgetAccentable`) without their
  declarations, breaking the device build. Implemented all six
  primitives in `WidgetDesignSystem.swift` using DESIGN.md tokens
  (`backgroundLight`, `surfaceLight`, "pressed sage" border #C5CEB6,
  primary gradient), added adaptive `background` / `surface` / `border`
  / `borderSubtle` aliases so the in-flight Warm Charcoal / Botanical
  Cream palette can land without touching call sites, and removed the
  duplicate `WidgetMetricBadge` declaration so only the design-system
  copy remains. A `#if DEBUG`-gated `_WidgetDesignSystemContractCanary`
  references every shared primitive so this exact class of breakage
  (call site without declaration) fails the widget compile in the
  future.

### Added
- **Mobile mission control streams are durable and observable.** iOS/iPadOS
  and Android mission launch payloads now include target project, depth,
  approval mode, command, and file-edit intent; Firestore rules allow the full
  mission-kind/runtime matrix while constraining event shapes. The Mac host now
  mirrors ordered mission events to an `events` subcollection for resumable
  mobile timelines, records typed LLM/tool/error/final-answer events, redacts
  common secrets before cloud writes, and can launch direct OpenCode, Ollama,
  Pi, and OpenClaw CLI missions in addition to the existing chat-backed Codex,
  Claude, and Hermes path. Execution is gated on the local Mac's
  `escrow_devices/{deviceId}` record being explicitly trusted; pending or
  revoked Macs mark launches `unauthorized` without running a local agent.
  Risky or manually gated missions now pause as `waiting_for_approval`, show
  mobile approve/reject controls, and resume on the Mac only after an approved
  response is persisted. Mobile detail views gained timeline filters for LLM,
  tools, errors, approvals, artifacts, and status.
- **Insights mission board.** iOS and Android Intelligence Briefs now keep
  findings, anomalies, recommendations, and generated charts, while adding
  first-class mission candidates generated from the same cited evidence.
  The rule-based engine proposes accretion, diligence, and tech-debt missions
  from project focus, quota/provider risk, and high-recurring model usage;
  strict model prompts and JSON schemas now accept `missionCandidates` so
  remote models can return complementary missions without replacing insights.
- **Benchmark-aware mobile Insights.** iOS and Android Intelligence Briefs now
  compare observed model usage against the public model-board evidence used by
  the router: Artificial Analysis / Design Arena / Terminal-Bench style
  score, rank, cost signal, latency, freshness, and attribution. The local
  rule engine can now surface UI/design model-fit warnings, cheaper
  similar-performance alternatives, and "benchmarks are advisory" guardrails
  without requiring a remote model call. Benchmark citation chips are wired
  into deterministic follow-up prompts.
- **Insights "Editorial Observatory" redesign (iOS / iPadOS).** The
  Intelligence Brief surface in the Insights tab is rewritten as a
  single-column editorial story instead of a card grid: eyebrow + window
  subtitle + 22pt headline + mono meta strip + mercury hairline hero;
  numbered 01 / 02 / 03 Top Findings with a 3pt severity-bar leading edge,
  confidence dots, footnote-chip citations, and a mono action stripe;
  horizontal Anomaly Atlas (220pt instrument cards, mono z-score top-left);
  Recommendations with an ember `●` seal top-right and a mono impact
  arrow; inline `InsightWidgetRenderer` for Generated Views with a
  borderless Pin label; whimsy underlined `AttributedString` follow-up
  questions separated by ` · `; full-width mercury hairline + monoTiny
  audit footer. Sections cascade in with a 0.04s stagger that respects
  `accessibilityReduceMotion`, the hero hairline runs a single 3s shimmer
  on appear, and Dynamic Type is clamped to `.xxLarge`. A new
  `snapshotMode` flag swaps the horizontal anomaly scroller for a
  two-column wrapping grid so `ImageRenderer`, PDF print, and App Store
  screenshot pipelines render the full atlas. Wired into
  `InsightsRootView` whenever `store.currentAnalysis` is present;
  replaces `InsightsMobileAnalysisBrief`.
- **`IntelligenceBriefSnapshotTests`.** Mobile target ships a seven-case
  snapshot + accessibility-traversal suite that drives SwiftUI's
  `ImageRenderer` directly (the target doesn't link
  `swift-snapshot-testing`). Renders are written to
  `.appstore-screenshots/insights-editorial/ios/` and cover full light,
  full dark, minimal (hero + footer only), Dynamic Type `.xLarge`,
  reduce-motion, and iPad regular. Fixtures use real-world AI-spend
  storytelling — Sonnet 4.6 cost dominance with cache decay, MiniMax
  M2.7 weekend spike, Anthropic 5h quota pressure — so the launch
  screenshots double as the highest-fidelity demo of the editorial
  voice. The traversal-order test asserts the contract sequence: hero →
  01 → 02 → 03 → anomalies L→R → recommendations → generated →
  follow-ups → audit.
- **`IntelligenceBriefWiringTests`.** Nine-case unit suite covering the
  `InsightCitation` → composer-prompt mapping that powers every
  footnote-chip tap. Asserts a deterministic, non-empty prompt for
  every `InsightCitation.Kind` variant (session, model, agent,
  project, day, anomaly, query, quota, benchmark) so adding a new kind
  without a prompt mapping fails the build.
- **`InsightsStore.pinGeneratedWidget(_:)`.** Pinning a generated widget
  from the brief now appends it to the active canvas (or replaces the
  existing widget with the same id, so repeated taps are idempotent)
  and refreshes the canvas so the pinned tile shows fresh data on
  first paint.
- **Authentic OpenCode logo.** Shipped the official OpenCode mark
  (sourced from `opencode.ai/favicon.svg`) into both
  `OpenBurnBarMobile/Resources/Assets.xcassets/OpenCodeLogo.imageset/`
  and `AgentLens/Resources/Assets.xcassets/OpenCodeLogo.imageset/` as
  vector SVGs, plus a 512×512 PNG at
  `android/app/src/main/res/drawable-nodpi/logo_open_code.png`. Wired
  through `AgentProvider.bundledLogoName`, `iconName`,
  `primary(for:)`, `accent(for:)`,
  `DashboardLargeView.color`, and the Android `AgentProvider.logoRes`
  mapping. `ProviderAvatarTests` green again after the `.openCode`
  enum case had been missing every brand asset.

### Changed
- **Editorial Observatory: Generated views row no longer duplicates the
  widget title.** `InsightWidgetChrome` already owns the title +
  freshness pill, so `GeneratedViewRow` renders only the renderer +
  bottom Pin/sidenote/citation strip. Stops the chrome's configure
  menu / freshness pill from being overlapped by an external Pin
  button.
- **Editorial Observatory: Recommendation impact arrow infers direction
  from sign.** `↘` + success green when the impact string starts with
  `−`/`-`, `↗` + ember warning when it starts with `+`. Prevents the
  surface from rewarding cost increases with the same green it uses
  for savings.
- **Editorial Observatory: cascade-in cancels on disappear via
  `Task`.** Replaced the `DispatchQueue.asyncAfter` chain with a
  stored `@State Task<Void, Never>` so navigating away mid-cascade
  cancels pending frames cleanly instead of silently calling
  `withAnimation` on a torn-down view.
- **Editorial Observatory: empty `executiveSummary` is omitted.** Hero
  no longer leaves a 22pt vertical gap when the analysis returns an
  empty headline.
- **Editorial Observatory: citation chips compose follow-up prompts.**
  Tapping a footnote chip now drives a deterministic
  composer prompt via `IntelligenceBriefCitationPrompt` (session →
  "open and summarize", quota → "detail headroom and refresh
  cadence", etc.) so the user always lands on the data behind the
  chip instead of a silent noop.
- **Insights "Editorial Observatory" redesign (Android, parity port).**
  `IntelligenceBriefScreen.kt` now matches the iOS story arc on Compose:
  `INTELLIGENCE BRIEF` eyebrow + window subtitle + 22sp rounded-semibold
  executive lede + mono meta strip + mercury-gradient hairline with a
  single 3s shimmer hero; ordered 01 / 02 / 03 Top Findings with mono
  ordinals, severity capsule, confidence dots, mono footnote-chip
  citations, and a mono `→` action stripe; horizontal `LazyRow`
  Anomaly Atlas with mono z-score numerals and a `Canvas`-drawn
  `ZScoreGauge` instrument scale (±2σ warning bands); Recommendations
  carry a severity-aware ember seal top-right and a mono `↑ impact`
  arrow; Generated views render via the existing
  `InsightWidgetRenderer` with `Fig. 01` ordinals and mercury-rule
  figure captions; Follow-ups are inline `ClickableText` whimsy
  segments separated by em-space (not chip buttons); the audit footer
  uses a mercury hairline + mono meta. Sections cascade in via
  `AnimatedVisibility` + `slideInVertically(8.dp)` + `fadeIn` at 40 ms
  stagger; reduce-motion (via `LocalAuroraReduceMotion` driven by
  `Settings.Global.animator_duration_scale==0`) paints synchronously.
  Font scale is clamped upstream by `InsightsTheme` to 1.15×. Wired
  into `InsightsScreen` so any non-null `currentAnalysis` routes to
  the new screen; the old card-grid `AnalysisBrief` is removed. A new
  instrumented Compose UI suite (`IntelligenceBriefScreenTest`,
  12 cases) covers smoke, full-render light/dark, sparse + empty
  fixtures, font-scale 1.15× layout, reduce-motion synchronous paint,
  a TalkBack reading-order contract (asserts monotonic
  `positionInRoot.y` per `testTag`), and four screenshot variants
  (light, dark, fontscale 1.15×, dark + fontscale 1.15×). Screenshots
  persist to `targetContext.getExternalFilesDir(null)/insights-editorial/`
  then sync to `.appstore-screenshots/insights-editorial/android/`.
  Audit pass added: (1) sign-aware impact arrow + accessibility label
  via `impactArrow(impact, isDark)` — `↘` + success green for `−`/`-`,
  `↗` + ember warning for `+`, `↗` + success for unprefixed strings;
  (2) `MetaStrip` folds the `·` separator into the trailing position of
  each non-final label so a wrapped row ends with a dot instead of
  orphaning one at the start of the next line;
  (3) instrumented assertions for citation-tap callback wiring and
  impact-arrow directionality (parity with iOS
  `IntelligenceBriefWiringTests`); (4) pure-JVM unit suite
  `IntelligenceBriefFormattingTest` (5 cases) locking down the
  `windowLabel`, `budgetLabel`, `tokenUsageLabel`, and `auditFooter`
  formatter contracts the brief and the audit log share;
  (5) **Charts are now front-and-center.** The hero picks the first
  chart-bearing generated widget (KPI / time-series / ranking / donut /
  treemap / heatmap / scatter / sankey / radar / cohort / funnel /
  quota-pulse / forecast / focus-matrix) and renders it inline directly
  below the 22 sp executive summary with a `Fig. 01 · <title>` editorial
  caption + Pin action. The renderer's `WidgetHeader` gained an opt-out
  (`showHeader = false`) so the editorial caption doesn't duplicate the
  widget title. Reading order is reordered to hero → Generated views →
  findings → anomalies → recommendations → follow-ups → audit so any
  remaining charts paint immediately after the hero instead of below
  findings. The instrumented fixture now seeds three real chart widgets
  (provider-mix time-series with the MiniMax burst spike, top-models
  bar ranking, spend-distribution donut) so every screenshot variant
  ships with actual graphs above the fold instead of pure typography.
- **OpenCode quota/failover parity.** OpenCode is now a first-class provider
  identity (`opencode`) across provider accounts, quota snapshots, settings
  search, mobile provider onboarding, Android provider display, CLI quota
  grouping, and the self-hosted quota runner. Users can find OpenCode from
  Settings search, connect local/self-hosted OpenCode quota sync, stack
	  multiple OpenCode CLI profiles/accounts, and fall over within the OpenCode
	  provider family when 5h, 7d, or monthly quota signals are exhausted. The
	  local/self-hosted runner now reads the 5-hour bucket from OpenCode's SQLite
	  ledger (`~/.local/share/opencode/opencode.db`) and keeps the 7d/monthly
	  buckets on CLI stats, so the short-window signal is exact instead of a
	  24-hour estimate. Hosted OpenCode credential refresh is intentionally
	  disabled until OpenCode exposes a stable public account quota API.
- **System-wide Insights intelligence layer.** Insights now has a shared
  structured analysis contract across Swift, Kotlin, and the canonical
  Functions schema: `InsightAnalysisRequest`, `InsightAnalysisContext`,
  `InsightAnalysisResult`, findings, anomalies, recommendations, citations,
  generated widgets, follow-up questions, model preference, budget reports,
  and audit entries. macOS and iOS/iPadOS aggregate privacy-bounded local or
  Firestore-backed context into an analysis-first Intelligence Brief before
  materializing generated widgets onto the canvas; Android now uses Firestore
  rollups/quota snapshots through the same digest/evidence/budget pattern
  instead of a production fixture/demo path. The default surfaces lead with
  "what changed / why it matters / what to do next", show the selected model,
  and keep generated widgets cited back to source data. The intelligence
  contract is published as `InsightJSONSchema.analysisResultSchemaV1` —
  identical strict-schema across Swift, Kotlin, and TypeScript — so tier-1
  model gateways can validate `response_format` and tier-2 callers embed it
  in the system prompt. Every run flows through a shared
  `OrchestratedInsightAnalysisEngine` (Swift) / `AndroidInsightAnalysisEngine`
  (Kotlin) that wraps the always-on rule-based fallback in a content-
  addressed `InsightAnalysisCache` (LRU, 64 entries, keyed by prompt + digest
  hash + model + instruction) and an append-only JSONL
  `InsightAnalysisAuditLog` sibling to the canvas-investigation audit. Each
  audit row records the request id, platform, model + egress tier, time
  window, budget report (included sources + truncation summary + bytes/
  tokens), prompt and result hashes, status (`started`/`succeeded`/`partial`/
  `modelUnavailable`/`schemaViolation`/`cancelled`/`failed`), token usage,
  and cost estimate. `InsightModelPreference` carries automatic vs explicit
  mode plus `restrictToLocalOnly`, `maxEgressTier`, and `deepTranscriptOptIn`
  so the composer can surface egress tier + larger-budget warnings before
  any non-local call. The orchestrators now execute the selected user-owned
  model gateway when registered, rather than only materializing local-rule
  analysis: macOS wires OpenAI/Codex, Claude, MiniMax, Z.ai, Kimi, Ollama, and
  local rules from user credentials or local runtimes; Android wires persisted
  model selection with local rules and Ollama behind the same audit/cache
  contract.
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
- **OpenBurnBar-native routed client setup and failover proof.** Routing pools
  now starts with a setup checklist, a one-click loopback gateway default
  (`127.0.0.1:8317`), and explicit client rows for Codex CLI, Droid/Factory,
  Forge CLI, and Claude Code. Local loopback clients can be wired with the
  harmless `openburnbar-local` placeholder when gateway auth is intentionally
  off. Droid/Factory sync now writes Factory custom models with
  `provider: "openai"` and the local `/v1` Hydrant gateway shape, while Forge
  gets a sentinel-fenced
  `[[providers]]` block in `~/forge/.forge.toml` with chat-completions and
  models URLs. Gateway tests now explicitly simulate quota exhaustion for
  Codex, Droid, Forge, and Claude Code and prove each request retries the
  backup account/key in the same wire-format pool.
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
- **macOS Google sign-in presentation.** Clicking **Sign in with Google** now
  starts the interactive GoogleSignIn macOS flow immediately with a real
  `ASWebAuthenticationSession` presentation window instead of first attempting
  silent restore or forcing a nil-window external-browser path that could leave
  the button spinning without showing auth UI.
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
    `providerLock != "factory"` are user-configured proxies (third-party proxy,
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
    filter (multi-session fixture with custom-proxy + anthropic + factory
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
