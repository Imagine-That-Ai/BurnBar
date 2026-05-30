# Lore

The public git history of OpenBurnBar begins in April 2026 with the commit "chore: create clean public OSS baseline" — a curated extraction from a private development tree. The design system documents in `DESIGN.md` trace the project back to at least March 2026. What follows is the project's history as it can be reconstructed from commit messages, CHANGELOG entries, and design decision logs.

---

## Era 1 — Private foundation (before April 2026)

The `DESIGN.md` decisions log shows an initial design consultation on **2026-03-22** that produced the Warm Charcoal dark palette, Botanical Cream light mode, and the SF Pro Rounded typography system. Hermes integration with the "Mercury Rising" design identity landed in the same session on **2026-03-25**.

Before the public OSS extraction, the app appears to have been a private macOS menu bar tool for tracking Claude Code and Factory Droid token usage. The earliest parsers (Claude Code, Factory Droid, Codex) were the founding surface. GRDB/SQLite was likely chosen over Firestore-only from the start; the "local-first" framing appears throughout the codebase as a settled principle rather than a migration.

---

## Era 2 — Public OSS baseline (April 2026)

**2026-04-04**: The public repository is seeded ("chore: create clean public OSS baseline"). `ClaudeCodeParser.swift` — the oldest tracked file — was introduced on this date.

Within the first weeks of the public repo:
- A full distribution pipeline was added (`Makefile`, release CI, Homebrew Cask).
- CodeQL security scanning was wired up (daily scan workflow).
- The account switcher feature launched: profile registry, browser launch adapter, Settings management UI.
- The token accounting worker shipped: exact-first precedence guards, row-level provenance metadata, checkpoint/resume, atomic visibility.
- M1/M2/M3 mission scrutiny rounds drove deterministic test fixes across the indexing and token accounting surfaces.

---

## Era 3 — Mercury media and Mobile parity (May 2026, early)

The master plan for Mercury media and Computer Use was written on **2026-05-16** (referenced in `AGENTS.md`). That date also marks "full iOS parity" for the Android app — Hermes Square, messaging, iroh transport, and Mercury Media (file transfer, screen-share viewer, 1:1 calls) shipping together.

Key Mercury media decisions (from `DESIGN.md`):
- P2P transport: `crates/openburnbar-iroh` compiled to `Vendor/openburnbar-iroh.xcframework` (iOS/macOS) and `Vendor/openburnbar-iroh.aar` (Android), with UniFFI bindings pinned to 0.28.3.
- Ed25519 pairing for all iroh sessions.
- Android incoming-call: `Notification.CallStyle.forIncomingCall` + `USE_FULL_SCREEN_INTENT`.
- Per-partner save preferences: iOS `MediaPartnerSavePreferenceStore`, Android DataStore Proto.
- Audio over `MercuryAudioDatagramChannel` on ALPN `openburnbar/mercury/audio/1`.

---

## Era 4 — Computer Use Phases 8–13 (May 2026, mid)

Computer Use decisions were logged on **2026-05-17**. The six phases:

| Phase | Capability |
|-------|-----------|
| 8 | Agent Watch — Mac → phone read-only mirror (cursor extension to Mercury transport) |
| 9 | Browser Computer Use — agent drives Playwright Chromium |
| 10 | Trust modes + scope rules + audit chain |
| 11 | Mac System Computer Use — CGEvent + Accessibility (Developer ID only) |
| 12 | Phone-as-controller — Ed25519-signed intents |
| 13 | Polish — trusted scopes library, audit export, OpenTimestamps |

The Computer Use loopback test workflow (`.github/workflows/computer-use-loopback-test.yml`) shipped on **2026-05-17**.

---

## Era 5 — Insights Editorial Observatory (May 2026, mid)

The "Editorial Observatory" Insights redesign was logged on **2026-05-13**. It replaced a card-grid Intelligence Brief with a single-column editorial story — eyebrow + executive headline + numbered 01/02/03 findings + Anomaly Atlas + Recommendations + Generated Views. The same design landed on Android in the same release, with `IntelligenceBriefScreen.kt` as a direct Kotlin port.

---

## Era 6 — Agent Live Stage (May 2026, late)

The Agent Live Stage decision was logged on **2026-05-21**. When a Computer Use session starts, an `AgentLiveStage` overlay auto-springs open in the iOS/iPadOS chat as a 320×180 dock tile. Tap promotes to split-screen; pinch-out or expand promotes to full-bleed mirror with a floating chat composer. A new `AgentWatchOverlaySingleton` owns the persistent iroh control stream so the live mirror survives tab swaps.

---

## Era 7 — SOTA hardening (May 2026, ongoing)

The `hardening/sota-100` branch (the current working branch as of 2026-05-30) is a sustained quality drive targeting a 100/100 technical readiness score. The commit log shows iterative validation rounds (m1, m2, m3), daemon regression tests, structured logging rollout across all 49 Firebase callables, CloudSync actor isolation, and provider updates (MiMo, Cursor Agent, Opus 4.8 as flagship model).

---

## Longest-standing code

The oldest tracked file is `AgentLens/Services/LogParser/ClaudeCodeParser.swift`, first committed on **2026-04-04**. Given the private pre-history, older logic likely existed before the public extraction — but within the tracked tree, the parser suite and `DesignSystem.swift` appear to be the most stable, least-churned foundations.

---

## Key architectural decisions

| Decision | Rationale |
|----------|-----------|
| Local-first over Firestore-only | Cloud sync is opt-in; local SQLite is canonical. Zero network dependency for core token tracking. |
| GRDB over Core Data | Ergonomic Swift API over bare SQLite, type-safe queries, no Objective-C overhead, easier testing. |
| UniFFI for iroh | Single Rust crate (`crates/openburnbar-iroh`) compiled to both XCFramework and AAR, sharing wire format, ALPN, and Ed25519 pairing across platforms. |
| Daemon-first | The macOS app is a UI shell over a local JSON-RPC daemon. The daemon owns log parsing, quota polling, budget enforcement, and the HTTP gateway. |
