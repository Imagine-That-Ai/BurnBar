The legacy.ts diff is scoped exactly to `SubscriptionTopicDoc` (10 insertions, 2 deletions, only that interface). Everything is complete and verified.

## CHANGELOG

### `packages/data-domains/registry.json` (OWNED — edited)
- **`conversations_chat` domain:** de-excluded `rollback_requests` and folded it in. Added `"rollback_requests"` to `firestorePaths`; added `"rollback scope paths"` + `"rollback error diagnostics"` to `deviceOnly`; extended `summary` to mention "rollback scope/diagnostics … sealed on-device."
- **`excludedCollections`:** removed the `rollback_requests` entry (now owned by `conversations_chat`, so driftcheck stays green via its first-path-segment coverage). Rewrote three understated one-liners to state the sealed-text contract:
  - `approval_policies`: now states project paths/file-glob/label are sealed (`sealedTargetProject`/`sealedFileGlob`/`sealedDisplayLabel`), doc ID is an opaque keyed hash, "Server never sees plaintext or runs matching."
  - `agent_identities`: now states any cloud copy seals `displayName`/`tagline`/`personas`, "server stores only opaque sealed envelopes … never plaintext."
  - `subscription_topics`: now states `displayName`/`description` are sealed (`sealedDisplayName`/`sealedDescription`), "written phone/tablet-only, never server-read."
- `cli_sessions/*/snapshots`: **no text change** — already covered by `conversations_chat` (top segment `cli_sessions`); sealing makes the existing `"project/file/command labels"` deviceOnly claim honest, as the brief specified.

### Regen (codegen + gradle — generated outputs, not hand-edited)
- Ran `node packages/data-domains/codegen.mjs` → regenerated `gen/DataDomains.kt`, `gen/DataDomains.swift`, `gen/domains.ts`, `website/src/data/trust.generated.ts`.
- Ran `cd android && ./gradlew :app:syncGeneratedSources --no-daemon` (gradle available, BUILD SUCCESSFUL) → synced `android/.../data/domains/DataDomains.kt`. Verified byte-for-byte equal to `gen/DataDomains.kt` (`diff` clean). The Android in-tree copy now contains `rollback_requests`.

### `packages/data-domains/registry.test.mjs` (OWNED — extended)
- Added test `"HONEST CLAIMS: rollback_requests is folded into the sealed conversations_chat domain…"` — asserts `rollback_requests` is in `conversations_chat.firestorePaths`, removed from `excludedCollections`, and the rollback scope/error deviceOnly facets are present.
- Added test `"HONEST CLAIMS: sealed device-only excluded collections state the sealed-text contract"` — asserts `approval_policies`/`agent_identities`/`subscription_topics` reasons mention seal + vault key + "never" and don't regress to the old understated one-liners.
- Result: 16/16 tests pass; no-drift test confirms 94 subcollections accounted for.

### `functions/src/types/legacy.ts` (OWNED — `SubscriptionTopicDoc` ONLY, ~3077)
- Made `displayName?`/`description?` optional (legacy plaintext fallback).
- Added `sealedDisplayName?: CloudVaultSealedTextDoc` and `sealedDescription?: CloudVaultSealedTextDoc`. `CloudVaultSealedTextDoc` is defined at line 918 (resolves). No other interface touched.

### `scripts/privacy/scan-chat-cloud-plaintext.mjs` (OWNED — extended)
- Added a `W3_SEALED_SURFACES` table-driven block asserting, per rule block (`approval_policies`, `cli_sessions/*/snapshots`, `rollback_requests`, `agent_identities`, `subscription_topics`): (a) semantic `keys().hasOnly([` allowlist presence; (b) `validCloudSealedText(…sealedField)` for every sealed field; (c) plaintext-key rejection — `rejectsPlaintextWhenSealed` for migration-safe surfaces, outright `!("x" in …)` for `agent_identities` (no legacy window), and **absent-from-allowlist** for `cli_sessions/*/snapshots` (sealed-only from day one, no live writer).
- Extended `assertRegistryPrivacyHonesty` to mirror the registry-test rollback-fold + excluded-collection sealed-contract checks.
- `node --check` passes.

### Scanner run result — **NOT the anticipated failure**
The assignment expected `node scripts/privacy/scan-chat-cloud-plaintext.mjs` to fail until W3-rules lands. **It passes (exit 0)** because the SD rules stream has already landed all five hardened rule blocks in `firestore.rules` (lines 1609, 1646, 1675, 1701, 1732). My new W3 scanner coverage validates those already-present blocks and all pre-existing assertions stay green.

### Deviations / notes
- **No blockers.** Gradle was available, so I used `./gradlew :app:syncGeneratedSources` (not the copy fallback).
- The five `firestore.rules` blocks my scanner asserts against are owned by stream SD and were already committed before this pass; I only read them to confirm my section boundaries and field names match. I edited none of them.
- I did not hand-edit any `gen/*`, `DataDomains.kt`, or `trust.generated.ts` — all are codegen/gradle outputs of my `registry.json` edit.