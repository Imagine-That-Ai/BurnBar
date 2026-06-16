# Remediation Plan — OpenBurnBar Security Audit (4-audit consolidation)

**Lane:** Opus 4.8 (1M) · **Date:** 2026-06-16 · **Code branch:** `remediation/opus-4-8-1m-2026-06-16` (isolated worktree at `/private/tmp/bb-opus48-remediation`)

This plan is **deduplicated against the parallel remediation agents** running concurrently (GLM-5.2, gpt-5.5, K2.7, and the opus-sibling auditor). I implement the high-value items **nobody else is touching**; for items already in flight elsewhere I specify the SOTA-correct approach so their work can be checked against it.

## Ownership map (who fixes what, observed live)

| Owner | Items in flight |
|-------|-----------------|
| **GLM-5.2** | V-17 Stripe redirect ✓, V-20 accountDeletion logWarn ✓, V-07 RestrictedLogPathValidator, V-31 SQLCipher keychain fail-closed, V-29a/b mission-event side-channel, V-21 buildFcmMessage I5, V-01 watchdog, V-03 phone-UI, V-25 deploy verify |
| **gpt-5.5** | V-02 daemon local-auth-proof wiring, (suggested V-04 daemon entitlement) |
| **K2.7** | V-15 App Check enforcement ops-verifier, broad ops-readiness |
| **This lane (Opus 4.8)** | **V-10 (Critical), V-34 (High), V-35 (Med), V-32 (Med-coverage)** + the deduped plan + verification + SOTA docs |
| **Unclaimed (recommended next)** | V-27b CODEOWNERS, V-24 SSRF, V-23a deletion manifest, V-16, V-22, V-37, V-38, V-11, V-26, V-27a, V-05, V-06 |

---

## Priority 0 — Critical (implementing in this lane)

### V-10 — Seal shared collaboration artifacts before Firestore  ⟵ THE headline fix
**Status: implemented on `remediation/opus-4-8-1m-2026-06-16`.**

**Root cause:** `SharedArtifactCloudCodec.encode` writes `title`/`body`/`relativePath` as raw strings; `firestore.rules` `sharedArtifactOwnerWrite` permits them.

**SOTA-correct fix (mirrors the proven `ChatThreadSyncService` sealing pattern):**
1. **Swift writer** — seal `body`, `title`, `relativePath` into a single `sealedPayload` via `CloudVaultCrypto.sealPayload` with **path-bound AAD** (`cloudVaultAADContext(uid, "artifacts", artifactID, "sealedPayload")` — and a distinct context for `versions/{revisionID}`), so ciphertext can't be relocated (closes V-11's class for this surface from day one). Drop the plaintext fields from the Firestore payload entirely.
2. **Keyed dedup hash** — replace the keyless `contentHash` with a vault-keyed HMAC (mirror the `pensieveDedupHash` pattern) so it stops being a plaintext confirmation oracle. Keep a separate *local* SHA-256 for on-device change detection (never written to cloud).
3. **Firestore rules** — wire `forbidsSealedPlaintextContentFields()` into `sharedArtifactOwnerWrite`, require `sealedPayload` to be a `validPathBoundSealedPayloadForUser(...)`, and reject any write carrying `body`/`title`/`relativePath`/unkeyed `contentHash`.
4. **Reader** — decode path: open `sealedPayload`, fall back to legacy plaintext **read-only** for already-synced docs during a migration window (gated, logged), then re-seal on next write.
5. **Migration** — one-time re-seal of existing plaintext artifact heads/versions on next collaboration sync; emit a metric for un-migrated docs.

**Tests:**
- `firestore-rules-tests/shared-artifact-sealed.test.js` — `assertFails` on a plaintext `body` write; `assertSucceeds` on a sealed write; relocation of a sealed blob to another docID `assertFails` (AAD).
- Swift `SharedArtifactCloudCodecSealingTests` — round-trip seal/open; asserts no plaintext `body`/`title`/`relativePath` and no keyless hash leaves the device; legacy-read fallback.

**Acceptance:** artifact write path emits a sealed, path-bound payload; rules require it; rules test proves plaintext write fails; hash is keyed.

---

## Priority 1 — High (implementing in this lane)

### V-34 — Wrap the one unwrapped untrusted-content path (prompt injection, LLM01)
**Status: implemented on the lane branch.**

**Root cause:** `ContextBuilder.buildDatabaseAnalystSystemPrompt` injects `latest.lastAssistantMessage` **raw** into the system prompt (flows to all chat backends via `augmentedSystem`). Every other ingestion→prompt boundary already uses `LLMSafeContent.wrapUntrusted` / `wrapTranscriptForPrompt`; this is the lone escapee.

