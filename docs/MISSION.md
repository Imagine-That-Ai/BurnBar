# OpenBurnBar Mission

## Mission

OpenBurnBar exists to give developers a trustworthy local read on AI-agent work: what ran, what it cost, what changed, and what deserves follow-up.

Today the shipped product is a native macOS menu bar app with a local daemon, a local SQLite store, and a Cursor / VS Code extension. It watches local agent logs, estimates spend and quota, indexes conversations and source artifacts, and exposes that state back through dashboard, settings, chat, and daemon-backed control surfaces.

## What the product must do well right now

- **Observe real agent activity** across providers such as Claude Code, Factory Droid, Codex, Kimi, Z.ai, MiniMax, and routed Cursor traffic when enabled.
- **Keep local state authoritative** so the app stays useful offline and does not depend on cloud sync to answer core questions.
- **Make operating state legible** through burn summaries, recent evidence, retrieval health, mission/direction snapshots, and controller runtime status.
- **Let users recover context quickly** from indexed conversations, artifacts, and recent sessions instead of reopening raw logs by hand.
- **Stay honest about confidence** by distinguishing exact vs estimated values, sparse vs grounded evidence, and healthy vs degraded indexing state.

## Product beliefs

- Multi-agent work is normal now; the missing layer is visibility and continuity.
- Local-first is a product requirement, not branding.
- Raw artifacts and provenance matter more than polished-but-unverifiable summaries.
- Search, retrieval, and operating snapshots should be grounded in the same local source of truth.
- Optional cloud features should extend the product, not redefine it.

## Current standard

When OpenBurnBar ships a feature, it should make one of these things better without weakening trust:

1. knowing what happened
2. knowing what it cost
3. knowing what still needs attention
4. finding the evidence fast

If a feature adds surface area without improving one of those outcomes, it is off mission.
