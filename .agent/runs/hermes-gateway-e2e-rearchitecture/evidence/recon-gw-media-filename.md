Confirmed. No Android writer/reader, no console reader (only generated domain metadata for counting). The only code that touches the `filename` value at the Firestore boundary is `dataExport.ts` (verbatim dump) and `dataDomainUsage.ts` (count-only). 

I have completed the exhaustive trace. Here is the design brief.

---

## FINDINGS SUMMARY

**The real Firestore writer of `users/{uid}/media_attachment_manifests/{id}` does not exist in code yet.** This is the load-bearing discovery. The collection is Phase-1 "compile-only, no server writes yet" (`docs/runbooks/media-rollout-status.md:53`). The doc shape, the rule, and the rule test (T9) all exist, but no Swift/Kotlin/TS code path calls `setData`/`set()` on this collection today.

What exists and where the plaintext filename lives in-memory:
- **Manifest producer (not a Firestore writer):** `OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFileTransferService.swift:120-128` builds `HermesRealtimeRelayAttachmentManifest(filename: fileURL.lastPathComponent, …)`. This is the iroh control-frame manifest, not the Firestore doc.
- **iOS adapter:** `OpenBurnBarMobile/Services/Media/iOSFileTransferService.swift:170-181, 277-291` emits a `TransferCompletion`/`AttachmentTransferRecord` carrying plaintext `filename` from `manifest.filename`.
- **iOS sink (local only):** `AppDelegate.swift:59-76` wires `receiver.onTransferCompleted` → `MercuryTransferHistoryStore.shared.append(...)`. `MercuryTransferHistoryStore.swift:91-101` writes a **local JSON file in Application Support** — never Firestore.
- **Mac adapter:** `AgentLens/Services/Media/MacFileTransferService.swift` has no `onTransferCompleted` / no Firestore write at all.

**The writer is intended to be a CLIENT (owner-device) write**, not server: rule `firestore.rules:2809` is `allow create: if ownerWritableNonSecret(userId) && hasActiveHostedMediaEntitlement(userId) && …`. So the seal happens on-device with the vault key — exactly the model the rest of this remediation uses.

**SERVER-READ requirement: definitively NO.** `mediaQuota.ts` reads only `iroh_audit_events`/`media_session_events` (never the manifest/filename). `mediaMonitoring.ts` has zero references to the manifest or filename. `dataDomainUsage.ts:68` only *counts* docs in the collection. `dataExport.ts:163` dumps the collection verbatim (it would echo plaintext filename if present, but does not require it). No function needs the cleartext name → **full seal; no keyed hash needed.**

**Type already prepped:** `functions/src/types/legacy.ts:2702-2721` — `filename?` is `@deprecated`, `sealedFilename?: CloudVaultSealedTextDoc` already added.

---

## DESIGN BRIEF

1. **Build the missing writer as an on-device sink that seals, then drop the plaintext rule branch.** Because no writer exists today, this slice both *creates* the canonical Firestore writer and *hardens* it in one pass — there is no legacy producer to retrofit. The writer is a new iOS sink (and a symmetric Mac sink if/when Mac persists manifests) that runs in place of / alongside the existing local-JSON history append.

