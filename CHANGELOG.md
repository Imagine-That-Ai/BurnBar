# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The macOS Mercury incoming screen-mirror / call sheet now renders the requesting account's profile photo in the avatar circle, falling back to the name monogram while it loads or when no photo is available (e.g. Sign in with Apple), instead of always showing only the name initial.

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

- **Droid custom models (Anthropic BYOK)** — the local gateway now accepts the gateway bearer token via `x-api-key` as well as `Authorization: Bearer`, matching Factory Droid's Anthropic adapter. Routed Claude custom models (`provider: anthropic` in `~/.factory/settings.local.json`) no longer fail with `401 unauthorized` / `Exec failed`.
- **Mobile Hermes Gateway replies** — BurnBar Cloud gateway replies now reopen the exact Hermes thread, persist replies before rendering mobile reply cards, hide older duplicate reconnect entries for the same device, and show the answering provider badge in notifications and gateway status UI.

### Added

- Added a daemon-backed Route log in Settings -> Agents -> CLIs for the local proxy, showing the requested model slug/name, the upstream model/provider/logo identity actually used, provider-reported model slug, exact-route invariant status, attempts, and usage metadata without logging prompt or response bodies.
- Added Settings -> Agents -> Advanced quota-popover controls so users can choose which provider quotas appear in the menu-bar drop-down, with a compact quick-access button in the popover header.

### Security

- **Hermes Gateway E2EE remediation** — paired BurnBar Cloud gateway links now treat the relay as untrusted: new writes require production `relayEnvelope` (v2/v3) or `ratchetEnvelope` for text/control when both peers publish ratchet material; message/attachment IDs round-trip for AAD binding; replay ledgers record only after successful open; both-key 128-bit safety codes include ratchet identities when available; macOS Keychain holds agent relay/ratchet private keys; setup no longer silently enables allow-all users. Proof gate: `bash scripts/ci/verify-hermes-gateway-e2ee-remediation.sh` (privacy scanner, focused Functions vitest, Firestore rules, schema drift, v2/v3 fixture mirrors, adapter mirror, local gateway smoke, 211 external Hermes pytest). See [`docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md`](docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md) for the honest claim boundary (not whole-product SOTA E2EE).
  - Post-implementation principal review found and fixed a control-dispatch gap: iOS E2E sends for `model_switch`/`approval_decision`/`oversight_mode` now emit `kind` (and control fields) at the root of the sealed payload so the agent's pinned open path dispatches to the special sealed handlers instead of dropping as empty chat text or leaking as JSON messages. Added unit coverage and updated oversight E2E delivery. All gates re-verified green.
- Sealed the remaining same-pattern cloud privacy surfaces: approval-policy labels/paths/globs, CLI session snapshot file/path labels, rollback request scopes/errors, agent identity persona text, subscription topic labels, and Hermes Gateway typing/private routing metadata. Mac, iOS/iPadOS, Android, functions, Firestore rules, privacy scans, and registry tests cover the sealed-only contract.

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
