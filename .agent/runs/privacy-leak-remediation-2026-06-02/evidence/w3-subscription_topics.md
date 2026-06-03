I have everything needed for a precise design brief.

---

## RECON FINDINGS — `users/{uid}/subscription_topics/{topicId}`

**What the collection is:** Per-agent push-notification subscription consent records (Hermes Square). One doc = "user subscribed to agent X's update topic, at this cadence/delivery mode." Doc ID = `<agentURI>:<topicID>` with `/` and `:` replaced by `_` (e.g. `agent__burnbar_research-scout_agent-updates`).

**(1) WRITERS and exact plaintext fields written**

- **iOS** `OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift`:
  - `encodeTopic` (`:1229-1243`) → full upsert via `upsert`/`subscribe` (`:1109-1118`, `:1072-1083`) writes: `agentURI`, `topicID`, **`displayName`**, **`description`**, `cadence`, `consentGivenAt`, `isMuted`, `deliveryMode`, `minimumEventImportance`, `deliveryCountThisMonth`, `lastDeliveredAt`, `updatedAt`.
  - `setDeliveryMode` (`:1092-1101`) merge-writes: `deliveryMode`, `minimumEventImportance`, `isMuted`, `updatedAt`.
  - `setMuted` (`:1144-1153`) merge-writes: `isMuted`, `deliveryMode`, `minimumEventImportance`, `updatedAt`.
- **Android** `android/app/src/main/java/com/openburnbar/data/square/AgentSubscriptionTopicStore.kt` `writeFirestore` (`:178-198`): `agentURI`, `topicID`, **`displayName`**, **`description`**, `cadence`, `consentGivenAt`, `isMuted`, `deliveryMode`, `minimumEventImportance`, `deliveryCountThisMonth`, `updatedAt`.
- **Mac (AgentLens):** NONE — grep of `AgentLens/` returns zero. Phone/tablet-only writes (matches the rule comment at `:1665-1667`).

**Private-text fields:** `agentURI`, `topicID`, `displayName`, `description`. The text is **agent/manifest-derived, not free-typed prose** — `displayName` = `"\(identity.displayName) updates"`, `description` = a templated string from `AgentBrandQuickActionComposer.defaultSubscriptionTopic` (`:921-939`) / Android `:99`. `AgentIdentity.displayName` is fixed-enum for built-ins but **manifest/QR/URL-supplied for third-party & user-installed agents** (`AgentIdentity.swift:59-67,85-87`). The genuinely sensitive datum is the **subscription graph itself**: `agentURI` reveals *which agents the user follows* (a behavioral fingerprint), and `displayName`/`description` echo that agent in cleartext.

