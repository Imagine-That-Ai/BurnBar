Confirmed the correct pattern: `AssistantChatHistoryStore.updateThreadMetadata` mutates the full in-memory `thread` then calls `upsert(thread)`, which re-seals the entire thread (customTitle inside `sealedPayload`) via the sealed-write path at line 466. This is the SOTA model for cli_sessions renames too.

I now have complete, definitive recon across all four surfaces with file:line precision. Here is the design brief.

---

# Privacy-Leak Recon — Client write/read regressions from the tightened rules

## Scope verdict (4 surfaces, 3 real regressions + 1 already-correct)

| # | Surface | Verdict |
|---|---|---|
| A | iOS `cancelMission` raw `liveSummary` | **REGRESSION** (rule reject + plaintext leak) |
| B | iOS `mergeMissionGroup` raw `synthesisSummary` | **REGRESSION** (rule reject + plaintext leak) |
| C | iOS `updateSessionMetadata` raw `customTitle` (cli_sessions) | **REGRESSION** (rule reject + plaintext leak) — plus a 2nd identical class on iOS/Android `mobile_assistant_chats` already-correct vs cli_sessions broken |
| D | Android `parseCLISession` plaintext-only read (no sealed branch) | **REGRESSION** (silent data loss after Mac switches to sealed writes; renders nothing/wrong) |
| — | iOS `respondToApproval` (brief's ~519) | **NOT a regression** — it delegates to the App-Check callable `respondMissionApproval`, which writes only non-private status fields with admin privileges. No client write, no plaintext. Leave as-is. |

---

## 1. DATA FLOW (writer + every reader)

### cli_agent_mission_requests (`users/{uid}/cli_agent_mission_requests/{id}`)
- **Writers (client):** iOS `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift` `cancelMission` (lines 526–541) writes `{status, liveSummary(raw), updatedAt}`; Android `android/.../assistants/CLIAgentMissionDispatcher.kt` `cancelMission` (lines 403–421) writes via `sealedMissionStateUpdate(...)` (lines 93–119) → seals `liveSummary` into `sealedStatePayload`.
- **Writer (server):** functions `respondMissionApproval` (`functions/src/callables/computerUseSecurity.ts:361`) writes only `{approvalStatus, approvalRespondedAt, approvedByDeviceId, updatedAt}` — no private text.
- **Readers:** iOS `CLIAgentMissionDispatcher.swift` `CLIAgentMissionSnapshot` decode (line 1036 opens `sealedStatePayload`, line 1067 prefers `statePrivate.liveSummary`); Android `toMissionSnapshot` (CLIAgentMissionDispatcher.kt:847 `openMissionPayload(get("sealedStatePayload"))`, line 870 prefers `statePrivate.liveSummary`).

### mission_groups (`users/{uid}/mission_groups/{groupId}`)
- **Writers:** iOS `mergeMissionGroup` (CLIAgentMissionDispatcher.swift:484–501) writes `{phase, winnerMissionID, synthesisSummary(raw)}`; Android dispatch seals via `CLIAgentMissionRequestPayloadFactory.sealGroupPayload` (CLIAgentMissionDispatcher.kt:563–579) putting `synthesisSummary`/`title`/`prompt`/`targetProject` into `sealedPayload`.
- **Readers:** iOS `MissionGroupDocument` (CLIAgentMissionDispatcher.swift ~470–477 with `vaultKey`); Android `MissionGroupDocument(documentID, data, vaultKey)`.

### cli_sessions (`users/{uid}/cli_sessions/{sessionId}`)
- **Authoritative writer (Mac):** `AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift:113,162` calls `CLIAgentSessionCodec.encodeSealed(...)` + `setData(merge:true)`. `encodeSealed` (`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift:432–478`) JSON-encodes the **entire** `CLIAgentSessionRecord` — **including `customTitle`** — into `sealedPayload`; top-level dict (lines 443–456) carries only non-private metadata (`labelColorHex`, `isPinned`, `priorityOrder` allowed; `customTitle` deliberately NOT top-level).
- **Partial writers (clients):** iOS `CLIAgentChatReader.updateSessionMetadata` (CLIAgentChatReader.swift:144–174) writes top-level `customTitle` (line 156) — **broken**; Android `ThreadInboxStore.updateSessionMetadata` (ThreadInboxStore.kt:159–191) writes top-level `customTitle` (line 175) — **broken**.
- **Readers:** iOS `CLIAgentChatFirestoreSource.decodeDocument` (CLIAgentChatReader.swift:224–234) → `CLIAgentSessionCodec.decodeSealed` (sealed) / `.decode` (legacy); Android `ThreadInboxStore.parseCLISession` (ThreadInboxStore.kt:195–224) reads **only plaintext** `data["title"]`, `data["messages"]`, `data["customTitle"]` — **no sealed branch** → **broken read**.

### mobile_assistant_chats (parallel, for completeness)
- iOS `MobileChatHistoryStore` writes the **whole** thread sealed (customTitle inside `sealedPayload`, line 390+) and reads with a sealed branch (line 559). Android `AssistantChatHistoryStore.updateThreadMetadata` (line 273) mutates the in-memory thread then `upsert(thread)` re-seals everything (customTitle in `sealedPayload`, line 466+). **Both correct — this is the reference pattern for the cli_sessions fix.**

---

## 2. SERVER-READ REQUIREMENT — definitive

No Cloud Function reads `liveSummary`, `synthesisSummary`, or `customTitle`. `respondMissionApproval` (`functions/src/callables/computerUseSecurity.ts:315–384`) only reads `status`/`approvalStatus`/device trust and writes status fields. These mission/session docs are pure **store-and-forward / denormalization** between the user's own devices. **Decision: SEAL, do not honest-label.** Every reader is the user's own client and has the vault key.

## 3. VAULT-KEY AVAILABILITY — confirmed for all readers
- iOS write key: `MobileCloudVaultKeyAccess.keyForWriting(uid:)` (MobileCloudVaultKeyAccess.swift:26) → `MobileCloudVaultResolvedKey{keyData, vaultKeyID}`; read key `keyForReading` (line 55).
- Android: `AndroidCloudVaultKeyAccess.keyForWriting` / `keyForReading` (`android/.../data/cloud/CloudVaultCrypto.kt:249,256`); `CloudVaultCrypto.openPayload` (line 135), `sealedPayloadFromMap` (line 158), `sealedPayloadMap`. All present. E2E sealing is fully feasible on every path.

## 4. RECOMMENDED FIX — minimal-drift, reuse existing primitives

### Fix A — iOS `cancelMission` (mirror Android `sealedMissionStateUpdate`)
`OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift:526–541`. Make `async throws`-await the write key, seal the user-facing summary, and write the sealed-state fields the rule expects. Reuse existing `CLIAgentMissionCloudSealer.seal` (line 45) and `CLIAgentMissionPrivatePayload` (line 7). Produce:
```
let key = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid)
let sealedState = try CLIAgentMissionCloudSealer.seal(
    CLIAgentMissionPrivatePayload(liveSummary: "Mission cancelled by user."),
    vaultKey: key.keyData, vaultKeyID: key.vaultKeyID)
.setData([
  "status": "cancelled",
  "contentSealed": true,
  "sealedStatePayload": sealedState,
  "sealedStateSchemaVersion": 1,
  "sealedStateVaultKeyID": key.vaultKeyID,
  "updatedAt": FieldValue.serverTimestamp()
], merge: true)
```
Drop the raw `"liveSummary"` key entirely. This satisfies `validCliAgentMissionRequest` (rules 1116–1122) — note: `cancelMission` is an UPDATE, so it must pass the `allow update` branch (rules 1231–1237). A status-only cancel is **not** covered by `validTrustedMissionHostUpdate`/`validMobileMissionApprovalResponse`/`validMissionRefusalOrFailureUpdate`. **PRODUCT FORK below applies here.**

### Fix B — iOS `mergeMissionGroup` (mirror Android `sealGroupPayload`)
`CLIAgentMissionDispatcher.swift:484–501`. The doc must always re-satisfy `validMissionGroup` (rules 1366–1393), which forbids top-level `title`/`prompt`/`targetProject`/`synthesisSummary` (line 1376) and requires `contentSealed==true` + full `sealedPayload`. A `merge:true` partial of only `{phase, winnerMissionID, synthesisSummary}` will **fail** because `validMissionGroup` validates the merged resource and synthesisSummary must be sealed. Correct fix: seal `synthesisSummary` into `sealedStatePayload` (rules allow optional `sealedStatePayload`/`sealedStateSchemaVersion`/`sealedStateVaultKeyID`, lines 1374, 1380–1383):
```
let key = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid)
var update = ["phase": .merged, "updatedAt": serverTimestamp(), "contentSealed": true]
if let winnerMissionID { update["winnerMissionID"] = winnerMissionID }
if let synthesisSummary {
  update["sealedStatePayload"] = try CLIAgentMissionCloudSealer.seal(
      CLIAgentMissionPrivatePayload(synthesisSummary: synthesisSummary),
      vaultKey: key.keyData, vaultKeyID: key.vaultKeyID)
  update["sealedStateSchemaVersion"] = 1
  update["sealedStateVaultKeyID"] = key.vaultKeyID
}
```
iOS reader already opens `sealedStatePayload` for `synthesisSummary` — confirm `MissionGroupDocument` reads `statePrivate?.synthesisSummary` (it uses the same `CLIAgentMissionPrivatePayload` which has the field at line 17). **Note:** `merge:true` on mission_groups is unsafe because `validMissionGroup` re-validates required top-level fields (`childMissionIDs`, `runtimeTokens`, `parallelismLimit`, `mergeStrategy`, etc.). Confirm Firestore `merge:true` only validates the **post-merge** document; since the existing doc already carries those, `merge:true` keeps them — acceptable.

### Exact sealed schema iOS must produce (= Android's, for A & B)
- `cli_agent_mission_requests` state: top-level `contentSealed:true`, `sealedStatePayload:{...envelope}`, `sealedStateSchemaVersion:1`, `sealedStateVaultKeyID:<id>`; private JSON fields inside: `CLIAgentMissionPrivatePayload{liveSummary, resultPreview, errorMessage, approvalTitle, approvalMessage}` (Android `AndroidMissionPrivatePayload`, dispatcher.kt:32–43, sealed at 106–117).
- `mission_groups`: `sealedPayload` (request) holds `{title, prompt, targetProject, synthesisSummary}`; for the merge update, `synthesisSummary` goes in `sealedStatePayload` with the same triplet of state fields.

### Fix C — cli_sessions rename (iOS + Android `updateSessionMetadata`)
`customTitle` is private text and is **not** in `validCliSessionMirror.hasOnly` (rules 1006–1026) nor `validMobileAssistantChatMirror.hasOnly` (rules 966–981). It only legally exists inside `sealedPayload` (via `CLIAgentSessionCodec.encodeSealed`, record JSON line 417–419). **Two coherent options — PRODUCT FORK C below.** Recommended (mirrors the already-correct `AssistantChatHistoryStore` pattern): the rename must re-seal the **whole** record. Both `updateSessionMetadata` functions must:
1. Fetch the current sealed doc, `decodeSealed`/`parseCLISession`→full record (need the vault key).
2. Set `record.customTitle` (+ optional `labelColorHex`/`isPinned`/`priorityOrder`).
3. Re-write via `CLIAgentSessionCodec.encodeSealed(record, vaultKey, vaultKeyID)` + `setData(merge:true)` (iOS) / `set(payload)` (Android).
   `labelColorHex`/`isPinned`/`priorityOrder` MAY stay as the existing top-level `merge:true` write (allowed by rules); only `customTitle` must move into `sealedPayload`.

### Fix D — Android `parseCLISession` sealed-read branch (mirror iOS `decodeDocument`)
`android/.../data/square/ThreadInboxStore.kt:195–224`. iOS reference: `CLIAgentChatReader.swift:224–228` — if `data["contentSealed"]==true || data["sealedPayload"]!=null`, require vault key, open `sealedPayload`. Android must:
1. Add imports `AndroidCloudVaultKeyAccess`, `CloudVaultCrypto` (currently absent).
2. In `refreshFromCloud` (ThreadInboxStore.kt:125, before the `mapNotNull` at line 147), fetch `val vaultKey = runCatching { AndroidCloudVaultKeyAccess.keyForReading(uid, firestore)?.keyData }.getOrNull()` and thread it into `parseCLISession`.
3. In `parseCLISession`, branch:
```
if (data["contentSealed"] == true || data["sealedPayload"] != null) {
    val key = vaultKey ?: return null
    val env = CloudVaultCrypto.sealedPayloadFromMap(data["sealedPayload"] as? Map<*,*>) ?: return null
    val json = CloudVaultCrypto.openPayload(env, key).toString(Charsets.UTF_8)
    // decode CLIAgentSessionRecord JSON: title, preview, messages[], customTitle,
    // workspaceLabel, modelName, resumeHandle, labelColorHex, isPinned, priorityOrder
}
```
Mirror the JSON field names from the iOS sealed record (`CLIAgentSessionRecord` Codable). Top-level fallbacks (`agent`, `updatedAt`, `labelColorHex`, `isPinned`, `priorityOrder`) stay; `title`/`preview`/`messages`/`customTitle`/`workspaceLabel`/`modelName` come from inside `sealedPayload`. Use a kotlinx `@Serializable` record matching iOS keys (see `AssistantChatHistoryStore` sealed-read at line 564–569 for the exact Android idiom). **Android primitives confirmed present:** `CloudVaultCrypto.openPayload`, `sealedPayloadFromMap`, `AndroidCloudVaultKeyAccess.keyForReading` (CloudVaultCrypto.kt:135,158,256).

## 5. PRODUCT FORK

**Fork B/A (rules coverage for client status writes):** `cancelMission` is a user-initiated UPDATE to `cli_agent_mission_requests`, but the only `allow update` predicates (rules 1231–1237) are trusted-Mac, mobile-approval-response, and refusal/failure — **none covers a phone-initiated cancel**. Either (i) extend `validMobileMissionApprovalResponse`-style with a new `validMobileMissionCancel()` predicate permitting `{status→cancelled, contentSealed, sealedStatePayload, sealedStateSchemaVersion, sealedStateVaultKeyID, updatedAt}` diff, OR (ii) route cancel through a Cloud Function (like `respondMissionApproval`). Verify whether the pre-tightening cancel even passed; if cancel currently relies on a now-removed permissive branch, this is a second-order rules gap that must be fixed in lockstep. Recommend (i) — keep the seal client-side, add one rules predicate.

**Fork C (rename design):** (a) **Full re-seal** (recommended, mirrors `AssistantChatHistoryStore`): phone reads + re-seals whole record on rename. Cost: extra read + dependency on vault key at rename time; benefit: zero schema change, `customTitle` stays private, single source of truth. (b) **Dedicated sealed metadata field** (e.g. add `sealedCustomTitle` using `validCloudSealedText` like `text_snippets.sealedTitle`, rules 449): add to both mirror `hasOnly` lists + a `validCloudSealedText` check, write only that field on rename. Cost: schema + rules churn on two collections + Mac writer must populate it too; benefit: partial-write rename without re-sealing transcript. **Recommend (a)** — lower drift, already proven on `mobile_assistant_chats`.

## 6. BLAST RADIUS
- **Rules:** if Fork B(i) chosen, add `validMobileMissionCancel()` to `cli_agent_mission_requests` update branch (rules ~1231). No rule change needed for C(a) or D.
- **Tests:** `OpenBurnBarMobileTests/CLIAgents/CLIAgentChatReaderTests.swift`, `CLIAgentSessionCodecTests.swift`; `OpenBurnBarCore/Tests/.../CLIAgentSessionCodecTests.swift`; Android `android/app/src/test/java/com/openburnbar/data/missions/MissionGroupObserverTest.kt`, `MobileMissionConsoleHostTest.kt`; add an Android `ThreadInboxStore` sealed-read test and an iOS cancel/merge sealed-write test. Any firestore.rules emulator test suite covering cli_sessions/mission_groups/mission_requests.
- **Clients:** all four files (iOS CLIAgentMissionDispatcher.swift, iOS CLIAgentChatReader.swift, Android ThreadInboxStore.kt, Android CLIAgentMissionDispatcher.kt is already correct — reference only).
- **Generated/shared:** `OpenBurnBarCore/.../CLIAgentSessionRecord.swift` codec is shared Mac+iOS (no change needed; already seals customTitle). Android needs a new `@Serializable` mirror struct for the sealed CLI-session record.
- **Docs:** SOTA remediation plan (`docs/SOTA_REMEDIATION_PLAN.md`) and any sealing-surface inventory in `droid-wiki/` / mem0.

## DESIGN BRIEF
1. **iOS `cancelMission`** — `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift:526–541`: remove raw `"liveSummary"`; await `MobileCloudVaultKeyAccess.keyForWriting(uid:)`; seal `CLIAgentMissionPrivatePayload(liveSummary: "Mission cancelled by user.")` via `CLIAgentMissionCloudSealer.seal`; write `status:"cancelled"`, `contentSealed:true`, `sealedStatePayload`, `sealedStateSchemaVersion:1`, `sealedStateVaultKeyID`, `updatedAt`. (Schema = Android `sealedMissionStateUpdate`, dispatcher.kt:93–119.)
2. **Rules (Fork B(i))** — add `validMobileMissionCancel()` to `cli_agent_mission_requests` `allow update` (firestore.rules ~1231) permitting diff `hasOnly(["status","contentSealed","sealedStatePayload","sealedStateSchemaVersion","sealedStateVaultKeyID","updatedAt"])` with `status=="cancelled"`. First verify the pre-tightening cancel path; fix the gap in lockstep.
3. **iOS `mergeMissionGroup`** — `CLIAgentMissionDispatcher.swift:484–501`: drop raw `"synthesisSummary"`; seal it into `sealedStatePayload` (`CLIAgentMissionPrivatePayload(synthesisSummary:)`) with `contentSealed:true`/`sealedStateSchemaVersion:1`/`sealedStateVaultKeyID`; keep `phase`/`winnerMissionID`/`updatedAt`; `merge:true`. Satisfies `validMissionGroup` (rules 1366–1393); reader already opens `sealedStatePayload`.
4. **iOS `updateSessionMetadata`** — `CLIAgentChatReader.swift:144–174`: stop writing top-level `customTitle` (line 156). Read current record via `decodeDocument`+vault key, set `record.customTitle`, re-`encodeSealed`, `setData(merge:true)`. Keep `labelColorHex`/`isPinned`/`priorityOrder` top-level. (Mirror `MobileChatHistoryStore`/Android `AssistantChatHistoryStore.updateThreadMetadata`.)
5. **Android `updateSessionMetadata`** — `ThreadInboxStore.kt:159–191`: same as #4; stop writing top-level `customTitle` (line 175); re-seal full record into `sealedPayload`.
6. **Android `parseCLISession` sealed read** — `ThreadInboxStore.kt:195–224`: add `AndroidCloudVaultKeyAccess`+`CloudVaultCrypto` imports; fetch `keyForReading` in `refreshFromCloud` (before line 147); branch on `contentSealed==true || sealedPayload!=null` → `sealedPayloadFromMap` + `openPayload` → decode `@Serializable` mirror of `CLIAgentSessionRecord` (fields: `title, preview, messages[], customTitle, workspaceLabel, modelName, resumeHandle, labelColorHex, isPinned, priorityOrder`). Keep plaintext path for legacy/unsealed docs. (Mirror iOS `decodeDocument` CLIAgentChatReader.swift:224–234 and Android `AssistantChatHistoryStore` sealed-read line 564.)
7. **Leave iOS `respondToApproval` unchanged** — `CLIAgentMissionDispatcher.swift:503–524` correctly delegates to callable `respondMissionApproval` (computerUseSecurity.ts:315), which writes no private text.
8. **Tests** — update iOS `CLIAgentChatReaderTests`/`CLIAgentSessionCodecTests` for sealed-customTitle round-trip + sealed cancel/merge; add Android `ThreadInboxStore` sealed-read test + mission cancel/merge sealed-write assertions; refresh firestore.rules emulator tests for the new cancel predicate.

**Sealed field names to use (copy-paste):** mission request/group request body → `sealedPayload` with `CLIAgentMissionPrivatePayload{title,prompt,targetProject,liveSummary,resultPreview,errorMessage,approvalTitle,approvalMessage,personaScopeJSON,synthesisSummary}`; mission state/merge → `sealedStatePayload` + `sealedStateSchemaVersion:1` + `sealedStateVaultKeyID` + `contentSealed:true`; cli_sessions record → full `CLIAgentSessionRecord` JSON in `sealedPayload` + `sealedSchemaVersion:1` + `vaultKeyID` + `contentSealed:true`, with `customTitle` living **only** inside that JSON.