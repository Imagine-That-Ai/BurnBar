All changes are intact and verified on disk. Every owned deliverable is complete: registry honesty edits + regenerated gen/Android/website, console repo-display from sealed name, website/docs honesty, semantic scanner + scrubber, and the idempotent migration backfill with tests (functions + console both typecheck clean, registry tests 14/14 green).

## CHANGELOG

### `packages/data-domains/registry.json` (edited)
- **`usage_spend`** (§1): dropped `"project"` from `serverSees`; added `"opaque project hashes"`. Added `"project names"` + `"budget labels"` to `deviceOnly`. Summary now states project names/budget labels are sealed on-device and the server groups only by opaque per-project hashes.
- **`pensieve`** (§3/§4): `serverSees` now lists `"opaque keyed slug/dedup hashes"` + `"opaque repo match token"` (replacing cleartext `sourceSlug`); added `"repo names"` to `deviceOnly`; appended a `NOTE:` caveat — a connected repo stores only an opaque keyed match token + sealed repo name; the cleartext repo name is observed transiently server-side only for GitHub-webhook routing, never stored.
- **`connected_devices`** (§8): `serverSees` now names the readable `"hosted chat gateway message text"`, `"...sender names"`, `"...attachment file names"`; `deviceOnly` rewritten from `"relayed payload contents (sealed per their own domains)"` to `"end-to-end relay frame contents (sealed per their own domains)"` so it no longer claims gateway payloads are sealed; summary NOTE distinguishes sealed relay from server-readable gateway chat and discloses the committed gateway E2E migration.
- **`excludedCollections`**: added `high_risk_action_nonces` (pre-existing drift — see Blockers).

### Regenerated (never hand-edited)
- `packages/data-domains/gen/{domains.ts,DataDomains.swift,DataDomains.kt}` + `website/src/data/trust.generated.ts` via `node packages/data-domains/codegen.mjs`.
- `android/.../data/domains/DataDomains.kt` via `./gradlew :app:syncGeneratedSources --no-daemon` (BUILD SUCCESSFUL); verified byte-identical to gen output.

### `packages/data-domains/registry.test.mjs` (edited)
- Added 3 honesty tests: `usage_spend hides project names behind an opaque hash`; `pensieve repo names are device-only with a webhook caveat`; `connected_devices distinguishes sealed relay from readable gateway chat`. Suite now 14/14 pass.

### `apps/console/lib/repoDisplay.ts` (new)
- New helpers `sealRepoFullName(repoFullName)` / `openRepoFullName(sealed)` + `RepoDisplayError`, reusing `escrow.ts` `sealText`/`openText`/`importVaultKey` and `vaultKeySession` (`getConsoleVaultCryptoKey`/`getConsoleVaultKeyBytes`). `openRepoFullName` returns `null` for legacy rows (LEGACY FALLBACK).

### `apps/console/components/pensieve/PensieveDashboard.tsx` (edited)
- `connectRepository()` now seals the repo name client-side (`sealRepoFullName`) and calls `connectKnowledgeRepo` with `sealedRepoFullName` + derived `sourceSlug` — never sending cleartext for storage. New `connectError` state; explanatory copy states the displayed name is decrypted locally from `sealedRepoFullName`, never the server row. Callable name read from `PENSIEVE.callables.connectRepo`.

### `website/src/pages/privacy.astro` (edited)
- Zone C relay bullet + "Hermes Remote Relay" opt-in scoped the "never sees plaintext" claim to the **end-to-end device-to-device relay**; both now disclose that the separate hosted chat gateway carries readable message text in transit with a committed E2E migration.

### Docs (edited)
- `docs/PROVIDERS.md`: new "Relay vs. hosted chat gateway — plaintext posture" section.
- `docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md`: new "Project-identity text is sealed, even in doc ids" subsection (project_memory_snapshots opaque `pm_` HMAC doc id, no `projectDisplayName`/name-slug; `knowledge_repos` opaque `repoMatchToken` + `sealedRepoFullName`, cleartext name webhook-transient only).
- `docs/PENSIEVE.md`: threat model + Firestore notes updated (opaque `repoMatchToken`/`sealedRepoFullName`; v0 `contentHash` dedup oracle removed; rules reject client cleartext `repoFullName`).
- `docs/pensieve-leakage-analysis.md`: `dedupHashVersion` now flag-day-enforced (v1 only; raw `embedding`/`contentHash` rejected; forced re-ingest via watermark bump).

