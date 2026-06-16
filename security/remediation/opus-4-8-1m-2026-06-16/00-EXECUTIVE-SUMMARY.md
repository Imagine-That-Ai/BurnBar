# Security Remediation — Opus 4.8 (1M) lane — Executive Summary

**Date:** 2026-06-16 · **Audited commit:** `60faa70227` · **Code branch:** `remediation/opus-4-8-1m-2026-06-16` (isolated worktree, local; not pushed)

## What I was asked to do
Examine four independent AI security audits (GLM-5.2, Opus-4.8-1M, Kimi/K2, Codex-GPT-5), **verify every claim against the actual code**, research 2026 SOTA, and remediate to that bar. Mid-task I was told other models are running the *same* job in parallel and to (a) keep my deliverables in my own namespaced folder, and (b) check the live agent panes before remediating so I don't duplicate.

## What I found
- I re-verified ~60 raw findings with five parallel verification agents (read-only, code-grounded). Result in **`01-VERIFICATION-REPORT.md`**: a 38-row reconciliation with per-finding verdicts and evidence.
- **One Critical, and only one, across all four audits:** shared/team collaboration artifacts were written to Firestore in **plaintext** (full source `body`, `title`, `relativePath` + a keyless content-hash oracle) — the single CloudVault surface that didn't seal. (Opus-F-001 → my **V-10**.)
- **Four findings are FALSE / non-exploitable** and would waste effort: Kimi's "no daemon authorization matrix" (V-08) and "HID tokens unbound" (V-09) are both hallucinated absences (the mechanisms demonstrably exist); Codex's "best-effort deletion audit" (V-23b) misreads a fail-CLOSED two-phase audit; Opus's quota-deflation "bypass" (V-28) is inert because the gates never read the client mirror.
- **Three are already fixed** (V-14 session_logs, V-33 Android iroh key, and the "silent SQLite plaintext" framing of V-30 — it's now loud/disclosed).
- The SQLCipher contradiction across the three audits is resolved authoritatively in the report (Opus correct; Kimi outdated; Codex true-but-inert).

## What I checked before touching code
Read the live cmux panes: **GLM-5.2** is fixing the Stripe redirect, accountDeletion logging, RestrictedLogPathValidator, the SQLCipher keychain branch, mission-event side-channels, `buildFcmMessage`, watchdog/phone-UI/deploy; **gpt-5.5** is wiring the daemon local-auth-proof verifier; **K2.7** is doing App Check ops-verification. The main working tree is **contested** (K2.7 shares my branch, 167 dirty files). So I worked in an **isolated git worktree** and picked the high-value items **nobody else was touching**.

## What I implemented (verified)
Both items were unclaimed by every other agent and are the two highest-value confirmed findings outside the in-flight set.

### V-10 — Critical — seal shared/team artifacts before Firestore  ✅ implemented + test-verified
- `SharedArtifactCloudCodec.encodeSealed` seals `{title, body, relativePath, contentHash}` into a single **path-bound** AES-256-GCM CloudVault envelope (AAD `uid|collection|docId|sealedPayload`), bound **separately** for the head (`artifacts`+artifactId) and each version (`artifact_versions`+revisionId) so an envelope can't be relocated within the vault. Stale cleartext fields are `FieldValue.delete()`'d so a merge can't leave plaintext behind. Decode opens the envelope and falls back to legacy plaintext for not-yet-migrated docs.
- `CollaborationSyncService` resolves the CloudVault key (mirroring `SessionLogSyncService`/`CLIAgentSessionMirror`) and threads it through push/commit/pull/decode.
- `firestore.rules` `sharedArtifactSealedOwnerWrite` now **requires** a path-bound `sealedPayload` + `contentSealed` and **forbids** any cleartext content field, for both head and versions.
- **Verified:** new `firestore-rules-tests/shared-artifact-sealed.test.js` (9 cases) runs **green in the Firestore emulator**, and the **full existing rules suite still passes** (no regressions). Swift round-trip/no-plaintext/relocation/legacy unit tests added.

### V-34 — High (conditional) — wrap indexed `lastAssistantMessage` as untrusted  ✅ implemented + test
- `ContextBuilder` injected the latest indexed assistant line **raw** into two system prompts — the lone ingestion→prompt boundary not already wrapped. Both now route through `LLMSafeContent.wrapUntrusted` (OWASP LLM01). Regression test pins the breakout-defense contract.

### V-35 — Medium — gate the local MCP semantic-search tool  ✅ implemented + test-verified
- `tools/openburnbar-mcp` `burnbar_semantic_search_conversations` returned raw indexed conversation snippets with **no** capability gate (the cloud variant and sibling sensitive reads already gate). Added the standard `sensitive_read` gate (OFF by default, policy-audited). **Verified:** full MCP suite **43/43 green** (incl. a new default-deny policy test).

## How to verify my work
```
# Rules enforcement (the security-critical control) — runs the emulator:
git worktree add /tmp/bb-review remediation/opus-4-8-1m-2026-06-16   # or check out the branch
cd firestore-rules-tests && npm ci && npm run test:shared-artifact-sealed   # 9/9
npm run test:ci                                                              # full suite, green
```
Or read the changes without checking out: **`IMPLEMENTED-changes.patch`** (combined diff, 8 files / +827) and **`patches/`** (per-commit).

## Honest status / caveats
- **Firestore rules + emulator tests: executed and green here.** This is the server-side enforcement guarantee — even a buggy client can no longer write plaintext.
- **Python MCP tests (V-35): executed and green here** — full suite 43/43, including the new default-deny test.
- **Swift code: pattern-faithful but not compiled in this environment.** The isolated worktree has no resolved SPM/Firebase module graph, so `xcodebuild`/SourceKit can't run; every Swift symbol I used (`CloudVaultCrypto.sealPayload`/`openPayload`/`sealedPayloadDictionary`/`sealedPayload(from:)`, `CloudVaultAADContext`, `MacCloudVaultKeyAccess.keyForWriting/Reading`, `CloudVaultResolvedKey`, `LLMSafeContent.wrapUntrusted`) was verified against its real definition and an existing compiling call site. Run `xcodebuild test -scheme OpenBurnBar -only-testing:AgentLensTests/SharedArtifactCloudCodecSealingTests` on a full checkout to confirm.
- **Migration:** existing plaintext artifact docs remain readable (legacy decode) and re-seal on next write. Deploy the client seal before/with the strict rule (the branch does both, so they're consistent).

## Deliverables in this folder
| File | What |
|------|------|
| `00-EXECUTIVE-SUMMARY.md` | this |
| `01-VERIFICATION-REPORT.md` | 4-audit reconciliation, 38 verdicts, false-positive + already-fixed call-outs, auditor scorecard |
| `02-SOTA-2026-RESEARCH.md` | cited 2026 SOTA per domain (OWASP LLM, prompt-injection/CaMeL, SSRF, SQLCipher truth, App Check, XPC audit-token, SLSA/WIF, capabilities, push privacy, GDPR erasure) |
| `03-REMEDIATION-PLAN.md` | prioritized + **deduplicated against the parallel agents**; what's owned where; specs for unclaimed items |
| `IMPLEMENTED-changes.patch` / `patches/` | the actual code (V-10 + V-34) |

## Recommended next (unclaimed, specced in the plan)
V-27b CODEOWNERS path rules · V-24 SSRF undici DNS-pin (latent) · V-23a deletion-scope manifest + CI completeness test · V-37 parser size/depth caps · V-38 scope-escalation adversarial test · V-35 MCP local-snippet gate · V-32 macOS Sentry scrubber tests.
