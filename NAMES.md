# NAMES.md — codename map

A reviewer's decoder ring. The repo (and its docs) use internal codenames; the
website uses public names. One line each: codename → what it is → key paths.
Authoritative definitions live in `droid-wiki/overview/glossary.md`.

## Product & repo

- **BurnBar / OpenBurnBar** — the product: a macOS menu-bar app that tracks AI-agent token usage/cost, plus its daemon, mobile companions, cloud functions, and website. "BurnBar" is the brand (burnbar.ai); "OpenBurnBar" is the app/open-source name. Repo: `github.com/Imagine-That-Ai/BurnBar`.
- **AgentLens** — the macOS app source tree (SwiftUI menu-bar app). Historical folder name only; the shipped product is OpenBurnBar, bundle ID `com.openburnbar.app`. Key path: `AgentLens/`.

## Feature codenames

- **Hermes** — the AI assistant/chat system inside OpenBurnBar (chat UI, model routing, tools), named after the upstream Nous Research `hermes-agent` it builds on. Key paths: `AgentLens/Views/Chat/`, `docs/HERMES_*.md`, `tools/hermes-platform-burnbar/` (the hosted **Hermes Gateway** adapter; see `docs/HERMES_GATEWAY_PLATFORM.md`).
- **Mercury** — the Mac ⇄ iPhone/iPad/Android P2P media system: file transfer, screen sharing, 1:1 voice/video calls over the iroh transport. Key paths: `plans/2026-05-15-mercury-media-master-plan.md`, `docs/runbooks/media-rollout-status.md`, `docs/HERMES_MEDIA_TRANSPORT.md`, `droid-wiki/features/mercury-media.md`.
- **Floo** — the *public* name for the phone ⇄ Mac companion experience (what Mercury + companion surfaces ship as on burnbar.ai). Single source of truth: the `FLOO` constant in `website/src/data/capabilities.ts`.
- **Agent Control** — the *public* name for Computer Use: an AI agent driving the Mac while the phone mirrors the screen with tap-to-drive and panic-halt. Internal docs say "Computer Use". Key paths: `docs/HERMES_COMPUTER_USE.md`, `website/src/data/capabilities.ts`.
- **Pensieve** — the member-facing E2EE personal knowledge memory (repo docs/notes/chat memories sealed on device, queried by agents over hosted MCP) *and* the Data & Privacy Control Center built around it. Internal SKU/entitlement id family: `mnemo`. Key paths: `docs/PENSIEVE.md`, `docs/PENSIEVE_CONTROL_CENTER.md`, `docs/PENSIEVE_CONTROL_CENTER_RUNBOOK.md`.
- **Horcrux** — the *public* name for the sealed-envelope encrypted gateway layer ("Hermetic Object Relay Crypto — Re-keyed Untrusted eXchange"); the relay in the middle can't read message contents. Single source of truth: the `HORCRUX` constant in `website/src/data/licensing.ts`; rendered on burnbar.ai `/trust`.

## Sub-feature names a reviewer will hit

- **Hermes Square** — the messaging/peer-grid surface in the mobile companions (the "My Mac" tile lives here). Key paths: `droid-wiki/apps/android-app.md`, `droid-wiki/features/mercury-media.md`.
- **Agent Watch** — the read-only phone mirror of the Mac screen during Computer Use. See `droid-wiki/overview/glossary.md`.
- **Agent Live Stage** — the iOS/iPadOS overlay that auto-opens on Computer Use session start (dockable mirror tile). See `droid-wiki/overview/glossary.md`.
- **Mission Control** — the daemon-backed runtime for project registry, scheduled reviews, missions, and simulator replay. Key path: `OpenBurnBarDaemon/`.
- **Signalification** — the program migrating BurnBar's E2EE onto the official libsignal libraries (`Vendor/libsignal` submodule). Key path: `docs/signalification/`.

## Not codenames (easy to confuse)

- **iroh** — third-party Rust P2P transport library (n0-computer), vendored as `Vendor/openburnbar-iroh.xcframework` / `Vendor/openburnbar-iroh.aar` via UniFFI.
- **hermes-agent** — the upstream Nous Research open-source agent (`github.com/NousResearch/hermes-agent`) that the Hermes assistant and gateway build on; it is a dependency, not a BurnBar codename. See `docs/HERMES_GATEWAY_PLATFORM.md`.

Public copy policy: marketing surfaces never expose internal codenames or
transport/protocol jargon — the mapping above is for reviewers reading the
repo, not for rendered copy (see `website/src/data/capabilities.ts` header).
