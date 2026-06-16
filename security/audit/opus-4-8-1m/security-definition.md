# Security Definition — Opus 4.8 1M lane

## B.1 What the product does
OpenBurnBar is a local-first macOS menu-bar app that tracks AI-agent token usage/cost across providers (Claude Code, Codex, Factory Droid, Kimi, MiniMax, …), with opt-in Firebase cloud sync, iOS/Android companions, an iroh P2P transport, a blind Hermes LLM-provider relay, Computer Use (agentic Mac automation with approval gates), and a server-blind Cloud Vault for sealed content.

## B.2 Definition of "secure" for this product
**Users:** their provider credentials never reach the cloud in plaintext; only the owner (and approved devices) can access their resources; private chat/session content is sealed before cloud upload; dangerous Mac actions require explicit approval; deletion removes their data; security claims are not misleading.

**Product:** clear trust boundaries; high-risk flows fail closed; object-level authorization is enforced, catalogued, and tested; releases are signed/notarized/attested; regressions are caught by CI gates; public claims match implementation.

**Business:** enterprise/customer claims are defensible; audit scope is clear; incidents can be detected and investigated; supply-chain risk is managed; risk decisions are tracked.

## B.3 Security goals
Protect confidentiality of provider credentials and sealed content; prevent cross-user/cross-tenant access; prevent unauthorized billing/entitlement grants; prevent untrusted-content-driven dangerous agent actions; minimize sensitive logging and stable cross-processor correlators; keep the release pipeline tamper-evident; support detection and response.

## B.4 Non-goals (explicit)
- Does **not** protect plaintext on a fully-compromised same-user endpoint (unsandboxed local-first model).
- Does **not** encrypt the local SQLite DB at rest today (SQLCipher not vendored).
- Does **not** seal shared collaboration artifacts (cloud-readable).
- Does **not** make the gateway blind to model-routing metadata (by design).
- Does **not** provide "Signal Protocol" content encryption (libsignal at-rest path is inert; sealing is AES-256-GCM/CryptoKit).
- Does **not** claim independent external audit (none has occurred).

## B.5 Assumptions
- The user's Mac is single-user and trusted; same-user processes are mutually trusted except where credential-bearing IPC adds peer codesign.
- macOS Keychain protects secrets at rest.
- Cloud features are opt-in and do not replace local state.
- Operational controls (TTLs, App Check console enforcement, alert delivery, branch protection) are assumed effective **only once confirmed** (see `open-questions.md`).
