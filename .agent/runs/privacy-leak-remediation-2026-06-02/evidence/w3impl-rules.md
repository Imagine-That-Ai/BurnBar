Each helper is defined exactly once. The shared helpers (`validCloudSealedText`, `rejectsPlaintextWhenSealed`) are reused, not redefined. All five rule blocks are complete and the test file syntax-checks clean. Task complete.

## CHANGELOG

### `firestore.rules` (FIVE blocks edited; shared helpers `validCloudSealedText`:449 + `rejectsPlaintextWhenSealed`:1013 reused, never redefined)

**(1) `approval_policies` (~:1609 `validApprovalPolicy`)** — Added to `hasOnly`: `sealedDisplayLabel`, `sealedFileGlob`, `sealedTargetProject`, `projectKeyHash`, `fileGlobHash`. Made plaintext `displayLabel`/`fileGlob`/`targetProject` optional and bounded (≤256/≤256/≤512). Added `rejectsPlaintextWhenSealed` for `displayLabel→sealedDisplayLabel`, `fileGlob→sealedFileGlob`, `targetProject→sealedTargetProject`; `validCloudSealedText` gate on each sealed field; `^[a-f0-9]{32}$` on both hashes. **New field names:** `sealedDisplayLabel`, `sealedFileGlob`, `sealedTargetProject`, `projectKeyHash`, `fileGlobHash`. Legacy plaintext stays bounded.

**(2) `cli_sessions/{id}/snapshots` (~:1675 `validRollbackSnapshot`)** — HARD-DROPPED plaintext `actionLabel`/`touchedFiles`/`macSnapshotPath` from `hasOnly` (no live writer → sealed-only from day one). Added `sealedActionLabel`, `sealedTouchedFiles`, `sealedMacSnapshotPath` (each `validCloudSealedText`-gated; `sealedTouchedFiles` is a single sealed JSON blob = one CloudVaultSealedText). Kept `sequence is int && >= 0`. **New field names:** `sealedActionLabel`, `sealedTouchedFiles`, `sealedMacSnapshotPath`.

**(3) `rollback_requests` (~:1646 `validRollbackRequest`)** — Added `sealedScope`, `sealedErrorMessage` to `hasOnly`. Added `rejectsPlaintextWhenSealed("scopeJSON","sealedScope")` + `("errorMessage","sealedErrorMessage")`; `validCloudSealedText` gate on each; kept legacy `scopeJSON`(≤4096)/`errorMessage`(≤2048) bounded. **New field names:** `sealedScope`, `sealedErrorMessage`.

**(4) `agent_identities` (~:1701)** — Replaced bare `size()<=24` with strict `validAgentIdentity()` `hasOnly` (non-private metadata `id`,`runtimeID`,`glyph`,`paletteHex`,`tier`,`availability`,`installSource`,`capabilities`,`dispatchTransport`,`lastSevenDays`,`lastRefreshedAt` + `sealedDisplayName`,`sealedTagline`,`sealedPersonas`,`updatedAt`). Added `rejectsPlaintextWhenSealed` for the three private fields, `validCloudSealedText` gates, AND outright `!("displayName"/"tagline"/"personas" in …)` denials (no legacy window — forward-declared). **New field names:** `sealedDisplayName`, `sealedTagline`, `sealedPersonas`.

**(5) `subscription_topics` (~:1732)** — Replaced bare `size()<=20` with `hasOnly` allowlist (`agentURI`,`topicID` + metadata + `sealedDisplayName`,`sealedDescription` + legacy `displayName`,`description` tolerated when sealed absent). Added `rejectsPlaintextWhenSealed` for both display fields, `validCloudSealedText` gates, kept existing `cadence`/`deliveryMode`/`minimumEventImportance`/`deliveryCountThisMonth` enum+int validators. merge:true partial writes (setMuted/setDeliveryMode) pass trivially (omit both keys). **New field names:** `sealedDisplayName`, `sealedDescription`.

### `functions/scripts/test-firestore-rules.mjs` (T13–T17 added before the final "rules test environment is isolated" test; mirror T11/T12 style, reuse `sealedText()`:134, `authedDb`, `assertSucceeds`/`assertFails`)

- **T13** (snapshots): sealed-all succeeds; plaintext `actionLabel`/`touchedFiles`/`macSnapshotPath` each fail (hard-dropped hasOnly); malformed sealed fails.
- **T14** (approval_policies): legacy plaintext-only succeeds; sealed (opaque doc ID + 32-hex hashes) succeeds; both-present fails (label/glob/project); non-hex `projectKeyHash` fails; unknown key fails.
- **T15** (rollback_requests): legacy plaintext scope succeeds; sealed scope+error succeeds; both-present fails (scope and error).
- **T16** (agent_identities): sealed succeeds; plaintext `displayName`/`personas` fail outright; arbitrary key fails (hasOnly); malformed sealed fails.
- **T17** (subscription_topics): sealed-only succeeds; legacy plaintext-only succeeds; both-present fails (displayName and description); arbitrary key fails.

`node --check functions/scripts/test-firestore-rules.mjs` → `SYNTAX_OK`.

### Deviations / notes
- agent_identities keeps both `rejectsPlaintextWhenSealed(...)` AND the outright `!("X" in …)` denials per the brief (the outright denial dominates; the `rejectsPlaintextWhenSealed` call is harmlessly redundant but matches the brief verbatim).
- I did NOT touch the registry.json honesty edits, the iOS/Android/Mac writers/readers, or the codegen step — those are owned by other streams (SE/S3/SC) per CONTRACT §STREAM OWNERSHIP. No builds run (central verify follows); only `node --check` per instructions.
- No blockers.