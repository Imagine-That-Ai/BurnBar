# Fun facts

## The folder that refused to die

The macOS app sources live under `AgentLens/` because "renaming folders is a personality test Xcode sometimes fails." The product name is OpenBurnBar; the bundle ID is `com.openburnbar.app`. The folder is historical.

## Mercury is silver, not purple

Provider purple (`#A855F7`) stays for tracking and charts. The Hermes chat interface uses warm silver (`hermesMercury`) and dark platinum (`hermesAureate`) — a metallic neutral axis that sits between warm accents and cool whimsy.

## Quarantine for tests

Stale test suites live in `AgentLensTests/Quarantine/`. They are intentionally excluded from CI until fixed and moved back to `Active/`. The directory name makes the intent unmistakable.

## 49 functions, all logged

Every one of the 49 Firebase Cloud Functions is wrapped with structured logging. The rollout completed in May 2026 as part of the SOTA hardening pass.

## Bot co-authorship

`factory-droid[bot]` appears as a co-author on roughly **27%** of all public commits. That is a lower bound on AI-assisted work — inline tools like Copilot leave no trace in git history.

## Oldest code

The oldest tracked file, `ClaudeCodeParser.swift`, dates to **2026-04-04**. Given the private pre-history, older logic likely existed before the public extraction.
