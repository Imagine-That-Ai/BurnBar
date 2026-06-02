# Lore

The public git history begins in April 2026 with a curated extraction from a private development tree.

## Era 1 — Private foundation (before April 2026)

- **2026-03-22**: Design consultation produced the Warm Charcoal dark palette, Botanical Cream light mode, and SF Pro Rounded typography.
- **2026-03-25**: Hermes integration with the Mercury Rising design identity landed.
- The earliest parsers (Claude Code, Factory Droid, Codex) were the founding surface.

## Era 2 — Public OSS baseline (April 2026)

- **2026-04-04**: Public repository seeded with clean baseline.
- Distribution pipeline (`Makefile`, release CI, Homebrew Cask) added within weeks.
- CodeQL security scanning wired up.
- Account switcher, token accounting worker, and M1/M2/M3 mission scrutiny rounds shipped.

## Era 3 — Mercury media and mobile parity (May 2026, early)

- **2026-05-16**: Android reached full iOS parity — Hermes Square, messaging, iroh transport, Mercury Media.
- Key decisions: UniFFI for single Rust crate → XCFramework + AAR, Ed25519 pairing, Android incoming-call via `Notification.CallStyle`, per-partner save preferences.

## Era 4 — Computer Use Phases 8–13 (May 2026, mid)

- **2026-05-17**: Computer Use phases logged. Agent Watch (cursor extension to Mercury transport), Browser (Playwright), Trust modes, Mac System CGEvent+AX, Phone-as-controller, and Polish (trusted scopes, audit export).

## Era 5 — Insights Editorial Observatory (May 2026, mid)

- **2026-05-13**: Replaced card-grid Intelligence Brief with editorial story: eyebrow + headline + numbered findings + Anomaly Atlas + Recommendations + Generated Views. Ported to Android in the same release.

## Era 6 — Agent Live Stage (May 2026, late)

- **2026-05-21**: iOS overlay auto-opens on Computer Use session start as a dockable mirror tile with split-screen and full-bleed modes. `AgentWatchOverlaySingleton` owns the persistent iroh control stream.

## Era 7 — SOTA hardening (May 2026, ongoing)

- `hardening/sota-100` branch: iterative validation rounds, daemon regression tests, structured logging rollout across all 49 callables, CloudSync actor isolation, provider updates.

## Longest-standing code

The oldest tracked file is `AgentLens/Services/LogParser/ClaudeCodeParser.swift`, committed on **2026-04-04**.

## Key architectural decisions

| Decision | Rationale |
|----------|-----------|
| Local-first over Firestore-only | Zero network dependency for core tracking; cloud is opt-in |
| GRDB over Core Data | Ergonomic Swift API, type-safe queries, easier testing |
| UniFFI for iroh | Single Rust crate compiles to all platforms, shared wire format |
| Daemon-first | macOS app is a UI shell; daemon owns routing, runs, missions |
