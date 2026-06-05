# BurnBar shared packages

Independent (non-workspace) packages shared across the BurnBar surfaces — the
foundation layer for the **Data & Privacy Control Center** (see
`docs/PENSIEVE.md` and the plan in `/Users/albertonunez/.claude/plans/`).

## `data-domains/` — the user-data domain registry

`registry.json` is the **single source of truth** for the ~12 user-facing data
domains (usage, conversations, session logs, Pensieve, providers, devices, MCP
access, computer-use, media, billing, device-trust/keys, audit). Each entry
carries its **encryption tier** (`server_readable` / `zero_access` /
`end_to_end`), what the server sees vs. what stays on device, Firestore/Storage
paths, count/byte sources, and the callables that view/export/delete it.

- `node codegen.mjs` → `gen/domains.ts` (web), `gen/DataDomains.swift` (Apple),
  `gen/DataDomains.kt` (Android). Generated files are committed; the test asserts
  they're fresh.
- `node driftcheck.mjs` → fails CI if any `users/{uid}/<col>` in
  `firestore.rules` is neither registered to a domain nor listed in
  `excludedCollections`. No new user-data collection can be added without
  consciously deciding whether it belongs in the control center.
- `npm test` — registry validation + drift check + codegen freshness.

## `design-tokens/` — "The Pensieve" design tokens

DTCG `tokens/pensieve.tokens.json` (a superset of the brand "Glass Console over
Furnace Core" system + control-center tokens: mercury-silver basin, frosted
sealed state, wax-crimson destructive, encryption-tier badge colors; brand fonts
Outfit/Geist/JetBrains Mono) → **Style Dictionary v5**:

- `npm run build` → `dist/css/pensieve.css` (web `:root` vars),
  `dist/swift/PensieveTokens.swift`, `dist/compose/PensieveTokens.kt`.
- `npm test` — builds + asserts all three platforms emit the same tokens with
  resolved values and distinct encryption-tier colors.

One source → every surface, so the control center is one product across web,
iOS, iPadOS, macOS, and Android.

## `libsignal-bridge/` — official Signal libsignal readiness

Pins `@signalapp/libsignal-client@0.94.4` and verifies the required Signal
Protocol symbols load from the official Signal-maintained package. The test
harness also establishes a real Signal Protocol session, consumes one-time
prekeys, marks Kyber prekeys used, decrypts out-of-order Whisper messages,
rejects replay, and proves safety-number changes on remote identity replacement.

This is the first bridge layer for the Signal-grade E2EE migration;
private-domain traffic must not switch to Signal-backed envelopes until the
platform bridge, cross-language vectors, replay rejection, skipped-key,
safety-number, and stale-session repair tests are green across shipping clients.

## `signal-envelope-contracts/` — Signal envelope v1 Node contract

Shared TypeScript schema constants and sanitizers for staged Signal-backed
`signalEnvelope` records. Functions, hosted MCP, and the Hermes realtime relay
consume this package so transport and at-rest envelope validation, export
redaction, downgrade rejection, and plaintext-sibling stripping stay identical
across Node services.

This package does **not** perform Signal Protocol cryptography. It only defines
the fail-closed Node contract that future official-libsignal writes must satisfy;
`third_party/libsignal/runtime-readiness.json` remains the release gate for
actual runtime migration.
