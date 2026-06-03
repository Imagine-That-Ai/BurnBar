`recent_usage/30d` carries `topProviders`/`topModels` only — no project names (no leak there). The `projects` collection on Android is read-only (no writer found). The leak surface is precisely: `usage.projectName` and `budgetRules.projectName`+`budgetRules.label`. I have everything needed for the design brief.

---

# RECON COMPLETE — DESIGN BRIEF: `usage` / `budgetRules` project-name plaintext leak

## 1. DATA FLOW (writer + every reader, file:line)

**`users/{uid}/usage/{usageId}` — field `projectName` (plaintext):**
- **WRITER (Mac, only writer):** `AgentLens/Services/CloudSync/UsageSyncService.swift:114` — `"projectName": usage.projectName` inside `encodeUsage(_:deviceId:)`. iOS and Android do **not** write usage docs (Android `usageCollection` at `android/.../firebase/FirestoreRepository.kt:69` is read-only; no `setData` on usage anywhere in iOS).
- **READERS (all on-device, all the same user's trusted devices):**
  - iOS decode: `OpenBurnBarMobile/Services/FirestoreRepository.swift:699` and `:776` (`data["projectName"]`)
  - Android decode: `android/.../firebase/FirestoreRepository.kt:402` (`toTokenUsage`)
  - iOS display: `Views/Pulse/RecentSessionsStripCard.swift:98 Text(usage.projectName)`, `Views/Streams/StreamsView.swift:452`, project grouping `Models/ProjectSummary.swift:61`
  - Mac display/grouping: `Views/Chat/InsightBriefCard.swift:67` (per-project cost sum), `Views/Dashboard/ProjectsView.swift:518` (`dataStore.usages.filter { $0.projectName == project.slug }`)
- **SERVER:** the only server code that opens `usage/{usageDoc}` is the rollup engine — Firestore trigger `functions/src/triggers.ts:28` → `applyUsageCounterDelta` (`rollups.ts:594`) → `usageContribution` (`rollups.ts:404`). It reads `provider/providerID/account/model/device/tokens/cost/date` and **never reads `projectName`**. Dedup key `logicalUsageKey` (`rollups.ts:251-258`) = `[provider, sessionId, deviceId, accountId, startedAt, tokenBucket]` — **no projectName**. The server's own type `UsageEventDoc` (`functions/src/types/legacy.ts:1200-1272`) **does not even declare `projectName`** — it is an undeclared passthrough field.

**`users/{uid}/budgetRules/{ruleId}` — fields `projectName` + `label` (plaintext):**
- **WRITERS (3 clients, peer cross-device sync):** Mac `AgentLens/Services/CloudBudgetService.swift:133` (`projectName`) + `:134` (`label`) in `encodeRule`; iOS `OpenBurnBarMobile/Models/BudgetRulesStore.swift:205`; Android `android/.../firebase/FirestoreRepository.kt:512` (`BudgetRule.toMap`).
- **READERS (all on-device):** Mac `CloudBudgetService.swift:100-116` reads peers' rules `whereField("sourceDeviceID", isNotEqualTo: deviceId)` → `decodeRule`; iOS `BudgetRulesStore.swift:284` → `toBudgetRule`; Android `FirestoreRepository.kt:539`. Display/match: iOS `BudgetSettings.swift:153 rules(forProject:)`, `BudgetGate.swift:80-81`, `BudgetCenterView.swift:537/990`.
- **SERVER:** **zero reads.** No `functions/src` code references `budgetRules`. Pure peer-to-peer sync of the same user.

## 2. SERVER-READ REQUIREMENT — definitive: **NO**

The server never needs `projectName`/`label` plaintext for any logic:
- **Budget enforcement** is 100% client-side (`OpenBurnBarMobile/Models/BudgetGate.swift`, `BudgetEnforcement.swift`; no server budget code exists). No Cloud Function reads `budgetRules`.
- **Aggregation/rollups** key on provider/account/model/device, never project (`rollups.ts:251-258`, `404-431`).
- **`getDataDomainUsage`** only `.count()`s the `usage` collection (`dataDomainUsage.ts:56,132`) — it reads cardinality, not field contents.
- **`serializeUsageForCallable`** (`shared.ts:508-543`, the only place server *touches* `projectName`, line 519) **has zero in-repo callers** — dead/echo-only path; even if live it only echoes the field back to the same authenticated owner for display.
- **`dataExport.ts:55-66`** classifies `usage`/`projects` as `server_readable` and bundles docs verbatim — no plaintext logic.
- **`demoSeed.ts:325-326`** is the only server *writer* of project name, and it writes **fabricated demo data** ("Demo project"), never real user text.

**Verdict: pure store-and-forward / client-display denormalization. This is sealable with no server functionality loss.**

## 3. VAULT-KEY AVAILABILITY — **YES, every reader holds the key**

Every reader of these fields is one of the same user's trusted devices (Mac/iOS/iPad/Android), each of which already resolves the Cloud Vault key for the *adjacent* sealed surfaces in the very same files: Android `AndroidCloudVaultKeyAccess.keyForWriting/keyForReading` + `CloudVaultCrypto.sealText/openText` (`android/.../data/cloud/CloudVaultCrypto.kt:67,88`); Swift `CloudVaultCrypto.sealText(_:keyData:)` / `openText` (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:124,129`). **No server or third party is a required reader.** E2E sealing is fully achievable.

## 4. RECOMMENDED FIX — **Option A: seal it.** SOTA, zero server-logic loss, reuses existing primitives.

Add a `sealedProjectName` field (and `sealedLabel` for budgetRules) using the **exact** primitives already sealing `session_logs.sealedTitle` and `text_snippets.sealedScope`:

**Crypto primitives to reuse (do NOT add new ones):**
- Swift: `CloudVaultCrypto.sealText(_:keyData:)` → `CloudVaultSealedText` (`OpenBurnBarCore/.../CloudVaultCrypto.swift:124`), serialized via the `dictionary(_:)` helper pattern at `SessionLogSyncService.swift:858`.
- Kotlin: `CloudVaultCrypto.sealText(text, vaultKey)` → `CloudVaultSealedText` + `sealedPayloadMap`-style map (`CloudVaultCrypto.kt:67`); key via `AndroidCloudVaultKeyAccess.keyForWriting`.
- TS type: `CloudVaultSealedTextDoc` (`functions/src/types/legacy.ts:915`) — add to `UsageEventDoc` so the schema is honest.

**For any per-project client aggregation that must survive without decrypt-all** (e.g. Mac `ProjectsView.swift:518` filtering usage by project, `InsightBriefCard.swift:67` summing cost per project): also write an **opaque keyed hash** `projectKeyHash = HMAC-SHA256(vaultKey, normalizedProjectName)` so clients/server can group-by-project on a stable token without plaintext. (This is the same "opaque token/semantic hash" pattern the registry already advertises for session_logs.) **Note:** server has no aggregation need today, so the hash is purely a client convenience to avoid N decrypts; if clients are willing to decrypt-then-group (small N, owner device), the hash is optional.

**Exact change points:**
1. `UsageSyncService.swift:114` — replace `"projectName": usage.projectName` with `"sealedProjectName": try dictionary(CloudVaultCrypto.sealText(usage.projectName, keyData: vaultKey))` (+ resolve vaultKey as the adjacent sync services do); add `"projectKeyHash"` if grouping retained. Drop plaintext `projectName`.
2. `CloudBudgetService.swift:133-134` — replace `projectName`/`label` with `sealedProjectName`/`sealedLabel` (sealText). Same in iOS `BudgetRulesStore.swift:205` and Android `FirestoreRepository.kt:512` (`toMap`).
3. All decoders (`FirestoreRepository.swift:699,776`; `FirestoreRepository.kt:402,539`; `BudgetRulesStore.swift:284`; `CloudBudgetService.swift decodeRule`) — open the sealed field with `openText`, with a legacy fallback that reads old plaintext `projectName` during migration.
4. `functions/src/types/legacy.ts:1200` — add `sealedProjectName?: CloudVaultSealedTextDoc` to `UsageEventDoc`; **delete** the dead `projectName` handling at `serializeUsageForCallable` `shared.ts:519` (or change it to pass through `sealedProjectName`).
5. `firestore.rules` — extend `hasNoPlaintextSecretFields()` (`firestore.rules:56-69`) **or** add a `usage`/`budgetRules`-specific validator that **rejects a plaintext `projectName`/`label` key on create/update** (lines 867-879), so the leak can't regress. This is the enforcement backstop.
6. `packages/data-domains/registry.json` — `usage_spend` (lines 12-25): remove `"project"` from `serverSees`, add `"opaque project hashes"`; add `"project names"`/`"budget labels"` to `deviceOnly`. Regenerate `gen/DataDomains.swift|kt|domains.ts` via `codegen.mjs`. This makes session_logs' existing `deviceOnly: ["project/path text"...]` claim (registry line ~53) finally *true across the whole app*.

## 5. PRODUCT FORK — present, but the code makes the answer near-certain

**The fork exists only because "server_readable" is a stated product posture for `usage_spend`** (registry line 15: `encryptionTier: "server_readable"`). Code proves the server never *needs* it, so this is a posture choice, not a capability constraint:

- **Option A (RECOMMENDED — seal):** project names + budget labels become E2E. Consequence: registry `usage_spend` drops "project" from `serverSees`; any *future* server-side per-project analytics would need the keyed-hash, not plaintext. Eliminates the confirmed leak and resolves the session_logs-vs-usage contradiction (today session_logs *promises* project text is device-only while usage ships the same names in clear — A makes the promise honest). **No feature regresses** because no server feature reads it.
- **Option B (keep server-readable, relabel):** leave `projectName` plaintext and instead make `session_logs`' `deviceOnly` claim honest by *removing* "project/path text" from it and admitting project names ARE server-visible via `usage`. Consequence: a permanent privacy downgrade of the marketed posture and a louder adversarial-review finding; the only upside is zero client work.

**Decision Alberto must ratify:** "Are project names / working-dir labels / budget labels considered private text that BurnBar must not be able to read?" Given the completion-bar standard and that the registry *already* markets these as device-only for the sibling domain, **A is the coherent SOTA path.** Recommend A unless Alberto explicitly wants hosted per-project analytics (none exists today).

## 6. BLAST RADIUS (lockstep changes)

- **Functions:** `types/legacy.ts` (UsageEventDoc), `callables/shared.ts:519` (serializeUsageForCallable — dead path, align/remove), `demoSeed.ts:325-326` (seed must write sealed/hash shape or be exempted), `firestore.rules:56-69 & 867-879`.
- **Generated:** `packages/data-domains/registry.json` + regenerate `gen/DataDomains.swift`, `gen/DataDomains.kt`, `gen/domains.ts` (`codegen.mjs`); `registry.test.mjs`/`driftcheck.mjs` will fail until regen.
- **Mac:** `UsageSyncService.swift`, `CloudBudgetService.swift` (encode+decode), display readers tolerate decrypt (`InsightBriefCard.swift:67`, `ProjectsView.swift:518`, `SessionLogsView.swift` group-by).
- **iOS:** `FirestoreRepository.swift:699,776`, `BudgetRulesStore.swift:205,284`, `ProjectSummary.swift:61`, `BudgetSettings.swift:153`/`BudgetGate.swift` (match on decrypted or on hash).
- **Android:** `FirestoreRepository.kt:402,512,539` (toTokenUsage / toMap / toBudgetRule), reuse `CloudVaultCrypto.sealText/openText` + `AndroidCloudVaultKeyAccess`.
- **Tests:** `AgentLensTests/Active/UsageSyncRoundTripTests.swift` (asserts `projectName` at lines 45,81,259,322,344,354,471,596 — must round-trip through seal/open), `functions/src/__tests__/dataDomainUsage.test.ts`, data-domains drift tests. Add new round-trip tests proving the server cannot read the field.
- **Docs:** `docs/PENSIEVE_CONTROL_CENTER.md`, `docs/android-budgeting-port-handoff.md`, `docs/ios-budgeting-port-handoff.md`, `droid-wiki/reference/data-models.md`, `droid-wiki/features/budget-governance.md` (and mem0 mirror) — update the usage/budget privacy posture.
- **Migration:** existing docs carry plaintext `projectName`/`label`; decoders need a legacy fallback (read plaintext if `sealedProjectName` absent), and a one-shot re-seal pass on next sync. The rules change must allow the transition (don't hard-reject until clients ship), or gate the plaintext-rejection behind a schema flag.

---

## DESIGN BRIEF

1. **Posture decision (Alberto):** ratify Option A — project names, working-dir labels, and budget labels are private text BurnBar must not read. (Code shows zero server dependency; this only contradicts the `usage_spend` "server_readable" label, which we will change.)
2. **Add sealed fields** using existing primitives only — Swift `CloudVaultCrypto.sealText(_:keyData:)`/`openText` (`OpenBurnBarCore/.../CloudVaultCrypto.swift:124`), Kotlin `CloudVaultCrypto.sealText/openText` (`CloudVaultCrypto.kt:67`), TS `CloudVaultSealedTextDoc` (`legacy.ts:915`).
3. **usage doc:** `UsageSyncService.swift:114` → write `sealedProjectName` (CloudVaultSealedText dict) + optional `projectKeyHash = HMAC(vaultKey, normalized)`; stop writing plaintext `projectName`. Update readers `FirestoreRepository.swift:699,776`, `FirestoreRepository.kt:402` to `openText` with legacy plaintext fallback. Add `sealedProjectName?: CloudVaultSealedTextDoc` to `UsageEventDoc` (`legacy.ts:1200`); fix/remove dead `serializeUsageForCallable` line 519.
4. **budgetRules doc:** seal `projectName`→`sealedProjectName` and `label`→`sealedLabel` in all 3 writers (`CloudBudgetService.swift:133-134`, `BudgetRulesStore.swift:205`, `FirestoreRepository.kt:512`); open in all 3 decoders (`CloudBudgetService.swift decodeRule`, `BudgetRulesStore.swift:284`, `FirestoreRepository.kt:539`). Client budget matching (`BudgetSettings.swift:153`, `BudgetGate.swift:80`) matches on decrypted value or on `projectKeyHash`.
5. **Rules backstop:** in `firestore.rules` extend the `usage` (867-871) and `budgetRules` (875-879) create/update to **reject plaintext `projectName`/`label`** once clients ship (gate behind schemaVersion to allow migration). Keep `hasNoPlaintextSecretFields()` as the generic guard.
6. **Registry truth:** edit `packages/data-domains/registry.json` `usage_spend` — drop `"project"` from `serverSees`, add project names/budget labels to `deviceOnly`, note `"opaque project hashes"`; regenerate `gen/*` via `codegen.mjs`; fix `registry.test.mjs`/`driftcheck.mjs`.
7. **Migration:** decoders fall back to legacy plaintext when sealed field absent; trigger a re-seal on next sync; `demoSeed.ts:325-326` writes the new sealed/hash shape (or is exempted from drift assertions).
8. **Tests:** update `UsageSyncRoundTripTests.swift` to assert seal→open round-trip and that a server-side decode of the raw doc yields no plaintext project name; add equivalent Android/iOS budget round-trip tests; refresh `dataDomainUsage.test.ts` and data-domain drift tests.
9. **Docs/mem0:** update PENSIEVE control-center, budgeting handoffs, and `droid-wiki/reference/data-models.md` + `features/budget-governance.md` to state usage/budget project text is now E2E-sealed; re-mirror to mem0.

**Key primitives by name (reuse, do not reinvent):** `CloudVaultCrypto.sealText` / `openText` (Swift `OpenBurnBarCore/.../CloudVaultCrypto.swift:124,129`; Kotlin `CloudVaultCrypto.kt:67,88`), `CloudVaultSealedText` / `CloudVaultSealedTextDoc` (`legacy.ts:915`), key resolution `AndroidCloudVaultKeyAccess.keyForWriting/Reading` and the Mac/iOS vault-key accessors already used by the sibling sync services.