**SOTA-correct fix (OWASP LLM01 / spotlighting §2):**
1. Route `lastAssistantMessage` (and any sibling DB-analyst injected content derived from stored/indexed text) through `LLMSafeContent.wrapUntrusted` with an explicit "untrusted prior content — data, not instructions" boundary, consistent with the rest of the codebase.
2. Add the path to `PromptInjectionHardeningTests` with an adversarial corpus entry (a poisoned `lastAssistantMessage` containing `"ignore previous instructions / system:"`) asserting the wrapper encloses it.

**Acceptance:** no untrusted stored content reaches a system/user prompt unwrapped; regression test covers the DB-analyst path.

---

## Priority 2 — Medium (implementing where unclaimed)

### V-35 — Gate the local MCP semantic-search tool
**Root cause:** `tools/openburnbar-mcp/server.py` `burnbar_semantic_search_conversations` returns raw conversation snippets with no capability gate, while the **cloud** variant already gates via `_capability_denial(..., "cloud_decrypt")`.

**Fix:** apply the same capability-denial gate to the local tool (consent/capability check before returning snippets), add an audit-log line per MCP tool call, and scope returned snippets to the explicit query. Documented as the OWASP-LLM02 (sensitive-information-disclosure) mitigation.

### V-32 — macOS Sentry scrubber unit tests
**Root cause:** `MacSentryScrubber` + `MacCrashReportingConsent.perInstallAnonymizedID` are pure/testable but only the iOS sibling is tested; macOS can regress silently and ship PII.

**Fix:** add `MacSentryScrubberTests` mirroring `MobileSentryScrubberTests` (PII redaction, install-id non-PII, `sendDefaultPii=false`, consent gate). Pure-logic test, runs in CI, no app build needed.

---

## Priority 3 — recommended next (specs for unclaimed items; not all implemented this pass)

- **V-27b CODEOWNERS** — add path rules for `functions/src/security/**`, crypto, billing/entitlements, `scripts/ci/**`, `Vendor/libsignal/**`, `firestore.indexes.json` (single-owner is fine; makes routing intentional). Cheap, high-signal.
- **V-24 SSRF** — implement the undici `Agent({connect:{lookup}})` DNS-pinning client now (latent), parse host-as-integer before range checks, redirects disabled, host/IP allow-list for the fixed provider set. Wire it before any user-URL feature.
- **V-23a deletion manifest** — replace `ROOT_COLLECTIONS_KEYED_BY_UID` with a manifest + emulator completeness test (mirror BOLA catalog-completeness) that fails CI on an unlisted uid-keyed root collection.
- **V-16** — make App Check attestation max-age Remote-Config-driven; default 7d for high-risk callables (nonce already covers replay).
- **V-22** — drop/rotate `androidDeviceId` in `fcm_outbound` (low; already TTL'd + erased).
- **V-37** — add a pre-flight `maxFileSize` guard + JSON-depth cap to the unbounded `Data(contentsOf:)` parsers (`OpenClawParser`, `GeminiCLIParser`, `WarpParser`, `GrokParser`, …) and a recursion-depth cap in `flattenSessionObjects`.
- **V-38** — add the missing **scope-escalation** adversarial test (deny→allow elevation / context mutation) to `ComputerUseScopeMatcherTests`.
- **V-11** — migrate `ChatThreadSyncService` + `CLIAgentSessionRecord` writers to path-bound AAD, then tighten `chat_threads`/`cli_sessions` rules to `validPathBoundSealedPayloadForUser`. (Coordinate: do writers first, then rules, to avoid bricking writes.)
- **V-26 / V-27a** — loud `::warning::` on missing GPG key; add `permissions:` to `computer-use-loopback-test.yml` + `droid-wiki-refresh.yml`.
- **V-05 / V-06 / V-01** — add `validateServerPeer`/`PrivilegedPeerAuthenticator` to the legacy `/var/run` write and the watchdog socket; prefer absolute-path allowlist exclusively for privileged resolution. (V-01 partly GLM's.)

## Do NOT spend effort on (verified false / already fixed)
V-08, V-09 (Kimi hallucinations), V-23b (fail-closed audit misread), V-28 (non-exploitable), V-14, V-33 (already fixed). See `01-VERIFICATION-REPORT.md`.

---

## Validation strategy

- **Firestore rules**: `npm --prefix firestore-rules-tests run test:ci` (emulator) — runnable here; the new `shared-artifact-sealed.test.js` proves the V-10 rule.
- **Swift**: new unit tests target pure codec/wrapper logic (no full app build needed to validate correctness; they compile against the same modules and mirror existing passing tests).
- **Python MCP**: gate added with a unit test asserting denial without capability.
- All code changes live on the isolated branch so they never contaminate the contested shared working tree or the parallel agents' diffs.