2. **New iOS Firestore writer — `OpenBurnBarMobile/App/AppDelegate.swift:59-76` (sink wiring) backed by a new store method.** In the `receiver.onTransferCompleted` closure, after appending to `MercuryTransferHistoryStore`, also write the sealed manifest doc. Concretely, add a method `func persistManifest(_ completion: iOSFileTransferService.TransferCompletion) async` to a Firestore-aware store (new file `OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift`, mirroring how `BudgetRulesStore` seals + writes). It must:
   - Resolve the vault key: `let resolved = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid)` (signature at `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift:26`), using `resolved.keyData`.
   - Seal the filename exactly like the ratified pattern (`BudgetRulesStore.swift:222-224`):
     ```swift
     let sealed = try CloudVaultCrypto.dictionary(
         CloudVaultCrypto.sealText(completion.filename, keyData: resolved.keyData)
     )
     ```
   - Build the doc with `sealedFilename: sealed` and **omit `filename` entirely** (rule rejects co-emitting). Fields must be the exact `hasOnly` set (`firestore.rules:2794-2806`): `id, blobHash, sealedFilename, mime, size, peerDeviceIdHash, direction, createdAt, expireAt?, schemaVersion`. `id == manifestId`; `peerDeviceIdHash` = SHA-256 of the peer NodeId (never plaintext — derive from `completion.connectionID`/manifest peer id); `direction` from `completion.direction` (`.sent → "iosToMac"` is wrong: map by who sent — `sent → "iosToMac"` only if iOS is sender; use `macToIos`/`iosToMac` per the actual sender, consistent with the manifest's perspective); `schemaVersion: 1`; write path `users/\(uid)/media_attachment_manifests/\(manifestId)` via `setData(doc, merge: false)`.
   - Gate on the media entitlement (rule requires `hasActiveHostedMediaEntitlement`); skip the write silently if absent so the local history still records.

3. **Symmetric Mac writer (only if Mac is meant to persist manifests).** `AgentLens/Services/Media/MacFileTransferService.swift` currently emits no completion and writes nothing. If product intent is that the Mac also records its sent/received manifests (the rule is per-owner and direction has a `macToIos` case, implying Mac writes too), add a `onTransferCompleted`-equivalent + a `MacMediaAttachmentManifestStore` that seals via `CloudVaultKeyAccess.keyForWriting(uid:deviceId:firestore:)` (`AgentLens/Services/CloudVaultKeyAccess.swift:28`) and `CloudVaultCrypto.dictionary(CloudVaultCrypto.sealText(filename, keyData:))`. **Honest note:** confirm with the orchestrator whether Mac is a writer at all — today it is not, and the `macToIos` direction value suggests the doc is written from whichever side initiates. Pick one writer-of-record per direction to avoid double-writes (manifestId is shared, but `allow update: if false`, so the second writer's `setData(merge:false)` of the same id would fail — choose a single owner).

4. **Android: not a writer/reader today — no change required, but mirror if Android becomes a media endpoint.** No Kotlin reads or writes this collection. If Android later writes manifests, seal via `CloudVaultCrypto.sealText(filename, vaultKey)` + `sealedPayloadMap`/`dictionary` equivalent (`android/.../data/cloud/CloudVaultCrypto.kt:67`) with `AndroidCloudVaultKeyAccess.keyForWriting`. Flag as out-of-scope for this pass.

5. **Readers — open with legacy fallback.** There is no Firestore *reader* of the manifest `filename` in native UI today (iOS reads the local-JSON `MercuryTransferHistoryStore`, not Firestore). The only consumers at the Firestore boundary are server-side and must NOT decrypt:
   - `functions/src/callables/dataExport.ts:163` — `collectInlineJson` dumps the collection verbatim. Once writers seal, this naturally exports `sealedFilename` (an opaque envelope) and no plaintext. **Tie-in to Stream SA's `sealAwareSerializeDoc`** (CONTRACT §5): under `end_to_end`/`zero_access` tiers it must treat `sealedFilename` as a passthrough sealed envelope and never expect/echo `filename`. No filename-specific code change needed here beyond confirming `media_attachment_manifests` rides the seal-aware allowlist; add `sealedFilename` to the recognized sealed-envelope keys.
   - `functions/src/callables/dataDomainUsage.ts:68` — count-only; no change.
   - **Future native reader rule:** any client that later reads the manifest for display must decode `sealedFilename` via `CloudVaultCrypto.openText` with a legacy fallback to plaintext `filename` (per CONTRACT.md:11 — "if the new sealed field is absent, read the old plaintext field"). Document this contract in the store; no such reader exists to change now.

6. **Firestore rule hardening — `firestore.rules:2792-2834`.** The rule already accepts `sealedFilename` + rejects co-emitted plaintext (`:2819-2825`) and bounds legacy `filename` to ≤256 (`:2826-2829`). **Once the sealing writer ships (steps 2-3), drop the plaintext-filename acceptance branch** so the server can never store a cleartext name:
   - Remove `"filename"` from the `validMediaAttachmentManifestKeys()` `hasOnly` allowlist (`:2798`).
   - Replace the "sealed OR plaintext present" clause (`:2821`) with a hard requirement: `&& ("sealedFilename" in request.resource.data) && validCloudSealedText(request.resource.data.sealedFilename)`.
   - Delete the legacy-filename branches (`:2822-2829`).
   - Keep `!("body"...)` / `!("ciphertext"...)` denials (`:2830-2831`).
   - **Sequencing/honesty:** this is the flag-day. Ship the writer first (or behind a build that always seals), confirm no in-flight plaintext writers remain, then drop the branch. Because there is no legacy on-device writer (the collection has never been written from native code), there is effectively **no legacy migration debt** — you can drop the plaintext branch in the same PR as the writer. Note this in the registry/honesty line: the previously-documented `[incomplete]` "if the media writer can't be cleanly updated this pass, bound filename ≤256" escape hatch (CONTRACT §6, rules:2447 note) is **not needed** — the writer can be created clean.

7. **Tests (owned by this slice, same stream as the code per CONTRACT §STREAM OWNERSHIP — Rules tests are SD's; the Swift writer tests are this slice's).**
   - **Rules test — update T9** at `functions/scripts/test-firestore-rules.mjs:2985-3032`: after dropping the plaintext branch, flip the "legacy plaintext filename still syncs" case (`:3007-3013`) from `assertSucceeds` to `assertFails`, and add a case that a manifest with **neither** `sealedFilename` nor `filename` fails (sealed now mandatory). Keep the `both-1` rejection and `hasOnly` smuggled-key rejection.
   - **iOS writer test** (new, e.g. `OpenBurnBarMobileTests/Media/MediaAttachmentManifestStoreTests.swift`): seal a filename via `CloudVaultCrypto.sealText` with a fixture key, assert the produced doc dict has `sealedFilename` (a `{algorithm:"AES-256-GCM",keyVersion:1,nonce,ciphertext,tag}` dict), has **no** `filename` key, has exactly the allowlisted keys, and round-trips: `CloudVaultCrypto.openText(sealed, keyData:) == filename`. Mirror the existing `BudgetRulesStore` seal test style.
   - **Interop:** filename uses the canonical sealed-text envelope already gated by `OpenBurnBarCoreTests/CloudVaultCryptoTests.swift` and `apps/console/test/interop.test.ts`; no new interop fixture needed (it's the same `CloudVaultSealedText` shape), but add `sealedFilename` to any dataExport seal-aware test fixture in SA's stream.

8. **Type / server-validator note.** `functions/src/types/legacy.ts:2702-2721` is already correct (`filename?` deprecated, `sealedFilename?: CloudVaultSealedTextDoc`). After the rule flag-day, the writer always emits `sealedFilename`; you may keep `filename?` optional in the type for one release to read any in-flight doc, then remove. No server callable validates this collection's writes (it's a direct client write gated by rules), so there is **no `requireSealedText` server validator to add** — the rule's `validCloudSealedText` is the enforcement point.

9. **Registry / honesty (Stream SE coordination).** `packages/data-domains/registry.json` `media` domain currently lists `media_attachment_manifests` as a server-visible audit collection. After sealing: update the `media` domain so `filename`/`names` move to `deviceOnly` and `serverSees` for this collection notes only `blobHash`, `mime`, `size`, opaque `peerDeviceIdHash`, `direction`, timestamps — **the human-readable filename is sealed (server-blind).** Then regenerate (`node packages/data-domains/codegen.mjs` + `cd android && ./gradlew :app:syncGeneratedSources`) per CONTRACT §8 — never hand-edit `gen/*`. Add `media_attachment_manifests` filename coverage to the privacy scanner (`scripts/privacy/scan-chat-cloud-plaintext.mjs`, which already references the collection) so a future regression that writes plaintext `filename` is caught.

**Single most important callout for the orchestrator:** this slice is *additive*, not a retrofit — the Firestore manifest writer is unimplemented, so the only safe-and-complete move is to (a) create the sealing writer, (b) decide the single writer-of-record per direction (iOS vs Mac) to respect `allow update: if false`, and (c) drop the plaintext-`filename` rule branch in the same PR (no legacy on-device plaintext writer ever existed, so there is no migration window to preserve). Full seal, no keyed hash — confirmed no server reader needs the cleartext name.

Relevant file paths (all absolute):
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaFileTransferService.swift` (manifest producer, plaintext filename origin, lines 120-128)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/Media/iOSFileTransferService.swift` (TransferCompletion carries plaintext filename, 170-181 / 277-291)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/App/AppDelegate.swift` (sink wiring, 59-76 — add seal+write here)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Features/Mercury/Stores/MercuryTransferHistoryStore.swift` (local-JSON only, NOT Firestore)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Models/BudgetRulesStore.swift` (canonical seal pattern, 222-231)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift` (keyForWriting:26 / keyForReading:55)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/Media/MacFileTransferService.swift` (Mac adapter — no Firestore write today)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/AgentLens/Services/CloudVaultKeyAccess.swift` (Mac keyForWriting:28)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules` (rule 2792-2834 — drop plaintext branch)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/types/legacy.ts` (MediaAttachmentManifestDoc, 2702-2721 — already sealed-ready)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/mediaQuota.ts` + `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/mediaMonitoring.ts` (confirmed: no filename read → full seal)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/dataExport.ts:163` + `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/dataDomainUsage.ts:68` (only server consumers; dump/count)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/scripts/test-firestore-rules.mjs` (T9, 2985-3032 — flip legacy-accept to reject)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/docs/runbooks/media-rollout-status.md:53` (confirms "no server writes yet")