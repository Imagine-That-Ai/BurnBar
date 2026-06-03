# Seal all confirmed server-readable private-text leaks

Goal ID: `privacy-leak-remediation-2026-06-02`
Started: 2026-06-03T04:48:00Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/privacy-leak-remediation-2026-06-02/`

## Objective

Close every confirmed cloud-plaintext leak (Hermes Gateway, project_memory, dataExport, knowledge_repos, usage/budget project text, Pensieve), convert denylist rules to hasOnly, fix client regressions, make trust copy honest, expand scanner+tests+scrubber, and verify across all platforms

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/privacy-leak-remediation-2026-06-02/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

Each confirmed leak from the 2026-06-02 adversarial review is closed with the real fix (seal or honest-label by design), plus rules, tests, docs, and verification:

- [done] **P0 Hermes Gateway**: recon proved it's a store-and-forward bridge to a KEYLESS third-party adapter → true E2E = re-architecture (chained goal `hermes-gateway-e2e-rearchitecture`). THIS pass corrected the dishonest `deviceOnly` "sealed" claim (registry/website/docs now honest; tier was already server_readable). E2E itself deferred per Alberto's ratified plan.
- [done] **P1 project_memory_snapshots**: sealed name + opaque deterministic doc id `pm_+HMAC(slug)`; encryptedSearch.ts drops name/slug, honors `legacyDocID` delete; rules reject plaintext. Verified (rules T11, encrypted-search tests).
- [done] **P1 dataExport**: `sealAwareSerializeDoc` default-deny on end_to_end/zero_access (sealed envelopes + opaque columns + `redactedFields`). Verified (dataExport.test.ts).
- [done] **P1 knowledge_repos + Pensieve**: server-keyed `repoMatchToken` + `sealedRepoFullName`; cloaking enforced (raw embeddings rejected); keyless dedup oracle removed → vault-keyed dedupHash/slugHmac. Verified (vitest).
- [done] **P2 usage/budget project text**: `sealedProjectName`/`sealedLabel` + `projectKeyHash` across Mac/iOS/Android (incl. peer-download readers); rules reject plaintext when sealed; registry honest. Verified (rules T12, Mac app UsageSync+BudgetRule round-trips).
- [done] **Rules**: `session_logs` manifest/chunk, `chat_threads`, `media_*` → strict `hasOnly()`; `sealedFilename`; `validMobileMissionCancel`. Verified (rules 40→45/45).
- [done] **Client regressions fixed**: iOS cancel/merge/rename sealed; Android `ThreadInboxStore` sealed read; Android rename fallback no longer attempts a rejected plaintext write. Verified (rules + Android compile).
- [done] **Scanner**: covers project_memory/gateway/knowledge/media (+ Wave-3 surfaces) + semantic `hasOnly()` check. Verified (scan PASS).
- [done] **Scrubber + migration**: extended; idempotent `privacyBackfill` callable (gated deletes + reseal watermark). Verified (vitest).
- [done] **Honesty**: registry.json + regenerated gen/* + website trust + docs match enforced reality. Verified (data-domains 16/16 incl. honesty asserts).
- [done] **WAVE 3 (Alberto: seal them all)**: approval_policies (sealed + opaque doc id), cli_sessions/{id}/snapshots, rollback_requests, agent_identities, subscription_topics all sealed/hardened. Verified (rules T13-T17, Android compile, scan). iOS compile pending build confirmation.
- [doing] **Validation**: scan PASS; functions build clean; rules 45/45; agent-notifications PASS; data-domains 16/16; Android compile 0 errors; Mac app UsageSync+BudgetRule round-trips PASS; adversarial closure re-scan confirmed all named leaks CLOSED. REMAINING: iOS OpenBurnBarMobile build-for-testing (in progress).
- [done] Keep `implementation-notes.html` current; evidence/ holds recon + changelogs + closure proof.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