### `scripts/privacy/scan-chat-cloud-plaintext.mjs` (edited)
- Added `assertRulesSectionHasOnly()` **semantic** check and applied it to 11 sensitive helpers (mirrors, relay, session-log, project_memory, media). Added coverage: `project_memory_snapshots` (rejects `projectDisplayName`/`projectSlug`, `schemaVersion>=2`); `knowledge_repos` (rejects cleartext `repoFullName`); `hermes_gateway_messages/events/attachments` (`allow write: if false`, via new `assertRulesBlockDeniesClientWrite()`); `media_attachment_manifests` (`sealedFilename` validation, no raw `body`). Added `assertRegistryPrivacyHonesty()` mirroring the registry honesty checks. `node --check` passes.

### `scripts/privacy/scrub-chat-cloud-plaintext.mjs` (edited)
- Added collections: `project_memory_snapshots` (`projectDisplayName`,`projectSlug`), `text_snippets`, `hermes_gateway_messages/events/attachments`, and a relay sub-walk for `hermes_relay_requests`/`pi_agent_relay_requests` + their `/chunks` (legacy `path,sessionId,body,error,data,text`). Help text updated. `node --check` passes.

### `functions/src/callables/privacyBackfill.ts` (new) + `functions/src/index.ts` (edited)
- New idempotent, owner-scoped callable `backfillPrivacyPlaintext` + daily `backfillPrivacyPlaintextScheduled`. Deletes a legacy plaintext field **only when its sealed gate field is present** (`gatedDeletions`; `requires` map covers usage `projectName`→`sealedProjectName`, budgetRules `projectName`/`label`→`sealedProjectName`/`sealedLabel`, chat mirrors `customTitle`/`title`/`preview`/`messages`→`sealedPayload`, project_memory `projectDisplayName`/`projectSlug`→`sealedSnapshot`, knowledge_repos `repoFullName`→`sealedRepoFullName`). Bumps a per-user reseal watermark `users/{uid}/privacy_reseal_state/current.resealEpoch` (`PRIVACY_RESEAL_EPOCH=1`) for client-driven re-seal. Registered in `index.ts` as a **new appended export line** (lowest-conflict; no overlap with existing grouped exports).

### `functions/src/__tests__/privacyBackfill.test.ts` (new)
- Tests the safe-by-construction gate, plan coverage (every gated field has a sealed `requires`), and an end-to-end idempotency run over an in-memory Firestore double (plaintext stripped only where sealed exists, ungated preserved, watermark bumped once, second run is a no-op).

### Verification performed (no builds/emulator)
- `node packages/data-domains/codegen.mjs` (clean), registry tests 14/14 pass, Android `DataDomains.kt` byte-matches gen, scanner/scrubber `node --check` pass, **functions `tsc --noEmit` = 0 errors**, **console `tsc --noEmit` = 0 errors**.

### Blockers / cross-stream dependencies (flagged for orchestrator)
1. **Scanner correctly fails on one SD-owned gap**: `firestore.rules: knowledge_repos must reject client-supplied cleartext repoFullName`. The `knowledge_repos` rules block (firestore.rules:1890) still has no `hasOnly`/`repoFullName` rejection — that change is owned by **stream SD** per CONTRACT §4. My scanner assertion is written to the locked target state; it goes green once SD lands the `knowledge_repos` rule (`!("repoFullName" in request.resource.data)` + allowlist). This is the intended honest failure, not a bug in my code.
2. **Pre-existing drift fixed**: `high_risk_action_nonces` was uncovered by the registry drift check **before** my edits (confirmed against HEAD registry). I added it to `excludedCollections` (ephemeral server-issued anti-replay nonces) to make the drift test green; if SD/orchestrator prefers it under a domain's `firestorePaths`, move it there and revert this one line.
3. **`index.ts` is shared**: I added one appended `export { backfillPrivacyPlaintext, backfillPrivacyPlaintextScheduled }` line for a brand-new module — no overlap with other streams' export blocks. If SA appends near the same spot, a trivial merge picks both lines.
4. The console connect flow assumes `connectKnowledgeRepo` accepts `{ sealedRepoFullName, sourceSlug }` (SA's §4 callable change). Until SA lands that signature, the console seals correctly but the server may ignore `sealedRepoFullName` — no console code change needed once SA's callable is in.