**(2) READERS** (all hold the vault key; all on the user's own devices)
- iOS realtime listener `restartRealtimeListener` → `decodeTopic` (`AgentBrandZoneView.swift:1185-1199`, `:1251-1286`); rendered at `HermesSquareSubscriptionsFolder.swift:77` (`displayName`), `:118` (`description`).
- Android listener `restartFirestoreListener` → `decodeFirestoreTopic` (`AgentSubscriptionTopicStore.kt:162-175`, `:208-223`); rendered at `HermesSquareDiscoverSheetSections.kt:538`.
- Local cache mirrors: Android SharedPreferences `save`/`load` (`:246-262`, `:225-244`).
- **No web/console reader. No Mac reader.**

**(3) SERVER-READ REQUIREMENT — NONE.** Zero Cloud Functions read this collection for any logic. `grep "subscription_topics" functions/src services/hosted-mcp` = empty. The only hit is a **dormant type** `SubscriptionTopicDoc` in `functions/src/types/legacy.ts:3077` with **zero referencing code**. No push-delivery function consumes `displayName`/`description`/`agentURI` server-side. Proof: `grep -rn "SubscriptionTopicDoc" functions/src` → only the interface declaration line; no callable, trigger, or scheduled job. **Pure store-and-forward between the user's own devices.** → SEAL is safe; no server matching/routing needs the plaintext.

**(4) VAULT-KEY availability for every reader:** YES for all. iOS/Mac via `CloudVaultKeyStore`; Android via `AndroidCloudVaultKeyAccess.keyForReading(uid:)` (`CloudVaultCrypto.kt:256`) / `keyForWriting` (`:253`). The server (the only non-key-holder) is not a reader. No reader is locked out by sealing.

**(5) Current rule block** (`firestore.rules:1675-1685`) — **no field allowlist, plaintext text allowed:**
```
match /users/{userId}/subscription_topics/{topicId} {
  allow read: if ownsUserNamespace(userId);
  allow create, update: if ownerWritableNonSecret(userId)
    && request.resource.data.keys().size() <= 20
    && (!("cadence" in request.resource.data) || request.resource.data.cadence in ["on_demand","daily","weekly","monthly"])
    && (!("deliveryMode" in request.resource.data) || ... ["action_only","full_stream","muted"])
    && (!("minimumEventImportance" in request.resource.data) || ... ["quiet","normal","action_required","terminal"])
    && (!("deliveryCountThisMonth" in request.resource.data) || (... is int && ... <= 64));
  allow delete: if ownsUserNamespace(userId);
}
```
Weaknesses: bare `size() <= 20` (no `hasOnly`), accepts plaintext `displayName`/`description`, no sealed-text validation. Helpers to reuse already exist: `validCloudSealedText` (`:449-478`) and `rejectsPlaintextWhenSealed` (`:1013-1016`).

**(6) Registry domain ownership:** `subscription_topics` is in **`excludedCollections`** (`packages/data-domains/registry.json:244`: `"Push-notification topic subscriptions."`) — it is NOT a surfaced privacy data domain (no `serverSees`/`deviceOnly` to fix). Honesty edit = tighten that one-line reason to state the contract: opaque + sealed, phone/tablet-only, server never reads. After editing run `node packages/data-domains/codegen.mjs` then `cd android && ./gradlew :app:syncGeneratedSources` (never hand-edit `gen/*` or `DataDomains.kt`).

**(7) Tests to add** (mirror `test-firestore-rules.mjs` T12 at `:3110-3163`, using the `sealedText()` helper at `:134`): legacy plaintext `displayName`/`description` row still syncs; sealed-only row accepted; row with BOTH sealed+plaintext denied; over-allowlist key denied (`hasOnly`). Plus a Swift round-trip test (seal→write→`decodeTopic` legacy-fallback path) and a Kotlin round-trip test (`decodeFirestoreTopic` sealed branch via `AndroidCloudVaultKeyAccess.keyForReading` + `CloudVaultCrypto.openText`).

---

## DESIGN BRIEF

This surface **DOES carry private text** (the subscription graph: which agents the user follows, echoed in `displayName`/`description`, plus `agentURI`/`topicID` in the doc ID). It is **pure store-and-forward; no server reads it.** Default fix applies: **seal the free-text fields + add a `hasOnly` allowlist**, mirroring the usage/budget `rejectsPlaintextWhenSealed` pattern. `agentURI`/`topicID` stay plaintext-functional (they are the routing/uniqueness key and the doc ID is already derived from them — sealing them would break listener `order(by:)`, dedup, and unsubscribe-by-id; they are agent identifiers, not user prose, lower sensitivity). Seal only the two display strings; if Alberto wants to also cloak *which agent* is followed, that requires opaque doc IDs + token-hashed `agentURI` (call out as an optional escalation, not the minimal fix).

1. **iOS writer** `OpenBurnBarMobile/Views/Hermes/Square/AgentBrandZoneView.swift` `encodeTopic` (`:1229-1243`): REMOVE plaintext `"displayName"` and `"description"`; ADD `"sealedDisplayName": CloudVaultCrypto.sealedText dict` (seal of `topic.displayName`) and `"sealedDescription"` (seal of `topic.description`), via `CloudVaultCrypto.sealText(_, keyData:)` using the resolved vault key. Keep `agentURI`, `topicID`, `cadence`, `consentGivenAt`, `isMuted`, `deliveryMode`, `minimumEventImportance`, `deliveryCountThisMonth`, `lastDeliveredAt`, `updatedAt`. (`displayName`/`description` are never empty — derived from the factory at `:929-932`.)

2. **iOS reader** `decodeTopic` (`:1251-1286`): read `sealedDisplayName`/`sealedDescription` via `CloudVaultCrypto.openText(_, keyData:)`; **legacy fallback** — if the sealed field is absent, read the old plaintext `data["displayName"]`/`data["description"]` (so in-flight/legacy docs still render). Keep the existing `displayName.isEmpty ? documentID : displayName` fallback.

3. **Android writer** `AgentSubscriptionTopicStore.kt` `writeFirestore` (`:178-198`): REMOVE `"displayName"`/`"description"`; ADD `"sealedDisplayName"`/`"sealedDescription"` via `CloudVaultCrypto.sealText(text, vaultKey)` + `sealedPayloadMap`/text dict, resolving the key with `AndroidCloudVaultKeyAccess.keyForWriting(uid)`. (This makes `writeFirestore` a `suspend` call or wraps the key fetch — mirror the existing chat sealed-write path on Android.)

4. **Android reader** `decodeFirestoreTopic` (`:208-223`): add a sealed branch — `CloudVaultCrypto.openText` on `sealedDisplayName`/`sealedDescription` using `AndroidCloudVaultKeyAccess.keyForReading(uid)`; **keep the plaintext `data["displayName"]`/`data["description"]` fallback** for legacy docs. Local SharedPreferences cache (`save`/`load`, `:246-262`/`:225-244`) is on-device-only and may keep plaintext.

5. **firestore.rules** `subscription_topics` block (`:1675-1685`) — replace the bare `size()<=20` gate with a `hasOnly` allowlist + seal validation, reusing existing helpers `rejectsPlaintextWhenSealed` (`:1013-1016`) and `validCloudSealedText` (`:449-478`):
```
match /users/{userId}/subscription_topics/{topicId} {
  allow read: if ownsUserNamespace(userId);
  allow create, update: if ownerWritableNonSecret(userId)
    && request.resource.data.keys().hasOnly([
      "agentURI","topicID","sealedDisplayName","sealedDescription",
      "cadence","consentGivenAt","isMuted","deliveryMode",
      "minimumEventImportance","deliveryCountThisMonth","lastDeliveredAt","updatedAt",
      "displayName","description"   // legacy plaintext — tolerated only when its sealed copy is ABSENT
    ])
    && rejectsPlaintextWhenSealed("displayName", "sealedDisplayName")
    && rejectsPlaintextWhenSealed("description", "sealedDescription")
    && (!("sealedDisplayName" in request.resource.data) || validCloudSealedText(request.resource.data.sealedDisplayName))
    && (!("sealedDescription" in request.resource.data) || validCloudSealedText(request.resource.data.sealedDescription))
    && (!("cadence" in request.resource.data) || request.resource.data.cadence in ["on_demand","daily","weekly","monthly"])
    && (!("deliveryMode" in request.resource.data) || request.resource.data.deliveryMode in ["action_only","full_stream","muted"])
    && (!("minimumEventImportance" in request.resource.data) || request.resource.data.minimumEventImportance in ["quiet","normal","action_required","terminal"])
    && (!("deliveryCountThisMonth" in request.resource.data) || (request.resource.data.deliveryCountThisMonth is int && request.resource.data.deliveryCountThisMonth <= 64));
  allow delete: if ownsUserNamespace(userId);
}
```
   - Merge semantics: writers use `merge:true`; the `setMuted`/`setDeliveryMode` partial writes (`displayName`/`description` absent) pass `hasOnly` and `rejectsPlaintextWhenSealed` trivially. Once writers reseal, the two legacy plaintext keys can be dropped from the allowlist in a follow-up flag-day.

6. **Type** `functions/src/types/legacy.ts` `SubscriptionTopicDoc` (`:3077`): make `displayName?`/`description?` optional and add `sealedDisplayName?: CloudVaultSealedTextDoc`, `sealedDescription?: CloudVaultSealedTextDoc` (keeps the dormant type honest; no server logic change since nothing reads it).

7. **Registry honesty** `packages/data-domains/registry.json:244`: change the `excludedCollections` reason to reflect the sealed/opaque contract, e.g. `"subscription_topics": "Per-agent push-subscription consent; topic display text is vault-sealed, written phone/tablet-only, never server-read."` Then run `node packages/data-domains/codegen.mjs` + `cd android && ./gradlew :app:syncGeneratedSources`.

8. **Tests** (`functions/scripts/test-firestore-rules.mjs`, mirror T12 `:3110-3163`, `sealedText()` at `:134`): (a) legacy `{displayName,description}`-only row → `assertSucceeds`; (b) `{sealedDisplayName,sealedDescription}` row → `assertSucceeds`; (c) `{sealedDisplayName, displayName}` both → `assertFails`; (d) `{sealedDescription, description}` both → `assertFails`; (e) row with a non-allowlisted key (e.g. `foo`) → `assertFails`. Plus Swift round-trip (`decodeTopic` sealed + legacy-fallback) and Kotlin round-trip (`decodeFirestoreTopic` sealed branch + legacy-fallback).

**SERVER-READ verdict: NONE** — no Cloud Function reads `subscription_topics`; the only reference is the unused `SubscriptionTopicDoc` type at `functions/src/types/legacy.ts:3077`. Seal `displayName`/`description` with the vault key (legacy plaintext fallback on read) and add the `hasOnly` allowlist; no keyed-hash needed. (Optional escalation, only if Alberto wants the *subscription graph* itself cloaked: opaque doc ID + token-hashed `agentURI` — out of scope for the minimal fix.)